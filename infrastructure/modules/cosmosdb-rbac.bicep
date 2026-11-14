// Data-plane RBAC for Cosmos DB: grants the function app's managed identity the
// built-in "Cosmos DB Built-in Data Contributor" role at database scope, so the
// Cosmos DB OUTPUT BINDING can write documents using Entra ID (no keys).

param cosmosAccountName string
param cosmosDatabaseId string
param functionPrincipalId string

// Cosmos DB Built-in Data Contributor (well-known role definition id)
var cosmosDataContributorRoleDefinitionId = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000002'

resource account 'Microsoft.DocumentDB/databaseAccounts@2025-04-01' existing = {
  name: cosmosAccountName
}

resource sqlRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-04-01' = {
  parent: account
  name: guid(cosmosAccountName, functionPrincipalId, 'cosmos-data-contributor')
  properties: {
    roleDefinitionId: cosmosDataContributorRoleDefinitionId
    principalId: functionPrincipalId
    scope: cosmosDatabaseId
  }
}
