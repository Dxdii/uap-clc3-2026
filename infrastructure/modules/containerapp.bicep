// Azure Container Apps: managed environment (Log Analytics backed) + ACR
// (Basic — the only daily-rated resource, $0.1666/day) + the upload app with
// external ingress. The app image is a placeholder; CI (or 'az containerapp up')
// pushes the real image to the ACR and updates the app.

param location string
param nameSuffix string
param tags object
param workspaceCustomerId string
param workspaceSharedKey string
param storageAccountName string
param imageContainerName string

var environmentName = 'cae-${nameSuffix}'
var acrName = 'acr${nameSuffix}'
var appName = 'ca-upload-${nameSuffix}'

resource acr 'Microsoft.ContainerRegistry/registries@2025-06-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: 'Basic' // cheapest tier ($0.1666/day, 10 GB included)
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    adminUserEnabled: false
  }
}

resource environment 'Microsoft.App/managedEnvironments@2025-07-01' = {
  name: environmentName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned' // used by the platform to pull images from ACR
  }
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspaceCustomerId
        sharedKey: workspaceSharedKey
      }
    }
    // NOTE: if creation fails with AKSCapacityHeavyUsage, switch 'location' in
    // main.bicep to the next region recommended by scripts/preflight.sh.
  }
}

resource app 'Microsoft.App/containerApps@2025-07-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned' // used by the app code (DefaultAzureCredential) for blob uploads
  }
  properties: {
    environmentId: environment.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
      }
      registries: [
        {
          server: acr.properties.loginServer
          // pull auth uses the environment's system-assigned identity,
          // which gets AcrPull on the registry in modules/rbac.bicep
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'upload-app'
          // placeholder image — replaced by CI/CD (containerapp-deploy.yml)
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'STORAGE_ACCOUNT_NAME'
              value: storageAccountName
            }
            {
              name: 'CONTAINER_NAME'
              value: imageContainerName
            }
            {
              name: 'PORT'
              value: '8080'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0 // scale to zero -> $0 while idle (cost guardrail)
        maxReplicas: 3
      }
    }
  }
}

output name string = app.name
output fqdn string = app.properties.configuration.ingress.fqdn
output principalId string = app.identity.principalId
output environmentPrincipalId string = environment.identity.principalId
output acrId string = acr.id
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
