// PostgreSQL Flexible Server(s).
//
// The warehouse server holds two databases, matching the two roles Postgres
// plays locally:
//
//   dagster   run, event and schedule storage -- shared state that makes the
//             webserver, the daemon and every run worker one Dagster instance
//   retail    the warehouse: airbyte_raw, retail_staging, retail_marts
//
// Both live on one server because they are the same workload with the same
// access pattern, and a second server would double the bill to isolate
// nothing. The demo CDC server below is separate for the opposite reason: it
// needs wal_level=logical, which is a server-wide setting, and enabling
// logical decoding on the warehouse to serve a demo source would be silly.
//
// Access is private only. The server is injected into a delegated subnet, so
// it has no public endpoint to firewall -- which is why there is not a single
// firewall rule in this file.

@description('Prefix for resource names.')
param namePrefix string

@description('Location for all resources.')
param location string

@description('Tags applied to every resource.')
param tags object

@description('Delegated subnet for the flexible servers.')
param delegatedSubnetId string

@description('Private DNS zone the servers register in.')
param privateDnsZoneId string

@description('Object id of the managed identity that becomes the Entra administrator.')
param adminPrincipalId string

@description('Name of that identity. This is the PostgreSQL role name the workloads connect as.')
param adminPrincipalName string

@description('Compute SKU for the warehouse server.')
param skuName string = 'Standard_B2s'

@description('Compute tier for the warehouse server.')
@allowed(['Burstable', 'GeneralPurpose', 'MemoryOptimized'])
param skuTier string = 'Burstable'

@description('Storage in GB. Flexible Server cannot shrink storage, only grow it.')
param storageSizeGB int = 32

@description('PostgreSQL major version.')
param postgresVersion string = '16'

@description('Deploy the second server that stands in for the local CDC source.')
param deployCdcSource bool = true

@description('Administrator password for the CDC demo server. PyAirbyte source-postgres cannot use Entra, so this one server keeps password auth.')
@secure()
param cdcAdminPassword string = ''

@description('Administrator login for the CDC demo server.')
param cdcAdminUser string = 'cdc'

// ---------------------------------------------------------------------------
// Warehouse server. Entra authentication only.
//
// passwordAuth is disabled outright, which is worth stating plainly: this
// server has no password to steal, rotate or leak, because it has no password.
// Every caller -- dagster-postgres, dbt, PyAirbyte -- authenticates with a
// short-lived Entra token issued to the managed identity.
// ---------------------------------------------------------------------------
resource warehouse 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: 'psql-${namePrefix}'
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    version: postgresVersion
    createMode: 'Create'
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Disabled'
      tenantId: subscription().tenantId
    }
    storage: {
      storageSizeGB: storageSizeGB
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      // A POC. Zone-redundant HA doubles the compute bill for a workload that
      // can be redeployed from this template in minutes.
      mode: 'Disabled'
    }
    network: {
      delegatedSubnetResourceId: delegatedSubnetId
      privateDnsZoneArmResourceId: privateDnsZoneId
      publicNetworkAccess: 'Disabled'
    }
  }
}

// The managed identity as Entra administrator.
//
// Administrator is broader than this workload strictly needs. A production
// deployment would connect as the admin once to run pgaadauth_create_principal
// for a non-privileged role and grant it only the two databases -- but that is
// a data-plane step, and nothing in ARM can express it. Doing it this way
// keeps the deployment one command, and the narrowing is documented in
// infra/README.md rather than silently skipped.
resource warehouseAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = {
  parent: warehouse
  name: adminPrincipalId
  properties: {
    principalName: adminPrincipalName
    principalType: 'ServicePrincipal'
    tenantId: subscription().tenantId
  }
}

resource dagsterDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: warehouse
  name: 'dagster'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

resource retailDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: warehouse
  name: 'retail'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [
    dagsterDb
  ]
}

// ---------------------------------------------------------------------------
// CDC demo source. Replaces the postgres-source container from the local
// stack, and exists only so option 5 in docs/local-ingestion-options.md has
// something to read from.
//
// wal_level=logical is the entire reason it is a separate server. It is a
// static parameter, so setting it restarts the server -- the three
// configurations below are chained rather than applied in parallel, because
// Flexible Server rejects a second parameter update while the first is still
// restarting.
// ---------------------------------------------------------------------------
resource cdcSource 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = if (deployCdcSource) {
  name: 'psql-${namePrefix}-cdc'
  location: location
  tags: tags
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: postgresVersion
    createMode: 'Create'
    administratorLogin: cdcAdminUser
    administratorLoginPassword: cdcAdminPassword
    authConfig: {
      // Password auth, unlike the warehouse: the Airbyte source-postgres
      // connector has no Entra support, so a demo source that used Entra
      // would be a demo of nothing.
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
      tenantId: subscription().tenantId
    }
    storage: {
      storageSizeGB: 32
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      delegatedSubnetResourceId: delegatedSubnetId
      privateDnsZoneArmResourceId: privateDnsZoneId
      publicNetworkAccess: 'Disabled'
    }
  }
}

resource cdcWalLevel 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = if (deployCdcSource) {
  parent: cdcSource
  name: 'wal_level'
  properties: {
    value: 'logical'
    source: 'user-override'
  }
}

resource cdcReplicationSlots 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = if (deployCdcSource) {
  parent: cdcSource
  name: 'max_replication_slots'
  properties: {
    value: '10'
    source: 'user-override'
  }
  dependsOn: [
    cdcWalLevel
  ]
}

resource cdcWalSenders 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = if (deployCdcSource) {
  parent: cdcSource
  name: 'max_wal_senders'
  properties: {
    value: '10'
    source: 'user-override'
  }
  dependsOn: [
    cdcReplicationSlots
  ]
}

resource cdcDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = if (deployCdcSource) {
  parent: cdcSource
  name: 'shop'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [
    cdcWalSenders
  ]
}

output warehouseFqdn string = warehouse.properties.fullyQualifiedDomainName
output warehouseName string = warehouse.name
output dagsterDatabaseName string = dagsterDb.name
output retailDatabaseName string = retailDb.name

output cdcFqdn string = deployCdcSource ? cdcSource!.properties.fullyQualifiedDomainName : ''
output cdcDatabaseName string = deployCdcSource ? 'shop' : ''
output cdcAdminUser string = cdcAdminUser
