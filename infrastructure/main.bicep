// =============================================================================
// uap-clc3-2026 — main deployment (subscription scope)
//
// Deploys the complete exercise infrastructure into ONE resource group in ONE
// region (pass the region from scripts/preflight.sh as 'location'):
//   - Resource group
//   - Log Analytics + Application Insights
//   - Storage account (GPv2) with 'imageanalysis' container + Event Grid topic
//   - Microsoft Foundry resource (AIServices) + project + gpt-5-mini deployment
//   - Cosmos DB for NoSQL (serverless) — database ImageAnalysis / container results
//   - Azure Functions app on the Flex Consumption plan (FC1) with system identity
//     (the Event Grid subscription -> function 'AnalyzeImage' is created AFTER the
//      function code is published — see .github/workflows/function-deploy.yml —
//      because the webhook endpoint is validated against the published function)
//   - Container Apps environment + ACR + upload app (image placeholder)
//   - All RBAC role assignments (managed identities only, no keys in code)
//
// Usage (from the repo root):
//   az deployment sub create --template-file infrastructure/main.bicep \
//     --location <region-from-preflight> --name clc3-2026 \
//     --parameters rgName=rg-clc3-<lastname> location=<region-from-preflight> uploadToken=<random>
// =============================================================================

targetScope = 'subscription'

@description('Name of the deployment (used for deployment history).')
param deploymentName string = 'clc3-2026'

@description('Name of the resource group to create. Use your lastname to avoid collisions: rg-clc3-<lastname>')
param rgName string

@description('Azure region for ALL resources. Take this from scripts/preflight.sh output (RECOMMENDED LOCATION).')
param location string

@description('Vision model deployed into the Foundry project.')
param modelName string = 'gpt-5-mini'

@description('Model version. NOTE: gpt-4o-mini (2024-07-18) is Deprecating and REJECTED for new deployments (verified 2026-11-14) — we default to gpt-5-mini (2025-08-07, GA). Check the deprecations page before the next semester.')
param modelVersion string = '2025-08-07'

@description('Deployment SKU (GlobalStandard = pay-per-token, cheapest for the exercise).')
param modelSkuName string = 'GlobalStandard'

@description('Deployment capacity (minimum 1). Tokens are the real cost driver, not capacity.')
@minValue(1)
param modelCapacity int = 1

@description('Name of the model deployment inside Foundry (used as the model name in SDK calls).')
param modelDeploymentName string = 'gpt-5-mini'

@description('Upload-app container image. Default = public MCR placeholder (pullable; unhealthy until replaced). Set to <acr>.azurecr.io/upload-app:latest to keep the deployed app across infra redeploys (infra-deploy.yml does this automatically when the tag exists).')
param uploadAppImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Shared token for the upload endpoint (X-Upload-Token header). Pass your own (openssl rand -hex 16) so it survives infra redeploys; otherwise a random GUID is used per deployment and must be re-read via "az containerapp secret show".')
@secure()
param uploadToken string = newGuid()

var tags = {
  exercise: 'uap-clc3-2026'
  deployedBy: 'bicep'
}

// short, stable suffix for globally unique resource names.
// uniqueString() returns hex only -> always valid for storage/ACR/Cosmos names,
// and keyed by subscription+rgName so two students with the same rgName in
// different subscriptions cannot collide.
var nameSuffix = take(uniqueString(subscription().subscriptionId, rgName), 16)

module rg 'modules/resourcegroup.bicep' = {
  name: '${deploymentName}-rg' // distinct from the parent deployment name (ARM forbids self-reference)
  scope: subscription()
  params: {
    name: rgName
    location: location
    tags: tags
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: '${deploymentName}-monitoring'
  scope: resourceGroup(rgName)
  dependsOn: [rg] // rg module creates the resource group these modules deploy into
  params: {
    location: location
    nameSuffix: nameSuffix
    tags: tags
  }
}

module storage 'modules/storage.bicep' = {
  name: '${deploymentName}-storage'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    location: location
    nameSuffix: nameSuffix
    tags: tags
    functionAppName: 'func-${nameSuffix}' // deployment package container name prefix
  }
}

module foundry 'modules/foundry.bicep' = {
  name: '${deploymentName}-foundry'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    location: location
    nameSuffix: nameSuffix
    tags: tags
    modelName: modelName
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity
    modelDeploymentName: modelDeploymentName
  }
}

module cosmos 'modules/cosmosdb.bicep' = {
  name: '${deploymentName}-cosmos'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    location: location
    nameSuffix: nameSuffix
    tags: tags
  }
}

module functionApp 'modules/function.bicep' = {
  name: '${deploymentName}-function'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    location: location
    nameSuffix: nameSuffix
    tags: tags
    storageAccountName: storage.outputs.storageAccountName
    blobEndpoint: storage.outputs.blobEndpoint
    deploymentContainerName: storage.outputs.deploymentContainerName
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    foundryProjectEndpoint: foundry.outputs.projectEndpoint
    modelDeploymentName: modelDeploymentName
    cosmosAccountEndpoint: cosmos.outputs.accountEndpoint
  }
}

module containerApp 'modules/containerapp.bicep' = {
  name: '${deploymentName}-containerapp'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    location: location
    nameSuffix: nameSuffix
    tags: tags
    workspaceCustomerId: monitoring.outputs.workspaceCustomerId
    workspaceSharedKey: monitoring.outputs.workspaceSharedKey
    storageAccountName: storage.outputs.storageAccountName
    imageContainerName: storage.outputs.imageContainerName
    uploadAppImage: uploadAppImage
    uploadToken: uploadToken
  }
}

// -----------------------------------------------------------------------------
// RBAC — all access via managed identities (no keys stored in app settings)
// -----------------------------------------------------------------------------
module rbac 'modules/rbac.bicep' = {
  name: '${deploymentName}-rbac'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    storageAccountName: storage.outputs.storageAccountName
    acrName: containerApp.outputs.acrName
    appInsightsName: monitoring.outputs.appInsightsName
    foundryAccountName: foundry.outputs.accountName
    foundryProjectName: foundry.outputs.projectName
    functionPrincipalId: functionApp.outputs.principalId
    containerAppPrincipalId: containerApp.outputs.principalId
  }
}

// Cosmos data-plane role assignment is a child resource of the account itself
module cosmosRbac 'modules/cosmosdb-rbac.bicep' = {
  name: '${deploymentName}-cosmos-rbac'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    cosmosAccountName: cosmos.outputs.accountName
    cosmosDatabaseName: cosmos.outputs.databaseName
    functionPrincipalId: functionApp.outputs.principalId
  }
}

// -----------------------------------------------------------------------------
// Observability — diagnostic settings routing resource logs + metrics of every
// exercise resource into the Log Analytics workspace (ACA env logs and App
// Insights telemetry already land there via appLogsConfiguration /
// workspace-based App Insights). See modules/diagnostics.bicep.
// -----------------------------------------------------------------------------
module diagnostics 'modules/diagnostics.bicep' = {
  name: '${deploymentName}-diagnostics'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    workspaceId: monitoring.outputs.workspaceId
    storageAccountName: storage.outputs.storageAccountName
    systemTopicName: storage.outputs.systemTopicName
    cosmosAccountName: cosmos.outputs.accountName
    acrName: containerApp.outputs.acrName
    foundryAccountName: foundry.outputs.accountName
    foundryProjectName: foundry.outputs.projectName
    functionAppName: functionApp.outputs.name
  }
}

output resourceGroupName string = rgName
output functionAppName string = functionApp.outputs.name
output uploadAppFqdn string = containerApp.outputs.fqdn
output foundryProjectEndpoint string = foundry.outputs.projectEndpoint
output modelDeploymentName string = modelDeploymentName
output cosmosAccountEndpoint string = cosmos.outputs.accountEndpoint
output cosmosDatabaseName string = cosmos.outputs.databaseName
output cosmosContainerName string = cosmos.outputs.containerName
output storageAccountName string = storage.outputs.storageAccountName
output imageContainerName string = storage.outputs.imageContainerName
output acrLoginServer string = containerApp.outputs.acrLoginServer
output acrName string = containerApp.outputs.acrName
output containerAppName string = containerApp.outputs.name
// NOTE: no output for uploadToken — @secure() output values are stripped from
// deployment history and NOT retrievable afterwards (verified empirically).
// Students pass the token explicitly at deploy time (see README step 4) or read
// it back with: az containerapp secret show -n <app> -g <rg> --secret-name upload-token
