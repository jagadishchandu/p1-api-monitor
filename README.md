# P1 API Monitor

Watches ServiceNow incidents through the **ServiceNow REST Table API** and:

- sends a **Teams** card and/or an **email** when a new incident appears, when its priority changes, or when an In Progress incident moves to **On Hold** or **Resolved**
- keeps a **SWAT board** (port **8080**) where SWAT teams mark which teams are Required, who joined, and fill in the intake form. The board can filter **In Progress**, **On Hold** and **Resolved** incidents, so intake forms can be created for resolved incidents too
- checks ServiceNow every **15 minutes** by default (`MONITOR_INTERVAL_MINUTES`)
- runs in **Docker**
- keeps its data (incidents, SWAT choices and notes) in an **Azure Storage** container, not on the local disk. Give it the connection string and it **creates the container and folders by itself** on first start

This replaces the older Selenium version (`P1-ui-monitor`). There is no browser, no Okta login and no MFA prompt, so it can run unattended on a server.

---

## Contents

1. [What you need before you start](#1-what-you-need-before-you-start)
2. [Create the ServiceNow OAuth application](#2-create-the-servicenow-oauth-application)
3. [Check the OAuth login and API access](#3-check-the-oauth-login-and-api-access)
4. [Get a Teams webhook (optional)](#4-get-a-teams-webhook-optional)
5. [Get SMTP details for email (optional)](#5-get-smtp-details-for-email-optional)
6. [Create your .env file](#6-create-your-env-file)
7. [Build and run with Docker](#7-build-and-run-with-docker)
8. [Open the SWAT board](#8-open-the-swat-board)
9. [Test it](#9-test-it)
10. [How it behaves](#10-how-it-behaves)
11. [Settings reference](#11-settings-reference)
12. [Troubleshooting](#12-troubleshooting)
13. [Security notes](#13-security-notes)
14. [Deploy to Azure Container Apps (free tier)](#14-deploy-to-azure-container-apps-free-tier)

---

## 1. What you need before you start

| Item | What it is | Who provides it |
|---|---|---|
| ServiceNow instance name | The part before `.service-now.com`, e.g. `acmecorp` for `https://acmecorp.service-now.com` | You already know it |
| ServiceNow OAuth application | A Client ID and Client Secret for an OAuth application that runs as a read-only service account with access to the **incident** table | ServiceNow admin (see [section 2](#2-create-the-servicenow-oauth-application)) |
| Azure Storage account | A storage account with one blob container. Its connection string goes in `.env` (see [section 6](#azure-storage-connection-string)) | Your Azure admin, or you |
| Docker Desktop (Windows/Mac) or Docker Engine (Linux) | Runs the container | Install from docker.com |
| Network access | The machine running Docker must reach `https://<instance>.service-now.com` and `<storage-account>.blob.core.windows.net` (port 443), and `hooks.powerautomate.com` / your SMTP server if you use those alerts | Your IT / firewall team |
| Teams webhook URL(s) (optional) | Power Automate "When a HTTP request is received" flow URL. Needed for Teams cards | Whoever owns the Teams channel flow |
| SMTP server and account (optional) | Needed only for email alerts | Your mail team |
| Port 8080 free on the host | SWAT board is served here | Your machine |

You do **not** need Python, Chrome or Selenium on the machine. Docker runs everything.

---

## 2. Create the ServiceNow OAuth application

The monitor logs in with **OAuth 2.0 client credentials** only. It does not use a user name and password. ServiceNow gives a short-lived bearer token, and the monitor refreshes it automatically.

Ask your ServiceNow admin to do the two steps below.

**Step 1: the service account** (the user the OAuth application runs as)

| Field | Value |
|---|---|
| User ID | e.g. `svc_p1_api_monitor` |
| Web service access only | **Tick this.** The account is used only by the API, so it doesn't need UI login |
| Active | Yes |
| Email | A shared mailbox or team address, so ServiceNow has a contact for the account |

Its roles: **read** access to the `incident` table (usually the `itil` role, or a read ACL on `incident`). It does **not** need write or admin rights.

**Step 2: the OAuth application**

1. Go to **System OAuth > Application Registry > New** and choose **Create an OAuth API endpoint for external clients**.
2. Give it a name, such as `P1 API Monitor`. Keep it **Active**.
3. Turn on the **client credentials** grant. Set the **user it runs as** to the service account from step 1, so the token has the same read access.
4. Save, then copy the **Client ID** and **Client Secret**.
5. Put them in `.env` as `SN_CLIENT_ID` and `SN_CLIENT_SECRET`.

If the client secret is rotated or expires, the monitor fails with HTTP 401 until you update `.env`.

If your ServiceNow release can't create client credentials, the monitor can't run on it. Ask the admin to check the release.

---

## 3. Check the OAuth login and API access

Before running Docker, check the credentials work. Replace the placeholders.

In **Git Bash, macOS or Linux terminal**, get a token, then read three incidents:

```bash
TOKEN=$(curl -s -X POST "https://yourinstance.service-now.com/oauth_token.do" \
  -d "grant_type=client_credentials&client_id=YOUR_CLIENT_ID&client_secret=YOUR_CLIENT_SECRET" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
```

```bash
curl "https://yourinstance.service-now.com/api/now/table/incident?sysparm_limit=3&sysparm_fields=number,state,priority" \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/json"
```

In **Windows PowerShell**:

```powershell
$tok = (Invoke-RestMethod -Method Post -Uri "https://yourinstance.service-now.com/oauth_token.do" -Body @{grant_type="client_credentials"; client_id="YOUR_CLIENT_ID"; client_secret="YOUR_CLIENT_SECRET"}).access_token
```

```powershell
Invoke-RestMethod -Uri "https://yourinstance.service-now.com/api/now/table/incident?sysparm_limit=3&sysparm_fields=number,state,priority" -Headers @{Authorization="Bearer $tok"; Accept="application/json"}
```

What you should see:

- **A result list** with three incidents. Good.
- **HTTP 401**: wrong Client ID or secret, the OAuth application is inactive, or it doesn't run as the service account.
- **HTTP 403**: the service account can't read the incident table. Ask the admin to check its roles.
- **HTTP 404**: the instance name is wrong.

---

## 4. Get a Teams webhook (optional)

The monitor posts to a **Power Automate** flow. The flow must accept the Adaptive Card as the request body and post it to the channel.

1. In Teams or Power Automate, create (or reuse) a flow that starts with **When a HTTP request is received**.
2. Copy the **HTTP POST URL**. It contains a secret signature, so treat it like a password.
3. Put it in `TEAMS_WEBHOOK_URLS` in `.env`. You can add several, separated by commas.

If there is no webhook, incidents are still tracked and the SWAT board still works. Only the Teams alerts are skipped.

---

## 5. Get SMTP details for email (optional)

Email uses standard SMTP, so the Docker container does not need Outlook. Ask your mail team for:

- SMTP host (e.g. `smtp.yourcompany.com`)
- Port (usually `587` with STARTTLS, or `25` internal relay)
- Whether it needs a login. If yes: an account user name and password
- A "from" address that the server allows

Put these in `.env`. If you leave `EMAIL_TO` empty, email is turned off.

---

## 6. Create your .env file

The `.env` file holds every setting. It is read when the container starts. The image itself has no secrets.

1. Copy the template:

   ```bash
   cp .env.example .env
   ```

   On Windows PowerShell:

   ```powershell
   copy .env.example .env
   ```

2. Edit `.env` and fill in at least:

   ```bash
   SN_INSTANCE=acmecorp
   SN_CLIENT_ID=your-oauth-client-id
   SN_CLIENT_SECRET=your-oauth-client-secret
   AZURE_STORAGE_CONNECTION_STRING=DefaultEndpointsProtocol=https;AccountName=...;AccountKey=...;EndpointSuffix=core.windows.net
   ```

3. Optional: `TEAMS_WEBHOOK_URLS`, the `EMAIL_*` and `SMTP_*` settings, `MONITOR_INTERVAL_MINUTES`, and `SWAT_BOARD_PUBLIC_URL`.

   The Azure settings are required too. See the next subsection.

**Rules for `.env`**

- No quotes are needed around values. Don't put spaces around `=`.
- Lines starting with `#` are comments.
- Never commit `.env` to git. It is already in `.gitignore` and `.dockerignore`.

### Azure Storage connection string

The monitor keeps `incidents.json`, `swat_status.json` and `swat_details/` as blobs in one **container** of an **Azure Storage account**, inside a **folder** you choose. Set these in `.env`:

| Setting | Meaning |
|---|---|
| `AZURE_STORAGE_CONNECTION_STRING` | Connection string of the storage account (required). It contains the account key, so treat it like a password |
| `AZURE_STORAGE_CONTAINER` | The blob container. Created automatically if it is missing. Default `p1-api-monitor` |
| `AZURE_STORAGE_FOLDER` | The folder inside the container. Default `p1-api-monitor`. Use a different folder for test and production |

To get the connection string, in the Azure portal open the storage account, then **Security + networking > Access keys > Connection string**. Or use the Azure CLI:

```bash
az storage account show-connection-string --name <storage-account> --resource-group <resource-group> --query connectionString -o tsv
```

**Automatic setup (new):** you don't need to create the container or the folders. When the monitor starts with a valid connection string, it does this for you:

| Created if missing | Name in Azure Storage | Notes |
|---|---|---|
| Container | `AZURE_STORAGE_CONTAINER` | Logs `Created storage container '...'` the first time |
| Data folder | `<AZURE_STORAGE_FOLDER>/` | Holds `incidents.json` and `swat_status.json` |
| Notes folder | `<AZURE_STORAGE_FOLDER>/swat_details/` | Holds one file per incident |

Blob storage has no real folders, so each folder is created as an empty placeholder blob named `.folder`. It shows up in Azure Storage Explorer and is harmless. Restarting the monitor doesn't duplicate anything.

The connection string needs permission to create containers, which the account key has. If you prefer to create the container yourself, use:

```bash
az storage container create --name p1-api-monitor --connection-string "<connection-string>"
```

**Security:** keep the connection string in `.env` on the server only. In Azure Container Apps, store it as a secret (section 14). For a test on your own PC you can use Azurite, Azure's local storage emulator, with `AZURE_STORAGE_CONNECTION_STRING=UseDevelopmentStorage=true`.

---

## 7. Build and run with Docker

From the `P1-api-monitor` folder:

```bash
docker compose up -d --build
```

This builds the image, starts the container in the background, and maps **host port 8080 to container port 8080**.

**Useful commands**

```bash
docker compose logs -f
```

Shows the live log. You should see a line like `Checking ServiceNow every 15 minute(s)` and then `In Progress incidents found: N`.

```bash
docker compose restart
```

Restarts the monitor after you change `.env`. (For a change to `.env` to take effect, use `docker compose up -d` instead, which recreates the container.)

```bash
docker compose down
```

Stops and removes the container. The data stays in Azure Storage.

**Run a single check without starting the loop**

```bash
docker compose run --rm p1-api-monitor python monitor.py --check-once
```

**Build the image without starting it**

```bash
docker build --build-arg SWAT_BOARD_PUBLIC_URL=http://swat-server.company.com:8080 -t p1-api-monitor:latest .
```

Note: `docker build` does not read `.env`. The settings are passed when the container runs (`docker compose up` or `docker run --env-file .env`). This keeps passwords out of the image.

**Run without compose**

```bash
docker run -d --name p1-api-monitor --env-file .env -p 8080:8080 p1-api-monitor:latest
```

### Where the data is kept

| What | Blob name in Azure Storage |
|---|---|
| `incidents.json` (the tracked incidents) | `<AZURE_STORAGE_FOLDER>/incidents.json` |
| `swat_status.json` (team choices and joined people) | `<AZURE_STORAGE_FOLDER>/swat_status.json` |
| `swat_details/` (notes and intake answers, one file per incident) | `<AZURE_STORAGE_FOLDER>/swat_details/<INC number>.json` |

These blobs and folders are created automatically on first start (see section 6). Everyone who uses the board shares this data, so no shared drive is needed. The container keeps nothing locally, so you can rebuild, move or restart it without losing data.

To copy an existing `incidents.json` from the old Selenium monitor, upload it to the folder. The format is the same. For example:

```bash
az storage blob upload --container-name p1-api-monitor --name p1-api-monitor/incidents.json --file incidents.json --connection-string "<connection-string>" --overwrite
```The format is the same.

---

## 8. Open the SWAT board

- On the host machine: `http://localhost:8080`
- From other computers: `http://<host-name-or-ip>:8080`. The machine's firewall must allow port 8080.

Set `SWAT_BOARD_PUBLIC_URL` to the address other people use, for example `http://swat-server.company.com:8080`. The Teams card's **Open SWAT board** button uses this address.

The image has a default built in: `http://localhost:8080`. It is set at build time, and the build is where you set the real address (see section 7). If `SWAT_BOARD_PUBLIC_URL` is empty in `.env`, the built-in default is used. Include the port in the address, because the button links to it directly.

**What the board shows**

- Filter buttons: **All**, **In Progress**, **On Hold**, **Resolved**, each with a count
- A state label on each card, with the time it changed
- For each team (Infra Ops, Container Ops, Network Ops): Required or Not required, and who joined
- An **Open details & notes** page for each incident, with the intake form and an Excel export

Anyone can change the choices, so users type their name in the box at the top before saving.

---

## 9. Test it

**1. Test the Teams and email alerts with a fake P1**

```bash
docker compose run --rm p1-api-monitor python monitor.py --test-notify
```

A red test card (`INC0000000`) should appear in each Teams channel, and a test email should be sent to the addresses in `EMAIL_TO`. The output says which channel accepted it.

**2. Test against live ServiceNow once**

```bash
docker compose run --rm p1-api-monitor python monitor.py --check-once
```

Check the output for the count of incidents found. Then open the SWAT board and check the filters.

**3. Check the Azure Storage setup**

Start the monitor once. On the first start, the log should show `Created storage container` (only if the container was missing). In the Azure portal or Storage Explorer, the container should contain `p1-api-monitor/.folder` and `p1-api-monitor/swat_details/.folder`, or the folder you set in `AZURE_STORAGE_FOLDER`. `incidents.json` appears after the first check.

**4. Check the board is reachable**

```bash
curl http://localhost:8080/api/incidents
```

You should get JSON with an `incidents` list.

---

## 10. How it behaves

**Every 15 minutes** (`MONITOR_INTERVAL_MINUTES`), the monitor asks ServiceNow for every incident in the states **In Progress**, **On Hold** and **Resolved**, and compares the result with `incidents.json`.

| What happened | What the monitor does |
|---|---|
| New incident is In Progress | Sends a **new incident** alert and stores it |
| Priority of a known In Progress incident changed | Sends a **priority changed** alert and updates the priority |
| In Progress incident is now **On Hold** | Sends an **update** alert ("moved to On Hold") and stores the state `On Hold` |
| In Progress incident is now **Resolved** | Sends an **update** alert ("moved to Resolved") and stores the state `Resolved` |
| On Hold or Resolved incident is back **In Progress** | Treated as **new** and alerted again, as before |
| Incident is now Closed, Canceled, or no longer in these states | Removed from `incidents.json` |

**Why On Hold and Resolved are kept:** SWAT teams often need an intake form for an incident that is already resolved. Those incidents stay on the board, under the Resolved filter, until ServiceNow no longer reports them in these states (for example, when they are Closed).

**Alerts are retried.** If Teams and email both fail for an alert, that alert is not recorded, so it is tried again on the next check.

**The first run** sends an alert for every In Progress incident it has never seen before. If you upload an existing `incidents.json` to the storage folder (section 6), only new changes are alerted.

---

## 11. Settings reference

All settings are environment variables in `.env`.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `SN_INSTANCE` | Yes | - | ServiceNow instance name (no `https://`, no `.service-now.com`) |
| `SN_CLIENT_ID` | Yes | - | OAuth application Client ID |
| `SN_CLIENT_SECRET` | Yes | - | OAuth application Client Secret |
| `TEAMS_WEBHOOK_URLS` | No | empty | Power Automate webhook URL(s), comma separated |
| `TEAMS_VERIFY_SSL` | No | `true` | Set `false` only if a corporate TLS proxy breaks the Teams call and the CA can't be installed |
| `EMAIL_TO` | No | empty | Email recipients, comma separated. Empty = no email |
| `EMAIL_CC` | No | empty | Copy recipients |
| `EMAIL_BCC` | No | empty | Hidden copy recipients |
| `SMTP_HOST` | If email | empty | SMTP server |
| `SMTP_PORT` | No | `587` | SMTP port |
| `SMTP_STARTTLS` | No | `true` | Use STARTTLS (usual for port 587) |
| `SMTP_USER` | No | empty | SMTP login. Leave empty for an unauthenticated internal relay |
| `SMTP_PASSWORD` | No | empty | SMTP password |
| `SMTP_FROM` | No | `SMTP_USER` | Sender address shown on emails |
| `MONITOR_INTERVAL_MINUTES` | No | `15` | Minutes between ServiceNow checks |
| `SWAT_BOARD_ENABLED` | No | `true` | Turn the SWAT board on or off |
| `SWAT_BOARD_PORT` | No | `8080` | Port the board listens on inside the container. Keep `8080` unless you change the port mapping too |
| `SWAT_BOARD_PUBLIC_URL` | No | built-in default `http://localhost:8080` | Address written on the Teams card's "Open SWAT board" button. Set the default at build time with `--build-arg SWAT_BOARD_PUBLIC_URL=...` |
| `AZURE_STORAGE_CONNECTION_STRING` | Yes | - | Azure Storage connection string. Contains the account key |
| `AZURE_STORAGE_CONTAINER` | No | `p1-api-monitor` | Blob container. Created automatically if missing |
| `AZURE_STORAGE_FOLDER` | No | `p1-api-monitor` | Folder inside the container for `incidents.json`, `swat_status.json` and `swat_details/` |

**Changing the port:** to use host port 9000 instead of 8080, change the compose mapping to `"9000:8080"`, and build with `SWAT_BOARD_PUBLIC_URL=http://<host>:9000` (or set it in `.env`).

---

## 12. Troubleshooting

| Symptom | What to check |
|---|---|
| `missing required environment variable(s): ...` | A required value (`SN_CLIENT_ID`, `SN_CLIENT_SECRET` or `AZURE_STORAGE_CONNECTION_STRING`) is missing from `.env`, or the name is misspelled. Run `docker compose config` to see what the container receives |
| `ServiceNow rejected the login (HTTP 401)` | Wrong Client ID or secret, OAuth application inactive, or it doesn't run as the service account. Test with the commands in [section 3](#3-check-the-oauth-login-and-api-access) |
| `ServiceNow refused access (HTTP 403)` | The account lacks read access to the incident table. Ask the admin for the `itil` role or a read ACL |
| `OAuth token request failed (HTTP 400/401)` | Client ID or secret is wrong, or the OAuth application is inactive. Test with the token command in section 3 |
| `could not create the storage container` or `not authorized` | The connection string's account key can't create containers. Use the account key connection string from the portal (section 6) |
| `AuthenticationFailed` or `Server failed to authenticate the request` | The storage connection string is wrong, or the account key was rotated. Copy the connection string again |
| `OAuth token response did not contain an access_token` | The token endpoint returned an error page. Check the instance name and that client credentials are enabled |
| `could not reach <instance>.service-now.com` | Docker host has no internet or proxy access, or the instance name is wrong. Try `curl` from the host |
| `SWAT board could not start on port 8080` | Another program uses port 8080. Stop it or change the port (see section 11) |
| Teams card shows but the **Open SWAT board** button doesn't work | The address is still the built-in `localhost` default. Set `SWAT_BOARD_PUBLIC_URL` in `.env` (or rebuild with `--build-arg`) to an address other people can reach |
| `Teams webhook rejected notification` | The webhook URL is wrong or the flow is off. Check the flow's run history in Power Automate |
| TLS / certificate error when posting to Teams | Your corporate proxy re-signs HTTPS. Install the company root CA into the image, or as a last resort set `TEAMS_VERIFY_SSL=false` |
| No alerts, but the log says `No new, priority-changed or state-changed incidents` | Working as designed: nothing changed since the last check |
| Email not sent | Check `SMTP_HOST`, port, and whether the server needs a login. Run `--test-notify` and read the warning |
| Nothing in the log at all | Run `docker compose logs -f`. If the container exited, the last lines show the error |

---

## 13. Security notes

- `.env` contains the OAuth client secret, the Azure Storage connection string (it includes the account key) and webhook secrets. Keep it on the server only. Don't email it or paste it in chat or tickets.
- Use a **read-only** service account. It should not have write or admin rights.
- The monitor uses **OAuth** only. The access token is kept in memory and is never written to disk. The client secret and the storage connection string are the long-lived secrets in `.env`.
- Rotate the OAuth client secret and the storage account key on the schedule your admin sets. After rotating, update `.env` (or the Container Apps secrets) and restart the monitor.
- The SWAT board has **no login**. Anyone who can reach port 8080 can change team choices and read notes. Limit access to the network, or put it behind your company's reverse proxy with authentication.
- The Teams webhook URL is a secret. Anyone with it can post to the channel.
- The container runs as a non-root user. It only needs outbound HTTPS to ServiceNow and to the Teams webhook, and optionally the SMTP server.

---

## 14. Deploy to Azure Container Apps (free tier)

This runs the same Docker image in **Azure Container Apps** instead of on your own machine. Use it if you don't have a server to run Docker on.

### What is free, and what is not

| Item | Cost |
|---|---|
| Container Apps **Consumption** plan | Has a monthly free grant of 180,000 vCPU-seconds, 360,000 GiB-seconds and 2 million requests per subscription |
| One app at 0.25 vCPU and 0.5 GiB, running 24/7 | About 648,000 vCPU-seconds and 1,296,000 GiB-seconds a month. **This is more than the free grant**, so expect a small bill. Check the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) for your region |
| Scale to zero | **Don't use it.** The monitor has to run its 15-minute loop all the time. Keep `minReplicas` at `1` |
| Azure Container Registry (ACR) Basic | Not free, about USD 5 a month. Covered by the free account credit while it lasts |
| Azure Blob Storage (the data) | A few cents a month for these small JSON files |
| Free account | A new Azure free account gives about USD 200 of credit for 30 days. Azure for Students gives credit without a card |

Keep **one** replica only (`minReplicas: 1`, `maxReplicas: 1`). Two copies would both write `incidents.json` and send duplicate alerts.

### Before you start

- An Azure subscription (free account or Azure for Students).
- **Azure CLI** installed. Check with `az --version`. In Windows, install it from [learn.microsoft.com/cli/azure/install-azure-cli](https://learn.microsoft.com/cli/azure/install-azure-cli).
- A `.env` file in the `P1-api-monitor` folder, as in [section 6](#6-create-your-env-file). You will copy its values into Azure. **Do not** upload `.env` to Azure or to git.

### Step 1: Sign in and set your variables

Run these in **Git Bash**, or in PowerShell with `$env:` instead of `export`. Change the values in capitals.

```bash
az login
```

```bash
az account set --subscription "YOUR-SUBSCRIPTION-NAME-OR-ID"
```

```bash
export RG="rg-p1-api-monitor"
export LOC="eastus"
export ACR="acrp1apimonYOURINITIALS"
export CAE="cae-p1-api-monitor"
export APP="p1-api-monitor"
export STG="stp1apimonYOURINITIALS"
```

`ACR` and `STG` must be **unique across Azure**, use only lowercase letters and numbers, Storage account names (`STG`) must be 3 to 24 characters, and registry names (`ACR`) 5 to 50 characters.

### Step 2: Install the Container Apps extension and register providers

```bash
az extension add --name containerapp --upgrade
```

```bash
az provider register --namespace Microsoft.App --wait
```

```bash
az provider register --namespace Microsoft.OperationalInsights --wait
```

### Step 3: Create the resource group and container registry

```bash
az group create --name $RG --location $LOC
```

```bash
az acr create --resource-group $RG --name $ACR --sku Basic --admin-enabled true
```

`--admin-enabled true` lets Container Apps pull the image with a user name and password. This is the quickest option. For a stricter setup, use a managed identity with the `AcrPull` role instead.

### Step 4: Build the image in Azure

Run this from inside the `P1-api-monitor` folder. Azure builds the image from the Dockerfile, so you don't need Docker on your machine. `.dockerignore` keeps `.env` out of the image.

```bash
az acr build --registry $ACR --image p1-api-monitor:latest .
```

### Step 5: Create the storage account and container

The monitor keeps its data in Blob Storage. Create a storage account, and the monitor creates the container and folders on first start. The connection string goes into the app secrets in step 7.

```bash
az storage account create --name $STG --resource-group $RG --location $LOC --sku Standard_LRS --kind StorageV2
```

```bash
export STG_CONN=$(az storage account show-connection-string --name $STG --resource-group $RG --query connectionString -o tsv)
```

```bash
az storage container create --name p1-api-monitor --connection-string "$STG_CONN"
```

The monitor also creates the container on first start, so this command is optional. Keep `$STG_CONN` for step 7. Don't paste it in chat or in tickets.

### Step 6: Create the Container Apps environment

```bash
az containerapp env create --name $CAE --resource-group $RG --location $LOC
```

### Step 7: Write the app definition

Create a file called `containerapp.yaml` **in a folder outside the git repo**, for example your Desktop. It holds secrets, so don't commit it. Replace every `<...>` value.

Get the registry password first:

```bash
export ACR_PASSWORD=$(az acr credential show --name $ACR --query "passwords[0].value" -o tsv)
```

```bash
export SUB_ID=$(az account show --query id -o tsv)
```

Then create the file:

```yaml
properties:
  managedEnvironmentId: /subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.App/managedEnvironments/<CAE>
  configuration:
    activeRevisionsMode: Single
    ingress:
      external: true
      targetPort: 8080
      transport: auto
      # Strongly recommended: allow only your office or VPN range, because the SWAT board has no login.
      # ipSecurityRestrictions:
      #   - name: office
      #     ipAddressRange: <your-office-ip-range-e.g.-203.0.113.0/24>
      #     action: Allow
    registries:
      - server: <ACR>.azurecr.io
        username: <ACR>
        passwordSecretRef: acr-password
    secrets:
      - name: acr-password
        value: <ACR_PASSWORD>
      - name: client-secret
        value: <SN_CLIENT_SECRET from your .env>
      - name: storage-connection-string
        value: <STG_CONN from step 5>
      - name: teams-webhook
        value: <TEAMS_WEBHOOK_URLS from your .env>
  template:
    containers:
      - name: p1-api-monitor
        image: <ACR>.azurecr.io/p1-api-monitor:latest
        env:
          - name: SN_INSTANCE
            value: <SN_INSTANCE from your .env>
          - name: SN_CLIENT_ID
            value: <SN_CLIENT_ID from your .env>
          - name: SN_CLIENT_SECRET
            secretRef: client-secret
          - name: AZURE_STORAGE_CONNECTION_STRING
            secretRef: storage-connection-string
          - name: AZURE_STORAGE_CONTAINER
            value: p1-api-monitor
          - name: AZURE_STORAGE_FOLDER
            value: p1-api-monitor
          - name: TEAMS_WEBHOOK_URLS
            secretRef: teams-webhook
          - name: SWAT_BOARD_PORT
            value: "8080"
          - name: MONITOR_INTERVAL_MINUTES
            value: "15"
        resources:
          cpu: 0.25
          memory: 0.5Gi
    scale:
      minReplicas: 1
      maxReplicas: 1

```

If you don't use Teams, delete the `teams-webhook` secret and the `TEAMS_WEBHOOK_URLS` env entry. Add any other settings from [section 11](#11-settings-reference) the same way, as `env` entries. Use `secretRef` for passwords, webhook URLs and SMTP passwords. Put `SN_CLIENT_SECRET` and `AZURE_STORAGE_CONNECTION_STRING` in `secrets` and reference them with `secretRef`. Never write them as plain values.

### Step 8: Deploy the app

```bash
az containerapp create --name $APP --resource-group $RG --environment $CAE --yaml containerapp.yaml
```

Get the public address:

```bash
export FQDN=$(az containerapp show --name $APP --resource-group $RG --query properties.configuration.ingress.fqdn -o tsv)
echo "https://$FQDN"
```

Tell the monitor its own public address, so the **Open SWAT board** button on Teams cards works:

```bash
az containerapp update --name $APP --resource-group $RG --set-env-vars SWAT_BOARD_PUBLIC_URL="https://$FQDN"
```

### Step 9: Check it works

Watch the logs. You should see `Checking ServiceNow every 15 minute(s)` and the count of incidents:

```bash
az containerapp logs show --name $APP --resource-group $RG --follow
```

Open `https://<FQDN>` in a browser for the SWAT board, or check the JSON:

```bash
curl "https://$FQDN/api/incidents"
```

If the log shows `ServiceNow rejected the login` or a similar error, fix the value in `containerapp.yaml`, run `az containerapp update --name $APP --resource-group $RG --yaml containerapp.yaml`, and check the logs again.

### Updating after code changes

After you change `monitor.py`, rebuild and restart:

```bash
az acr build --registry $ACR --image p1-api-monitor:latest .
```

```bash
az containerapp update --name $APP --resource-group $RG --image $ACR.azurecr.io/p1-api-monitor:latest
```

To change a setting, edit `containerapp.yaml` and run `az containerapp update --name $APP --resource-group $RG --yaml containerapp.yaml`. The monitor's state is kept in Azure Storage, so updates don't reset it.

### Stop or delete everything

To stop the monitor and avoid charges, delete the resource group. This deletes **everything** in it, including the data share:

```bash
az group delete --name $RG --yes --no-wait
```

### Azure troubleshooting

| Symptom | What to check |
|---|---|
| `containerapp.yaml` is rejected | YAML is indentation-sensitive. Use spaces, not tabs. `<...>` placeholders must all be replaced |
| The app shows **Failed** or keeps restarting | `az containerapp logs show --name $APP --resource-group $RG --tail 100`. Usually a wrong setting or secret |
| The monitor can't create the container | Check the `storage-connection-string` secret. The monitor creates the container and folders on first start |
| `AuthenticationFailed` | The `storage-connection-string` secret is wrong, or the storage key was rotated. Copy the connection string again |
| Image pull fails | Check that the ACR admin user is enabled and that the `registries` block uses the right password |
| The SWAT board opens for anyone | Turn on the `ipSecurityRestrictions` lines in `containerapp.yaml` and update the app |
| Costs are higher than expected | Check `minReplicas` is `1` (scale to zero stops the monitor), and check the region in the pricing calculator |

---

## Files in this folder

| File | Purpose |
|---|---|
| `monitor.py` | The whole application: ServiceNow API client, alert logic, Teams and email, SWAT board |
| `requirements.txt` | Python packages (`requests`, `urllib3`, `openpyxl`) |
| `Dockerfile` | Builds the container image |
| `docker-compose.yml` | Runs the container and maps port 8080 |
| `.env.example` | Template for your settings. Copy to `.env` |
| `.dockerignore` / `.gitignore` | Keep `.env` and data files out of the image and git |
