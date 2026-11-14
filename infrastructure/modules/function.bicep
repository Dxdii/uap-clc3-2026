// Azure Functions app on the FLEX CONSUMPTION plan (FC1) — Python 3.13, system
// assigned identity. Hosts the single function 'AnalyzeImage':
//   blob trigger (Event Grid source) -> Foundry SDK -> Cosmos DB output binding
//
// NOTE: the Event Grid event subscription that feeds the blob trigger is NOT
// created here — an AzureFunction endpoint is validated against the function,
// which only exists after the code is published. It is created right after
// 'func azure functionapp publish' in .github/workflows/function-deploy.yml
// (manual equivalent: see README.md) using the 'functionResourceId' output.

param location string
param nameSuffix string
param tags object

param storageAccountName string
param blobEndpoint string // e.g. https://st....blob.core.windows.net/
param deploymentContainerName string
param systemTopicName string
@secure()
param appInsightsConnectionString string // embeds the App Insights instrumentation key
param foundryProjectEndpoint string
param modelDeploymentName string
param cosmosAccountEndpoint string

var planName = 'asp-${nameSuffix}'
var functionAppName = 'func-${nameSuffix}'
var functionName = 'AnalyzeImage'

resource plan 'Microsoft.Web/serverfarms@2025-03-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp'
  properties: {
    reserved: true // Linux
  }
}

resource site 'Microsoft.Web/sites@2025-03-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    reserved: true
    httpsOnly: true
    siteConfig: {
      appSettings: [
        // Host storage + blob trigger connection via MANAGED IDENTITY
        // (identity-based connection: <PREFIX>__<service>Uri + __credential)
        {
          name: 'AzureWebJobsStorage__blobServiceUri'
          value: blobEndpoint
        }
        {
          name: 'AzureWebJobsStorage__queueServiceUri'
          value: 'https://${storageAccountName}.queue.${environment().suffixes.storage}'
        }
        {
          name: 'AzureWebJobsStorage__tableServiceUri'
          value: 'https://${storageAccountName}.table.${environment().suffixes.storage}'
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        // Foundry project endpoint + model deployment for the azure-ai-projects SDK
        {
          name: 'FOUNDRY_PROJECT_ENDPOINT'
          value: foundryProjectEndpoint
        }
        {
          name: 'FOUNDRY_MODEL_DEPLOYMENT'
          value: modelDeploymentName
        }
        // Cosmos DB output binding via MANAGED IDENTITY (data-plane RBAC in cosmosdb-rbac.bicep)
        {
          name: 'COSMOS_CONNECTION__accountEndpoint'
          value: cosmosAccountEndpoint
        }
        {
          name: 'COSMOS_CONNECTION__credential'
          value: 'managedidentity'
        }
        // Application Insights with Entra ID auth
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
          value: 'Authorization=AAD'
        }
      ]
    }
    // Flex Consumption specific configuration
    functionAppConfig: {
      runtime: {
        name: 'python'
        version: '3.13'
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40 // cost guardrail: never more than 40 instances
        instanceMemoryMB: 2048 // azure-ai-projects needs the memory; 512MB would OOM
      }
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${blobEndpoint}${deploymentContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
    }
  }
}

// NOTE: the Event Grid event subscription (BlobCreated in 'imageanalysis' ->
// this function) is created AFTER code publish, because an AzureFunction
// endpoint is validated against the function resource itself. The endpoint
// must be the FULL function resource id: /sites/<app>/functions/<function>.
// Creation command (used by function-deploy.yml and documented in README.md):
//   az eventgrid event-subscription create \
//     --source-resource-id <storageAccountId> --name sub-<app>-AnalyzeImage \
//     --endpoint-type azurefunction \
//     --endpoint "${functionResourceId}" \
//     --included-event-types Microsoft.Storage.BlobCreated \
//     --subject-begins-with "/blobServices/default/containers/${imageContainerName}/blobs/"

output name string = site.name
output id string = site.id
output principalId string = site.identity.principalId
output functionName string = functionName
output functionResourceId string = '${site.id}/functions/${functionName}'
output systemTopicName string = systemTopicName
