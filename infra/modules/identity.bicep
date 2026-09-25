// One user-assigned managed identity for every workload, plus the role
// assignments that let it do its job without a single stored credential.
//
// User-assigned rather than system-assigned for one concrete reason: role
// assignments on a system-assigned identity cannot exist before the resource
// that owns it, which makes the container apps and their permissions a
// circular dependency. A standalone identity is created first, granted
// everything up front, and then attached.

@description('Prefix for resource names.')
param namePrefix string

@description('Location for all resources.')
param location string

@description('Tags applied to every resource.')
param tags object

@description('Container registry the workloads pull images from.')
param registryName string

@description('Storage account used for Pipes messages, compute logs and the data lake.')
param storageAccountName string

@description('Key Vault holding the SFTP local-user password.')
param keyVaultName string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${namePrefix}'
  location: location
  tags: tags
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: registryName
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// ---------------------------------------------------------------------------
// A custom role for starting job executions, rather than a built-in one.
//
// The Container Apps documentation is explicit that a wildcard over
// Microsoft.App/jobs/*/action also matches listSecrets, which would let any
// holder read every secret configured on the job in plain text. The Dagster
// run launcher needs exactly four operations, so it gets exactly four:
//
//   jobs/read             clone the deployed template before overriding it,
//                         which is what stops an override dropping the image,
//                         resource limits and secret-backed env vars
//   jobs/start/action     start one execution
//   jobs/stop/action      terminate a run, and time out an ingest sync
//   jobs/executions/read  poll status for run monitoring
//
// Deliberately no listSecrets, no write, no delete.
// ---------------------------------------------------------------------------
resource jobExecutorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroup().id, 'dagster-job-executor')
  properties: {
    roleName: 'Dagster Container Apps Job Executor (${namePrefix})'
    description: 'Start, stop and observe Container Apps job executions. No access to job secrets.'
    type: 'CustomRole'
    assignableScopes: [
      resourceGroup().id
    ]
    permissions: [
      {
        actions: [
          'Microsoft.App/jobs/read'
          'Microsoft.App/jobs/start/action'
          'Microsoft.App/jobs/stop/action'
          'Microsoft.App/jobs/executions/read'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource jobExecutorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identity.id, jobExecutorRole.id)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: jobExecutorRole.id
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// AcrPull. Container Apps pulls images as this identity, which is why no
// registry admin user or password appears anywhere in this deployment.
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, identity.id, acrPullRoleId)
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Blob Data Contributor. Covers all three uses of the account: the
// Pipes context and message blobs, the compute-log manager's stdout/stderr
// uploads, and reading and writing the lake container.
var blobContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource blobAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, blobContributorRoleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobContributorRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Key Vault Secrets User -- read, not manage. The ingest job resolves the SFTP
// password through a Container Apps secret backed by the vault, so the value
// never appears in the template, in a deployment history, or in `az` output.
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName
}

var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource keyVaultAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, identity.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output identityId string = identity.id
output identityName string = identity.name
output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
