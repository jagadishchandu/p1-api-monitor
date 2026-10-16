# deploy-azure.ps1: what it does

`deploy-azure.ps1` creates the Azure resources for the P1 API Monitor, builds the image with your local Docker, and runs it in Azure Container Apps. All Azure work uses **Azure PowerShell (Az modules)**. The Azure CLI (`az`) is not used. It is the automated version of [README section 14](README.md#14-deploy-to-azure-container-apps-free-tier).

Run it from this folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-azure.ps1 -Suffix jc01
```

If the resources already exist from an earlier run, you can leave out `-Suffix`:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-azure.ps1
```

---

## Before you run it

| Requirement | Why |
|---|---|
| **Azure PowerShell** (Az module) | Creates and configures Azure resources. Install once in PowerShell: `Install-Module Az -Scope CurrentUser` |
| **Docker Desktop**, running | Builds the image on your PC and pushes it to Azure |
| **`.env` file** in this folder | Read for the ServiceNow, Teams, email and storage settings. Copy `.env.example` to `.env` and fill it in |
| An Azure subscription where you can create resources | The script creates billable resources |
| `SN_INSTANCE`, `SN_CLIENT_ID` and `SN_CLIENT_SECRET` filled in `.env` | The script stops if any of them is empty |

The script checks that the `Az.Accounts` module is installed. If you are not signed in yet, it runs `Connect-AzAccount -UseDeviceAuthentication`. It prints a code and a web address (`https://microsoft.com/devicelogin`). Open the address in any browser, enter the code, and sign in.

---

## Parameters

| Parameter | Required | Default | What it sets |
|---|---|---|---|
| `-Suffix` | No (see below) | none | Makes the registry and storage account names unique. Lowercase letters and digits, 3 to 12 characters. Example: `jc01` |
| `-ResourceGroup` | No | `rg-p1-api-monitor` | Resource group that holds everything |
| `-Location` | No | `eastus` | Azure region for all resources |
| `-AppName` | No | `p1-api-monitor` | Name of the Container App |
| `-EnvironmentName` | No | `cae-p1-api-monitor` | Name of the Container Apps environment |
| `-Subscription` | No | your current subscription | Subscription name or ID to use. Leave empty to use the current one |
| `-EnvFile` | No | `.env` in this folder | Settings file to read |
| `-StorageContainer` | No | `p1-api-monitor` | Blob container for the data |
| `-StorageFolder` | No | `p1-api-monitor` | Folder inside the container |
| `-AllowedIpRange` | No | empty | IP range allowed to open the app (for example `203.0.113.0/24`). Recommended, because the SWAT board has no login |

### Reusing existing resources

The script checks every resource before creating it. If it already exists, the script reuses it and does not change it:

| Resource | If it exists |
|---|---|
| Resource group | Reused |
| Storage account | Reused. Its key is read to build the connection string. No prompt |
| Storage container | Reused |
| Container registry | Reused. The admin user is turned on if it is off |
| Container Apps environment | Reused. The script waits only if it is still provisioning |
| Container App | Updated with a new revision |

**Without `-Suffix`:** the script looks in the resource group for an existing registry (`acrp1apimon<suffix>`) or storage account (`stp1apimon<suffix>`) and uses its suffix.
- One set found: it is reused, and the script continues.
- More than one set found: the script stops and asks you to pass `-Suffix` to choose one.
- None found: the script creates new resources with a random 6-character suffix. The suffix is printed. Later runs without `-Suffix` find these resources again.

The `storage-connection.txt` file and the "fill in .env" prompt appear when the script creates the storage account, or when `.env` names an account that is not used. Otherwise nothing is prompted.

**Storage account in `.env`:** if `AZURE_STORAGE_CONNECTION_STRING` names an account that is not in the resource group, the script ignores it, prints a warning, and uses (or creates) `stp1apimon<suffix>` instead.

**One check per resource:** each resource is looked up once, and if it is missing it is created. The storage container is created through the management API, so the script does not wait on the storage endpoint.

Names created from `-Suffix`:

| Resource | Name pattern | Example with `-Suffix jc01` |
|---|---|---|
| Container registry | `acrp1apimon<suffix>` | `acrp1apimonjc01` |
| Storage account | `stp1apimon<suffix>` | `stp1apimonjc01` |

---

## What the script does, step by step

### 1. Checks the tools and settings
- Stops if the `Az.Accounts` module is not installed.
- Stops if Docker is not running (`docker info` fails).
- Reads `.env` and stops if `SN_INSTANCE`, `SN_CLIENT_ID` or `SN_CLIENT_SECRET` is empty.

**Changes:** none.

### 2. Signs in to Azure
- If there is no current context (`Get-AzContext`), runs `Connect-AzAccount -UseDeviceAuthentication` (device code sign-in).
- If `-Subscription` is set, runs `Set-AzContext`.

**Changes:** Azure PowerShell keeps the sign-in in your user profile (the normal behaviour).

### 3. Registers the resource providers
- Checks `Microsoft.App` with `Get-AzResourceProvider`.
- Registers any that are not registered (`Register-AzResourceProvider`) and waits until they are. The wait is at most 5 minutes.

**Changes in Azure:** the two providers are registered on the subscription. Registering again is harmless.

### 4. Creates the resource group
- `New-AzResourceGroup` creates `rg-p1-api-monitor` (or `-ResourceGroup`) in `-Location`, if it does not exist.

**Changes in Azure:** one resource group.

### 5. Storage
- If `.env` has `AZURE_STORAGE_CONNECTION_STRING`, the script uses that value and creates no storage account.
- If it is empty, the script:
  - creates the storage account `stp1apimon<suffix>` (`New-AzStorageAccount`, Standard LRS, StorageV2), if it does not exist
  - reads its first access key (`Get-AzStorageAccountKey`) and builds the connection string from it. The key and the string are not printed
  - writes the details to **`storage-connection.txt`** in this folder: resource group, account, container, folder, and the `AZURE_STORAGE_CONNECTION_STRING=...` line ready to copy. This file holds the account key, so keep it private. It is listed in `.gitignore` and `.dockerignore`, so it is never committed or put in the image
  - stops and asks you to copy that line into `.env`, save the file, and press Enter. If `AZURE_STORAGE_CONNECTION_STRING` is still empty in `.env` at that point, the script stops with an error
- Creates the blob container `-StorageContainer` with `New-AzStorageContainer`, if it does not exist. The app also creates it on start.

If `.env` already has `AZURE_STORAGE_CONNECTION_STRING`, the script skips this file and the prompt.

**Changes in Azure:** one storage account (only when `.env` has no connection string), and one blob container.

### 6. Container registry
- Creates the registry `acrp1apimon<suffix>` (`New-AzContainerRegistry`, Basic SKU, admin user on) if it does not exist.
- Reads the login server and the admin password (`Get-AzContainerRegistryCredential`). The password is used only to log in to the registry and to set the app's registry secret.

**Changes in Azure:** one container registry, with the admin user turned on. For a stricter setup, use a managed identity (see README section 14).

### 7. Container Apps environment
- Creates the environment `cae-p1-api-monitor` (`New-AzContainerAppManagedEnv`) if it does not exist. No log destination is set, so **no Log Analytics workspace is created**. This is the slowest step, and it can take several minutes.
- Logs are still shown in the portal under **Monitoring > Log stream**.

**Changes in Azure:** one Container Apps environment.

### 8. Builds the image with local Docker
- Runs `docker build` on this folder, using the `Dockerfile`. The build runs on your PC, not in Azure.
- Tags the image twice: with a timestamp (for example `20261016133000`) and with `latest`.

**Changes:** Docker images are stored on your PC.

### 9. Pushes the image to the registry
- Runs `docker login` to the registry with the admin password. The password is sent through standard input, so it does not appear in the command line.
- Pushes both tags.

**Changes in Azure:** the image is stored in the registry.
**Changes on your PC:** `docker login` saves the registry login in your Docker config file (`%USERPROFILE%\.docker\config.json`).

### 10. Builds the app settings
The script reads the values from `.env` and turns them into app settings (`New-AzContainerAppSecretObject`, `New-AzContainerAppEnvironmentVarObject`).

**Secrets** (stored in Container Apps, referenced by name):

| Secret name | Value from | Used for |
|---|---|---|
| `acr-password` | registry admin password | Pulling the image |
| `client-secret` | `SN_CLIENT_SECRET` | ServiceNow OAuth |
| `storage-connection-string` | `.env` or the storage account | Storage access |
| `teams-webhook` | `TEAMS_WEBHOOK_URLS`, only if set | Teams alerts |
| `smtp-password` | `SMTP_PASSWORD`, only if set | Email alerts |

**Environment variables** (plain values, or a reference to a secret):

| Variable | Value |
|---|---|
| `SN_INSTANCE` | from `.env` |
| `SN_CLIENT_ID` | from `.env` |
| `SN_CLIENT_SECRET` | `secretref: client-secret` |
| `AZURE_STORAGE_CONNECTION_STRING` | `secretref: storage-connection-string` |
| `AZURE_STORAGE_CONTAINER` | `-StorageContainer` |
| `AZURE_STORAGE_FOLDER` | `-StorageFolder` |
| `SWAT_BOARD_PORT` | `8080` |
| `MONITOR_INTERVAL_MINUTES`, `TEAMS_VERIFY_SSL`, `EMAIL_TO`, `EMAIL_CC`, `EMAIL_BCC`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_STARTTLS`, `SMTP_USER`, `SMTP_FROM` | from `.env`, only if set |
| `TEAMS_WEBHOOK_URLS` | `secretref: teams-webhook`, only if set |
| `SMTP_PASSWORD` | `secretref: smtp-password`, only if set |
| `SWAT_BOARD_PUBLIC_URL` | `https://<app address>`, set in step 12 |

**Changes:** none yet. The values are only collected.

### 11. Creates or updates the app
- **Ingress:** external, target port `8080`, transport `auto`, single revision mode.
- **Registry:** pulls from the registry with the `acr-password` secret.
- **Scale:** 1 replica minimum and 1 maximum (the monitor must run all the time, and two copies would send duplicate alerts).
- **Size:** 0.25 vCPU and 0.5 GiB memory.
- **Access rule:** when `-AllowedIpRange` is given, one IP rule named `allowed-network` that allows only that range.

Then:
- **If the app does not exist**, `New-AzContainerApp` creates it in the environment.
- **If the app exists**, `Update-AzContainerApp` creates a new revision with the new image and the current settings.

**Changes in Azure:** a new Container App, or a new revision of the existing one.

### 12. Sets the public SWAT board address
- When the app is created for the first time, its public address is only known afterwards. The script reads it (`LatestRevisionFqdn`) and updates the app with `SWAT_BOARD_PUBLIC_URL=https://<address>`. On later runs the address is already known, so the value is set in step 11.
- The address has no port number, because Container Apps serves HTTPS on 443. This is the address the **Open SWAT board** button in Teams uses.

**Changes in Azure:** one more revision of the app.

### 13. Access warning
- If `-AllowedIpRange` is not given, the script prints a warning that anyone with the address can open the SWAT board.

**Changes:** none.

### 14. Checks the app
- Waits 30 seconds, then calls `https://<address>/api/incidents`.
- If it answers, prints the number of incidents on the board.
- If not, prints a warning. The app can take a minute or two to start. The check can also fail if `-AllowedIpRange` blocks your network.

**Changes:** none.

### 15. Prints the result
- The SWAT board address.

---

## Summary of changes

**In Azure (created or updated):**

| Resource | Created | Updated on re-run |
|---|---|---|
| Resource group | Yes | No |
| Resource provider registration | Yes | No |
| Storage account | Only if `.env` has no connection string | No |
| Blob container | Yes | No |
| Container registry (admin user on) | Yes | No |
| Container Apps environment | Yes | No |
| Container App | Yes | Yes (new revision with the new image and settings) |

The IP access rule is part of the app's ingress settings. It is set whenever `-AllowedIpRange` is given.

**On your PC:**
- Docker images built and tagged.
- Docker login saved in `%USERPROFILE%\.docker\config.json`.
- Azure PowerShell sign-in kept in your user profile.

**Not changed:**
- `.env` is only read, never written.
- No files in the repository are changed.
- No Azure resources are deleted.

**Note on re-runs:** the app's settings are replaced with what the script sends. A setting you added in the portal and not in `.env` will be removed on the next run. Put app settings in `.env` instead.

---

## Security notes

- **Secrets are not printed.** The script never writes secret values to the console.
- **The registry admin user is on.** This keeps the setup simple. Turn it off and use a managed identity if your security team requires it.
- **The SWAT board has no login.** Use `-AllowedIpRange`, or put the app behind an authenticated front end.
- **Keep `.env` private.** It holds the OAuth client secret and the storage connection string.

---

## Troubleshooting

| Message | What to do |
|---|---|
| `Azure PowerShell is not installed` | Run `Install-Module Az -Scope CurrentUser` in PowerShell, then run the script again |
| `Docker is not running` | Start Docker Desktop and wait until it says it is running |
| `No .env file` | Copy `.env.example` to `.env` and fill it in |
| `SN_INSTANCE is empty in .env` (or the other required names) | Fill in the value in `.env` |
| `...is not registered yet` | Wait a few minutes and run the script again |
| An error from an `*-Az*` cmdlet | Read the message. Common causes: the name is already taken (use another `-Suffix`), or your account lacks permission to create resources |
| `docker login ... failed` | Check that the registry was created and try again |
| `The app did not answer yet` | Wait a minute, then open the app address in a browser |
| Board opens for anyone | Re-run with `-AllowedIpRange` |

To read the logs, open the Azure portal, go to the app `p1-api-monitor`, and choose **Monitoring > Log stream**. To see the revision status in PowerShell:

```powershell
Get-AzContainerAppRevision -ResourceGroupName rg-p1-api-monitor -ContainerAppName p1-api-monitor
```

---

## Remove everything

This deletes the resource group and **all** resources in it, including the storage account and its data. It cannot be undone.

```powershell
Remove-AzResourceGroup -Name rg-p1-api-monitor -Force
```
