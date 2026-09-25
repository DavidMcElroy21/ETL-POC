// The two ephemeral workloads.
//
//   caj-<prefix>-run     one execution per Dagster run
//   caj-<prefix>-ingest  one execution per ingest sync
//
// Both are Manual-trigger jobs, which in Container Apps means "nothing starts
// these except an explicit API call". Dagster makes that call: the run
// launcher for the first, the Pipes client for the second. Neither is ever
// started by the platform, and neither has a schedule -- scheduling belongs to
// the Dagster daemon, which already owns it.
//
// The `args` below are a deliberate refusal rather than a real command. Every
// real execution arrives with an override that supplies both, so a job started
// by hand with no override should say so and exit rather than run something
// arbitrary.

// No namePrefix parameter here on purpose: both job names arrive as
// parameters, because the code location has to be told the ingest job's name
// before either job exists. Deriving them a second time would create two
// sources of truth for one string.

@description('Location for all resources.')
param location string

@description('Tags applied to every resource.')
param tags object

@description('Container Apps managed environment.')
param environmentId string

@description('Registry login server.')
param registryLoginServer string

param orchestratorImage string
param ingestImage string

param identityId string
param identityClientId string

@description('The identity name, which is also the PostgreSQL role the workloads connect as.')
param postgresUser string

param postgresHost string
param dagsterDatabase string
param retailDatabase string

param storageAccountName string
param blobEndpoint string
param dagsterContainerName string = 'dagster'

@description('Name of the ingest job, so the run worker knows what to start.')
param ingestJobName string

@description('Name of this run job, so a run worker that launches sub-runs uses the same one.')
param runJobName string

param sftpHost string = ''
param sftpUserName string = ''
param sftpFolderPath string = '/sftp/retail'

@description('Key Vault URI of the SFTP local-user password, e.g. https://kv-x.vault.azure.net/secrets/sftp-password. Empty when the demo SFTP source is not deployed.')
param sftpPasswordSecretUri string = ''

@description('Seconds a single execution may run before Container Apps kills it.')
param replicaTimeoutSeconds int = 3600

var subscriptionId = subscription().subscriptionId
var resourceGroupName = resourceGroup().name
var hasSftp = !empty(sftpPasswordSecretUri)

var identityConfig = {
  type: 'UserAssigned'
  userAssignedIdentities: {
    '${identityId}': {}
  }
}

var registries = [
  {
    server: registryLoginServer
    identity: identityId
  }
]

var runEnv = [
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
  {
    name: 'ACA_INGEST_JOB_NAME'
    value: ingestJobName
  }
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
]

// ---------------------------------------------------------------------------
// Run worker.
//
// replicaRetryLimit: 0 is the important line. Container Apps retries a failed
// replica by starting the container again with the same arguments -- which
// here means executing the same Dagster run a second time, against an event
// log that already has that run's events in it. Retries are Dagster's job and
// Dagster already does them; the platform must not have an opinion.
// ---------------------------------------------------------------------------
resource runJob 'Microsoft.App/jobs@2024-03-01' = {
  name: runJobName
  location: location
  tags: tags
  identity: identityConfig
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: replicaTimeoutSeconds
      replicaRetryLimit: 0
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
      registries: registries
    }
    template: {
      containers: [
        {
          name: 'main'
          image: orchestratorImage
          args: [
            'python'
            '-c'
            'import sys; sys.exit("run worker: started with no execution override; the Dagster run launcher supplies the command")'
          ]
          env: runEnv
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Ingest job.
//
// The SFTP password is the only real secret in the deployment, and it never
// appears here: the secret below is a Key Vault reference resolved by the
// managed identity at container start. It is also why the Pipes client merges
// environment variables by name instead of replacing the list -- a replacement
// would drop this secretRef and the sync would fail to authenticate.
// ---------------------------------------------------------------------------
var ingestEnv = concat(runEnv, hasSftp ? [
  {
    name: 'SFTP_PASSWORD'
    secretRef: 'sftp-password'
  }
] : [])

resource ingestJob 'Microsoft.App/jobs@2024-03-01' = {
  name: ingestJobName
  location: location
  tags: tags
  identity: identityConfig
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: replicaTimeoutSeconds
      // Same reasoning as the run worker. A retried sync would re-read the
      // same files into the same cache while Dagster believed one attempt was
      // in flight.
      replicaRetryLimit: 0
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
      registries: registries
      secrets: hasSftp ? [
        {
          name: 'sftp-password'
          keyVaultUrl: sftpPasswordSecretUri
          identity: identityId
        }
      ] : []
    }
    template: {
      containers: [
        {
          name: 'main'
          image: ingestImage
          args: [
            'python'
            '-c'
            'import sys; sys.exit("ingest job: started with no execution override; Dagster Pipes supplies the module to run")'
          ]
          env: ingestEnv
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
        }
      ]
    }
  }
}

output runJobName string = runJob.name
output ingestJobName string = ingestJob.name
