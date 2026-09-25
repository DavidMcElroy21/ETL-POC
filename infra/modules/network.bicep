// VNet, subnets and the private DNS zones the rest of the deployment resolves
// through.
//
// Three subnets rather than one, because two of them are *delegated* -- handed
// to a service that manages the NICs inside them -- and a delegated subnet
// cannot hold anything else:
//
//   snet-aca-infra  delegated to Microsoft.App/environments
//   snet-postgres   delegated to Microsoft.DBforPostgreSQL/flexibleServers
//   snet-pe         ordinary, holds private endpoints for storage and ACR
//
// The Container Apps infrastructure subnet must be at least /27 for a
// workload-profiles environment, and Azure reserves addresses inside it for
// its own infrastructure. /23 is the documented recommendation and costs
// nothing but address space in a VNet nothing else shares.

@description('Prefix for resource names.')
param namePrefix string

@description('Location for all resources.')
param location string

@description('Tags applied to every resource.')
param tags object

@description('Address space for the virtual network.')
param vnetAddressPrefix string = '10.20.0.0/16'

param acaSubnetPrefix string = '10.20.0.0/23'
param postgresSubnetPrefix string = '10.20.2.0/24'
param privateEndpointSubnetPrefix string = '10.20.3.0/24'

@description('DNS zone for VNet-integrated PostgreSQL Flexible Servers. Must end in .private.postgres.database.azure.com.')
param postgresDnsZoneName string

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${namePrefix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: 'snet-aca-infra'
        properties: {
          addressPrefix: acaSubnetPrefix
          delegations: [
            {
              name: 'aca-environment'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'snet-postgres'
        properties: {
          addressPrefix: postgresSubnetPrefix
          delegations: [
            {
              name: 'postgres-flexible'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          // Private endpoint NICs ignore NSG/UDR unless this is disabled, and
          // the platform requires it disabled to create one here.
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Private DNS.
//
// A private endpoint gives a service a VNet-internal IP but does not change
// what its public name resolves to. These zones are what make
// <account>.blob.core.windows.net answer with the internal address from inside
// the VNet -- without them, traffic would leave for the public endpoint and be
// refused once public access is turned off.
//
// The PostgreSQL zone is different: a VNet-integrated Flexible Server is not a
// private endpoint, and its FQDN is literally <server>.<this zone>. One zone
// holds every server in this deployment.
// ---------------------------------------------------------------------------
var zoneNames = [
  postgresDnsZoneName
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.dfs.${environment().suffixes.storage}'
  'privatelink${environment().suffixes.acrLoginServer}'
]

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for zone in zoneNames: {
    name: zone
    location: 'global'
    tags: tags
  }
]

resource zoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (zone, i) in zoneNames: {
    parent: zones[i]
    name: 'link-${namePrefix}'
    location: 'global'
    tags: tags
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnet.id
      }
    }
  }
]

output vnetId string = vnet.id
output vnetName string = vnet.name
output acaSubnetId string = vnet.properties.subnets[0].id
output postgresSubnetId string = vnet.properties.subnets[1].id
output privateEndpointSubnetId string = vnet.properties.subnets[2].id

output postgresDnsZoneId string = zones[0].id
output blobDnsZoneId string = zones[1].id
output dfsDnsZoneId string = zones[2].id
output acrDnsZoneId string = zones[3].id
