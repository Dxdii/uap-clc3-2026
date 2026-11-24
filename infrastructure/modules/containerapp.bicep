// Azure Container Apps: managed environment (Log Analytics backed) + ACR
// (Basic — the only daily-rated resource, $0.1666/day) + the upload app with
// external ingress. The app image is a placeholder; CI (or 'az containerapp up')
// pushes the real image to the ACR and updates the app.

param location string
param nameSuffix string
param tags object
param workspaceCustomerId string
@secure()
param workspaceSharedKey string // Log Analytics shared key for the ACA environment (never printed)
param storageAccountName string
param imageContainerName string

@description('Image of the upload app. Default = public MCR placeholder (only needs to be pullable; its revision is unhealthy until the real image is pushed). infra-deploy passes the ACR image once pushed, so infra redeploys do not reset it.')
param uploadAppImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Shared token required in the X-Upload-Token header of /upload (stored as an ACA secret, never in code). Pass your own value so it survives redeploys; otherwise a random GUID per deployment. Read back with: az containerapp secret show --secret-name upload-token.')
@secure()
param uploadToken string = newGuid()

var environmentName = 'cae-${nameSuffix}'
var acrName = 'acr${nameSuffix}'
var appName = 'ca-upload-${nameSuffix}'

resource acr 'Microsoft.ContainerRegistry/registries@2025-11-01' = {
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
      secrets: [
        {
          name: 'upload-token'
          value: uploadToken
        }
      ]
      // NOTE: no `registries` entry here on purpose. The placeholder image is
      // public (MCR), and declaring the ACR with identity 'system' would make the
      // platform mint an ACR token at first-revision time — but AcrPull for the
      // app identity is only assigned by modules/rbac.bicep AFTER this module
      // completes (chicken-and-egg -> "Operation expired"). Instead,
      // containerapp-deploy.yml adds the registry credential together with the
      // real image (`--registry-server ... --registry-identity system`), by which
      // time rbac.bicep has granted AcrPull.
    }
    template: {
      containers: [
        {
          name: 'upload-app'
          // placeholder: any pullable image; replaced by the real app via containerapp-deploy
          // by the real image via containerapp-deploy.yml / the uploadAppImage param
          image: uploadAppImage
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
            {
              name: 'UPLOAD_TOKEN'
              secretRef: 'upload-token'
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
output acrId string = acr.id
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
