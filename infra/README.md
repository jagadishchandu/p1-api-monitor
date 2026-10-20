# infra: Terraform for the P1 API Monitor on an existing AKS cluster

This folder deploys the monitor and SWAT board into an **existing AKS cluster**. It creates:
- the storage account and container (no keys, no public blob access)
- the workload identity and its federated credential, which lets the ServiceAccount sign in to Azure without a secret
- the roles: Storage Blob Data Contributor for the identity, and AcrPull for the cluster to pull the image
- the Kubernetes namespace, ServiceAccount, ConfigMap (non-secret `.env` values), Secret (secret `.env` values), Deployment (one replica) and Service (the SWAT board)

It does **not** change the cluster. It reads it with a data source.

Every `.env` setting is a variable with the same name in lowercase. See `terraform.tfvars.example`.

## Architecture

```
ServiceNow <── monitor pod (AKS, namespace p1-api-monitor, 1 replica) ──> Teams / SMTP
                  │ Workload Identity: ServiceAccount -> federated credential -> managed identity (no key)
                  ├── AcrPull (kubelet identity) ────────> container registry (image)
                  └── Storage Blob Data Contributor ─────> storage account / container
SWAT users ──> Service LoadBalancer (internal by default, allowed ranges) ──> pod :8080
```

## Prerequisites

1. **Terraform 1.6 or newer**, and **kubelogin** (`az aks install-cli` installs `kubectl` and `kubelogin`).
2. **The cluster has OIDC issuer and Workload Identity enabled.** Check it, and enable it if needed:

   ```bash
   az aks show -g <aks-rg> -n <aks-name> --query "{oidc:oidcIssuerProfile.issuerUrl, wi:securityProfile.workloadIdentity.enabled}" -o table
   az aks update -g <aks-rg> -n <aks-name> --enable-oidc-issuer --enable-workload-identity
   ```

   The plan stops with a clear message if the OIDC issuer is missing.
3. **Your account** needs:
   - **Azure Kubernetes Service Cluster User Role** on the cluster, and **Azure Kubernetes Service RBAC Writer** (or Admin) on the namespace, or equivalent. Entra ID login must be allowed for kubelogin.
   - **Contributor** on the resource group and **Owner** (or User Access Administrator) to create the role assignments.
4. **The image is in the registry.** Build it from the project root:

   ```bash
   az acr build --registry <acr-name> --image p1-api-monitor:<tag> .
   ```

## Step 1: Set your values

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. Put the secrets in environment variables:

```bash
export TF_VAR_sn_client_secret="<servicenow-client-secret>"
export TF_VAR_teams_webhook_urls="<power-automate-url>"
export TF_VAR_smtp_password="<smtp-password>"
```

PowerShell: `$env:TF_VAR_sn_client_secret = "<servicenow-client-secret>"`

## Step 2: Deploy

```bash
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

Review the plan. Nothing is created until you approve the apply.

## Step 3: Get the board address and set the Teams link

```bash
terraform output board_url
```

The Service gets its IP after a few minutes. Run `terraform output board_url` again if it's empty. Then set `swat_board_public_url` in `terraform.tfvars` to that value and apply again.

## Step 4: Check the pod

```bash
kubectl -n p1-api-monitor get pods -o wide
kubectl -n p1-api-monitor logs deploy/p1-api-monitor --tail=100
```

Look for:
- No `AuthorizationPermissionMismatch`: the role isn't in place yet. Wait a few minutes and check again.
- No `DefaultAzureCredential failed`: the federated credential subject or the ServiceAccount annotation doesn't match. Check the `federated_subject` output against the ServiceAccount.
- The board answering from an allowed address: `curl http://<board_ip>/api/incidents`

## Changing a setting

Edit `terraform.tfvars` and run `terraform apply`. The ConfigMap and Secret update, and the Deployment restarts with the new values.

To update the image, change `container_image` and apply. The Deployment uses the `Recreate` strategy, so the old pod stops before the new one starts.

## Exposing the board

| Setting | Result |
|---|---|
| `board_internal = true` (default) | Internal load balancer, reachable from the VNet only. Recommended. |
| `board_internal = false` | Public load balancer. Always set `board_allowed_ip_ranges` too. |
| `board_allowed_ip_ranges = ["10.20.0.0/16"]` | Only these ranges can reach the load balancer. |

The board has no login, so an empty `board_allowed_ip_ranges` means anyone who can reach the address can use it.

For HTTPS or a host name, put an ingress in front of the Service (for example the NGINX ingress your cluster already runs). That step is outside this Terraform.

## Clashes with resources already deployed

If `deploy-azure.ps1` or the manual steps already created the namespace, storage account, or identity, Terraform will try to create them again. Either:
- import them into the state, then run `terraform plan` and check it shows no unexpected changes, or
- use new names (a new `name_suffix`, `kubernetes_namespace`, or `app_name`).

## Notes and limits

- **Single replica is fixed.** Two copies would send duplicate alerts.
- **The Kubernetes provider uses your Azure CLI sign-in** through kubelogin. A pipeline should use a service principal or workload identity for kubelogin instead.
- **Terraform state holds sensitive values.** Keep `terraform.tfstate` out of git, and use the remote backend in `versions.tf` for a team.
- **AcrPull:** if the cluster was already attached to the registry (`az aks update --attach-acr`), set `grant_acr_pull = false` to avoid a duplicate assignment.
- **`AZURE_STORAGE_CONNECTION_STRING` is not used.** Remove it from `.env`.
- **Not validated in this environment.** Terraform wasn't installed when these files were written. Run `terraform init` and `terraform validate` before the first plan.
- **Kubernetes provider version.** The `load_balancer_source_ranges` and workload identity settings depend on the provider version. Check the plan output if the provider reports unknown arguments.
