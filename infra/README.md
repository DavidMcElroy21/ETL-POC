# Deploying ETL-POC to Azure

The local stack is one image and three fixture containers, run by
`docker compose`. This directory deploys the same pipeline to Azure Container
Apps with the Dagster processes separated the way Dagster is meant to be run,
and with ingestion as its own image in its own container.

```
                      ACA Environment (VNet-injected)
  ┌──────────────────────────────────────────────────────────────┐
  │  ca-<prefix>-webserver   external ingress 443 → 3000         │
  │  ca-<prefix>-daemon      no ingress, min = max = 1 replica   │
  │  ca-<prefix>-code        internal ingress, HTTP/2 gRPC :4000 │
  │                                                              │
  │  caj-<prefix>-run        Job — one execution per Dagster run │
  │  caj-<prefix>-ingest     Job — one execution per sync        │
  └──────────────────────────────────────────────────────────────┘
        │ private endpoints / delegated subnets
        ▼
  PostgreSQL Flexible Server        ADLS Gen2 storage account
    dagster   run + event storage     dagster   Pipes, compute logs
    retail    the warehouse           lake      object storage
                                      sftp      SFTP landing zone
  PostgreSQL Flexible Server (demo, wal_level=logical) — CDC source
```

## Two images, five workloads

| Image | Contains | Runs as |
|---|---|---|
| `etl-poc-orchestrator` | Dagster, dagster-dbt, dbt-postgres, the dbt project, `pipeline/` | webserver, daemon, code location, run worker |
| `etl-poc-ingest` | PyAirbyte, the baked connector venvs, `ingest/` | ingest job |

Both come from the existing `Dockerfile`, as the `orchestrator` and `ingest`
targets. The venv split that phase 1 needed for dependency reasons is what
makes this split cheap: the two stages already existed.

`ingest/streams.py` ships in **both** images. It is the single definition of
the stream list and the raw schema names, and shipping it twice is what stops
the Dagster asset keys and the connector configuration drifting apart. It is
standard library only, so the orchestrator image can import it without
PyAirbyte.

## Prerequisites

- Azure CLI 2.60 or later, logged in to the target subscription.
- **Owner**, or Contributor plus **User Access Administrator**. The deployment
  creates a custom role definition and four role assignments; Contributor alone
  cannot do either.
- Docker is *not* required. Images are built by `az acr build`, inside the
  registry.

## Deploying

```bash
./infra/deploy.sh rg-etl-poc eastus
```

```powershell
.\infra\deploy.ps1 -ResourceGroup rg-etl-poc -Location eastus
```

The script runs the same template twice, with image builds in between:

1. **Infrastructure** — `deployWorkloads=false`. Everything except the apps and
   jobs.
2. **Images and secrets** — build and push both images; have Azure generate the
   SFTP local-user password and store it in Key Vault; upload the retail CSVs.
3. **Workloads** — `deployWorkloads=true`.

The split is forced, not stylistic. A container app revision that cannot pull
its image fails, and on the first pass the registry the apps would pull from
was created by that same deployment and is empty. The Key Vault reference on
the ingest job has the same shape of problem: it resolves when the revision
starts, so the secret must already exist.

Images are tagged with the source commit rather than `latest`, so a running
revision names exactly what it was built from.

## Grant the identity inside PostgreSQL

**One manual step is required before a pipeline run will succeed**, and it is
not an oversight in the template: creating database objects is a data-plane
operation, and nothing in ARM or Bicep can express it.

The managed identity is the server's Entra administrator, so it can create what
it needs — but the schemas that `postgres/init.sql` creates locally have no
equivalent here. Connect to the `retail` database and run that file:

```bash
# From a machine on the VNet, or through a jump host -- the server has no
# public endpoint.
export PGPASSWORD="$(az account get-access-token \
  --resource-type oss-rdbms --query accessToken --output tsv)"
psql "host=<postgresFqdn> port=5432 dbname=retail user=<your-entra-upn> sslmode=require" \
  --file postgres/init.sql
```

The token *is* the password — that is how Entra authentication to Azure
Database for PostgreSQL works, and it is the same trick
`scripts/azure/entra_pg_token.py` uses inside the containers.

To narrow the identity's rights afterwards, connect as the admin and create a
non-privileged role instead:

```sql
SELECT * FROM pgaadauth_create_principal('<identity-name>', false, false);
GRANT ALL ON SCHEMA airbyte_raw, retail, retail_staging, retail_marts TO "<identity-name>";
```

then remove the Entra administrator assignment from `postgres.bicep`. The
template leaves the identity as administrator because doing otherwise would
make a first deployment fail with a permissions error before anyone could run
the grant.

## No passwords

Nothing in this deployment stores a credential for Azure, with exactly one
exception.

- **Registry** — the apps pull as the managed identity. No admin user is
  enabled, so there is no registry password to leak.
- **Storage** — Entra, via `Storage Blob Data Contributor` on the identity.
- **PostgreSQL** — the warehouse has `passwordAuth: Disabled`. It has no
  password to steal because it has no password. `dagster-postgres[azure]`
  mints a token for its own connections; dbt and PyAirbyte read
  `POSTGRES_PASSWORD`, which `scripts/azure/entrypoint.sh` fills with a token
  at container start.
- **The exception: the SFTP local user.** Blob Storage SFTP authenticates
  through "local users", an identity system that does not interoperate with
  Entra, managed identity or Azure RBAC at all. That password is generated by
  Azure, stored in Key Vault, and reaches the ingest job as a Key Vault-backed
  Container Apps secret. It never appears in the template or in a deployment
  history.

The job-start permission is a **custom role**, not the built-in one. The
Container Apps documentation warns that a wildcard over
`Microsoft.App/jobs/*/action` also matches `listSecrets`, which would let the
holder read every secret on the job in plain text. The role here contains four
actions and no wildcard:

```
Microsoft.App/jobs/read              clone the template before overriding it
Microsoft.App/jobs/start/action      start an execution
Microsoft.App/jobs/stop/action       terminate a run, time out a sync
Microsoft.App/jobs/executions/read   poll status for run monitoring
```

## Things that are load-bearing

**The daemon is pinned to one replica.** `minReplicas: 1, maxReplicas: 1` on
`ca-<prefix>-daemon` is a correctness constraint, not a cost setting. The
daemon owns schedules, sensors and the run queue, and there is no leader
election. A second replica double-fires every schedule.

**`replicaRetryLimit: 0` on both jobs.** Container Apps retries a failed
replica by re-running the container with the same arguments — which here means
executing the same Dagster run a second time against an event log that already
contains it. Retries belong to Dagster, which already does them.

**Execution overrides replace the whole template.** From the Azure docs: *"the
job's entire template configuration is replaced with the new configuration"*.
Send a template with only a command and the image, resource limits and
secret-backed environment variables are gone for that execution — and the
container then fails in ways that look nothing like the cause. Every override
in `pipeline/azure/aca_client.py` is built by reading the deployed job and
copying it forward.

**Overrides go through the entrypoint.** Container Apps' `command` maps to the
image's `ENTRYPOINT`, not to `CMD`. Both the run launcher and the Pipes client
therefore prepend `/opt/etl/scripts/azure/entrypoint.sh` to the command they
build — without that the Postgres token is never minted and the instance config
is never laid down. The three container apps sidestep this by setting `args`
only, which replaces `CMD` and leaves the entrypoint alone.

**gRPC needs `ssl: true`.** Container Apps terminates TLS at its ingress, so
`workspace.azure.yaml` sets `ssl: true` against port 443. A mismatch surfaces
as a handshake error that names nothing useful.

**The dbt manifest is baked at build time.** `prepare_if_dev()` was removed in
phase 1 so the image works offline, and nothing regenerates `manifest.json` at
runtime. Any dbt model change needs an image rebuild — the same constraint as
the local stack.

## Parameters worth knowing

| Parameter | Default | Effect |
|---|---|---|
| `deployDemoSources` | `true` | SFTP landing zone, `lake` container, and the `wal_level=logical` CDC server. Replaces atmoz/sftp, MinIO and postgres-source. **SFTP bills hourly whenever it is enabled**, and the CDC server is a second Flexible Server — real money on both counts. |
| `internalOnly` | `false` | Internal load balancer only. The Dagster UI then has no public address and needs a VPN or bastion. |
| `registryAllowPublicNetworkAccess` | `true` | Needed to push images from a developer machine or a hosted CI runner, neither of which is on this VNet. The private endpoint carries the pull path either way. |
| `storageAllowPublicNetworkAccess` | `true` | Needed to seed the sample data and write the Key Vault secret from outside the VNet. |
| `replicaTimeoutSeconds` | `3600` | Ceiling on a single execution. Keep it above `ACA_INGEST_TIMEOUT_SECONDS` so Dagster reports a timeout first, with a message that explains it. |
| `alertEmail` | `''` | Notification target. Empty still creates the alert rules, just with nowhere to send. |

Turning the demo sources off also turns off shared-key access on the storage
account, because SFTP local users are the only thing that needs it. With
`deployDemoSources=false` the account has no key-based path at all.

## Verifying a deployment

1. The Dagster UI answers on the webserver FQDN, and the code location loads.
   A code location that fails to load is usually a stale baked dbt manifest or
   the `ssl: true` mismatch above.
2. The daemon shows a recent heartbeat.
3. Materialize the `airbyte_raw` asset group. An execution appears under
   `caj-<prefix>-run`, and a second under `caj-<prefix>-ingest`.
4. The phase-1 acceptance criterion still holds:
   `Done. PASS=52 WARN=13 ERROR=0 SKIP=0 NO-OP=0 TOTAL=65`, exit 0.
5. Stop a run worker execution mid-run
   (`az containerapp job stop --name caj-<prefix>-run --job-execution-name ...`)
   and confirm the daemon marks the run failed rather than leaving it STARTED.
   That path is `check_run_worker_health` in `pipeline/azure/run_launcher.py`.

## Tearing down

```bash
az group delete --name rg-etl-poc --yes
```

The custom role definition is scoped to the resource group and goes with it.
Key Vault has soft delete enabled with a 7-day retention, so redeploying the
same name inside a week needs `az keyvault purge` first.
