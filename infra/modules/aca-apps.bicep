// The three long-running Dagster processes.
//
//   ca-<prefix>-code       `dagster api grpc` -- the code location
//   ca-<prefix>-webserver  the UI
//   ca-<prefix>-daemon     schedules, sensors, the run queue, run monitoring
//
// All three run the same orchestrator image and differ only in the arguments
// Container Apps passes. That is deliberate: one image means the code the UI
// displays and the code a run executes cannot drift apart.
//
// None of them overrides `command`, only `args`. Container Apps maps `command`
// to the image's ENTRYPOINT, so an override there would skip
// scripts/azure/entrypoint.sh and with it the Entra token that becomes
// POSTGRES_PASSWORD. Setting `args` alone replaces CMD and leaves the
// entrypoint in place, which is what we want everywhere it is possible. (The
// run worker and the ingest job cannot do this -- their commands are built at
// launch time -- which is why those two prepend the entrypoint explicitly.)

@description('Prefix for resource names.')
param namePrefix string

@description('Location for all resources.')
param location string

@description('Tags applied to every resource.')
param tags object

@description('Container Apps managed environment.')
param environmentId string

@description('Registry login server, e.g. crexample.azurecr.io.')
param registryLoginServer string

@description('Fully qualified orchestrator image reference.')
param orchestratorImage string

@description('Resource id of the user-assigned managed identity.')
param identityId string

@description('Client id of that identity. DefaultAzureCredential needs it to pick the right one.')
param identityClientId string

@description('The identity name, which is also the PostgreSQL role the workloads connect as.')
param postgresUser string

param postgresHost string
param dagsterDatabase string
param retailDatabase string

param storageAccountName string
param blobEndpoint string

@description('Blob container used for Pipes messages and compute logs.')
param dagsterContainerName string = 'dagster'

@description('Name of the Container Apps job that runs one Dagster run.')
param runJobName string

@description('Name of the Container Apps job that runs one ingest sync.')
param ingestJobName string

param sftpHost string = ''
param sftpUserName string = ''
param sftpFolderPath string = '/sftp/retail'

var subscriptionId = subscription().subscriptionId
var resourceGroupName = resourceGroup().name

// Every container needs these. The Postgres block is here rather than only on
// the code location because dbt and PyAirbyte read it from the environment,
// and because dagster-postgres reads DAGSTER_PG_* to reach the shared event
// log -- two different consumers of the same server.
var baseEnv = [
  {
    name: 'AZURE_CLIENT_ID'
    value: identityClientId
  }
  {
    name: 'AZURE_SUBSCRIPTION_ID'
    value: subscriptionId
  }
  {
    name: 'AZURE_RESOURCE_GROUP'
    value: resourceGroupName
  }
  {
    name: 'DAGSTER_HOME'
    value: '/opt/dagster/home'
  }
  {
    name: 'DAGSTER_PG_USERNAME'
    value: postgresUser
  }
  {
    name: 'DAGSTER_PG_HOST'
    value: postgresHost
  }
  {
    name: 'DAGSTER_PG_DB'
    value: dagsterDatabase
  }
  {
    name: 'AZURE_STORAGE_ACCOUNT'
    value: storageAccountName
  }
  {
    name: 'AZURE_STORAGE_ACCOUNT_URL'
    value: blobEndpoint
  }
  {
    name: 'AZURE_LOGS_CONTAINER'
    value: dagsterContainerName
  }
  {
    name: 'AZURE_PIPES_CONTAINER'
    value: dagsterContainerName
  }
  {
    name: 'ACA_RUN_JOB_NAME'
    value: runJobName
  }
  // The warehouse connection, for dbt and for PyAirbyte's Postgres cache.
  // No password: POSTGRES_ENTRA_AUTH makes the entrypoint mint a token.
  {
    name: 'POSTGRES_ENTRA_AUTH'
    value: '1'
  }
  {
    name: 'POSTGRES_HOST'
    value: postgresHost
  }
  {
    name: 'POSTGRES_PORT'
    value: '5432'
  }
  {
    name: 'POSTGRES_USER'
    value: postgresUser
  }
  {
    name: 'POSTGRES_DB'
    value: retailDatabase
  }
]

// Only the containers that load user code need to know how to launch an
// ingest sync: pipeline/resources.py switches to the Container Apps Pipes
// client on the presence of ACA_INGEST_JOB_NAME. The webserver and daemon
// load no user code at all -- that is the point of the gRPC code server -- so
// setting it there would be misleading.
var codeEnv = concat(baseEnv, [
  {
    name: 'ACA_INGEST_JOB_NAME'
    value: ingestJobName
  }
  {
    name: 'SFTP_HOST'
    value: sftpHost
  }
  {
    name: 'SFTP_PORT'
    value: '22'
  }
  {
    name: 'SFTP_USER'
    value: sftpUserName
  }
  {
    name: 'SFTP_FOLDER_PATH'
    value: sftpFolderPath
  }
])

var registries = [
  {
    server: registryLoginServer
    identity: identityId
  }
]

var identityConfig = {
  type: 'UserAssigned'
  userAssignedIdentities: {
    '${identityId}': {}
  }
}

// ---------------------------------------------------------------------------
// Code location.
//
// Internal ingress with HTTP/2 transport, which is how gRPC works over
// Container Apps. `allowInsecure` stays false: ingress serves TLS, and
// workspace.azure.yaml sets ssl: true to match. A mismatch here is a
// handshake error that names nothing useful, so the two have to move together.
// ---------------------------------------------------------------------------
resource codeApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-${namePrefix}-code'
  location: location
  tags: tags
  identity: identityConfig
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      ingress: {
        external: false
        targetPort: 4000
        exposedPort: 0
        transport: 'http2'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'main'
          image: orchestratorImage
          env: codeEnv
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]
      scale: {
        // Never zero. A code server that has scaled to zero makes the whole
        // UI show the code location as unavailable, and the cold start lands
        // on whoever opened the page.
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// For an app with internal ingress this is already the internal-only name --
// ca-<prefix>-code.internal.<environment default domain> -- and it resolves
// nowhere outside the environment.
var codeServerHost = codeApp.properties.configuration.ingress.fqdn

// ---------------------------------------------------------------------------
// Webserver.
// ---------------------------------------------------------------------------
resource webserverApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-${namePrefix}-webserver'
  location: location
  tags: tags
  identity: identityConfig
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      ingress: {
        external: true
        targetPort: 3000
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'main'
          image: orchestratorImage
          args: [
            'dagster-webserver'
            '--host'
            '0.0.0.0'
            '--port'
            '3000'
            '--workspace'
            '/opt/etl/workspace.azure.yaml'
          ]
          env: concat(baseEnv, [
            {
              name: 'DAGSTER_CODE_SERVER_HOST'
              value: codeServerHost
            }
          ])
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Daemon.
//
// minReplicas == maxReplicas == 1 is a correctness constraint, not a cost
// setting. The daemon owns schedules, sensors and the run queue; a second
// replica double-fires every schedule and races the queue. There is no
// leader election to fall back on.
// ---------------------------------------------------------------------------
resource daemonApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-${namePrefix}-daemon'
  location: location
  tags: tags
  identity: identityConfig
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      // No ingress. Nothing connects to the daemon; it connects outward.
    }
    template: {
      containers: [
        {
          name: 'main'
          image: orchestratorImage
          args: [
            'dagster-daemon'
            'run'
            '--workspace'
            '/opt/etl/workspace.azure.yaml'
          ]
          env: concat(baseEnv, [
            {
              name: 'DAGSTER_CODE_SERVER_HOST'
              value: codeServerHost
            }
          ])
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

output webserverFqdn string = webserverApp.properties.configuration.ingress.fqdn
output codeServerHost string = codeServerHost
output codeAppName string = codeApp.name
output daemonAppName string = daemonApp.name
output webserverAppName string = webserverApp.name
