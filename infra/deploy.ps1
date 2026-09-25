# Deploy ETL-POC to Azure. PowerShell equivalent of deploy.sh.
#
#   .\infra\deploy.ps1 -ResourceGroup rg-etl-poc -Location eastus
#
# Same three phases, same reasons. See the comments in deploy.sh; they are not
# repeated here so the two cannot drift into disagreeing with each other.
#
# Written for Windows PowerShell 5.1 as well as PowerShell 7, which is why it
# avoids &&, ternaries and null-coalescing throughout.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$Location = 'eastus',

    [string]$NamePrefix = 'etl-poc',

    [string]$ImageTag
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot

try {
    if (-not $ImageTag) {
        $gitSha = (git rev-parse --short HEAD).Trim()
        git diff --quiet
        $dirty = -not $?
        if (-not $dirty) {
            git diff --cached --quiet
            $dirty = -not $?
        }
        if ($dirty) {
            $ImageTag = "$gitSha-dirty"
        }
        else {
            $ImageTag = $gitSha
        }
    }

    Write-Host "==> Resource group $ResourceGroup ($Location), image tag $ImageTag"
    az group create --name $ResourceGroup --location $Location --output none

    # A generated password for the CDC demo server, which cannot use Entra.
    $bytes = New-Object 'System.Byte[]' 18
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $cdcPassword = ([System.Convert]::ToBase64String($bytes) -replace '[/+=]', '') + 'Aa1!'

    Write-Host '==> Phase 1: infrastructure'
    az deployment group create `
        --resource-group $ResourceGroup `
        --name 'etl-poc-infra' `
        --template-file infra/main.bicep `
        --parameters infra/main.parameters.json `
        --parameters namePrefix=$NamePrefix deployWorkloads=false cdcAdminPassword=$cdcPassword `
        --output none

    function Read-Output([string]$Name) {
        return (az deployment group show `
                --resource-group $ResourceGroup `
                --name 'etl-poc-infra' `
                --query "properties.outputs.$Name.value" `
                --output tsv).Trim()
    }

    $registryName = Read-Output 'registryName'
    $loginServer = Read-Output 'registryLoginServer'
    $storageAccount = Read-Output 'storageAccountName'
    $keyVault = Read-Output 'keyVaultName'
    $keyVaultUri = Read-Output 'keyVaultUri'
    $sftpLocalUser = Read-Output 'sftpLocalUserName'

    $deployDemo = (az deployment group show --resource-group $ResourceGroup --name 'etl-poc-infra' `
            --query 'properties.parameters.deployDemoSources.value' --output tsv).Trim()

    Write-Host "    registry        $loginServer"
    Write-Host "    storage         $storageAccount"
    Write-Host "    key vault       $keyVault"

    Write-Host '==> Phase 2a: building images in ACR'
    az acr build --registry $registryName --image "etl-poc-orchestrator:$ImageTag" `
        --target orchestrator --file Dockerfile . --output none
    az acr build --registry $registryName --image "etl-poc-ingest:$ImageTag" `
        --target ingest --file Dockerfile . --output none

    $sftpSecretUri = ''
    if ($deployDemo -eq 'true') {
        Write-Host '==> Phase 2b: SFTP credential and sample data'

        $existing = az keyvault secret show --vault-name $keyVault --name 'sftp-password' --output none 2>$null
        if (-not $?) {
            $sftpPassword = (az storage account local-user regenerate-password `
                    --account-name $storageAccount `
                    --resource-group $ResourceGroup `
                    --user-name $sftpLocalUser `
                    --query sshPassword --output tsv).Trim()

            az keyvault secret set --vault-name $keyVault --name 'sftp-password' --value $sftpPassword --output none
            Remove-Variable sftpPassword
            Write-Host "    stored sftp-password in $keyVault"
        }
        else {
            Write-Host "    sftp-password already present in $keyVault; leaving it alone"
        }

        $sftpSecretUri = "${keyVaultUri}secrets/sftp-password"

        az storage blob upload-batch `
            --account-name $storageAccount `
            --auth-mode login `
            --destination sftp `
            --destination-path retail `
            --source data/sftp/retail `
            --pattern '*.csv' `
            --overwrite `
            --output none
        Write-Host '    uploaded sample data to sftp/retail'
    }

    Write-Host '==> Phase 3: container apps and jobs'
    az deployment group create `
        --resource-group $ResourceGroup `
        --name 'etl-poc-workloads' `
        --template-file infra/main.bicep `
        --parameters infra/main.parameters.json `
        --parameters namePrefix=$NamePrefix deployWorkloads=true imageTag=$ImageTag sftpPasswordSecretUri=$sftpSecretUri cdcAdminPassword=$cdcPassword `
        --output none

    $dagsterUrl = (az deployment group show `
            --resource-group $ResourceGroup `
            --name 'etl-poc-workloads' `
            --query 'properties.outputs.dagsterUrl.value' --output tsv).Trim()

    Write-Host ''
    Write-Host '==> Done.'
    Write-Host "    Dagster UI: $dagsterUrl"
    Write-Host ''
    Write-Host '    One manual step remains before a pipeline run will succeed: the'
    Write-Host '    managed identity needs database-level grants that ARM cannot make.'
    Write-Host "    See 'Grant the identity inside PostgreSQL' in infra/README.md."
}
finally {
    Pop-Location
}
