<#
.SYNOPSIS
    Creates the Azure resources for the P1 API Monitor and deploys it to Azure Container Apps.

.DESCRIPTION
    Uses Azure PowerShell (Az modules) for all Azure work. The image is built with your local Docker,
    pushed to Azure Container Registry, and run in Azure Container Apps (1 replica, port 8080, HTTPS on the app address).
    Settings are read from .env in this folder. Secrets are stored as Container Apps secrets and are never printed.
    Running the script again creates a new revision with the new image and the current .env values.

    Requires: Azure PowerShell (Az module), Docker Desktop running, and a .env file made from .env.example.

.EXAMPLE
    .\deploy-azure.ps1 -Suffix jc01

.EXAMPLE
    .\deploy-azure.ps1 -Suffix jc01 -AllowedIpRange 203.0.113.0/24
#>
[CmdletBinding()]
param(
    # Short text, lowercase letters and digits only (3-12 characters). Makes the registry and storage account names unique.
    # Optional: when empty, the script reuses the registry and storage account already in the resource group.
    [ValidatePattern('^([a-z0-9]{3,12})?$')]
    [string]$Suffix = "",

    [string]$ResourceGroup = "rg-p1-api-monitor",
    [string]$Location = "eastus",
    [string]$AppName = "p1-api-monitor",
    [string]$EnvironmentName = "cae-p1-api-monitor",
    [string]$Subscription = "",
    [string]$EnvFile = (Join-Path $PSScriptRoot ".env"),
    [string]$StorageContainer = "p1-api-monitor",
    [string]$StorageFolder = "p1-api-monitor",

    # Optional. Only this address range can open the app (recommended, because the SWAT board has no login).
    [string]$AllowedIpRange = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ---------------------------------------------------------------- helpers

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
        $values[$key] = $text.Substring($i + 1).Trim().Trim('"').Trim("'")
    }
    return $values
}

# Docker writes progress to stderr. Let it finish, then check the exit code.
function Invoke-Docker {
    param([string[]]$DockerArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & docker @DockerArgs
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($code -ne 0) { throw "docker $($DockerArgs[0]) failed (exit $code)." }
}

# Returns the object, or $null when it does not exist. "Not found" is expected here, so it is not shown as an error.
function Get-IfExists {
    param([scriptblock]$Get)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try { $result = & $Get } catch { $result = $null }
    $ErrorActionPreference = $previous
    return $result
}

# ---------------------------------------------------------------- checks

Write-Host "== Checking tools and settings" -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    throw "Azure PowerShell is not installed. Run: Install-Module Az -Scope CurrentUser"
}
docker info | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Docker is not running. Start Docker Desktop and try again." }

$settings = Read-EnvFile $EnvFile
foreach ($key in @("SN_INSTANCE", "SN_CLIENT_ID", "SN_CLIENT_SECRET")) {
    if (-not $settings[$key]) { throw "$key is empty in $EnvFile" }
}

# ---------------------------------------------------------------- Azure sign-in and providers

Write-Host "== Azure sign-in" -ForegroundColor Cyan
if (-not (Get-AzContext)) {
    # Device code: prints a code and a URL to open in any browser, so no browser window is opened by the script.
    Connect-AzAccount -UseDeviceAuthentication | Out-Null
}
if ($Subscription) {
    Set-AzContext -Subscription $Subscription | Out-Null
}
$context = Get-AzContext
$subscriptionId = $context.Subscription.Id
Write-Host "Subscription: $($context.Subscription.Name)"

Write-Host "== Resource providers" -ForegroundColor Cyan
foreach ($namespace in @("Microsoft.App")) {
    $state = (Get-AzResourceProvider -ProviderNamespace $namespace)[0].RegistrationState
    if ($state -ne "Registered") {
        Register-AzResourceProvider -ProviderNamespace $namespace | Out-Null
        $waited = 0
        while ($state -ne "Registered" -and $waited -lt 300) {
            Start-Sleep -Seconds 10
            $waited += 10
            $state = (Get-AzResourceProvider -ProviderNamespace $namespace)[0].RegistrationState
        }
        if ($state -ne "Registered") { throw "$namespace is not registered yet. Try again in a few minutes." }
    }
    Write-Host "${namespace}: Registered"
}

Write-Host "== Resource group $ResourceGroup" -ForegroundColor Cyan
$resourceGroupObject = Get-IfExists { Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue }
if ($resourceGroupObject) {
    Write-Host "Found existing resource group. Reusing it."
}
else {
    New-AzResourceGroup -Name $ResourceGroup -Location $Location | Out-Null
    Write-Host "Created resource group."
}

# ---------------------------------------------------------------- find existing resources

# Without -Suffix, reuse the registry and storage account already in the resource group.
if (-not $Suffix) {
    $names = @()
    if ($resourceGroupObject) {
        $names += @(Get-AzStorageAccount -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue |
            Where-Object { $_.StorageAccountName -like "stp1apimon*" } |
            ForEach-Object { $_.StorageAccountName.Substring(10) })
        $names += @(Get-AzContainerRegistry -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "acrp1apimon*" } |
            ForEach-Object { $_.Name.Substring(11) })
    }
    $suffixes = @($names | Select-Object -Unique)
    if ($suffixes.Count -eq 1) {
        $Suffix = $suffixes[0]
        Write-Host "Found existing resources with suffix '$Suffix'. Reusing them." -ForegroundColor Green
    }
    elseif ($suffixes.Count -gt 1) {
        throw "More than one set of resources was found in $ResourceGroup ($($suffixes -join ', ')). Run the script again with -Suffix to choose one."
    }
    else {
        # Nothing exists yet: create new resources with a random suffix. A later run without -Suffix finds them again.
        $Suffix = -join ((@(48..57) + @(97..122)) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
        Write-Host "No existing resources found. Creating new ones with suffix '$Suffix'." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------- storage

$storageName = "stp1apimon$Suffix"
$acrName = "acrp1apimon$Suffix"

# The account named in .env is used only if it exists in the resource group. Otherwise it is ignored, and the
# script uses (or creates) its own account. Each lookup is a single check, with no retries.
$envConn = $settings["AZURE_STORAGE_CONNECTION_STRING"]
$envAccount = $null
if ($envConn -match 'AccountName=([^;]+)') {
    $envAccountName = $Matches[1]
    $envAccount = Get-IfExists { Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $envAccountName -ErrorAction SilentlyContinue }
}

$storageCreated = $false
if ($envAccount) {
    Write-Host "== Storage: using the account from .env ($($envAccount.StorageAccountName))" -ForegroundColor Cyan
    $storageName = $envAccount.StorageAccountName
    $storageConn = $envConn
}
else {
    if ($envConn) {
        Write-Host "The storage account in .env was not found in $ResourceGroup, so it is ignored." -ForegroundColor Yellow
    }
    Write-Host "== Storage account $storageName" -ForegroundColor Cyan
    $storageAccount = Get-IfExists { Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $storageName -ErrorAction SilentlyContinue }
    if ($storageAccount) {
        Write-Host "Found existing storage account. Reusing it."
    }
    else {
        New-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $storageName -Location $Location -SkuName Standard_LRS -Kind StorageV2 | Out-Null
        $storageCreated = $true
        Write-Host "Created storage account."
    }
    $key = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroup -Name $storageName)[0].Value
    $storageConn = "DefaultEndpointsProtocol=https;AccountName=$storageName;AccountKey=$key;EndpointSuffix=core.windows.net"
}

# .env needs the new value when the account was just created, or when .env names an account that is not used.
$staleEnvString = [bool]$envConn -and -not $envAccount

if ($storageCreated -or $staleEnvString) {
    # Write the details to their own file, so they can be copied into .env. The file holds the account key:
    # keep it private. It is listed in .gitignore and .dockerignore.
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

    Write-Host ""
    Write-Host "ACTION NEEDED: open .env, set AZURE_STORAGE_CONNECTION_STRING to the value in storage-connection.txt, and save the file." -ForegroundColor Yellow
    Read-Host "Press Enter when .env is saved" | Out-Null

    $settings = Read-EnvFile $EnvFile
    if (-not $settings["AZURE_STORAGE_CONNECTION_STRING"]) {
        throw "AZURE_STORAGE_CONNECTION_STRING is still empty in .env. Fill it in and run the script again."
    }
    $storageConn = $settings["AZURE_STORAGE_CONNECTION_STRING"]
}

# The container is created through the management API, so no data-plane call (and no retry loop) is needed.
Write-Host "== Storage container $StorageContainer" -ForegroundColor Cyan
$container = Get-IfExists { Get-AzRmStorageContainer -ResourceGroupName $ResourceGroup -StorageAccountName $storageName -Name $StorageContainer -ErrorAction SilentlyContinue }
if ($container) {
    Write-Host "Found existing container. Reusing it."
}
else {
    New-AzRmStorageContainer -ResourceGroupName $ResourceGroup -StorageAccountName $storageName -Name $StorageContainer | Out-Null
    Write-Host "Created container."
}

# ---------------------------------------------------------------- container registry

Write-Host "== Container registry $acrName" -ForegroundColor Cyan
$registry = Get-IfExists { Get-AzContainerRegistry -ResourceGroupName $ResourceGroup -Name $acrName -ErrorAction SilentlyContinue }
if ($registry) {
    Write-Host "Found existing registry. Reusing it."
    if (-not $registry.AdminUserEnabled) {
        # The admin user is needed to push the image and to pull it into Container Apps.
        $registry = Update-AzContainerRegistry -ResourceGroupName $ResourceGroup -Name $acrName -EnableAdminUser
        Write-Host "Turned on the admin user for the existing registry."
    }
}
else {
    $registry = New-AzContainerRegistry -ResourceGroupName $ResourceGroup -Name $acrName -Location $Location -Sku Basic -EnableAdminUser
    Write-Host "Created registry."
}
$loginServer = $registry.LoginServer
$registryCreds = Get-AzContainerRegistryCredential -ResourceGroupName $ResourceGroup -RegistryName $acrName
$acrPassword = $registryCreds.Password

# ---------------------------------------------------------------- logs and Container Apps environment

Write-Host "== Container Apps environment $EnvironmentName (no Log Analytics)" -ForegroundColor Cyan
$managedEnvironment = Get-IfExists { Get-AzContainerAppManagedEnv -ResourceGroupName $ResourceGroup -Name $EnvironmentName -ErrorAction SilentlyContinue }
if ($managedEnvironment) {
    Write-Host "Found existing environment. Reusing it."
}
else {
    Write-Host "Creating the environment (this takes a few minutes)..."
    # No log destination is set, so no Log Analytics workspace is created. Logs are still available in the portal (Log stream).
    New-AzContainerAppManagedEnv -Name $EnvironmentName -ResourceGroupName $ResourceGroup -Location $Location | Out-Null
}
# The app can only be created once the environment has finished provisioning, so wait for it here.
$managedEnvironment = $null
$deadline = (Get-Date).AddMinutes(20)
while (-not $managedEnvironment) {
    $current = Get-IfExists { Get-AzContainerAppManagedEnv -ResourceGroupName $ResourceGroup -Name $EnvironmentName -ErrorAction SilentlyContinue }
    if ($current -and $current.ProvisioningState -eq "Succeeded") {
        $managedEnvironment = $current
    }
    elseif ($current -and @("Failed", "Canceled") -contains $current.ProvisioningState) {
        throw "The Container Apps environment $EnvironmentName failed to provision (state: $($current.ProvisioningState)). Delete it in the portal and run the script again."
    }
    elseif ((Get-Date) -gt $deadline) {
        throw "Timed out waiting for the Container Apps environment $EnvironmentName."
    }
    else {
        Start-Sleep -Seconds 20
    }
}
Write-Host "Environment ready (state: $($managedEnvironment.ProvisioningState))."
$environmentId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/managedEnvironments/$EnvironmentName"

# ---------------------------------------------------------------- build locally and push

$tag = Get-Date -Format "yyyyMMddHHmmss"
$image = "$loginServer/p1-api-monitor"

Write-Host "== Building the image with local Docker (tag $tag)" -ForegroundColor Cyan
Invoke-Docker -DockerArgs @("build", "-t", "${image}:$tag", "-t", "${image}:latest", $PSScriptRoot)

Write-Host "== Pushing the image to $loginServer" -ForegroundColor Cyan
$previous = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$acrPassword | & docker login $loginServer --username $acrName --password-stdin
$loginCode = $LASTEXITCODE
$ErrorActionPreference = $previous
if ($loginCode -ne 0) { throw "docker login to $loginServer failed." }
Invoke-Docker -DockerArgs @("push", "${image}:$tag")
Invoke-Docker -DockerArgs @("push", "${image}:latest")

# ---------------------------------------------------------------- app settings

# Secrets: stored in Container Apps. The environment variables below refer to them by name.
$secretDefinitions = @(
    @{ Name = "acr-password"; Value = $acrPassword },
    @{ Name = "client-secret"; Value = $settings["SN_CLIENT_SECRET"] },
    @{ Name = "storage-connection-string"; Value = $storageConn }
)

# Plain environment variables: name and value.
$plainVars = @(
    @{ Name = "SN_INSTANCE"; Value = $settings["SN_INSTANCE"] },
    @{ Name = "SN_CLIENT_ID"; Value = $settings["SN_CLIENT_ID"] },
    @{ Name = "AZURE_STORAGE_CONTAINER"; Value = $StorageContainer },
    @{ Name = "AZURE_STORAGE_FOLDER"; Value = $StorageFolder },
    @{ Name = "SWAT_BOARD_PORT"; Value = "8080" }
)
foreach ($key in @("MONITOR_INTERVAL_MINUTES", "TEAMS_VERIFY_SSL", "EMAIL_TO", "EMAIL_CC", "EMAIL_BCC", "SMTP_HOST", "SMTP_PORT", "SMTP_STARTTLS", "SMTP_USER", "SMTP_FROM")) {
    if ($settings[$key]) { $plainVars += @{ Name = $key; Value = $settings[$key] } }
}

# Optional secrets: only when set in .env.
$optionalSecrets = @{ "TEAMS_WEBHOOK_URLS" = "teams-webhook"; "SMTP_PASSWORD" = "smtp-password" }
$secretVars = @()
foreach ($key in $optionalSecrets.Keys) {
    if ($settings[$key]) {
        $secretDefinitions += @{ Name = $optionalSecrets[$key]; Value = $settings[$key] }
        $secretVars += @{ Name = $key; SecretRef = $optionalSecrets[$key] }
    }
}

function New-AppDefinition {
    param([string]$PublicUrl)

    $secretObjects = @()
    foreach ($s in $secretDefinitions) {
        $secretObjects += New-AzContainerAppSecretObject -Name $s.Name -Value $s.Value
    }

    $envObjects = @()
    foreach ($v in $plainVars) {
        $envObjects += New-AzContainerAppEnvironmentVarObject -Name $v.Name -Value $v.Value
    }
    foreach ($v in $secretVars) {
        $envObjects += New-AzContainerAppEnvironmentVarObject -Name $v.Name -SecretRef $v.SecretRef
    }
    $envObjects += New-AzContainerAppEnvironmentVarObject -Name "SN_CLIENT_SECRET" -SecretRef "client-secret"
    $envObjects += New-AzContainerAppEnvironmentVarObject -Name "AZURE_STORAGE_CONNECTION_STRING" -SecretRef "storage-connection-string"
    if ($PublicUrl) {
        $envObjects += New-AzContainerAppEnvironmentVarObject -Name "SWAT_BOARD_PUBLIC_URL" -Value $PublicUrl
    }

    $registryObject = New-AzContainerAppRegistryCredentialObject -Server $loginServer -Username $acrName -PasswordSecretRef "acr-password"

    $configParams = @{
        ActiveRevisionsMode = "Single"
        IngressExternal     = $true
        IngressTargetPort   = 8080
        IngressTransport    = "auto"
        Secret              = $secretObjects
        Registry            = @($registryObject)
    }
    if ($AllowedIpRange) {
        $configParams["IngressIPSecurityRestriction"] = @(
            New-AzContainerAppIPSecurityRestrictionRuleObject -Name "allowed-network" -IPAddressRange $AllowedIpRange -Action Allow
        )
    }
    $configuration = New-AzContainerAppConfigurationObject @configParams

    $container = New-AzContainerAppTemplateObject -Name $AppName -Image "${image}:$tag" -ResourceCpu 0.25 -ResourceMemory "0.5Gi" -Env $envObjects

    return @{ Configuration = $configuration; Container = $container }
}

# ---------------------------------------------------------------- create or update the app

$app = Get-IfExists { Get-AzContainerApp -ResourceGroupName $ResourceGroup -Name $AppName -ErrorAction SilentlyContinue }

if ($app) {
    Write-Host "== Updating $AppName (new revision)" -ForegroundColor Cyan
    $publicUrl = "https://$($app.LatestRevisionFqdn)"
    $definition = New-AppDefinition -PublicUrl $publicUrl
    Update-AzContainerApp -Name $AppName -ResourceGroupName $ResourceGroup `
        -Configuration $definition.Configuration -TemplateContainer @($definition.Container) `
        -ScaleMinReplica 1 -ScaleMaxReplica 1 | Out-Null
}
else {
    Write-Host "== Creating $AppName" -ForegroundColor Cyan
    $definition = New-AppDefinition -PublicUrl ""
    New-AzContainerApp -Name $AppName -ResourceGroupName $ResourceGroup -Location $Location `
        -ManagedEnvironmentId $environmentId `
        -Configuration $definition.Configuration -TemplateContainer @($definition.Container) `
        -ScaleMinReplica 1 -ScaleMaxReplica 1 | Out-Null

    # The public address exists only after the app is created, so set the SWAT board address now.
    # The public address can take a short time to appear after the first creation.
    $publicUrl = ""
    $deadline = (Get-Date).AddMinutes(3)
    while (-not $publicUrl) {
        $created = Get-AzContainerApp -ResourceGroupName $ResourceGroup -Name $AppName
        if ($created.LatestRevisionFqdn) {
            $publicUrl = "https://$($created.LatestRevisionFqdn)"
        }
        elseif ((Get-Date) -gt $deadline) {
            throw "The app was created, but its public address is not known yet. Run the script again in a few minutes."
        }
        else {
            Start-Sleep -Seconds 10
        }
    }
    Write-Host "== Setting the SWAT board address to $publicUrl" -ForegroundColor Cyan
    $definition = New-AppDefinition -PublicUrl $publicUrl
    Update-AzContainerApp -Name $AppName -ResourceGroupName $ResourceGroup `
        -Configuration $definition.Configuration -TemplateContainer @($definition.Container) `
        -ScaleMinReplica 1 -ScaleMaxReplica 1 | Out-Null
}

$app = Get-AzContainerApp -ResourceGroupName $ResourceGroup -Name $AppName
$fqdn = $app.LatestRevisionFqdn

if (-not $AllowedIpRange) {
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
    Write-Warning "Check the logs: Azure portal > $AppName > Monitoring > Log stream (or Get-AzContainerAppRevision for the status)."
}

Write-Host ""
Write-Host "Deployed." -ForegroundColor Green
Write-Host "SWAT board: https://$fqdn"
