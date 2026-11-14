// RBAC role assignments — managed identities only (no keys in app settings).
//
// Role definition ids (built-in, well-known GUIDs):
//   Storage Blob Data Owner ........ b7e6dc6d-f1e8-4753-8033-0f276bb0955b
//   Storage Blob Data Contributor .. ba92f5b4-2d11-453d-a403-e96b0029c9fe
//   AcrPull ........................ 7f951dda-4ed3-4680-a7ca-43fe172d538d
//   Azure AI User .................. 53ca6127-db72-4b80-b1b0-d745d6d5456d
//   Monitoring Metrics Publisher ... 3913510d-42f4-4e42-8a64-420c390055b5

param storageAccountName string
param acrName string
param appInsightsName string
param foundryAccountName string
param foundryProjectName string
param functionPrincipalId string
param containerAppPrincipalId string
param containerAppEnvironmentPrincipalId string

var roles = {
  storageBlobDataOwner: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  storageBlobDataContributor: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  acrPull: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  azureAiUser: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')
  monitoringMetricsPublisher: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055b5')
}

resource storage 'Microsoft.Storage/storageAccounts@2025-04-01' existing = {
  name: storageAccountName
}

resource acr 'Microsoft.ContainerRegistry/registries@2025-06-01' existing = {
  name: acrName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  name: '${foundryAccountName}/${foundryProjectName}'
}

// Function app identity -> Storage Blob Data Owner
// (host storage + poison-blob queue writes of the Event Grid blob trigger)
resource raFuncStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, functionPrincipalId, roles.storageBlobDataOwner)
  scope: storage
  properties: {
    roleDefinitionId: roles.storageBlobDataOwner
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Function app identity -> Azure AI User on the Foundry project (Entra ID inference)
resource raFuncAi 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryProject.id, functionPrincipalId, roles.azureAiUser)
  scope: foundryProject
  properties: {
    roleDefinitionId: roles.azureAiUser
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Function app identity -> Monitoring Metrics Publisher on App Insights (AAD telemetry auth)
resource raFuncAppInsights 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, functionPrincipalId, roles.monitoringMetricsPublisher)
  scope: appInsights
  properties: {
    roleDefinitionId: roles.monitoringMetricsPublisher
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Container app identity -> Storage Blob Data Contributor (image uploads)
resource raCappStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, containerAppPrincipalId, roles.storageBlobDataContributor)
  scope: storage
  properties: {
    roleDefinitionId: roles.storageBlobDataContributor
    principalId: containerAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Container Apps environment identity -> AcrPull on the registry (image pulls)
resource raEnvAcr 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, containerAppEnvironmentPrincipalId, roles.acrPull)
  scope: acr
  properties: {
    roleDefinitionId: roles.acrPull
    principalId: containerAppEnvironmentPrincipalId
    principalType: 'ServicePrincipal'
  }
}
