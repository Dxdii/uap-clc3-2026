// Data-plane RBAC for Cosmos DB: grants the function app's managed identity the
// built-in "Cosmos DB Built-in Data Contributor" role at DATABASE scope, so the
// Cosmos DB OUTPUT BINDING can write documents using Entra ID (no keys).
//
// Two Cosmos-specific details (both verified against the ARM API):
//   1. roleDefinitionId must be the full resource id of the account-scoped
//      sqlRoleDefinition child resource — NOT an Azure Authorization role id.
//   2. scope must be the DATA-PLANE path .../dbs/<database>, not the ARM path
//      .../sqlDatabases/<database>.

param cosmosAccountName string
param cosmosDatabaseName string
param functionPrincipalId string

// Cosmos DB Built-in Data Contributor (well-known built-in data role id)
var cosmosDataContributorRoleDefinitionId = resourceId(
  'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions',
  cosmosAccountName,
  '00000000-0000-0000-0000-000000000002'
)

// data-plane scope of the database: /dbs/<name> under the account
var cosmosDatabaseScope = '${resourceId('Microsoft.DocumentDB/databaseAccounts', cosmosAccountName)}/dbs/${cosmosDatabaseName}'

resource account 'Microsoft.DocumentDB/databaseAccounts@2025-04-15' existing = {
  name: cosmosAccountName
}

resource sqlRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-04-15' = {
  parent: account
  name: guid(cosmosAccountName, functionPrincipalId, 'cosmos-data-contributor')
  properties: {
    roleDefinitionId: cosmosDataContributorRoleDefinitionId
    principalId: functionPrincipalId
    scope: cosmosDatabaseScope
  }
}
