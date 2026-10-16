# deploy-azure.ps1: what it does

`deploy-azure.ps1` deploys the P1 API Monitor to Azure Container Apps. It uses **Azure PowerShell (Az)** for all Azure work and does not call the Azure CLI (`az`). It follows the same approach as `school-lms\infra\deploy-containerapp.ps1`. It is the automated version of [README section 14](README.md#14-deploy-to-azure-container-apps-free-tier).

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-azure.ps1
```

To create resources with a name of your choice, or to restrict access:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-azure.ps1 -Suffix jc01 -AllowedIpRange 203.0.113.0/24
```

---

## Before you run it

| Requirement | Why |
|---|---|
| **Azure PowerShell** (Az modules) | Creates and configures Azure resources. Install once: `Install-Module Az -Scope CurrentUser` |
| **Docker Desktop**, running | Builds the image on your PC and pushes it to Azure |
| **`.env`** in this folder | Read for the ServiceNow and optional Teams, email and storage settings. Copy `.env.example` to `.env` |

The script stops if `SN_INSTANCE`, `SN_CLIENT_ID` or `SN_CLIENT_SECRET` is empty. Sign-in uses device code: the script prints a code and a web address (`https://microsoft.com/devicelogin`). Open the address in any browser, enter the code, and sign in.

---

## Parameters

| Parameter | Default | What it does |
|---|---|---|
| `-Suffix` | none (see [Naming](#naming-and-reuse)) | Makes the storage account and registry names unique. Lowercase letters and digits, 3 to 12 characters |
| `-ResourceGroup` | `rg-p1-api-monitor` | Resource group that holds everything |
| `-Location` | `eastus` | Azure region |
| `-AppName` | `p1-api-monitor` | Container app name |
| `-EnvironmentName` | `cae-p1-api-monitor` | Container Apps environment name |
| `-ImageName` | `p1-api-monitor` | Image repository name in the registry |
| `-SubscriptionId` | current subscription | Subscription to use. Leave empty to use the current one |
| `-EnvFile` | `.env` in this folder | Settings file to read |
| `-StorageContainer` | `p1-api-monitor` | Blob container for the data |
| `-StorageFolder` | `p1-api-monitor` | Folder inside the container |
| `-AllowedIpRange` | empty | Only this IP range can open the app. Recommended, because the SWAT board has no login |

---

## Where each resource lives

The script searches only the subscription and resource group named for each resource. It does not search other subscriptions.

| Resource | Subscription parameter | Resource group parameter |
|---|---|---|
| Storage account | -StorageSubscriptionId | -StorageResourceGroup |
| Container registry | -RegistrySubscriptionId | -RegistryResourceGroup |
| Container Apps environment | -EnvironmentSubscriptionId | -EnvironmentResourceGroup |
| Container app | -AppSubscriptionId | -AppResourceGroup |

Leave a pair empty to use -SubscriptionId and -ResourceGroup. The app must be in the same subscription as its environment, and the script stops if they differ. If a resource is found in its place, it is reused. If not, it is created there.

## Naming and reuse

Names are `stp1apimon<suffix>` (storage account) and `acrp1apimon<suffix>` (registry).

**Without `-Suffix`:** the script looks in the resource group for an existing storage account or registry.
- One set found: it is reused.
- More than one set found: the script stops and asks you to pass `-Suffix`.
- None found: the script creates new resources with a random 6-character suffix and prints it. Later runs without `-Suffix` find those resources again.

**With `-Suffix`:** the names are built from it. Existing resources with those names are reused.

---

## What the script does, step by step

### 1. Checks
- Stops if an Az module (`Az.Accounts`, `Az.Resources`, `Az.Storage`, `Az.ContainerRegistry`) is missing.
- Stops if Docker is not running.
- Reads `.env` and stops if `SN_INSTANCE`, `SN_CLIENT_ID` or `SN_CLIENT_SECRET` is empty.

**Changes:** none.

### 2. Signs in and registers providers
- If there is no Azure context, runs `Connect-AzAccount -UseDeviceAuthentication`.
- If `-SubscriptionId` is given, selects it with `Set-AzContext`.
- Registers `Microsoft.App`, `Microsoft.ContainerRegistry` and `Microsoft.Storage` (`Register-AzResourceProvider`). Registering again is harmless.

**Changes in Azure:** provider registrations on the subscription.

### 3. Shows what exists
Prints one line per resource: **present** (green) or **missing** (yellow) for the resource group, storage account, registry, environment and container app. Nothing is created yet.

### 4. Resource group
Creates the resource group in `-Location` if it does not exist.

**Changes in Azure:** one resource group, if missing.

### 5. Storage account and container
- If `.env` names a storage account (in `AZURE_STORAGE_CONNECTION_STRING`) that exists in the resource group, the script uses it. If not, it prints a warning and ignores that value.
- Otherwise it uses `stp1apimon<suffix>`. If it does not exist, it is created with Standard LRS, StorageV2, **TLS 1.2 minimum** and **public blob access off**.
- The storage key is read and the connection string is built from it. The key is never printed.
- The container is created through the management API (`New-AzRmStorageContainer`) with **public access off**. If it exists, it is reused.
- **Only when the account is new, or when `.env` names an account that is not used:** the script writes `storage-connection.txt` in this folder and asks you to copy the `AZURE_STORAGE_CONNECTION_STRING=` line into `.env`. Type `YES` after saving, or `NO` to stop. `storage-connection.txt` is listed in `.gitignore` and `.dockerignore`, so it is never committed or put in the image.

**Changes in Azure:** one storage account and one container, if missing.

### 6. Container registry
- Creates `acrp1apimon<suffix>` (Basic, admin user on) if it does not exist.
- If it exists but the admin user is off, turns the admin user on (`Update-AzContainerRegistry`). The admin user is needed to push the image and to pull it into the app.
- Reads the login server and admin credentials.

**Changes in Azure:** one registry, if missing.

### 7. Container Apps environment
- If the environment exists and is provisioned, it is reused.
- If it exists but is not provisioned (for example after a failed run), it is removed and created again.
- The environment is created with **New-AzResource** and an empty property set. **No log destination is set**, so no Log Analytics workspace is created.
- Waits until the environment reports `Succeeded`. Stops with a message if it fails or takes more than 20 minutes.

**Changes in Azure:** one Container Apps environment, if missing.

### 8. Build and push
- Signs in to the registry with local Docker. The login is stored in a **temporary Docker config folder**, not in the Windows credential store, and the folder is deleted at the end. The password goes through standard input, so it is not on the command line.
- Builds the image from this folder with the `Dockerfile`. The build runs on your PC.
- Tags it with a timestamp (for example `20261016133000`) and as `latest`, then pushes both.
- **Removes older images:** tags other than the new one and `latest` are deleted from the registry, and older local images of this repository are deleted from your PC. This keeps storage and cost down.

**Changes:** the image is pushed to the registry. Old tags and local images are removed. On your PC, the Docker login is kept only in the temporary folder.

### 9. Creates or updates the container app
- Creates or updates `p1-api-monitor` with **New-AzResource** (an ARM request with `-Force`).
- Settings: external ingress on port `8080`, single revision mode, **exactly 1 replica** (minimum and maximum), 0.25 vCPU, 0.5 GiB.
- **Secrets:** every value from `.env` is stored as a Container Apps secret, not as a plain environment variable. The registry password is a secret too. Each secret name is the variable name in lowercase with hyphens, shortened to 20 characters (for example `SN_CLIENT_SECRET` becomes `sn-client-secret`, and `AZURE_STORAGE_CONNECTION_STRING` becomes `azure-storage-connec`). Settings with an empty value are left out.
- Environment variables: each setting from `.env` (and `SWAT_BOARD_PORT=8080`, `AZURE_STORAGE_CONTAINER`, `AZURE_STORAGE_FOLDER`, `SWAT_BOARD_PUBLIC_URL` set by the script) points to its secret with `secretRef`. The values themselves are only in the secrets.
- With `-AllowedIpRange`, the ingress allows only that range.
- For a new app, the script reads the public address and updates the app once more with `SWAT_BOARD_PUBLIC_URL=https://<address>`, so the **Open SWAT board** button in Teams uses the public address (no port, HTTPS on 443).

**Changes in Azure:** a new container app, or a new revision of the existing one.

### 10. Health check
Calls `https://<address>/api/incidents` every 15 seconds, for up to 5 minutes. It shows a warning, not an error, if the app does not answer. Check the log stream if so.

---

## Summary of changes

| Resource | Created | Updated on re-run |
|---|---|---|
| Resource group | if missing | no |
| Provider registrations | yes | no |
| Storage account (TLS 1.2, no public blob access) | if missing, and only if `.env` names no existing account | no |
| Storage container (no public access) | if missing | no |
| Container registry (admin user on) | if missing | admin user turned on if off |
| Container Apps environment (no log destination) | if missing, or re-created if not provisioned | no |
| Container app | yes | yes: new revision with the new image and settings |
| Old image tags and local images | - | removed |

**On your PC:** the image is built and tagged. The Docker login lives only in a temporary folder that is deleted. `storage-connection.txt` is written only when the storage account is new or `.env` is stale.

**Not changed:** `.env` is only read. No repository files are changed except `storage-connection.txt`. No Azure resource is deleted, except an unprovisioned environment or an old image tag.

**Re-run note:** the app's settings are replaced with what the script sends. A setting added in the portal but not in `.env` is removed on the next run. Put app settings in `.env`.

---

## Security notes

- Secrets are not printed.
- The registry admin user is on, for simplicity. Turn it off and use a managed identity if policy requires it.
- The SWAT board has no login. Use `-AllowedIpRange`, or put the app behind an authenticated front end.
- Keep `.env` and `storage-connection.txt` private. They hold the OAuth client secret and the storage key.

---

## Troubleshooting

| Message | What to do |
|---|---|
| `PowerShell module ... is missing` | `Install-Module Az -Scope CurrentUser`, then run again |
| `Docker is not running` | Start Docker Desktop and wait until it is running |
| `No .env file` | Copy `.env.example` to `.env` and fill it in |
| `... is empty in .env` | Fill in the value in `.env` |
| `More than one set of resources was found` | Run again with `-Suffix` |
| `The Container Apps environment ... ended in state Failed` | Delete the environment in the portal, then run again |
| `docker login ... failed` | Read the message. Check that the registry exists and the admin user is on |
| `The app did not answer at ...` | Wait a minute, then open the address. Check the log stream |

To read the logs: Azure portal, the app `p1-api-monitor`, **Monitoring > Log stream**.

---

## Remove everything

This deletes the resource group and **all** resources in it, including the storage account and its data. It cannot be undone.

```powershell
Remove-AzResourceGroup -Name rg-p1-api-monitor -Force
```
