<#
.SYNOPSIS
    Deploys the P1 API Monitor to Azure Container Apps using Azure PowerShell (Az) only.

.DESCRIPTION
    Follows the same approach as school-lms\infra\deploy-containerapp.ps1:
      1. Signs in with device code (Connect-AzAccount -UseDeviceAuthentication), if needed.
      2. Reads settings from .env in this folder. Nothing is printed, and secrets go only to Azure.
      3. Looks for each resource only in the subscription and resource group given for it (see the parameters).
         Existing resources are reused. Missing ones are created in that same subscription and resource group.
      4. Builds the image with local Docker, pushes it, and removes older images from the registry and this PC.
      5. Creates or updates the container app with New-AzResource (an ARM request), then checks the app.

    Each resource has its own -<Resource>SubscriptionId and -<Resource>ResourceGroup. Leave them empty to use the
    main -SubscriptionId and -ResourceGroup. The app must be in the same subscription as its environment.

    Docker is needed to build and push the image. The Azure CLI is not used.
    The Container Apps environment has no log destination, so no Log Analytics workspace is created.

    Required modules: Az.Accounts, Az.Resources, Az.Storage, Az.ContainerRegistry.
    Install once with:  Install-Module Az -Scope CurrentUser

.EXAMPLE
    .\deploy-azure.ps1

.EXAMPLE
    .\deploy-azure.ps1 -Suffix jc01 -AllowedIpRange 203.0.113.0/24

.EXAMPLE
    .\deploy-azure.ps1 -SubscriptionId <sub-a> -ResourceGroup rg-p1 -StorageSubscriptionId <sub-b> -StorageResourceGroup rg-data
#>
[CmdletBinding()]
param(
    # Short text, lowercase letters and digits (3-12 characters). Makes the registry and storage account names unique.
    # Optional: when empty, the script reuses the registry and storage account already in the main resource group,
    # or creates new ones with a random suffix.
    [ValidatePattern('^([a-z0-9]{3,12})?$')]
    [string]$Suffix = "",

    # Main subscription and resource group. Used for every resource that has no own subscription or group below.
    [string]$SubscriptionId = "a8515d0e-8966-4b18-8231-4f6b763b8945",
    [string]$ResourceGroup = "rg-p1-api-monitor0",
    [string]$Location = "eastus2",

    # Optional per-resource location. Leave empty to use -SubscriptionId and -ResourceGroup.
    [string]$StorageSubscriptionId = "a8515d0e-8966-4b18-8231-4f6b763b8945",
    [string]$StorageResourceGroup = "rg-p1-api-monitor0",
    [string]$RegistrySubscriptionId = "a8515d0e-8966-4b18-8231-4f6b763b8945",
    [string]$RegistryResourceGroup = "rg-p1-api-monitor0",
    [string]$EnvironmentSubscriptionId = "a8515d0e-8966-4b18-8231-4f6b763b8945",
    [string]$EnvironmentResourceGroup = "rg-p1-api-monitor0",
    [string]$AppSubscriptionId = "a8515d0e-8966-4b18-8231-4f6b763b8945",
    [string]$AppResourceGroup = "rg-p1-api-monitor0",

    [string]$AppName = "p1-api-monitor",
    [string]$EnvironmentName = "cae-p1-api-monitor",
    [string]$ImageName = "p1-api-monitor",
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

# Prints one line per resource: where it was found, or that it will be created there.
function Write-Status([string]$Name, [hashtable]$Place, [bool]$Present) {
  $where = "subscription $($Place.Sub), resource group $($Place.Rg)"
  if ($Present) {
    Write-Host ("  {0,-40} found in {1}" -f $Name, $where) -ForegroundColor Green
  } else {
    Write-Host ("  {0,-40} missing, will be created in {1}" -f $Name, $where) -ForegroundColor Yellow
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

# Switches the Azure context to a subscription, only when it is not already the current one.
function Use-Subscription([string]$Id) {
  if ((Get-AzContext).Subscription.Id -ne $Id) { Set-AzContext -Subscription $Id | Out-Null }
}

# A place is a subscription and a resource group. Empty values fall back to the main ones.
function New-Place([string]$Sub, [string]$Rg) {
  $s = $Sub
  if (-not $s) { $s = $script:targetSub }
  $r = $Rg
  if (-not $r) { $r = $script:ResourceGroup }
  return @{ Sub = $s; Rg = $r }
}

# Looks for one resource in exactly one place: the subscription and resource group given for it. No other subscription is searched.
function Find-InPlace([hashtable]$Place, [string]$Type, [string]$Name, [string]$Version = "") {
  Use-Subscription $Place.Sub
  if ($Version) {
    return Get-IfExists { Get-AzResource -ResourceGroupName $Place.Rg -ResourceType $Type -Name $Name -ApiVersion $Version -ErrorAction SilentlyContinue }
  }
  return Get-IfExists { Get-AzResource -ResourceGroupName $Place.Rg -ResourceType $Type -Name $Name -ErrorAction SilentlyContinue }
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
$targetSub = (Get-AzContext).Subscription.Id
Write-Host "Main subscription: $((Get-AzContext).Subscription.Name) ($targetSub)"

# Where each resource lives. Only these places are searched.
$storagePlace = New-Place $StorageSubscriptionId $StorageResourceGroup
$registryPlace = New-Place $RegistrySubscriptionId $RegistryResourceGroup
$environmentPlace = New-Place $EnvironmentSubscriptionId $EnvironmentResourceGroup
$appPlace = New-Place $AppSubscriptionId $AppResourceGroup
if ($AppSubscriptionId -eq "" -and $AppResourceGroup -eq "") { $appPlace = $environmentPlace }
if ($appPlace.Sub -ne $environmentPlace.Sub) {
  throw "The app and its Container Apps environment must be in the same subscription. Set -AppSubscriptionId to the environment's subscription."
}

Write-Step "Resource providers"
Use-Subscription $targetSub
foreach ($namespace in @("Microsoft.App", "Microsoft.ContainerRegistry", "Microsoft.Storage")) {
  Register-AzResourceProvider -ProviderNamespace $namespace | Out-Null
}

# ---------------------------------------------------------------- names

# Without -Suffix, reuse the registry or storage account already in the main resource group.
if ($Suffix -eq "") {
  $names = @()
  Use-Subscription $targetSub
  if (Get-IfExists { Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue }) {
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

$defaultStorageName = "stp1apimon$Suffix"
$registryName = "acrp1apimon$Suffix"

# The storage account named in .env is used only when it exists in the storage place. Otherwise it is ignored.
$envUrl = $settings["AZURE_STORAGE_ACCOUNT_URL"]
$envAccountName = ""
if ($envUrl -match 'https://([^.]+)\.blob\.') { $envAccountName = $Matches[1] }
$envAccountFound = $false
if ($envAccountName) {
  $envAccountFound = [bool](Find-InPlace $storagePlace "Microsoft.Storage/storageAccounts" $envAccountName)
}
if ($envAccountFound) { $storageName = $envAccountName }
else { $storageName = $defaultStorageName }

# ---------------------------------------------------------------- resource check

Write-Step "Checking which resources already exist"
$storageRef = Find-InPlace $storagePlace "Microsoft.Storage/storageAccounts" $storageName
$registryRef = Find-InPlace $registryPlace "Microsoft.ContainerRegistry/registries" $registryName
$envRef = Find-InPlace $environmentPlace "Microsoft.App/managedEnvironments" $EnvironmentName $ApiVersion
$appRef = Find-InPlace $appPlace "Microsoft.App/containerApps" $AppName $ApiVersion
Write-Status "Storage account $storageName" $storagePlace ([bool]$storageRef)
Write-Status "Container registry $registryName" $registryPlace ([bool]$registryRef)
Write-Status "Container Apps environment $EnvironmentName" $environmentPlace ([bool]$envRef)
Write-Status "Container app $AppName" $appPlace ([bool]$appRef)
if ($envUrl -and -not $envAccountFound) {
  Write-Host "The storage account in .env ($envAccountName) was not found in its storage place, so it is ignored." -ForegroundColor Yellow
}

# Creates the resource group in a place when it does not exist yet.
function Ensure-Group([hashtable]$Place) {
  Use-Subscription $Place.Sub
  if (-not (Get-IfExists { Get-AzResourceGroup -Name $Place.Rg -ErrorAction SilentlyContinue })) {
    New-AzResourceGroup -Name $Place.Rg -Location $Location | Out-Null
    Write-Host "created resource group $($Place.Rg)"
  }
}

# ---------------------------------------------------------------- storage

Write-Step "Storage account and container"
$storageCreated = $false
if (-not $storageRef) {
  Ensure-Group $storagePlace
  Use-Subscription $storagePlace.Sub
  New-AzStorageAccount -ResourceGroupName $storagePlace.Rg -Name $storageName -Location $Location `
    -SkuName Standard_LRS -Kind StorageV2 -MinimumTlsVersion TLS1_2 -AllowBlobPublicAccess $false `
    -AllowSharedKeyAccess $false | Out-Null
  $storageCreated = $true
  Write-Host "Storage account $storageName created."
}
else {
  Write-Host "Storage account $storageName exists. Reusing it."
}
Use-Subscription $storagePlace.Sub

# The app gets this URL, not a key. Access comes from the app's managed identity, granted further down.
$storageUrl = "https://$storageName.blob.core.windows.net"

# The container is created through the management API, so no data-plane call is needed.
$container = Get-IfExists { Get-AzRmStorageContainer -ResourceGroupName $storagePlace.Rg -StorageAccountName $storageName -Name $StorageContainer -ErrorAction SilentlyContinue }
if ($container) {
  Write-Host "Container $StorageContainer exists."
} else {
  New-AzRmStorageContainer -ResourceGroupName $storagePlace.Rg -StorageAccountName $storageName -Name $StorageContainer -PublicAccess None | Out-Null
  Write-Host "Container $StorageContainer created."
}

# No key file and no prompt: the app reads the account URL from .env, and its managed identity gets the role below.
if ($storageCreated) {
  Write-Host "Storage account created. Its URL is $storageUrl. The app uses its managed identity, so no key is needed." -ForegroundColor Green
}

# ---------------------------------------------------------------- container registry

Write-Step "Container registry $registryName"
Use-Subscription $registryPlace.Sub
if ($registryRef) {
  Write-Host "exists"
  $registry = Get-AzContainerRegistry -ResourceGroupName $registryPlace.Rg -Name $registryName
  # The admin user lets the container app pull the image, and lets docker push to it.
  if (-not $registry.AdminUserEnabled) {
    Update-AzContainerRegistry -ResourceGroupName $registryPlace.Rg -Name $registryName -EnableAdminUser | Out-Null
    Write-Host "admin user turned on"
  }
} else {
  Ensure-Group $registryPlace
  Use-Subscription $registryPlace.Sub
  New-AzContainerRegistry -ResourceGroupName $registryPlace.Rg -Name $registryName -Location $Location -Sku Basic -EnableAdminUser | Out-Null
  Write-Host "created (Basic tier)"
}
$registry = Get-AzContainerRegistry -ResourceGroupName $registryPlace.Rg -Name $registryName
if (-not $registry.LoginServer) { throw "Could not read registry $registryName." }
$loginServer = $registry.LoginServer

$registryCredential = Get-AzContainerRegistryCredential -ResourceGroupName $registryPlace.Rg -RegistryName $registryName
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
Use-Subscription $environmentPlace.Sub
$managedEnv = $envRef
if ($managedEnv -and $managedEnv.Properties.provisioningState -ne "Succeeded") {
  # A failed earlier attempt can leave an environment that never finishes provisioning. Remove it and create it again.
  Write-Host "exists but is not provisioned (state: $($managedEnv.Properties.provisioningState)). Removing it."
  Remove-AzResource -ResourceId $managedEnv.ResourceId -Force | Out-Null
  $managedEnv = $null
}
if (-not $managedEnv) {
  Ensure-Group $environmentPlace
  Use-Subscription $environmentPlace.Sub
  New-AzResource -ResourceGroupName $environmentPlace.Rg -ResourceType $envType -ResourceName $EnvironmentName `
    -Location $Location -ApiVersion $ApiVersion -Properties @{} -Force | Out-Null
  Write-Host "created"
} else {
  Write-Host "exists and is provisioned"
}

# The app cannot be created before the environment is ready.
$waited = 0
while ($true) {
  $managedEnv = Get-AzResource -ResourceGroupName $environmentPlace.Rg -ResourceType $envType -Name $EnvironmentName -ApiVersion $ApiVersion
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
  "SN_INSTANCE", "SN_CLIENT_ID", "SN_CLIENT_SECRET", "AZURE_STORAGE_ACCOUNT_URL",
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
  $values["AZURE_STORAGE_ACCOUNT_URL"] = $storageUrl
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

# Creates or replaces the app with one PUT. The system-assigned identity is part of the same body,
# so an update can't remove it.
function Save-ContainerApp([string]$PublicUrl) {
  $body = @{
    location   = $Location
    identity   = @{ type = "SystemAssigned" }
    properties = New-AppProperties $PublicUrl
  } | ConvertTo-Json -Depth 30
  $path = "/subscriptions/$($appPlace.Sub)/resourceGroups/$($appPlace.Rg)/providers/Microsoft.App/containerApps/$($AppName)?api-version=$ApiVersion"
  $response = Invoke-AzRestMethod -Method PUT -Path $path -Payload $body
  if ($response.StatusCode -notin 200, 201) { throw "Saving container app $AppName failed ($($response.StatusCode)): $($response.Content)" }
}

# Gives the app's managed identity read and write access to blobs in the storage account, and nothing else.
# Storage Blob Data Contributor is a data-plane role: it does not allow listing keys or changing the account.
function Grant-StorageAccess {
  $path = "/subscriptions/$($appPlace.Sub)/resourceGroups/$($appPlace.Rg)/providers/Microsoft.App/containerApps/$($AppName)?api-version=$ApiVersion"
  $principal = $null
  for ($tries = 0; -not $principal -and $tries -lt 12; $tries++) {
    $current = Invoke-AzRestMethod -Method GET -Path $path
    $principal = ($current.Content | ConvertFrom-Json).identity.principalId
    if (-not $principal) { Start-Sleep -Seconds 10 }
  }
  if (-not $principal) { throw "Container app $AppName has no managed identity yet. Run the script again in a few minutes." }

  $scope = (Get-AzStorageAccount -ResourceGroupName $storagePlace.Rg -Name $storageName).Id
  $role = "Storage Blob Data Contributor"
  $existing = Get-AzRoleAssignment -ObjectId $principal -Scope $scope -RoleDefinitionName $role -ErrorAction SilentlyContinue
  if ($existing) {
    Write-Host "The app identity already has $role on $storageName."
    return
  }
  # A new identity can take a short while to appear in Microsoft Entra ID, so retry if it is not found yet.
  for ($tries = 0; $tries -lt 8; $tries++) {
    try {
      New-AzRoleAssignment -ObjectId $principal -RoleDefinitionName $role -Scope $scope | Out-Null
      Write-Host "Granted $role on $storageName to the app identity."
      return
    } catch {
      if ($tries -eq 7) {
        throw "Could not grant $role on $storageName. Run this script as a user with Owner, or User Access Administrator plus Contributor, on the storage account. Details: $($_.Exception.Message)"
      }
      Start-Sleep -Seconds 15
    }
  }
}

Write-Step "Container app $AppName"
# -Force replaces the app with these settings. It creates the app if it is missing, and updates it if it exists.
$publicUrl = ""
if ($appRef -and $appRef.Properties.configuration.ingress.fqdn) {
  $publicUrl = "https://$($appRef.Properties.configuration.ingress.fqdn)"
}

if (-not $appRef) { Ensure-Group $appPlace }
Use-Subscription $appPlace.Sub
Save-ContainerApp $publicUrl
Write-Host "created or updated (image: $image)"
Grant-StorageAccess

# The public address is known only after the app exists. For a new app, read it and set the SWAT board address.
$app = Get-AzResource -ResourceGroupName $appPlace.Rg -ResourceType "Microsoft.App/containerApps" -Name $AppName -ApiVersion $ApiVersion
$fqdn = $app.Properties.configuration.ingress.fqdn
if (-not $fqdn) { $fqdn = $app.Properties.latestRevisionFqdn }
$deadline = (Get-Date).AddMinutes(3)
while (-not $fqdn -and (Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 10
  $app = Get-AzResource -ResourceGroupName $appPlace.Rg -ResourceType "Microsoft.App/containerApps" -Name $AppName -ApiVersion $ApiVersion
  $fqdn = $app.Properties.configuration.ingress.fqdn
  if (-not $fqdn) { $fqdn = $app.Properties.latestRevisionFqdn }
}
if (-not $fqdn) { throw "The app was created, but its public address is not known yet. Run the script again in a few minutes." }

if ($publicUrl -ne "https://$fqdn") {
  Write-Step "Setting the SWAT board address to https://$fqdn"
  Save-ContainerApp "https://$fqdn"
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
