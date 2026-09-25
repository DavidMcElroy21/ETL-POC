// Azure Container Registry for the two images this project builds.
//
// Public network access stays on by default, and that is a considered choice
// rather than an oversight: the images are pushed from a developer machine or
// a CI runner, neither of which is inside this VNet. Turning it off makes the
// registry unreachable from exactly the place that fills it. The private
// endpoint below is what the pull path uses regardless, so disabling public
// access later is a one-parameter change once pushes come from a build agent
// on the network.

@description('Prefix for resource names.')
param namePrefix string

@description('Location for all resources.')
param location string

@description('Tags applied to every resource.')
param tags object

@description('Subnet that holds the private endpoint.')
param privateEndpointSubnetId string

@description('Private DNS zone for the registry login server.')
param acrDnsZoneId string

@description('Allow pushes from outside the virtual network. See the note above before disabling.')
param allowPublicNetworkAccess bool = true

// Registry names are globally unique across all of Azure, not just this
// subscription, so the prefix alone would collide with anyone else who
// deployed this template. 5-50 characters, alphanumeric only.
var registryName = take('cr${replace(namePrefix, '-', '')}${uniqueString(resourceGroup().id)}', 50)

// Premium is required for private endpoints. On Basic or Standard the private
// endpoint below simply cannot be created.
resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: registryName
  location: location
  tags: tags
  sku: {
    name: 'Premium'
  }
  properties: {
    // No admin user. The workloads pull with the managed identity, and there
    // is no second credential to leak or rotate.
    adminUserEnabled: false
    publicNetworkAccess: allowPublicNetworkAccess ? 'Enabled' : 'Disabled'
    networkRuleBypassOptions: 'AzureServices'
    zoneRedundancy: 'Disabled'
    policies: {
      retentionPolicy: {
        status: 'enabled'
        days: 30
      }
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-cr-${namePrefix}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'registry'
        properties: {
          privateLinkServiceId: registry.id
          groupIds: ['registry']
        }
      }
    ]
  }
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'acr'
        properties: {
          privateDnsZoneId: acrDnsZoneId
        }
      }
    ]
  }
}

output registryId string = registry.id
output registryName string = registry.name
output loginServer string = registry.properties.loginServer
