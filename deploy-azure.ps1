<#
.SYNOPSIS
    Creates the Azure resources for the P1 API Monitor and deploys it to Azure Container Apps.

.DESCRIPTION
    The image is built with your local Docker, pushed to Azure Container Registry, and run in
    Azure Container Apps (1 replica, port 8080, HTTPS on the Container Apps address).
    Settings are read from .env in this folder. Secrets are stored as Container Apps secrets and are never printed.
    Running the script again updates the existing app with a new image and the current .env values.

    Requires: Azure CLI (az), Docker Desktop running, and a .env file made from .env.example.

.EXAMPLE
    .\deploy-azure.ps1 -Suffix jc01

.EXAMPLE
    .\deploy-azure.ps1 -Suffix jc01 -AllowedIpRange 203.0.113.0/24
#>
[CmdletBinding()]
param(
    # Short text, lowercase letters and digits only (3-12 characters). Makes the registry and storage account names unique.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{3,12}$')]
    [string]$Suffix,

    [string]$ResourceGroup = "rg-p1-api-monitor",
    [string]$Location = "eastus",
    [string]$AppName = "p1-api-monitor",
    [string]$EnvironmentName = "cae-p1-api-monitor",
    [string]$Subscription = "",
    [string]$EnvFile = (Join-Path $PSScriptRoot ".env"),
    [string]$StorageContainer = "p1-api-monitor",
    [string]$StorageFolder = "p1-api-monitor",

    # Optional. Only this address range can open the SWAT board (recommended, because the board has no login).
    [string]$AllowedIpRange = ""
)

# Continue (not Stop): the Azure CLI and Docker write progress to stderr, which would stop the script.
# Every external command is checked with $LASTEXITCODE instead.
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

function Invoke-Az {
    param([string[]]$AzArgs)
    & az @AzArgs
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $($AzArgs[0]) $($AzArgs[1])" }
}

# Runs a read-only az query. Returns the trimmed output, or $null when the command fails (for example when not logged in).
function Test-Az {
    param([string[]]$AzArgs)
    $output = & az @AzArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return (($output | Out-String).Trim())
}

function Read-EnvFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "No .env file at $Path. Copy .env.example to .env and fill it in first." }
    $values = @{}
    foreach ($line in Get-Content $Path) {
        $text = $line.Trim()
        if ($text -eq "" -or $text.StartsWith("#")) { continue }
        $i = $text.IndexOf("=")
        if ($i -lt 1) { continue }
        $key = $text.Substring(0, $i).Trim()
        $value = $text.Substring($i + 1).Trim().Trim('"').Trim("'")
        $values[$key] = $value
    }
    return $values
}

# ---------------------------------------------------------------- checks

Write-Host "== Checking tools" -ForegroundColor Cyan
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is not installed. Install it from https://learn.microsoft.com/cli/azure/install-azure-cli"
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is not installed or not on PATH. Install Docker Desktop."
}
docker info | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Docker is not running. Start Docker Desktop and try again." }

$settings = Read-EnvFile $EnvFile
foreach ($key in @("SN_INSTANCE", "SN_CLIENT_ID", "SN_CLIENT_SECRET")) {
    if (-not $settings[$key]) { throw "$key is empty in $EnvFile" }
}

# ---------------------------------------------------------------- Azure login and setup

Write-Host "== Azure login" -ForegroundColor Cyan
if (-not (Test-Az @("account", "show", "--query", "id", "-o", "tsv"))) {
    Invoke-Az -AzArgs @("login", "--only-show-errors")
}
if ($Subscription) {
    Invoke-Az -AzArgs @("account", "set", "--subscription", $Subscription)
}

Write-Host "== Preparing Azure CLI extensions and resource providers" -ForegroundColor Cyan
Invoke-Az -AzArgs @("extension", "add", "--name", "containerapp", "--upgrade", "--only-show-errors")
Invoke-Az -AzArgs @("provider", "register", "--namespace", "Microsoft.App", "--wait", "--only-show-errors")
Invoke-Az -AzArgs @("provider", "register", "--namespace", "Microsoft.OperationalInsights", "--wait", "--only-show-errors")

Write-Host "== Resource group $ResourceGroup" -ForegroundColor Cyan
Invoke-Az -AzArgs @("group", "create", "--name", $ResourceGroup, "--location", $Location, "--only-show-errors") | Out-Null

# ---------------------------------------------------------------- storage

$storageName = "stp1apimon$Suffix"
$acrName = "acrp1apimon$Suffix"

if ($settings["AZURE_STORAGE_CONNECTION_STRING"]) {
    Write-Host "== Storage: using AZURE_STORAGE_CONNECTION_STRING from .env" -ForegroundColor Cyan
    $storageConn = $settings["AZURE_STORAGE_CONNECTION_STRING"]
}
else {
    Write-Host "== Storage account $storageName" -ForegroundColor Cyan
    $found = Test-Az @("storage", "account", "list", "--resource-group", $ResourceGroup, "--query", "[?name=='$storageName'].name", "-o", "tsv")
    if (-not $found) {
        Invoke-Az -AzArgs @("storage", "account", "create", "--name", $storageName, "--resource-group", $ResourceGroup, "--location", $Location, "--sku", "Standard_LRS", "--kind", "StorageV2", "--only-show-errors") | Out-Null
    }
    $storageConn = Test-Az @("storage", "account", "show-connection-string", "--name", $storageName, "--resource-group", $ResourceGroup, "--query", "connectionString", "-o", "tsv")
    if (-not $storageConn) { throw "Could not read the connection string of storage account $storageName." }
    Write-Host "Connection string read from the storage account (not printed)."
}

Write-Host "== Storage container $StorageContainer (the monitor also creates it on start)" -ForegroundColor Cyan
Invoke-Az -AzArgs @("storage", "container", "create", "--name", $StorageContainer, "--connection-string", $storageConn, "--only-show-errors") | Out-Null

# ---------------------------------------------------------------- container registry

Write-Host "== Container registry $acrName" -ForegroundColor Cyan
$found = Test-Az @("acr", "list", "--resource-group", $ResourceGroup, "--query", "[?name=='$acrName'].name", "-o", "tsv")
if (-not $found) {
    Invoke-Az -AzArgs @("acr", "create", "--name", $acrName, "--resource-group", $ResourceGroup, "--location", $Location, "--sku", "Basic", "--admin-enabled", "true", "--only-show-errors") | Out-Null
}
$loginServer = Test-Az @("acr", "show", "--name", $acrName, "--query", "loginServer", "-o", "tsv")
$acrPassword = Test-Az @("acr", "credential", "show", "--name", $acrName, "--query", "passwords[0].value", "-o", "tsv")
if (-not $loginServer -or -not $acrPassword) { throw "Could not read the registry details for $acrName." }

# ---------------------------------------------------------------- Container Apps environment

Write-Host "== Container Apps environment $EnvironmentName" -ForegroundColor Cyan
$found = Test-Az @("containerapp", "env", "list", "--resource-group", $ResourceGroup, "--query", "[?name=='$EnvironmentName'].name", "-o", "tsv")
if (-not $found) {
    Write-Host "Creating the environment (this takes a few minutes)..."
    Invoke-Az -AzArgs @("containerapp", "env", "create", "--name", $EnvironmentName, "--resource-group", $ResourceGroup, "--location", $Location, "--only-show-errors") | Out-Null
}

# ---------------------------------------------------------------- build locally and push

$tag = Get-Date -Format "yyyyMMddHHmmss"
$image = "$loginServer/p1-api-monitor"

Write-Host "== Building the image with local Docker (tag $tag)" -ForegroundColor Cyan
docker build -t "${image}:$tag" -t "${image}:latest" $PSScriptRoot
if ($LASTEXITCODE -ne 0) { throw "docker build failed." }

Write-Host "== Pushing the image to $loginServer" -ForegroundColor Cyan
$acrPassword | docker login $loginServer --username $acrName --password-stdin
if ($LASTEXITCODE -ne 0) { throw "docker login to $loginServer failed." }
docker push "${image}:$tag"
if ($LASTEXITCODE -ne 0) { throw "docker push failed." }
docker push "${image}:latest"
if ($LASTEXITCODE -ne 0) { throw "docker push failed." }

# ---------------------------------------------------------------- settings for the app

# Secrets: stored in Container Apps, referenced by name from the environment variables.
$secrets = @(
    "acr-password=$acrPassword",
    "client-secret=$($settings['SN_CLIENT_SECRET'])",
    "storage-connection-string=$storageConn"
)
$envVars = @(
    "SN_INSTANCE=$($settings['SN_INSTANCE'])",
    "SN_CLIENT_ID=$($settings['SN_CLIENT_ID'])",
    "SN_CLIENT_SECRET=secretref:client-secret",
    "AZURE_STORAGE_CONNECTION_STRING=secretref:storage-connection-string",
    "AZURE_STORAGE_CONTAINER=$StorageContainer",
    "AZURE_STORAGE_FOLDER=$StorageFolder",
    "SWAT_BOARD_PORT=8080"
)

# Optional plain settings: passed on only when they are set in .env.
foreach ($key in @("MONITOR_INTERVAL_MINUTES", "TEAMS_VERIFY_SSL", "EMAIL_TO", "EMAIL_CC", "EMAIL_BCC", "SMTP_HOST", "SMTP_PORT", "SMTP_STARTTLS", "SMTP_USER", "SMTP_FROM")) {
    if ($settings[$key]) { $envVars += "$key=$($settings[$key])" }
}
# Optional secrets: stored as secrets, never as plain values.
$optionalSecrets = @{ "TEAMS_WEBHOOK_URLS" = "teams-webhook"; "SMTP_PASSWORD" = "smtp-password" }
foreach ($key in $optionalSecrets.Keys) {
    $secretName = $optionalSecrets[$key]
    if ($settings[$key]) {
        $secrets += "$secretName=$($settings[$key])"
        $envVars += "$key=secretref:$secretName"
    }
}

# ---------------------------------------------------------------- create or update the app

$existing = Test-Az @("containerapp", "list", "--resource-group", $ResourceGroup, "--query", "[?name=='$AppName'].name", "-o", "tsv")

if ($existing) {
    Write-Host "== Updating $AppName" -ForegroundColor Cyan
    Invoke-Az -AzArgs (@("containerapp", "secret", "set", "--name", $AppName, "--resource-group", $ResourceGroup, "--secrets") + $secrets + @("--only-show-errors")) | Out-Null
    Invoke-Az -AzArgs (@("containerapp", "update", "--name", $AppName, "--resource-group", $ResourceGroup, "--image", "${image}:$tag", "--min-replicas", "1", "--max-replicas", "1", "--set-env-vars") + $envVars + @("--only-show-errors")) | Out-Null
}
else {
    Write-Host "== Creating $AppName" -ForegroundColor Cyan
    Invoke-Az -AzArgs (@(
        "containerapp", "create",
        "--name", $AppName,
        "--resource-group", $ResourceGroup,
        "--environment", $EnvironmentName,
        "--image", "${image}:$tag",
        "--registry-server", $loginServer,
        "--registry-username", $acrName,
        "--registry-password", $acrPassword,
        "--ingress", "external",
        "--target-port", "8080",
        "--transport", "auto",
        "--min-replicas", "1",
        "--max-replicas", "1",
        "--cpu", "0.25",
        "--memory", "0.5Gi",
        "--secrets"
    ) + $secrets + @("--env-vars") + $envVars + @("--only-show-errors")) | Out-Null
}

# ---------------------------------------------------------------- public address and access

$fqdn = Test-Az @("containerapp", "show", "--name", $AppName, "--resource-group", $ResourceGroup, "--query", "properties.configuration.ingress.fqdn", "-o", "tsv")
if (-not $fqdn) { throw "Could not read the public address of $AppName." }

Write-Host "== Setting the SWAT board address to https://$fqdn" -ForegroundColor Cyan
Invoke-Az -AzArgs @("containerapp", "update", "--name", $AppName, "--resource-group", $ResourceGroup, "--set-env-vars", "SWAT_BOARD_PUBLIC_URL=https://$fqdn", "--only-show-errors") | Out-Null

if ($AllowedIpRange) {
    Write-Host "== Allowing only $AllowedIpRange to reach the app" -ForegroundColor Cyan
    Invoke-Az -AzArgs @("containerapp", "ingress", "access-restriction", "set", "--name", $AppName, "--resource-group", $ResourceGroup, "--rule-name", "allowed-network", "--ip-address", $AllowedIpRange, "--action", "Allow", "--only-show-errors") | Out-Null
}
else {
    Write-Warning "No -AllowedIpRange given. The SWAT board has no login, so anyone with the address can use it. Re-run with -AllowedIpRange to restrict it."
}

# ---------------------------------------------------------------- check

Write-Host "== Checking the app (it can take a minute to start)" -ForegroundColor Cyan
Start-Sleep -Seconds 30
try {
    $response = Invoke-RestMethod -Uri "https://$fqdn/api/incidents" -TimeoutSec 60
    $count = @($response.incidents).Count
    Write-Host "The app answers. Incidents on the board: $count" -ForegroundColor Green
}
catch {
    Write-Warning "The app did not answer yet: $($_.Exception.Message)"
    Write-Warning "Check the logs: az containerapp logs show --name $AppName --resource-group $ResourceGroup --tail 100"
}

Write-Host ""
Write-Host "Deployed." -ForegroundColor Green
Write-Host "SWAT board:  https://$fqdn"
Write-Host "Logs:        az containerapp logs show --name $AppName --resource-group $ResourceGroup --follow"
