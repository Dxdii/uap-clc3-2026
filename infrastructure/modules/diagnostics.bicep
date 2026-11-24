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
//
// Foundry (verified live, 2026-11-15): inference calls go to the PROJECT endpoint
// and are observable via AllMetrics on the account — AzureMetrics rows
// (AzureOpenAIRequests, InputTokens/OutputTokens/TotalTokens, Latency) appear within
// ~1-2 min. The LOG categories (account Audit/Trace/AzureOpenAIRequestUsage, project
// Audit/Trace) did NOT emit any AzureDiagnostics rows within 25 min for
// project-endpoint calls, so the reliable LAW path for model usage is AzureMetrics
// plus the Foundry portal (ai.azure.com -> project -> Monitoring).
// =============================================================================

param workspaceId string
param storageAccountName string
param systemTopicName string
param cosmosAccountName string
param acrName string
param foundryAccountName string
param foundryProjectName string
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

// The function calls the PROJECT endpoint (.../api/projects/<project>). The project
// child resource supports only Audit/Trace (+AllMetrics) — 'AzureOpenAIRequestUsage'
// is rejected there ("Category ... is not supported", verified live). Keep a setting
// on the project so project-level Audit (CRUD on the project) is captured; the actual
// inference usage is visible via AllMetrics (AzureMetrics) on the account.
resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  name: '${foundryAccountName}/${foundryProjectName}'
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

// Project level: captures project CRUD audit events. Inference traces/usage for
// project-endpoint calls are NOT emitted here (verified live) — use AzureMetrics
// on the account + the Foundry portal for token usage. RequestResponse stays off
// (it would log full payloads incl. base64 images).
resource dsFoundryProject 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: foundryProject
  dependsOn: [dsFoundry] // serialize writes on the same parent account
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'Audit', enabled: true }
      { category: 'Trace', enabled: true }
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
