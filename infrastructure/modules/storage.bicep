// Storage account (GPv2 — required for Event Grid blob subscriptions) with the
// 'imageanalysis' container (upload target / blob trigger source), the
// Functions deployment package container, and the Event Grid system topic.
// The event SUBSCRIPTION to the function app lives in modules/function.bicep
// (it needs the function app id, which depends on this module -> avoids cycles).

param location string
param nameSuffix string
param tags object
param functionAppName string

var storageAccountName = 'st${nameSuffix}'
var imageContainerName = 'imageanalysis'
var deploymentContainerName = 'app-package-${take(functionAppName, 32)}'
var systemTopicName = 'systopic-${nameSuffix}'

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-04-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS' // cheapest redundancy; sufficient for the exercise
  }
  kind: 'StorageV2' // required for Event Grid blob subscriptions
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    // NOTE: shared key access stays enabled so students can use Storage
    // Explorer / portal data tools with the account key. All app code uses
    // managed identities, never keys.
    allowSharedKeyAccess: true
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2025-04-01' = {
  parent: storageAccount
  name: 'default'
}

resource imageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-04-01' = {
  parent: blobServices
  name: imageContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource webjobsHosts 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-04-01' = {
  parent: blobServices
  name: 'azure-webjobs-hosts'
  properties: {
    publicAccess: 'None'
  }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-04-01' = {
  parent: blobServices
  name: deploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

// cost guardrail: auto-delete uploaded images after 7 days
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-08-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'delete-old-images'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                '${imageContainerName}/'
              ]
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: 7
                }
              }
            }
          }
        }
      ]
    }
  }
}

// Event Grid system topic on the storage account (source of BlobCreated events)
resource systemTopic 'Microsoft.EventGrid/systemTopics@2025-06-01' = {
  name: systemTopicName
  location: location
  tags: tags
  properties: {
    source: storageAccount.id
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output imageContainerName string = imageContainerName
output deploymentContainerName string = deploymentContainerName
output systemTopicName string = systemTopicName
