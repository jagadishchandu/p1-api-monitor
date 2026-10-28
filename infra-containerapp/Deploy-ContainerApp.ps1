<#
.SYNOPSIS
    Creates the Azure resources with Terraform, builds and pushes the image, and deploys the P1 API Monitor.

.DESCRIPTION
    1. Checks the tools (terraform, docker, Az PowerShell) and signs in to Azure (device code) if needed.
    2. Reads ..\.env. Values are passed to Terraform as TF_VAR_ environment variables, so secrets are never written
       to a file. Nothing from .env is printed.
    3. terraform init, then creates the resource group and the container registry only.
    4. Shows where to get the registry user name and password, and asks for them (see the instructions it prints).
    5. Logs in to the registry, builds the image from the project root, and pushes it.
    6. terraform apply creates the rest (storage, identity, roles, logs, environment, container app) with that image.

    Run it from the infra-containerapp folder:
        .\Deploy-ContainerApp.ps1 -NameSuffix jc01

    Required: terraform 1.6+, docker (running), Az PowerShell:  Install-Module Az -Scope CurrentUser

.EXAMPLE
    .\Deploy-ContainerApp.ps1 -NameSuffix jc01

.EXAMPLE
    # Second run, when the registry already exists: give the registry credentials without being asked.
    $registrySecret = Read-Host "Registry password" -AsSecureString
    .\Deploy-ContainerApp.ps1 -NameSuffix jc01 -RegistryUsername acrp1apimonjc01 -RegistryPassword $registrySecret -AutoApprove
#>
[CmdletBinding()]
param(
    # 3-12 lowercase letters or digits. Makes the registry and storage account names unique.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{3,12}$')]
    [string]$NameSuffix,

    [string]$SubscriptionId = "",
    [string]$Location = "eastus2",
    [string]$ResourceGroupName = "rg-p1-api-monitor",

    # The .env of the project, one folder up from this script.
    [string]$EnvFile = (Join-Path $PSScriptRoot "..\.env"),

    # Image tag. Defaults to a timestamp so every deployment gets a new revision.
    [string]$ImageTag = (Get-Date -Format "yyyyMMddHHmmss"),

    # Registry admin user name and password, for the docker push. Asked for when empty.
    [string]$RegistryUsername = "",
    [SecureString]$RegistryPassword,

    # Skip the confirmation prompts of terraform apply.
    [switch]$AutoApprove
)

$ErrorActionPreference = "Stop"
$infraDir = $PSScriptRoot
$projectDir = Split-Path -Parent $PSScriptRoot

function Write-Step($text) { Write-Host ""; Write-Host "== $text" -ForegroundColor Cyan }

function Read-DotEnv($path) {
    # Parses NAME=value lines. Quotes around a value are removed. Values are returned, never printed.
    $values = @{}
    foreach ($raw in Get-Content -LiteralPath $path) {
        $line = $raw.Trim()
        if ($line -eq "" -or $line.StartsWith("#") -or -not $line.Contains("=")) { continue }
        $name, $value = $line.Split("=", 2)
        $value = $value.Trim()
        if ($value.Length -ge 2 -and $value[0] -eq $value[-1] -and ($value[0] -eq "'" -or $value[0] -eq '"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$name.Trim()] = $value
    }
    return $values
}

function Invoke-Terraform([string[]]$Arguments) {
    Push-Location $infraDir
    try {
        & terraform @Arguments
        if ($LASTEXITCODE -ne 0) { throw "terraform $($Arguments[0]) failed (exit $LASTEXITCODE). Read the messages above." }
    } finally {
        Pop-Location
    }
}

function Get-TerraformOutput([string]$Name) {
    Push-Location $infraDir
    try {
        $value = & terraform output -raw $Name
        if ($LASTEXITCODE -ne 0) { throw "Could not read the Terraform output $Name." }
        return $value
    } finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------- 1. tools and Azure sign-in
Write-Step "Checking the tools"
foreach ($tool in @("terraform", "docker")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is not installed or not on PATH." }
}
& docker info *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker is not running. Start Docker Desktop and run the script again." }
foreach ($module in @("Az.Accounts", "Az.Resources", "Az.ContainerRegistry")) {
    if (-not (Get-Module -ListAvailable -Name $module)) { throw "Missing PowerShell module $module. Run: Install-Module Az -Scope CurrentUser" }
}
Import-Module Az.Accounts, Az.Resources, Az.ContainerRegistry -ErrorAction Stop

Write-Step "Signing in to Azure"
$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Connect-AzAccount -UseDeviceAuthentication | Out-Null
    $context = Get-AzContext
}
if ($SubscriptionId -ne "") {
    Set-AzContext -Subscription $SubscriptionId | Out-Null
    $context = Get-AzContext
}
Write-Host "Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))"
$subscriptionId = $context.Subscription.Id

# ---------------------------------------------------------------- 2. settings from .env
Write-Step "Reading settings from .env (values are not printed)"
if (-not (Test-Path -LiteralPath $EnvFile)) { throw "No settings file at $EnvFile. Copy .env.example to .env and fill it in." }
$settings = Read-DotEnv $EnvFile
foreach ($required in @("SN_INSTANCE")) {
    if (-not $settings.ContainsKey($required) -or $settings[$required] -eq "") {
        throw "$required is missing or empty in $EnvFile."
    }
}
# Either the OAuth client (SN_CLIENT_ID and SN_CLIENT_SECRET) or a user name and password (SN_USE_USERNAME_PASSWORD=true).
$usesUserPassword = ($settings["SN_USE_USERNAME_PASSWORD"] -match '^(?i)(true|1|yes|on)$')
if ($usesUserPassword) {
    foreach ($required in @("SN_USERNAME", "SN_PASSWORD")) {
        if (-not $settings.ContainsKey($required) -or $settings[$required] -eq "") {
            throw "$required is missing or empty in $EnvFile. It is required when SN_USE_USERNAME_PASSWORD=true."
        }
    }
} else {
    foreach ($required in @("SN_CLIENT_ID", "SN_CLIENT_SECRET")) {
        if (-not $settings.ContainsKey($required) -or $settings[$required] -eq "") {
            throw "$required is missing or empty in $EnvFile. It is required when SN_USE_USERNAME_PASSWORD is not true."
        }
    }
}

# .env name -> Terraform variable. Secrets go through the environment only.
$variableMap = [ordered]@{
    "SN_INSTANCE"              = "sn_instance"
    "SN_CLIENT_ID"             = "sn_client_id"
    "SN_CLIENT_SECRET"         = "sn_client_secret"
    "SN_USE_USERNAME_PASSWORD" = "sn_use_username_password"
    "SN_USERNAME"              = "sn_username"
    "SN_PASSWORD"              = "sn_password"
    "SN_VERIFY_SSL"            = "sn_verify_ssl"
    "AZURE_STORAGE_CONTAINER"  = "storage_container"
    "AZURE_STORAGE_FOLDER"     = "storage_folder"
    "TEAMS_WEBHOOK_URLS"       = "teams_webhook_urls"
    "TEAMS_VERIFY_SSL"         = "teams_verify_ssl"
    "EMAIL_TO"                 = "email_to"
    "EMAIL_CC"                 = "email_cc"
    "EMAIL_BCC"                = "email_bcc"
    "SMTP_HOST"                = "smtp_host"
    "SMTP_PORT"                = "smtp_port"
    "SMTP_STARTTLS"            = "smtp_starttls"
    "SMTP_USER"                = "smtp_user"
    "SMTP_PASSWORD"            = "smtp_password"
    "SMTP_FROM"                = "smtp_from"
    "MONITOR_INTERVAL_MINUTES" = "monitor_interval_minutes"
    "SWAT_BOARD_ENABLED"       = "swat_board_enabled"
    "SWAT_BOARD_PORT"          = "swat_board_port"
    "SWAT_BOARD_PUBLIC_URL"    = "swat_board_public_url"
}
foreach ($envName in $variableMap.Keys) {
    if ($settings.ContainsKey($envName) -and $settings[$envName] -ne "") {
        Set-Item -Path ("env:TF_VAR_" + $variableMap[$envName]) -Value $settings[$envName]
    }
}
# Terraform variables that are not in .env.
$env:TF_VAR_subscription_id = $subscriptionId
$env:TF_VAR_location = $Location
$env:TF_VAR_resource_group_name = $ResourceGroupName
$env:TF_VAR_name_suffix = $NameSuffix
$env:TF_VAR_image_tag = $ImageTag
Write-Host "Settings read. Secrets are passed to Terraform in memory only."

# ---------------------------------------------------------------- 3. Terraform: registry first
Write-Step "terraform init"
Invoke-Terraform @("init", "-upgrade")

Write-Step "Step 1 of 2: create the resource group, the container registry and the identity"
$firstTargets = @(
    "-target=azurerm_resource_group.main",
    "-target=azurerm_container_registry.acr",
    "-target=azurerm_user_assigned_identity.app",
    "-target=azurerm_role_assignment.acr_pull"
)
$applyArgs = @("apply") + $firstTargets
if ($AutoApprove) { $applyArgs += "-auto-approve" }
Invoke-Terraform $applyArgs

$registryName = Get-TerraformOutput "registry_name"
$loginServer = Get-TerraformOutput "registry_login_server"

# ---------------------------------------------------------------- 4. registry user name and password
Write-Host ""
Write-Host "================================================================================" -ForegroundColor Yellow
Write-Host " The container registry is created: $registryName" -ForegroundColor Yellow
Write-Host " Address: $loginServer" -ForegroundColor Yellow
Write-Host "================================================================================" -ForegroundColor Yellow
Write-Host @"

To push the image, the script needs the registry's ADMIN USER NAME and PASSWORD.

WHERE TO GET THEM (Azure portal):
  1. Go to https://portal.azure.com and search for "Container registries".
  2. Open the registry named  $registryName
  3. In the left menu, under Settings, click "Access keys".
  4. Turn on "Admin user" if it is off. (Terraform already turns it on.)
  5. USER NAME  = the "Username" box.  It is the registry name:  $registryName
     PASSWORD   = the "password" box (click the copy icon). "password2" also works.

OR WITH AZURE CLI (run in a terminal; copy the output, do not paste it into chat):
  az acr credential show --name $registryName --query username -o tsv
  az acr credential show --name $registryName --query "passwords[0].value" -o tsv

NEXT TIME, pass them as parameters so the script does not ask:
  `$registrySecret = Read-Host "Registry password" -AsSecureString
  .\Deploy-ContainerApp.ps1 -NameSuffix $NameSuffix -RegistryUsername $registryName -RegistryPassword `$registrySecret

"@

if ($RegistryUsername -eq "") {
    $RegistryUsername = Read-Host "Registry user name (press Enter to use $registryName)"
    if ($RegistryUsername -eq "") { $RegistryUsername = $registryName }
}
if (-not $RegistryPassword) {
    $RegistryPassword = Read-Host "Registry password (hidden)" -AsSecureString
}
$plainPassword = [System.Net.NetworkCredential]::new("", $RegistryPassword).Password
if ([string]::IsNullOrEmpty($plainPassword)) { throw "No registry password was given." }

# ---------------------------------------------------------------- 5. build and push the image
Write-Step "Logging in to the registry with Docker"
$plainPassword | & docker login $loginServer -u $RegistryUsername --password-stdin
if ($LASTEXITCODE -ne 0) {
    throw "docker login failed. Check the user name and password (see the instructions above), then run the script again."
}
$plainPassword = $null

$image = "$loginServer/p1-api-monitor:$ImageTag"
Write-Step "Building the image $image from $projectDir"
& docker build -t $image $projectDir
if ($LASTEXITCODE -ne 0) { throw "docker build failed." }

Write-Step "Pushing the image"
& docker push $image
if ($LASTEXITCODE -ne 0) { throw "docker push failed." }
& docker logout $loginServer | Out-Null

# ---------------------------------------------------------------- 6. Terraform: everything else
Write-Step "Step 2 of 2: create the storage, logs, environment and the container app"
$applyArgs = @("apply")
if ($AutoApprove) { $applyArgs += "-auto-approve" }
Invoke-Terraform $applyArgs

$appUrl = Get-TerraformOutput "app_url"
$appName = Get-TerraformOutput "container_app_name"

Write-Step "Checking the app"
try {
    $response = Invoke-WebRequest -Uri "$appUrl/" -UseBasicParsing -TimeoutSec 60
    Write-Host "SWAT board answered with HTTP $($response.StatusCode): $appUrl"
} catch {
    Write-Host "The board is not answering yet ($($_.Exception.Message)). The first start can take a few minutes." -ForegroundColor Yellow
    Write-Host "Watch the logs with:  az containerapp logs show -n $appName -g $ResourceGroupName --follow --type console"
}

Write-Host ""
Write-Host "Deployed. SWAT board: $appUrl" -ForegroundColor Green
Write-Host "Storage account, identity and roles are created. The app uses its managed identity (no key)."
Write-Host "Terraform state (terraform.tfstate) holds the secrets. Keep it private, or use a private backend (versions.tf)."
