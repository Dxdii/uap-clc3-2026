// Cosmos DB for NoSQL — SERVERLESS (pay per consumed RU, no baseline cost; ideal
// for the student budget). Database 'ImageAnalysis', container 'results' with
// partition key /filename. The data-plane role assignment for the function app
// identity lives in modules/cosmosdb-rbac.bicep (needs the function principalId).
//
// NOTE: local auth (keys) stays enabled so students can browse data in the
// portal Data Explorer with the account key. The function app itself uses a
// managed identity + built-in data role.

param location string
param nameSuffix string
param tags object

var accountName = 'cosmos-${nameSuffix}'
var databaseName = 'ImageAnalysis'
var containerName = 'results'

resource account 'Microsoft.DocumentDB/databaseAccounts@2025-04-15' = {
  name: accountName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    publicNetworkAccess: 'Enabled'
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    backupPolicy: {
      type: 'Periodic'
      periodicModeProperties: {
        backupIntervalInMinutes: 240
        backupRetentionIntervalInHours: 8
      }
    }
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2025-04-15' = {
  parent: account
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
  }
}

resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2025-04-15' = {
  parent: database
  name: containerName
  properties: {
    resource: {
      id: containerName
      partitionKey: {
        paths: [
          '/filename'
        ]
        kind: 'Hash'
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true
      }
    }
  }
}

output accountId string = account.id
output accountName string = account.name
output accountEndpoint string = account.properties.documentEndpoint
output databaseName string = databaseName
output containerName string = containerName
