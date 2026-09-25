// The Container Apps managed environment: the shared boundary the three apps
// and two jobs live in.
//
// VNet-injected, because everything these workloads talk to -- Postgres,
// storage, the registry -- is reachable only from inside the network. An
// environment on the platform-managed network could not resolve any of them.
//
// Consumption workload profile. Scale to zero on the jobs is most of the cost
// story here: a run worker exists for the length of a run and is billed for
// the length of a run.

@description('Prefix for resource names.')
param namePrefix string

@description('Location for all resources.')
param location string

@description('Tags applied to every resource.')
param tags object

@description('Delegated subnet for the environment infrastructure.')
param infrastructureSubnetId string

@description('Log Analytics workspace that receives console and system logs.')
param logAnalyticsWorkspaceId string

@description('Give the environment an internal load balancer only. The Dagster UI then has no public address and needs a VPN or bastion to reach.')
param internalOnly bool = false

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: last(split(logAnalyticsWorkspaceId, '/'))
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${namePrefix}'
  location: location
  tags: tags
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: infrastructureSubnetId
      internal: internalOnly
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspace.properties.customerId
        // The only shared key in this deployment, and it is the platform's
        // own ingestion key rather than a credential for any of this
        // project's data. Container Apps offers no managed-identity option
        // for log ingestion.
        sharedKey: workspace.listKeys().primarySharedKey
      }
    }
    zoneRedundant: false
  }
}

output environmentId string = environment.id
output environmentName string = environment.name
output defaultDomain string = environment.properties.defaultDomain
output staticIp string = environment.properties.staticIp
