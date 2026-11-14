param location string
param nameSuffix string
param tags object

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' = {
  name: 'log-${nameSuffix}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30 // cost guardrail: keep logs 30 days only
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${nameSuffix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    DisableLocalAuth: true // Entra ID only for telemetry auth
  }
}

output workspaceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
// The ACA environment needs the workspace shared key for log shipping (standard
// pattern). Marked @secure() so the key is never persisted as plaintext in
// deployment history/outputs.
@secure()
output workspaceSharedKey string = workspace.listKeys().primarySharedKey
output appInsightsId string = appInsights.id
output appInsightsName string = appInsights.name
// The connection string embeds the instrumentation key -> @secure() as well.
@secure()
output appInsightsConnectionString string = appInsights.properties.ConnectionString
