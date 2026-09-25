// ADLS Gen2 account: Dagster's blob traffic, the data lake, and the SFTP
// landing zone that replaces the atmoz/sftp container from the local stack.
//
// Hierarchical namespace is on because Blob Storage SFTP requires it. It is
// not optional and it cannot be turned on after the account is created, so the
// account is built this way whether or not the demo SFTP source is deployed.

@description('Prefix for resource names.')
param namePrefix string

@description('Location for all resources.')
param location string

@description('Tags applied to every resource.')
param tags object

@description('Subnet that holds the private endpoints.')
param privateEndpointSubnetId string

param blobDnsZoneId string
param dfsDnsZoneId string

@description('Deploy the SFTP landing zone and its local user. SFTP bills hourly whenever it is enabled on the account, which is why it is a switch.')
param deploySftp bool = true

@description('Local user name for SFTP. Matches SFTP_USER in the local stack so the ingest code is unchanged.')
param sftpUserName string = 'etl'

@description('Allow access from outside the virtual network. Needed to seed the sample data from a developer machine.')
param allowPublicNetworkAccess bool = true

var storageAccountName = take('st${replace(namePrefix, '-', '')}${uniqueString(resourceGroup().id)}', 24)

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    isHnsEnabled: true
    isSftpEnabled: deploySftp

    // Shared key access is enabled only when SFTP is. SFTP local users
    // authenticate with a password or an SSH key, and Azure classes that as
    // shared-key authorization -- disabling shared key locks SFTP clients out
    // along with everything else. Every other caller here uses Entra, so with
    // the demo source switched off the account has no key-based path at all.
    allowSharedKeyAccess: deploySftp

    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: allowPublicNetworkAccess ? 'Enabled' : 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: allowPublicNetworkAccess ? 'Allow' : 'Deny'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

// dagster  -- Pipes context and message blobs, and compute logs.
// lake     -- general object storage; what MinIO stands in for locally.
// sftp     -- the SFTP local user's home, holding the retail CSVs.
var containerNames = deploySftp ? ['dagster', 'lake', 'sftp'] : ['dagster', 'lake']

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [
  for name in containerNames: {
    parent: blobService
    name: name
    properties: {
      publicAccess: 'None'
    }
  }
]

// ---------------------------------------------------------------------------
// SFTP local user.
//
// Local users are their own identity system. They do not interoperate with
// Entra, managed identity or Azure RBAC at all -- permissions are the
// permissionScope list below and nothing else. That is why this one credential
// is a real secret while nothing else in this deployment is, and why it goes
// to Key Vault rather than into an app setting.
//
// The password is not set here. Azure generates it, and the only way to read
// it is a regenerate call after deployment; see infra/deploy.sh.
// ---------------------------------------------------------------------------
resource sftpUser 'Microsoft.Storage/storageAccounts/localUsers@2023-05-01' = if (deploySftp) {
  parent: storage
  name: sftpUserName
  properties: {
    hasSharedKey: false
    hasSshKey: false
    hasSshPassword: true
    homeDirectory: 'sftp'
    permissionScopes: [
      {
        // Read and list only. The pipeline reads the sample data; nothing in
        // it should be able to modify or delete what it is reading, which was
        // also true of the read-only bind mount this replaces.
        permissions: 'rl'
        service: 'blob'
        resourceName: 'sftp'
      }
    ]
  }
  dependsOn: [
    containers
  ]
}

// ---------------------------------------------------------------------------
// Key Vault, for that one password.
//
// RBAC rather than access policies, so the grant lives alongside every other
// role assignment instead of in a second, parallel permission model.
// ---------------------------------------------------------------------------
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: 'kv-${namePrefix}-${substring(uniqueString(resourceGroup().id), 0, 6)}'
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: allowPublicNetworkAccess ? 'Enabled' : 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: allowPublicNetworkAccess ? 'Allow' : 'Deny'
    }
  }
}

resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-blob-${namePrefix}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: ['blob']
        }
      }
    ]
  }
}

resource blobDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: blobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: blobDnsZoneId
        }
      }
    ]
  }
}

// A second endpoint for the dfs name. Hierarchical-namespace operations --
// which is what an SFTP client and any ADLS-aware SDK actually use -- go to
// <account>.dfs.core.windows.net, a different name that needs its own
// endpoint and its own zone.
resource dfsPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-dfs-${namePrefix}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'dfs'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: ['dfs']
        }
      }
    ]
  }
}

resource dfsDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: dfsPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'dfs'
        properties: {
          privateDnsZoneId: dfsDnsZoneId
        }
      }
    ]
  }
}

output storageAccountId string = storage.id
output storageAccountName string = storage.name
output blobEndpoint string = storage.properties.primaryEndpoints.blob

// The SFTP endpoint is the blob name, and the user name is
// <account>.<localuser> -- not the bare local user name, which is a common way
// to spend an afternoon on a "permission denied" that is really a parse error.
output sftpHost string = deploySftp ? '${storage.name}.blob.${environment().suffixes.storage}' : ''
output sftpUserName string = deploySftp ? '${storage.name}.${sftpUserName}' : ''
output sftpLocalUserName string = sftpUserName

output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
