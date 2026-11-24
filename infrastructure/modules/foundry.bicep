// Microsoft Foundry resource (AIServices account with project management) +
// project + vision model deployment (gpt-5-mini, GlobalStandard).
//
// The project endpoint format is:
//   https://<account-name>.services.ai.azure.com/api/projects/<project-name>

param location string
param nameSuffix string
param tags object
param modelName string
param modelVersion string
param modelSkuName string
param modelCapacity int
param modelDeploymentName string

var accountName = 'ais-${nameSuffix}'
var projectName = 'clc3-project'

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true // makes this a Foundry resource that hosts projects as child resources
    disableLocalAuth: true // Entra ID only — all SDK calls use managed identity
    publicNetworkAccess: 'Enabled'
    customSubDomainName: accountName
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: account
  name: projectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'CLC3 2026 exercise project'
    description: 'Foundry project for the uap-clc3-2026 image analysis exercise'
  }
}

// Model deployment: ACCOUNT-level child resource (accounts/deployments). The
// project-scoped variant (accounts/projects/deployments) is only in preview
// APIs — at stable 2025-06-01 the RP rejects it with
// "UnsupportedAction: deployments/<name>" (verified by a real deployment).
// The Foundry project routes SDK calls to the account-level deployments.
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: modelDeploymentName
  // serialize child writes: parallel PUTs on account+project+deployment make the
  // RP fail one of them with RequestConflict ("another operation on the parent")
  dependsOn: [project]
  sku: {
    name: modelSkuName // e.g. 'GlobalStandard' (pay-per-token)
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

output accountName string = account.name
output accountId string = account.id
output projectId string = project.id
output projectName string = project.name
output projectEndpoint string = 'https://${account.name}.services.ai.azure.com/api/projects/${project.name}'
output modelDeploymentName string = modelDeployment.name
