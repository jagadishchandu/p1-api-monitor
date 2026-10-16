# deploy-azure.ps1: what it does

`deploy-azure.ps1` creates the Azure resources for the P1 API Monitor, builds the image with your local Docker, and runs it in Azure Container Apps. It is the automated version of [README section 14](README.md#14-deploy-to-azure-container-apps-free-tier).

Run it from this folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-azure.ps1 -Suffix jc01
```

---

## Before you run it

| Requirement | Why |
|---|---|
| **Azure CLI** (`az`) | Creates and configures Azure resources. Install from [learn.microsoft.com/cli/azure/install-azure-cli](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| **Docker Desktop**, running | Builds the image on your PC and pushes it to Azure |
| **`.env` file** in this folder | Read for the ServiceNow, Teams, email and storage settings. Copy `.env.example` to `.env` and fill it in |
| An Azure subscription where you can create resources | The script creates billable resources |
| `SN_INSTANCE`, `SN_CLIENT_ID` and `SN_CLIENT_SECRET` filled in `.env` | The script stops if any of them is empty |

---

## Parameters

| Parameter | Required | Default | What it sets |
|---|---|---|---|
| `-Suffix` | **Yes** | none | Makes the registry and storage account names unique. Lowercase letters and digits, 3 to 12 characters. Example: `jc01` |
| `-ResourceGroup` | No | `rg-p1-api-monitor` | Resource group that holds everything |
| `-Location` | No | `eastus` | Azure region for all resources |
| `-AppName` | No | `p1-api-monitor` | Name of the Container App |
| `-EnvironmentName` | No | `cae-p1-api-monitor` | Name of the Container Apps environment |
| `-Subscription` | No | your current subscription | Subscription name or ID to use. Leave empty to use the one `az` is set to |
| `-EnvFile` | No | `.env` in this folder | Settings file to read |
| `-StorageContainer` | No | `p1-api-monitor` | Blob container for the data |
| `-StorageFolder` | No | `p1-api-monitor` | Folder inside the container |
| `-AllowedIpRange` | No | empty | IP range allowed to open the app (for example `203.0.113.0/24`). Recommended, because the SWAT board has no login |

Names created from `-Suffix`:

| Resource | Name pattern | Example with `-Suffix jc01` |
|---|---|---|
| Container registry | `acrp1apimon<suffix>` | `acrp1apimonjc01` |
| Storage account | `stp1apimon<suffix>` | `stp1apimonjc01` |

---

## What the script does, step by step

### 1. Checks the tools and settings
- Stops if `az` is not on the PATH.
- Stops if `docker` is not on the PATH.
- Stops if Docker is not running (`docker info` fails).
- Reads `.env` and stops if `SN_INSTANCE`, `SN_CLIENT_ID` or `SN_CLIENT_SECRET` is empty.

**Changes:** none.

### 2. Signs in to Azure
- Checks whether you are signed in (`az account show`). If not, runs `az login`, which opens a browser.
- If `-Subscription` is set, runs `az account set`.

**Changes:** the Azure CLI keeps its sign-in token in your user profile (the normal `az login` behaviour).

### 3. Prepares the Azure CLI and providers
- Installs or upgrades the `containerapp` extension for `az`.
- Registers the resource providers `Microsoft.App` and `Microsoft.OperationalInsights`, and waits until they are ready.

**Changes in Azure:** the two providers are registered on the subscription. Registering is safe to repeat.

### 4. Creates the resource group
- Creates `rg-p1-api-monitor` (or `-ResourceGroup`) in `-Location`. It does nothing if the group already exists.

**Changes in Azure:** one resource group.

### 5. Storage
- If `.env` has `AZURE_STORAGE_CONNECTION_STRING`, the script uses that value and creates no storage account.
- If it is empty, the script:
  - creates a storage account `stp1apimon<suffix>` (Standard LRS, StorageV2), if it does not exist
  - reads its connection string from Azure. The string is not printed.
- Creates the blob container `-StorageContainer` if it does not exist. The app also creates it on start.

**Changes in Azure:** one storage account (only when `.env` has no connection string), and one blob container.

### 6. Container registry
- Creates the registry `acrp1apimon<suffix>` (Basic SKU, admin user enabled) if it does not exist.
- Reads the registry login server and the admin password. The password is used only to log in to the registry and to set the app's registry secret.

**Changes in Azure:** one container registry, with the admin user turned on. The admin user is simple to set up. For a stricter setup, use a managed identity (see README section 14).

### 7. Container Apps environment
- Creates `cae-p1-api-monitor` if it does not exist. This is the slowest step, and it can take several minutes.

**Changes in Azure:** one Container Apps environment. Azure also creates a Log Analytics workspace for its logs.

### 8. Builds the image with local Docker
- Runs `docker build` on this folder, using the `Dockerfile`. The build runs on your PC, not in Azure.
- Tags the image twice: with a timestamp (for example `20261016133000`) and with `latest`.

**Changes:** Docker images are stored on your PC.

### 9. Pushes the image to the registry
- Runs `docker login` to the registry with the admin password, sent through standard input so it doesn't appear in the command line.
- Pushes both tags.

**Changes in Azure:** the image is stored in the registry.
**Changes on your PC:** `docker login` saves the registry login in your Docker config file (`%USERPROFILE%\.docker\config.json`).

### 10. Builds the settings for the app
The script reads the values from `.env` and turns them into app settings.

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
| `SN_CLIENT_SECRET` | `secretref:client-secret` |
| `AZURE_STORAGE_CONNECTION_STRING` | `secretref:storage-connection-string` |
| `AZURE_STORAGE_CONTAINER` | `-StorageContainer` |
| `AZURE_STORAGE_FOLDER` | `-StorageFolder` |
| `SWAT_BOARD_PORT` | `8080` |
| `MONITOR_INTERVAL_MINUTES` | from `.env`, only if set (the app default is 15) |
| `TEAMS_VERIFY_SSL`, `EMAIL_TO`, `EMAIL_CC`, `EMAIL_BCC`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_STARTTLS`, `SMTP_USER`, `SMTP_FROM` | from `.env`, only if set |
| `TEAMS_WEBHOOK_URLS` | `secretref:teams-webhook`, only if set |
| `SMTP_PASSWORD` | `secretref:smtp-password`, only if set |
| `SWAT_BOARD_PUBLIC_URL` | `https://<app address>`, set in step 12 |

**Changes:** none yet. The values are only collected.

### 11. Creates or updates the app
- **If the app does not exist**, creates it with:
  - image `acrp1apimon<suffix>.azurecr.io/p1-api-monitor:<timestamp>`
  - registry login with the `acr-password` secret
  - external ingress, target port `8080`, transport `auto`
  - **1 replica minimum and 1 maximum** (the monitor must run all the time, and two copies would send duplicate alerts)
  - 0.25 vCPU and 0.5 GiB memory
  - the secrets and environment variables above
- **If the app exists**, updates it:
  - sets the secrets again (`az containerapp secret set`)
  - sets the new image and 1 replica minimum and maximum
  - sets the environment variables (existing variables not in this list are kept)

**Changes in Azure:** a new Container App, or a new revision of the existing one.

### 12. Sets the public SWAT board address
- Reads the app's public address (`properties.configuration.ingress.fqdn`).
- Sets `SWAT_BOARD_PUBLIC_URL=https://<address>` so the **Open SWAT board** button in Teams links to the public address (no port number; Container Apps serves HTTPS on 443).

**Changes in Azure:** one more environment variable, which creates another revision.

### 13. Access restriction (optional)
- If `-AllowedIpRange` is given, adds an ingress rule named `allowed-network` that allows only that range.
- If it is not given, prints a warning that anyone with the address can open the SWAT board.

**Changes in Azure:** an ingress access rule, only when `-AllowedIpRange` is set.
**Note:** re-running without `-AllowedIpRange` does **not** remove a rule that is already there. Remove it in the portal or with `az containerapp ingress access-restriction remove` if needed.

### 14. Checks the app
- Waits 30 seconds, then calls `https://<address>/api/incidents`.
- If it answers, prints the number of incidents.
- If not, prints a warning and the log command. The app can take a minute or two to start, and the check can fail if `-AllowedIpRange` blocks your network.

**Changes:** none.

### 15. Prints the result
- The SWAT board address.
- The command to follow the logs.

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
| Container App | Yes | Yes (new image, settings, secrets) |
| Ingress access rule | Only with `-AllowedIpRange` | Only with `-AllowedIpRange` |

**On your PC:**
- Docker images built and tagged.
- Docker login saved in `%USERPROFILE%\.docker\config.json`.
- Azure CLI sign-in token kept by `az`.

**Not changed:**
- `.env` is only read, never written.
- No files in the repository are changed.
- No Azure resources are deleted.

---

## Security notes

- **Secrets are not printed.** The script never writes secret values to the console. It does pass them as command-line arguments to `az` and `docker`, so they are briefly visible to other processes on your PC.
- **The registry admin user is on.** This keeps the setup simple. Turn it off and use a managed identity if your security team requires it.
- **The SWAT board has no login.** Use `-AllowedIpRange`, or put the app behind an authenticated front end.
- **Keep `.env` private.** It holds the OAuth client secret and the storage connection string.

---

## Troubleshooting

| Message | What to do |
|---|---|
| `Azure CLI (az) is not installed` | Install the Azure CLI and open a new PowerShell window |
| `Docker is not running` | Start Docker Desktop and wait until it says it is running |
| `No .env file` | Copy `.env.example` to `.env` and fill it in |
| `SN_INSTANCE is empty in .env` (or the other required names) | Fill in the value in `.env` |
| `Azure CLI failed: az ...` | Read the error printed above it. Common causes: name already taken (use another `-Suffix`), or no permission to create resources |
| `docker login ... failed` | Check that the registry was created and try again |
| `The app did not answer yet` | Wait a minute and run the log command shown at the end |
| Board opens for anyone | Re-run with `-AllowedIpRange`, or remove the rule later |

To follow the logs:

```bash
az containerapp logs show --name p1-api-monitor --resource-group rg-p1-api-monitor --follow
```

---

## Remove everything

This deletes the resource group and **all** resources in it, including the storage account and its data. It cannot be undone.

```bash
az group delete --name rg-p1-api-monitor --yes --no-wait
```
