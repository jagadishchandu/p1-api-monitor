# Deploy the P1 API Monitor and SWAT Board to an existing AKS cluster

This plan deploys the P1 API monitor to an **existing** Azure Kubernetes Service (AKS) cluster and exposes the **SWAT board** (port 8080) through a Kubernetes Service.

It uses the managed-identity design from [README.md](README.md) section 6. There is **no storage key and no connection string**. The pod signs in to Azure Storage with **Microsoft Entra Workload Identity**, and the image is pulled from Azure Container Registry (ACR) with the cluster's own identity.

---

## 1. What gets deployed

| Object | Name (default) | Purpose |
|---|---|---|
| Namespace | `p1-api-monitor` | Keeps everything in one place |
| ServiceAccount | `p1-api-monitor-sa` | Linked to the managed identity, so the pod gets an Azure identity |
| Managed identity | `p1-api-monitor-id` | Has **Storage Blob Data Contributor** on the storage account |
| ConfigMap | `p1-monitor-config` | Non-secret settings from `.env` |
| Secret | `p1-monitor-secrets` | `SN_CLIENT_SECRET`, Teams webhook URLs, SMTP password |
| Deployment | `p1-api-monitor` | Runs the monitor, **one replica only** |
| Service | `p1-api-monitor-board` | Exposes the SWAT board (port 80 to container port 8080) |

**Why one replica:** the monitor is the only writer of `incidents.json`, and two copies would send duplicate alerts. The Deployment uses the `Recreate` strategy so a rollout never runs two copies at once.

### Architecture

```
ServiceNow REST API <── monitor pod (AKS, namespace p1-api-monitor)
                          │  Workload Identity (no key)
                          ▼
                 Azure Storage account (blob container p1-api-monitor)
                          ▲
                          │  role: Storage Blob Data Contributor
                 managed identity p1-api-monitor-id

SWAT users ──> Service p1-api-monitor-board (LoadBalancer, restricted IP range) ──> pod :8080
Monitor ──> Teams (Power Automate webhook) and SMTP email
```

---

## 2. Inputs to collect first

| Input | Example | Where to get it |
|---|---|---|
| Subscription | `<subscription-id>` | `az account show` |
| AKS resource group and cluster | `rg-aks`, `aks-prod` | Your AKS owner |
| ACR name | `acrp1apimonjc01` | `az acr list -o table` |
| Storage account and URL | `stp1apimonjc01`, `https://stp1apimonjc01.blob.core.windows.net` | Created by `deploy-azure.ps1`, or your storage admin |
| Storage container and folder | `p1-api-monitor`, `p1-api-monitor` | Same as `.env` |
| ServiceNow instance, client ID, client secret | `acmecorp`, ... | Your ServiceNow admin |
| Teams webhook URL and email settings | | Your Teams and SMTP owners |
| Allowed IP range for the board | `203.0.113.0/24` | Your network team (SWAT users' egress IPs or VPN range) |

Check that you have these permissions:
- On the AKS cluster: **Azure Kubernetes Service Cluster User Role** (to download credentials) and rights to run `az aks update`
- On the resource group: **Contributor** (to create the managed identity and federated credential)
- On the storage account: **Owner**, or **User Access Administrator** plus **Contributor**, to assign the role

---

## 3. Phase 1: Prepare the cluster

Set variables once. Use them in every command below.

```bash
RG=rg-aks
AKS=aks-prod
ACR=acrp1apimonjc01
STG=stp1apimonjc01
STG_RG=rg-p1-api-monitor0
NS=p1-api-monitor
APP_ID_NAME=p1-api-monitor-id
```

### 3.1 Confirm the cluster is healthy

```bash
az aks show -g $RG -n $AKS --query "{state:provisioningState, k8s:kubernetesVersion, power:powerState.code}" -o table
az aks get-credentials -g $RG -n $AKS --overwrite-existing
kubectl get nodes
```

Expected: `provisioningState` is `Succeeded`, `power` is `Running`, and every node is `Ready`.

### 3.2 Let the cluster pull images from ACR without a password

```bash
az aks update -g $RG -n $AKS --attach-acr $ACR
```

This gives the cluster's kubelet identity the **AcrPull** role on the registry. No registry username or password is needed in the cluster. (The Container Apps design still uses the ACR admin user; this plan doesn't.)

### 3.3 Turn on OIDC issuer and Workload Identity

```bash
az aks update -g $RG -n $AKS --enable-oidc-issuer --enable-workload-identity
ISSUER=$(az aks show -g $RG -n $AKS --query "oidcIssuerProfile.issuerUrl" -o tsv)
echo $ISSUER
```

Keep the issuer URL. You need it in step 4.3. Turning these on can take several minutes. It doesn't restart existing workloads.

### 3.4 Check the cluster has enough room

The manifest requests 100m CPU and 256Mi memory, and limits memory to 512Mi. Check that your nodes have room for that:

```bash
kubectl top nodes
```

If `kubectl top` says the metrics server is missing, skip this check. It doesn't block the deployment.

---

## 4. Phase 2: Prepare Azure resources

### 4.1 Build and push the image to ACR

Run from the project folder, which contains the `Dockerfile`. Use a version tag, not `latest`, so rollbacks are easy.

```bash
TAG=2026.10.20-1
az acr build --registry $ACR --image p1-api-monitor:$TAG .
az acr repository show-tags --name $ACR --repository p1-api-monitor -o table
```

Confirm that `$TAG` is in the list.

### 4.2 Make sure the storage account has the right settings

Use the storage account from `deploy-azure.ps1`. It should have:
- Public blob access **disabled**
- Shared key access **disabled** (the script sets this on new accounts)
- A **firewall** that allows the AKS cluster. If the account allows only selected networks, add the AKS virtual network subnet or use a private endpoint.

```bash
az storage account show -g $STG_RG -n $STG --query "{publicBlob:allowBlobPublicAccess, sharedKey:allowSharedKeyAccess, netDefault:networkRuleSet.defaultAction}" -o table
```

If `sharedKey` is `true`, turn it off after confirming no other application uses the key:

```bash
az storage account update -g $STG_RG -n $STG --allow-shared-key-access false
```

### 4.3 Create the managed identity and link it to the Kubernetes ServiceAccount

```bash
az identity create -g $RG -n $APP_ID_NAME -o json
CLIENT_ID=$(az identity show -g $RG -n $APP_ID_NAME --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -g $RG -n $APP_ID_NAME --query principalId -o tsv)
IDENTITY_ID=$(az identity show -g $RG -n $APP_ID_NAME --query id -o tsv)
```

Give the identity access to the blobs:

```bash
STG_ID=$(az storage account show -g $STG_RG -n $STG --query id -o tsv)
az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" --scope $STG_ID
```

Create the federated credential. It trusts tokens from this cluster's ServiceAccount:

```bash
az identity federated-credential create --name p1-api-monitor-fc \
  --identity-name $APP_ID_NAME --resource-group $RG \
  --issuer $ISSUER \
  --subject system:serviceaccount:$NS:p1-api-monitor-sa \
  --audience api://AzureADTokenExchange
```

The `--subject` must match the namespace and ServiceAccount name in the manifests exactly. A typo here means the pod can't sign in.

Keep `$CLIENT_ID`. You need it for the ServiceAccount annotation.

---

## 5. Phase 3: Kubernetes manifests

Create a folder `k8s` in the project and save the files below. Replace every value in `<angle brackets>`.

### 5.1 Namespace and ServiceAccount: `k8s/00-namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: p1-api-monitor
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: p1-api-monitor-sa
  namespace: p1-api-monitor
  annotations:
    azure.workload.identity/client-id: "<CLIENT_ID>"
```

### 5.2 Non-secret settings: `k8s/10-configmap.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: p1-monitor-config
  namespace: p1-api-monitor
data:
  SN_INSTANCE: "acmecorp"
  SN_CLIENT_ID: "<servicenow-oauth-client-id>"
  AZURE_STORAGE_ACCOUNT_URL: "https://<storage-account>.blob.core.windows.net"
  AZURE_STORAGE_CONTAINER: "p1-api-monitor"
  AZURE_STORAGE_FOLDER: "p1-api-monitor"
  MONITOR_INTERVAL_MINUTES: "15"
  SWAT_BOARD_ENABLED: "true"
  SWAT_BOARD_PORT: "8080"
  # Address the Teams links use to open the board. Set it after the Service has an IP (step 7).
  SWAT_BOARD_PUBLIC_URL: "http://<external-ip-or-dns>"
  TEAMS_VERIFY_SSL: "true"
  SMTP_HOST: "<smtp-host>"
  SMTP_PORT: "587"
  SMTP_STARTTLS: "true"
  SMTP_USER: "<smtp-user>"
  SMTP_FROM: "<sender-address>"
  EMAIL_TO: "<team-or-distribution-list>"
```

### 5.3 Secrets: `k8s/20-secret.yaml`

Don't commit real values. Create this from the command line instead, or encrypt it with your standard secret tool (for example Azure Key Vault with the Secrets Store CSI driver).

```bash
kubectl -n p1-api-monitor create secret generic p1-monitor-secrets \
  --from-literal=SN_CLIENT_SECRET='<servicenow-oauth-client-secret>' \
  --from-literal=TEAMS_WEBHOOK_URLS='<power-automate-webhook-url>' \
  --from-literal=SMTP_PASSWORD='<smtp-password>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

The `--dry-run | apply` pattern lets you run it again to rotate a value without deleting the secret.

### 5.4 Deployment: `k8s/30-deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: p1-api-monitor
  namespace: p1-api-monitor
  labels:
    app: p1-api-monitor
spec:
  replicas: 1                    # Keep at 1. Two copies would send duplicate alerts.
  strategy:
    type: Recreate               # Stop the old pod before starting the new one.
  selector:
    matchLabels:
      app: p1-api-monitor
  template:
    metadata:
      labels:
        app: p1-api-monitor
        azure.workload.identity/use: "true"   # Lets Workload Identity inject the token
    spec:
      serviceAccountName: p1-api-monitor-sa
      securityContext:
        # The Dockerfile sets USER app (a name, not a number). Kubernetes can't verify that a name is non-root,
        # so runAsNonRoot is left out. To enforce it, add runAsUser with the numeric UID of the app user
        # (check with: docker run --rm --entrypoint id <image>) and then set runAsNonRoot: true.
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: p1-api-monitor
          image: <ACR>.azurecr.io/p1-api-monitor:<TAG>
          imagePullPolicy: IfNotPresent
          ports:
            - name: board
              containerPort: 8080
          envFrom:
            - configMapRef:
                name: p1-monitor-config
            - secretRef:
                name: p1-monitor-secrets
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
          readinessProbe:
            tcpSocket:
              port: board
            initialDelaySeconds: 10
            periodSeconds: 15
          livenessProbe:
            tcpSocket:
              port: board
            initialDelaySeconds: 60
            periodSeconds: 30
            failureThreshold: 4
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            readOnlyRootFilesystem: false   # The app writes temporary files
```

### 5.5 Service: `k8s/40-service.yaml`

This is the step that exposes the SWAT board. The first version is an **internal** load balancer, reachable only from your private network. That is the safest choice for a board with no login.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: p1-api-monitor-board
  namespace: p1-api-monitor
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    # Optional: use a specific subnet for the internal IP
    # service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "<subnet-name>"
spec:
  type: LoadBalancer
  selector:
    app: p1-api-monitor
  ports:
    - name: http
      port: 80
      targetPort: board
  loadBalancerSourceRanges:
    - "<allowed-cidr-e.g.-10.20.0.0/16>"
```

`loadBalancerSourceRanges` is required. It limits the Service to the CIDR ranges you list. Without it, anyone who can reach the load balancer can open the board.

### 5.6 Optional: public exposure with a restricted range

If SWAT users are outside your private network, change the annotation block:

```yaml
  annotations: {}    # remove the internal annotation to get a public IP
```

Keep `loadBalancerSourceRanges` set to the corporate egress IPs or VPN range. Don't use `0.0.0.0/0` for a board with no login.

### 5.7 Optional: HTTPS with an Ingress

For a browser-friendly URL with TLS, put an ingress controller (for example NGINX ingress or Application Gateway for Containers) in front of the Service, with a certificate from your certificate store or cert-manager. Use one Ingress rule that points at `p1-api-monitor-board` on port 80. Apply the same IP restrictions in the ingress annotations. This step is optional and depends on the controller your cluster already runs.

---

## 6. Phase 4: Deploy

Replace the placeholders, then apply in this order:

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/10-configmap.yaml
# Create the secret with the command in section 5.3
kubectl apply -f k8s/30-deployment.yaml
kubectl apply -f k8s/40-service.yaml
```

Watch the rollout:

```bash
kubectl -n p1-api-monitor rollout status deployment/p1-api-monitor
kubectl -n p1-api-monitor get pods -o wide
```

---

## 7. Phase 5: Verify and expose

### 7.1 Check the pod logs

```bash
kubectl -n p1-api-monitor logs deploy/p1-api-monitor --tail=100
```

Look for:
- `Created storage container` or no error about the container. Either means storage access works.
- No `AuthorizationPermissionMismatch` and no `DefaultAzureCredential failed` messages.
- The monitor's first poll of ServiceNow completing without an authentication error.

### 7.2 Test the board before it's exposed

Use port forwarding first. This works even before the load balancer has an IP:

```bash
kubectl -n p1-api-monitor port-forward svc/p1-api-monitor-board 8080:80
```

Open `http://localhost:8080` in a browser, and check that the page loads and shows incidents.

### 7.3 Get the address and update the Teams link

```bash
kubectl -n p1-api-monitor get svc p1-api-monitor-board -w
```

When `EXTERNAL-IP` appears, set `SWAT_BOARD_PUBLIC_URL` in `k8s/10-configmap.yaml` to `http://<EXTERNAL-IP>` (or the HTTPS URL if you added an ingress), apply the ConfigMap again, and restart:

```bash
kubectl apply -f k8s/10-configmap.yaml
kubectl -n p1-api-monitor rollout restart deployment/p1-api-monitor
```

### 7.4 Test from an allowed network

From a machine inside the allowed range, open the address. From a machine outside it, the connection should fail. Test both.

---

## 8. Operations

| Task | Command or action |
|---|---|
| View logs | `kubectl -n p1-api-monitor logs deploy/p1-api-monitor -f` |
| Restart the monitor | `kubectl -n p1-api-monitor rollout restart deployment/p1-api-monitor` |
| Upgrade the image | Build a new tag (step 4.1), change `image:` in `30-deployment.yaml`, apply, then check `rollout status` |
| Roll back | `kubectl -n p1-api-monitor rollout undo deployment/p1-api-monitor`, or set the previous tag and apply |
| Rotate the ServiceNow secret | Run the `create secret` command from 5.3 with the new value, then restart |
| Change the allowed range | Edit `loadBalancerSourceRanges` in `40-service.yaml` and apply |
| Scale | Don't. Keep `replicas: 1` |

---

## 9. Security checklist

- [ ] The board is reachable only from the allowed range (`loadBalancerSourceRanges` set, and not `0.0.0.0/0`).
- [ ] The storage account has shared key access disabled, and the pod has no storage key in any secret or ConfigMap.
- [ ] The managed identity has **Storage Blob Data Contributor** on the storage account only, not a broader role.
- [ ] The ServiceAccount, federated credential subject and namespace match exactly (`system:serviceaccount:p1-api-monitor:p1-api-monitor-sa`).
- [ ] The ACR pull uses the cluster identity (`--attach-acr`), not a registry password.
- [ ] Secrets are created from the command line or a secret manager, not committed to git.
- [ ] The container runs as non-root, with privilege escalation off and all capabilities dropped.
- [ ] Network policy or NSG rules allow outbound traffic from the cluster to ServiceNow, Teams, SMTP and the storage account only.

---

## 10. Monitoring the monitor

The monitor is one pod, so the risk is that it stops and nobody notices. Set up:
- **Container Insights** on the cluster, with an alert when the pod restarts more than a few times in 15 minutes.
- An alert if the pod is not `Running` for more than 10 minutes.
- Check the Storage container for a fresh `incidents.json` timestamp once a day.

---

## 11. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Pod stuck in `ImagePullBackOff` | Cluster not attached to ACR, or wrong tag | Run step 3.2, check the tag in `30-deployment.yaml` |
| Pod in `CrashLoopBackOff`, log says `missing required environment variable(s)` | A required ConfigMap or Secret key is missing | Check `SN_INSTANCE`, `SN_CLIENT_ID`, `AZURE_STORAGE_ACCOUNT_URL`, and the `SN_CLIENT_SECRET` secret |
| Log says `DefaultAzureCredential failed to retrieve a token` | No federated credential, wrong subject, or missing `azure.workload.identity/use` label | Check the label, ServiceAccount annotation, and the federated credential subject from step 4.3 |
| Log says `AuthorizationPermissionMismatch` | Identity lacks **Storage Blob Data Contributor** | Check the role assignment (step 4.3) and wait a few minutes after assigning |
| Storage errors about network or firewall | Storage firewall blocks the AKS subnet | Add the subnet or a private endpoint (step 4.2) |
| Board not reachable from allowed network | `EXTERNAL-IP` pending, or the range doesn't include your IP | Check `kubectl get svc`, then check the CIDR in `loadBalancerSourceRanges` |
| Teams links point to the wrong address | `SWAT_BOARD_PUBLIC_URL` not updated | Step 7.3 |
| Two alert copies | More than one replica running | Set `replicas: 1` and check for a leftover pod from another deployment |

---

## 12. Rollback

1. Find the last good tag: `az acr repository show-tags --name $ACR --repository p1-api-monitor -o table`.
2. Set `image:` in `30-deployment.yaml` to that tag, and apply.
3. Or run `kubectl -n p1-api-monitor rollout undo deployment/p1-api-monitor`.

The ConfigMap and Secret stay unchanged during a rollback. The monitor's state is in Blob storage, so a restart doesn't lose incidents.

---

## 13. Cleanup (only if you are removing the deployment)

```bash
kubectl delete namespace p1-api-monitor
az identity delete -g $RG -n $APP_ID_NAME
```

Deleting the namespace doesn't delete the storage account. Its data is kept.
