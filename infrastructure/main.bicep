// =============================================================================
// uap-clc3-2026 — main deployment (subscription scope)
//
// Deploys the complete exercise infrastructure into ONE resource group in ONE
// region (pass the region from scripts/preflight.sh as 'location'):
//   - Resource group
//   - Log Analytics + Application Insights
//   - Storage account (GPv2) with 'imageanalysis' container + Event Grid topic
//   - Microsoft Foundry resource (AIServices) + project + gpt-4o-mini deployment
//   - Cosmos DB for NoSQL (serverless) — database ImageAnalysis / container results
//   - Azure Functions app on the Flex Consumption plan (FC1) with system identity
//     (the Event Grid subscription -> function 'AnalyzeImage' is created AFTER the
//      function code is published — see .github/workflows/function-deploy.yml —
//      because AzureFunction endpoint validation requires the function to exist)
//   - Container Apps environment + ACR + upload app (image placeholder)
//   - All RBAC role assignments (managed identities only, no keys in code)
//
// Usage:
//   az deployment sub create --template-file infrastructure/main.bicep \
//     --location <region-from-preflight> \
//     --parameters deploymentName=clc3-2026 rgName=rg-clc3-<lastname>
// =============================================================================

targetScope = 'subscription'

@description('Name of the deployment (used for deployment history).')
param deploymentName string = 'clc3-2026'

@description('Name of the resource group to create. Use your lastname to avoid collisions: rg-clc3-<lastname>')
param rgName string

@description('Azure region for ALL resources. Take this from scripts/preflight.sh output (RECOMMENDED LOCATION).')
param location string

@description('Vision model deployed into the Foundry project.')
param modelName string = 'gpt-4o-mini'

@description('Model version. NOTE: gpt-4o-mini (2024-07-18) is reported to retire 2027-01-14 — verify on the official deprecations page and switch this param if needed.')
param modelVersion string = '2024-07-18'

@description('Deployment SKU (GlobalStandard = pay-per-token, cheapest for the exercise).')
param modelSkuName string = 'GlobalStandard'

@description('Deployment capacity (minimum 1). Tokens are the real cost driver, not capacity.')
@minValue(1)
param modelCapacity int = 1

@description('Name of the model deployment inside Foundry (used as the model name in SDK calls).')
param modelDeploymentName string = 'gpt-4o-mini'

var tags = {
  exercise: 'uap-clc3-2026'
  deployedBy: 'bicep'
}

// short, stable suffix derived from the rg name for globally unique resource names
var nameSuffix = '${take(replace(toLower(rgName), '-', ''), 10)}${take(uniqueString(rgName), 6)}'

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
