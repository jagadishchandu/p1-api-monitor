<#
.SYNOPSIS
    Deploys the P1 API Monitor to Azure Container Apps using Azure PowerShell (Az) only.

.DESCRIPTION
    Follows the same approach as school-lms\infra\deploy-containerapp.ps1:
      1. Signs in with device code (Connect-AzAccount -UseDeviceAuthentication), if needed.
      2. Reads settings from .env in this folder. Nothing is printed, and secrets go only to Azure.
      3. Shows which resources already exist, and which are missing.
      4. Reuses existing resources and creates the missing ones (resource group, storage account, container,
         container registry, Container Apps environment, container app).
      5. Builds the image with local Docker, pushes it, and removes older images from the registry and this PC.
      6. Creates or updates the container app with New-AzResource (an ARM request), then checks the app.

    Docker is needed to build and push the image. The Azure CLI is not used.
    The Container Apps environment has no log destination, so no Log Analytics workspace is created.

    Required modules: Az.Accounts, Az.Resources, Az.Storage, Az.ContainerRegistry.
    Install once with:  Install-Module Az -Scope CurrentUser

.EXAMPLE
    .\deploy-azure.ps1

.EXAMPLE
    .\deploy-azure.ps1 -Suffix jc01 -AllowedIpRange 203.0.113.0/24
#>
[CmdletBinding()]
param(
    # Short text, lowercase letters and digits (3-12 characters). Makes the registry and storage account names unique.
    # Optional: when empty, the script reuses the registry and storage account already in the resource group,
    # or creates new ones with a random suffix.
    [ValidatePattern('^([a-z0-9]{3,12})?$')]
    [string]$Suffix = "",

    [string]$ResourceGroup = "rg-p1-api-monitor-test",
    [string]$Location = "eastus",
    [string]$AppName = "p1-api-monitor",
    [string]$EnvironmentName = "cae-p1-api-monitor",
    [string]$ImageName = "p1-api-monitor",
    # Optional. Leave empty to use the current subscription.
    [string]$SubscriptionId = "",
    [string]$EnvFile = (Join-Path $PSScriptRoot ".env"),
    [string]$StorageContainer = "p1-api-monitor",
    [string]$StorageFolder = "p1-api-monitor",

    # Optional. Only this address range can open the app (recommended, because the SWAT board has no login).
    [string]$AllowedIpRange = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ApiVersion = "2024-03-01"

# ---------------------------------------------------------------- helpers

function Write-Step([string]$Text) {
  Write-Host ""
  Write-Host "==> $Text" -ForegroundColor Cyan
}

# Prints one line per resource: present (green) or missing (yellow).
function Write-Status([string]$Name, [bool]$Present) {
  if ($Present) {
    Write-Host ("  {0,-40} present" -f $Name) -ForegroundColor Green
  } else {
    Write-Host ("  {0,-40} missing (will be created)" -f $Name) -ForegroundColor Yellow
  }
}

# Reads KEY=VALUE lines. Comments and blank lines are skipped. Values may contain "=".
function Read-EnvFile([string]$Path) {
  if (-not (Test-Path $Path)) { throw "No .env file at $Path. Copy .env.example to .env and fill it in first." }
  $values = @{}
  foreach ($line in Get-Content -Path $Path) {
    $text = $line.Trim()
    if ($text -eq "" -or $text.StartsWith("#")) { continue }
    $index = $text.IndexOf("=")
    if ($index -le 0) { continue }
    $key = $text.Substring(0, $index).Trim()
    $value = $text.Substring($index + 1).Trim()
    if ($value.Length -ge 2 -and ($value[0] -eq '"' -or $value[0] -eq "'") -and $value[$value.Length - 1] -eq $value[0]) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    $values[$key] = $value
  }
  return $values
}

# Returns the object, or $null when it does not exist. "Not found" is expected, so it is not shown as an error.
function Get-IfExists([scriptblock]$Get) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  try { $result = & $Get } catch { $result = $null }
  $ErrorActionPreference = $previous
  return $result
}

# Random lowercase letters and digits, used to make resource names unique.
function New-RandomSuffix([int]$Length) {
  $chars = (48..57) + (97..122)
  return -join ($chars | Get-Random -Count $Length | ForEach-Object { [char]$_ })
}

# Docker writes progress to stderr. Let it finish, then check the exit code.
function Invoke-Docker([string[]]$DockerArgs) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & docker @DockerArgs
  $code = $LASTEXITCODE
  $ErrorActionPreference = $previous
  if ($code -ne 0) { throw "docker $($DockerArgs[0]) failed (exit $code)." }
}

# ---------------------------------------------------------------- checks

Write-Step "Checking tools and settings"
foreach ($module in @("Az.Accounts", "Az.Resources", "Az.Storage", "Az.ContainerRegistry")) {
  if (-not (Get-Module -ListAvailable -Name $module)) {
    throw "PowerShell module $module is missing. Install it with: Install-Module Az -Scope CurrentUser"
  }
}
Import-Module Az.Accounts, Az.Resources, Az.Storage, Az.ContainerRegistry -ErrorAction Stop

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker is not installed or not on PATH." }
& docker info *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker is not running. Start Docker Desktop and try again." }

$settings = Read-EnvFile $EnvFile
foreach ($key in @("SN_INSTANCE", "SN_CLIENT_ID", "SN_CLIENT_SECRET")) {
  if (-not $settings.ContainsKey($key) -or $settings[$key] -eq "") { throw "$key is empty in $EnvFile" }
}

# ---------------------------------------------------------------- sign in

Write-Step "Signing in to Azure"
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
  # Device code: prints a code and a web address. No browser window is opened by the script.
  Connect-AzAccount -UseDeviceAuthentication | Out-Null
}
if ($SubscriptionId -ne "") { Set-AzContext -Subscription $SubscriptionId | Out-Null }
$context = Get-AzContext
$subscriptionId = $context.Subscription.Id
Write-Host "Using subscription: $($context.Subscription.Name)"

Write-Step "Resource providers"
foreach ($namespace in @("Microsoft.App", "Microsoft.ContainerRegistry", "Microsoft.Storage")) {
  Register-AzResourceProvider -ProviderNamespace $namespace | Out-Null
}

# ---------------------------------------------------------------- names

$existingGroup = Get-IfExists { Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue }

# Without -Suffix, reuse the registry or storage account already in the resource group.
if ($Suffix -eq "") {
  $names = @()
  if ($existingGroup) {
    $names += @(Get-AzStorageAccount -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue |
      Where-Object { $_.StorageAccountName -like "stp1apimon*" } | ForEach-Object { $_.StorageAccountName.Substring(10) })
    $names += @(Get-AzContainerRegistry -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "acrp1apimon*" } | ForEach-Object { $_.Name.Substring(11) })
  }
  $found = @($names | Select-Object -Unique)
  if ($found.Count -eq 1) {
    $Suffix = $found[0]
    Write-Host "Found existing resources with suffix '$Suffix'. Reusing them." -ForegroundColor Green
  }
  elseif ($found.Count -gt 1) {
    throw "More than one set of resources was found in $ResourceGroup ($($found -join ', ')). Run the script again with -Suffix to choose one."
  }
  else {
    $Suffix = New-RandomSuffix 6
    Write-Host "No existing resources found. Creating new ones with suffix '$Suffix'." -ForegroundColor Green
  }
}

$storageName = "stp1apimon$Suffix"
$registryName = "acrp1apimon$Suffix"
$image = $null  # set after the registry is known

# ---------------------------------------------------------------- resource check

Write-Step "Checking which resources already exist"
$envPresentNow = [bool](Get-IfExists { Get-AzResource -ResourceGroupName $ResourceGroup -ResourceType "Microsoft.App/managedEnvironments" -Name $EnvironmentName -ApiVersion $ApiVersion -ErrorAction SilentlyContinue })
$appPresentNow = [bool](Get-IfExists { Get-AzResource -ResourceGroupName $ResourceGroup -ResourceType "Microsoft.App/containerApps" -Name $AppName -ApiVersion $ApiVersion -ErrorAction SilentlyContinue })
$storagePresentNow = [bool](Get-IfExists { Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $storageName -ErrorAction SilentlyContinue })
$registryPresentNow = [bool](Get-IfExists { Get-AzContainerRegistry -ResourceGroupName $ResourceGroup -Name $registryName -ErrorAction SilentlyContinue })
Write-Status "Resource group $ResourceGroup" ([bool]$existingGroup)
Write-Status "Storage account $storageName" $storagePresentNow
Write-Status "Container registry $registryName" $registryPresentNow
Write-Status "Container Apps environment $EnvironmentName" $envPresentNow
Write-Status "Container app $AppName" $appPresentNow

# ---------------------------------------------------------------- resource group

Write-Step "Resource group $ResourceGroup"
if ($existingGroup) {
  Write-Host "exists"
} else {
  New-AzResourceGroup -Name $ResourceGroup -Location $Location | Out-Null
  Write-Host "created"
}

# ---------------------------------------------------------------- storage

Write-Step "Storage account and container"
# The account named in .env is used only if it exists in the resource group. Otherwise the script uses its own account.
$envConn = $settings["AZURE_STORAGE_CONNECTION_STRING"]
$envAccount = $null
if ($envConn -match 'AccountName=([^;]+)') {
  $envAccountName = $Matches[1]
  $envAccount = Get-IfExists { Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $envAccountName -ErrorAction SilentlyContinue }
}

$storageCreated = $false
if ($envAccount) {
  Write-Host "Using the storage account from .env: $($envAccount.StorageAccountName)"
  $storageName = $envAccount.StorageAccountName
  $storageConn = $envConn
}
else {
  if ($envConn) { Write-Host "The storage account in .env was not found in $ResourceGroup, so it is ignored." -ForegroundColor Yellow }
  $storage = Get-IfExists { Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $storageName -ErrorAction SilentlyContinue }
  if ($storage) {
    Write-Host "Storage account $storageName exists."
  }
  else {
    New-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $storageName -Location $Location `
      -SkuName Standard_LRS -Kind StorageV2 -MinimumTlsVersion TLS1_2 -AllowBlobPublicAccess $false | Out-Null
    $storageCreated = $true
    Write-Host "Storage account $storageName created."
  }
  $key = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroup -Name $storageName)[0].Value
  $storageConn = "DefaultEndpointsProtocol=https;AccountName=$storageName;AccountKey=$key;EndpointSuffix=core.windows.net"
}

# The container is created through the management API, so no data-plane call is needed.
$container = Get-IfExists { Get-AzRmStorageContainer -ResourceGroupName $ResourceGroup -StorageAccountName $storageName -Name $StorageContainer -ErrorAction SilentlyContinue }
if ($container) {
  Write-Host "Container $StorageContainer exists."
} else {
  New-AzRmStorageContainer -ResourceGroupName $ResourceGroup -StorageAccountName $storageName -Name $StorageContainer -PublicAccess None | Out-Null
  Write-Host "Container $StorageContainer created."
}

# Storage key check: the storage connection string must match the account in the resource group.
if ($storageConn -notmatch "^DefaultEndpointsProtocol=https;AccountName=$storageName;AccountKey=[^;]+;EndpointSuffix=core\.windows\.net$") {
  throw "The storage connection string does not match storage account $storageName."
}

# .env needs the value when the account was just created, or when .env names an account that is not used.
$staleEnvString = [bool]$envConn -and -not $envAccount
if ($storageCreated -or $staleEnvString) {
  # The file holds the storage key. It is listed in .gitignore and .dockerignore.
  $storageFile = Join-Path $PSScriptRoot "storage-connection.txt"
  $lines = @(
    "Azure Storage details created by deploy-azure.ps1",
    "KEEP THIS FILE PRIVATE. It contains the storage account key.",
    "",
    "Resource group:   $ResourceGroup",
    "Storage account:  $storageName",
    "Container:        $StorageContainer",
    "Folder:           $StorageFolder",
    "",
    "Copy the next line into .env, replacing the empty AZURE_STORAGE_CONNECTION_STRING= line:",
    "AZURE_STORAGE_CONNECTION_STRING=$storageConn"
  )
  [System.IO.File]::WriteAllText($storageFile, (($lines -join "`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($false))
  Write-Host "Storage details written to: $storageFile" -ForegroundColor Green
  do {
    $answer = (Read-Host "Copy AZURE_STORAGE_CONNECTION_STRING from that file into .env and save it. Type YES to continue, or NO to stop").Trim()
    if ($answer -eq "NO") { throw "Stopped. Update .env, then run the script again." }
  } while ($answer -ne "YES")
  $settings = Read-EnvFile $EnvFile
  if (-not $settings["AZURE_STORAGE_CONNECTION_STRING"]) { throw "AZURE_STORAGE_CONNECTION_STRING is still empty in .env." }
}

# ---------------------------------------------------------------- container registry

Write-Step "Container registry $registryName"
$registry = Get-IfExists { Get-AzContainerRegistry -ResourceGroupName $ResourceGroup -Name $registryName -ErrorAction SilentlyContinue }
if ($registry) {
  Write-Host "exists"
  # The admin user lets the container app pull the image, and lets docker push to it.
  if (-not $registry.AdminUserEnabled) {
    Update-AzContainerRegistry -ResourceGroupName $ResourceGroup -Name $registryName -EnableAdminUser | Out-Null
    Write-Host "admin user turned on"
  }
} else {
  New-AzContainerRegistry -ResourceGroupName $ResourceGroup -Name $registryName -Location $Location -Sku Basic -EnableAdminUser | Out-Null
  Write-Host "created (Basic tier)"
}
$registry = Get-AzContainerRegistry -ResourceGroupName $ResourceGroup -Name $registryName
if (-not $registry.LoginServer) { throw "Could not read registry $registryName." }
$loginServer = $registry.LoginServer

$registryCredential = Get-AzContainerRegistryCredential -ResourceGroupName $ResourceGroup -RegistryName $registryName
$registryUser = $registryCredential.Username
$registryPassword = $registryCredential.Password
if (-not $registryPassword) { $registryPassword = $registryCredential.Password2 }
if (-not $registryUser -or -not $registryPassword) {
  throw "Could not read the admin credentials for $registryName. Check that the admin user is enabled, then run again."
}

# ---------------------------------------------------------------- Container Apps environment

Write-Step "Container Apps environment $EnvironmentName"
# The environment and the app are created with New-AzResource, which sends the Azure Resource Manager request directly.
# The environment has no log destination, so no Log Analytics workspace is created.
$envType = "Microsoft.App/managedEnvironments"
$managedEnv = Get-IfExists { Get-AzResource -ResourceGroupName $ResourceGroup -ResourceType $envType -Name $EnvironmentName -ApiVersion $ApiVersion -ErrorAction SilentlyContinue }
if ($managedEnv -and $managedEnv.Properties.provisioningState -ne "Succeeded") {
  # A failed earlier attempt can leave an environment that never finishes provisioning. Remove it and create it again.
  Write-Host "exists but is not provisioned (state: $($managedEnv.Properties.provisioningState)). Removing it."
  Remove-AzResource -ResourceId $managedEnv.ResourceId -Force | Out-Null
  $managedEnv = $null
}
if (-not $managedEnv) {
  New-AzResource -ResourceGroupName $ResourceGroup -ResourceType $envType -ResourceName $EnvironmentName `
    -Location $Location -ApiVersion $ApiVersion -Properties @{} -Force | Out-Null
  Write-Host "created"
} else {
  Write-Host "exists and is provisioned"
}

# The app cannot be created before the environment is ready.
$waited = 0
while ($true) {
  $managedEnv = Get-AzResource -ResourceGroupName $ResourceGroup -ResourceType $envType -Name $EnvironmentName -ApiVersion $ApiVersion
  $state = $managedEnv.Properties.provisioningState
  if ($state -eq "Succeeded") { break }
  if ($state -eq "Failed" -or $state -eq "Canceled") { throw "Container Apps environment $EnvironmentName ended in state $state. Delete it in the portal and run the script again." }
  if ($waited -ge 1200) { throw "Timed out waiting for environment $EnvironmentName (state: $state)." }
  Write-Host "waiting for environment (state: $state)..."
  Start-Sleep -Seconds 15
  $waited += 15
}
if (-not $managedEnv.ResourceId) { throw "Container Apps environment $EnvironmentName has no resource id." }

# ---------------------------------------------------------------- build and push

Write-Step "Building and pushing the image"
$tag = Get-Date -Format "yyyyMMddHHmmss"
$repository = $ImageName
$image = "$loginServer/$($repository):$tag"
$latestImage = "$loginServer/$($repository):latest"
Write-Host "Image tag: $tag (also tagged latest)" -ForegroundColor Yellow

# A temporary Docker config folder avoids credential-helper errors with Docker Desktop. It is deleted afterwards.
$dockerConfigDir = Join-Path ([System.IO.Path]::GetTempPath()) ("p1-docker-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $dockerConfigDir | Out-Null
$previousDockerConfig = $env:DOCKER_CONFIG
$env:DOCKER_CONFIG = $dockerConfigDir

try {
  Write-Step "Logging in to the registry with local Docker"
  # The password goes to docker through stdin, so it is not on the command line.
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $loginOutput = ($registryPassword | & docker login $loginServer -u $registryUser --password-stdin 2>&1 | Out-String)
  $loginExit = $LASTEXITCODE
  $ErrorActionPreference = $previousPreference
  if ($loginExit -ne 0) { throw "docker login to $loginServer failed: $($loginOutput.Trim())" }
  Write-Host "Login Succeeded"

  Write-Step "Building image $image"
  Invoke-Docker @("build", "-t", $image, $PSScriptRoot)
  Invoke-Docker @("tag", $image, $latestImage)

  Write-Step "Pushing image"
  Invoke-Docker @("push", $image)
  Invoke-Docker @("push", $latestImage)

  # Remove older images only now that the new one is in the registry. The app is set to $image below.
  Write-Step "Removing old images from the registry and this PC"
  $keepTags = @($tag, "latest")
  $tagObjects = @(Get-IfExists { Get-AzContainerRegistryTag -RegistryName $registryName -RepositoryName $repository -ErrorAction SilentlyContinue })
  foreach ($tagObject in $tagObjects) {
    $name = if ($tagObject.Name) { [string]$tagObject.Name } elseif ($tagObject.TagName) { [string]$tagObject.TagName } else { "" }
    if ($name -and $keepTags -notcontains $name) {
      Remove-AzContainerRegistryTag -RegistryName $registryName -RepositoryName $repository -Name $name -ErrorAction Continue | Out-Null
      Write-Host "  removed registry tag $name"
    }
  }
  $localImages = & docker image ls "$loginServer/$repository" --format "{{.Repository}}:{{.Tag}}" 2>$null
  foreach ($local in $localImages) {
    if ($local -and $local -notin @($image, $latestImage)) {
      & docker image rm $local | Out-Null
      Write-Host "  removed local image $local"
    }
  }
}
finally {
  $env:DOCKER_CONFIG = $previousDockerConfig
  Remove-Item -Recurse -Force -Path $dockerConfigDir -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- app settings

# Every value from .env is stored as a Container Apps secret. The environment variables refer to the secrets with secretRef,
# so no setting appears in plain text in the app's configuration.
$appVariableNames = @(
  "SN_INSTANCE", "SN_CLIENT_ID", "SN_CLIENT_SECRET", "AZURE_STORAGE_CONNECTION_STRING",
  "AZURE_STORAGE_CONTAINER", "AZURE_STORAGE_FOLDER", "SWAT_BOARD_ENABLED", "SWAT_BOARD_PORT",
  "SWAT_BOARD_PUBLIC_URL", "MONITOR_INTERVAL_MINUTES", "TEAMS_WEBHOOK_URLS", "TEAMS_VERIFY_SSL",
  "EMAIL_TO", "EMAIL_CC", "EMAIL_BCC", "SMTP_HOST", "SMTP_PORT", "SMTP_STARTTLS", "SMTP_USER",
  "SMTP_PASSWORD", "SMTP_FROM"
)

# Container Apps secret names: lowercase letters, digits and hyphens. Kept to 20 characters.
function Get-SecretName([string]$Variable) {
  $name = $Variable.ToLower().Replace("_", "-")
  if ($name.Length -gt 20) { $name = $name.Substring(0, 20).TrimEnd("-") }
  return $name
}

# Returns the secrets and the environment variables for the app. A setting with an empty value is left out.
function New-AppSettings([string]$PublicUrl) {
  $values = @{}
  foreach ($name in $appVariableNames) { $values[$name] = $settings[$name] }
  # Values the script sets itself take precedence over .env.
  $values["AZURE_STORAGE_CONNECTION_STRING"] = $storageConn
  $values["AZURE_STORAGE_CONTAINER"] = $StorageContainer
  $values["AZURE_STORAGE_FOLDER"] = $StorageFolder
  $values["SWAT_BOARD_PORT"] = "8080"
  if ($PublicUrl) { $values["SWAT_BOARD_PUBLIC_URL"] = $PublicUrl }

  $secretList = @( @{ name = "acr-password"; value = $registryPassword } )
  $envList = @()
  $usedNames = @{ "acr-password" = $true }
  foreach ($name in $appVariableNames) {
    $value = [string]$values[$name]
    if (-not $value) { continue }
    $secretName = Get-SecretName $name
    if ($usedNames.ContainsKey($secretName)) { throw "Two settings would share the secret name '$secretName'. Rename one of them." }
    $usedNames[$secretName] = $true
    $secretList += @{ name = $secretName; value = $value }
    $envList += @{ name = $name; secretRef = $secretName }
  }
  return @{ secrets = $secretList; env = $envList }
}

function New-AppProperties([string]$PublicUrl) {
  $appSettings = New-AppSettings $PublicUrl
  $ingress = @{ external = $true; targetPort = 8080; transport = "auto"; allowInsecure = $false }
  if ($AllowedIpRange) {
    $ingress["ipSecurityRestrictions"] = @( @{ name = "allowed-network"; ipAddressRange = $AllowedIpRange; action = "Allow" } )
  }
  return @{
    managedEnvironmentId = $managedEnv.ResourceId
    configuration = @{
      activeRevisionsMode = "Single"
      ingress = $ingress
      secrets = $appSettings.secrets
      registries = @( @{ server = $loginServer; username = $registryUser; passwordSecretRef = "acr-password" } )
    }
    template = @{
      containers = @( @{ name = $AppName; image = $image; env = $appSettings.env; resources = @{ cpu = 0.25; memory = "0.5Gi" } } )
      # Exactly one replica: the monitor must run all the time, and two copies would send duplicate alerts.
      scale = @{ minReplicas = 1; maxReplicas = 1 }
    }
  }
}

# ---------------------------------------------------------------- create or update the app

Write-Step "Container app $AppName"
# -Force replaces the app with these settings. It creates the app if it is missing, and updates it if it exists.
$existingApp = Get-IfExists { Get-AzResource -ResourceGroupName $ResourceGroup -ResourceType "Microsoft.App/containerApps" -Name $AppName -ApiVersion $ApiVersion -ErrorAction SilentlyContinue }
$publicUrl = ""
if ($existingApp -and $existingApp.Properties.configuration.ingress.fqdn) {
  $publicUrl = "https://$($existingApp.Properties.configuration.ingress.fqdn)"
}

New-AzResource -ResourceGroupName $ResourceGroup -ResourceType "Microsoft.App/containerApps" -ResourceName $AppName `
  -Location $Location -ApiVersion $ApiVersion -Properties (New-AppProperties $publicUrl) -Force | Out-Null
Write-Host "created or updated (image: $image)"

# The public address is known only after the app exists. For a new app, read it and set the SWAT board address.
$app = Get-AzResource -ResourceGroupName $ResourceGroup -ResourceType "Microsoft.App/containerApps" -Name $AppName -ApiVersion $ApiVersion
$fqdn = $app.Properties.configuration.ingress.fqdn
if (-not $fqdn) { $fqdn = $app.Properties.latestRevisionFqdn }
$deadline = (Get-Date).AddMinutes(3)
while (-not $fqdn -and (Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 10
  $app = Get-AzResource -ResourceGroupName $ResourceGroup -ResourceType "Microsoft.App/containerApps" -Name $AppName -ApiVersion $ApiVersion
  $fqdn = $app.Properties.configuration.ingress.fqdn
  if (-not $fqdn) { $fqdn = $app.Properties.latestRevisionFqdn }
}
if (-not $fqdn) { throw "The app was created, but its public address is not known yet. Run the script again in a few minutes." }

if ($publicUrl -ne "https://$fqdn") {
  Write-Step "Setting the SWAT board address to https://$fqdn"
  New-AzResource -ResourceGroupName $ResourceGroup -ResourceType "Microsoft.App/containerApps" -ResourceName $AppName `
    -Location $Location -ApiVersion $ApiVersion -Properties (New-AppProperties "https://$fqdn") -Force | Out-Null
}

if (-not $AllowedIpRange) {
  Write-Warning "No -AllowedIpRange given. The SWAT board has no login, so anyone with the address can use it. Re-run with -AllowedIpRange to restrict it."
}

# ---------------------------------------------------------------- health check

Write-Step "Checking the app"
$healthUrl = "https://$fqdn/api/incidents"
$healthy = $false
$waited = 0
while ($waited -lt 300) {
  try {
    $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 20
    if ($response.StatusCode -eq 200) { $healthy = $true; break }
  } catch {
    # The app may still be starting. Keep waiting.
  }
  Write-Host "waiting for the app to answer..."
  Start-Sleep -Seconds 15
  $waited += 15
}
if ($healthy) {
  Write-Host "app is up" -ForegroundColor Green
} else {
  Write-Warning "The app did not answer at $healthUrl. Check the log stream in the portal (Monitoring > Log stream)."
}

Write-Step "Done"
Write-Host "SWAT board: https://$fqdn"
Write-Host "Health:     $healthUrl"
