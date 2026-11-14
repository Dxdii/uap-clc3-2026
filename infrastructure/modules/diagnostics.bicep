// =============================================================================
// Observability — route resource logs + platform metrics of every exercise
// resource into the Log Analytics workspace, so students can explore the whole
// pipeline in one place with Azure native tooling:
//   portal -> Log Analytics workspace -> Logs   (KQL, e.g. AzureDiagnostics,
//        ContainerAppConsoleLogs_CL, AppTraces, ...)
//   portal -> Azure Monitor -> Metrics          (platform metrics are automatic;
//        we also copy AllMetrics into the workspace)
//
// Already covered WITHOUT diagnostic settings (not repeated here):
//   - ACA environment logs: appLogsConfiguration.destination='log-analytics'
//     in containerapp.bicep -> ContainerApp* tables in the workspace
//   - Function worker telemetry: workspace-based App Insights
//     (APPLICATIONINSIGHTS_CONNECTION_STRING + AAD) -> AppTraces/AppRequests
//
// Auth: the workspace keeps local auth enabled (shared keys), so workspaceId-
// based settings work without extra RBAC role assignments.
//
// Cost: LAW is PerGB2018 with 30-day retention; first 5 GB/month ingestion is
// free and this stack emits MBs -> $0. NOTE: CognitiveServices 'RequestResponse'
// is deliberately NOT enabled — it logs full payloads including the base64
// image (~1.4x the upload size). Enable it manually if you want to inspect
// inference payloads and accept the extra ingestion.
//
// Category names below were verified against live resources with
// 'az monitor diagnostic-settings categories list --resource <id>':
//   - storage ACCOUNT supports only Capacity/Transaction metrics — blob op logs
//     (StorageRead/Write/Delete) live on the blobServices/default CHILD and land
//     in the resource-specific StorageBlobLogs table
//   - a Flex Consumption site supports only FunctionAppLogs + audit categories
//     (AppServiceHTTPLogs etc. are rejected on this SKU)
//   - Event Grid system topics expose only DeliveryFailures
// =============================================================================

param workspaceId string
param storageAccountName string
param systemTopicName string
param cosmosAccountName string
param acrName string
param foundryAccountName string
param functionAppName string

resource storage 'Microsoft.Storage/storageAccounts@2025-06-01' existing = {
  name: storageAccountName
}

// Blob operation logs (StorageRead/Write/Delete) live on the blobServices/default
// CHILD resource, not the account — they land in the resource-specific
// StorageBlobLogs table. Verified live via
// 'az monitor diagnostic-settings categories list --resource <account>/blobServices/default'.
resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2025-06-01' existing = {
  name: '${storageAccountName}/default'
}

resource systemTopic 'Microsoft.EventGrid/systemTopics@2025-02-15' existing = {
  name: systemTopicName
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2025-04-15' existing = {
  name: cosmosAccountName
}

resource acr 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: acrName
}

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryAccountName
}

resource site 'Microsoft.Web/sites@2025-03-01' existing = {
  name: functionAppName
}

// Account level: only Capacity/Transaction metrics exist here (verified live) —
// blob operation logs are on the child resource below.
resource dsStorage 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: storage
  properties: {
    workspaceId: workspaceId
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

resource dsStorageBlob 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: blobServices
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'StorageRead', enabled: true }
      { category: 'StorageWrite', enabled: true }
      { category: 'StorageDelete', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

resource dsEventGrid 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: systemTopic
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'DeliveryFailures', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

resource dsCosmos 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: cosmos
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'DataPlaneRequests', enabled: true }
      { category: 'QueryRuntimeStatistics', enabled: true }
      { category: 'PartitionKeyStatistics', enabled: true }
      { category: 'PartitionKeyRUConsumption', enabled: true }
      { category: 'ControlPlaneRequests', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

resource dsAcr 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: acr
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'ContainerRegistryLoginEvents', enabled: true }
      { category: 'ContainerRegistryRepositoryEvents', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

resource dsFoundry 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: foundry
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'Audit', enabled: true }
      { category: 'Trace', enabled: true }
      { category: 'AzureOpenAIRequestUsage', enabled: true } // token usage per call — no payloads
      // 'RequestResponse' intentionally disabled — logs full payloads incl.
      // the base64 image (see header comment).
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// NOTE: a Flex Consumption (Linux) site supports ONLY FunctionAppLogs +
// audit categories (verified live via 'az monitor diagnostic-settings
// categories list'): AppServiceHTTPLogs/ConsoleLogs/AppLogs/PlatformLogs are
// rejected with "Category ... is not supported" on this SKU. The Event Grid
// webhook calls and worker telemetry are visible via App Insights / AppTraces
// in the same workspace instead.
resource dsFunctionApp 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: site
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'FunctionAppLogs', enabled: true }
      { category: 'AppServiceAuditLogs', enabled: true }
      { category: 'AppServiceAuthenticationLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}
