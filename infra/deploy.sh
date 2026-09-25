#!/usr/bin/env bash
# Deploy ETL-POC to Azure.
#
#   ./infra/deploy.sh <resource-group> [location]
#
# Three phases, in this order for reasons the template cannot express:
#
#   1. Infrastructure. No container apps, because the registry they would pull
#      from is created by this same deployment and is empty.
#   2. Images, secrets and sample data. Build and push both images; have Azure
#      generate the SFTP local-user password and store it in Key Vault; upload
#      the retail CSVs to the SFTP container.
#   3. Workloads. The three apps and the two jobs, now that every image and
#      every secret they reference exists.
#
# Re-running is safe and is the normal way to deploy a new image: phase 1 is a
# no-op against unchanged infrastructure, and phase 3 rolls the apps onto the
# new tag.
set -euo pipefail

RESOURCE_GROUP="${1:-}"
LOCATION="${2:-eastus}"
NAME_PREFIX="${NAME_PREFIX:-etl-poc}"

if [ -z "${RESOURCE_GROUP}" ]; then
  echo "usage: $0 <resource-group> [location]" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Tag images with the source commit rather than 'latest', so what is deployed
# names exactly what it was built from. A dirty tree gets a -dirty suffix,
# which is not a deployable state but is an honest label while iterating.
GIT_SHA="$(git rev-parse --short HEAD)"
if ! git diff --quiet || ! git diff --cached --quiet; then
  GIT_SHA="${GIT_SHA}-dirty"
fi
IMAGE_TAG="${IMAGE_TAG:-${GIT_SHA}}"

echo "==> Resource group ${RESOURCE_GROUP} (${LOCATION}), image tag ${IMAGE_TAG}"

az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --output none

# ---------------------------------------------------------------------------
# Phase 1: infrastructure.
#
# The CDC demo server needs a password because the Airbyte source-postgres
# connector cannot use Entra. Generated here and kept only in Key Vault; it is
# passed to the template as a secure parameter, so it does not appear in the
# deployment history.
# ---------------------------------------------------------------------------
CDC_PASSWORD="$(openssl rand -base64 24 | tr -d '\n/+=' | head -c 24)Aa1!"

echo "==> Phase 1: infrastructure"
az deployment group create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "etl-poc-infra" \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.json \
  --parameters namePrefix="${NAME_PREFIX}" \
               deployWorkloads=false \
               cdcAdminPassword="${CDC_PASSWORD}" \
  --output none

read_output() {
  az deployment group show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "etl-poc-infra" \
    --query "properties.outputs.$1.value" \
    --output tsv
}

REGISTRY_NAME="$(read_output registryName)"
LOGIN_SERVER="$(read_output registryLoginServer)"
STORAGE_ACCOUNT="$(read_output storageAccountName)"
KEY_VAULT="$(read_output keyVaultName)"
KEY_VAULT_URI="$(read_output keyVaultUri)"
SFTP_LOCAL_USER="$(read_output sftpLocalUserName)"
DEPLOY_DEMO="$(az deployment group show --resource-group "${RESOURCE_GROUP}" --name etl-poc-infra \
  --query "properties.parameters.deployDemoSources.value" --output tsv)"

echo "    registry        ${LOGIN_SERVER}"
echo "    storage         ${STORAGE_ACCOUNT}"
echo "    key vault       ${KEY_VAULT}"

# ---------------------------------------------------------------------------
# Phase 2a: build and push.
#
# `az acr build` runs the build inside ACR rather than locally. That is worth
# the round trip here: the Dockerfile fetches its source from a pinned git
# commit, so the build does not need the working tree, and an ACR Task has the
# network access a build needs without the registry having to be reachable
# from wherever this script runs.
# ---------------------------------------------------------------------------
echo "==> Phase 2a: building images in ACR"
az acr build \
  --registry "${REGISTRY_NAME}" \
  --image "etl-poc-orchestrator:${IMAGE_TAG}" \
  --target orchestrator \
  --file Dockerfile \
  . \
  --output none

az acr build \
  --registry "${REGISTRY_NAME}" \
  --image "etl-poc-ingest:${IMAGE_TAG}" \
  --target ingest \
  --file Dockerfile \
  . \
  --output none

# ---------------------------------------------------------------------------
# Phase 2b: the one real secret, and the sample data.
# ---------------------------------------------------------------------------
SFTP_SECRET_URI=""
if [ "${DEPLOY_DEMO}" = "true" ]; then
  echo "==> Phase 2b: SFTP credential and sample data"

  # Azure generates the password; there is no API that returns an existing
  # one, so regenerating is the only way to learn it. Doing this on every
  # deployment would invalidate the value the running ingest job holds, so it
  # only happens when the secret is not already in the vault.
  if ! az keyvault secret show --vault-name "${KEY_VAULT}" --name sftp-password --output none 2>/dev/null; then
    SFTP_PASSWORD="$(az storage account local-user regenerate-password \
      --account-name "${STORAGE_ACCOUNT}" \
      --resource-group "${RESOURCE_GROUP}" \
      --user-name "${SFTP_LOCAL_USER}" \
      --query sshPassword --output tsv)"

    az keyvault secret set \
      --vault-name "${KEY_VAULT}" \
      --name sftp-password \
      --value "${SFTP_PASSWORD}" \
      --output none
    unset SFTP_PASSWORD
    echo "    stored sftp-password in ${KEY_VAULT}"
  else
    echo "    sftp-password already present in ${KEY_VAULT}; leaving it alone"
  fi

  SFTP_SECRET_URI="${KEY_VAULT_URI}secrets/sftp-password"

  # The retail CSVs, into the path the SFTP local user's home maps onto.
  # --auth-mode login so this uses the operator's Entra identity rather than
  # an account key.
  az storage blob upload-batch \
    --account-name "${STORAGE_ACCOUNT}" \
    --auth-mode login \
    --destination sftp \
    --destination-path retail \
    --source data/sftp/retail \
    --pattern "*.csv" \
    --overwrite \
    --output none
  echo "    uploaded sample data to sftp/retail"

  # The CDC source database still needs its schema and seed rows. That is a
  # data-plane step against a server with no public endpoint, so it is not
  # something this script can do from outside the VNet; see infra/README.md.
fi

# ---------------------------------------------------------------------------
# Phase 3: workloads.
# ---------------------------------------------------------------------------
echo "==> Phase 3: container apps and jobs"
az deployment group create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "etl-poc-workloads" \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.json \
  --parameters namePrefix="${NAME_PREFIX}" \
               deployWorkloads=true \
               imageTag="${IMAGE_TAG}" \
               sftpPasswordSecretUri="${SFTP_SECRET_URI}" \
               cdcAdminPassword="${CDC_PASSWORD}" \
  --output none

DAGSTER_URL="$(az deployment group show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "etl-poc-workloads" \
  --query "properties.outputs.dagsterUrl.value" --output tsv)"

echo
echo "==> Done."
echo "    Dagster UI: ${DAGSTER_URL}"
echo
echo "    One manual step remains before a pipeline run will succeed: the"
echo "    managed identity needs database-level grants that ARM cannot make."
echo "    See 'Grant the identity inside PostgreSQL' in infra/README.md."
