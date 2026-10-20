# One variable for every setting in .env.example, with the same name (in lowercase), so terraform.tfvars maps 1:1 to .env.
# Secrets are marked sensitive. Give their values as TF_VAR_<name> environment variables, not in a committed file.

# ---------------------------------------------------------------------------
# Existing AKS cluster
# ---------------------------------------------------------------------------

variable "aks_cluster_name" {
  description = "Name of the existing AKS cluster. It must have OIDC issuer and Workload Identity enabled (see infra/README.md)."
  type        = string
}

variable "aks_resource_group_name" {
  description = "Resource group of the existing AKS cluster."
  type        = string
}

variable "kubernetes_namespace" {
  description = "Namespace the app is deployed into. Also used in the federated credential subject."
  type        = string
  default     = "p1-api-monitor"
}

variable "app_name" {
  description = "Name of the Deployment, Service and labels."
  type        = string
  default     = "p1-api-monitor"
}

variable "container_image" {
  description = "Image to run, for example <acr>.azurecr.io/p1-api-monitor:2026.10.20-1. Push it to the registry before the apply."
  type        = string
}

# ---------------------------------------------------------------------------
# Existing container registry
# ---------------------------------------------------------------------------

variable "acr_name" {
  description = "Existing container registry that holds the image."
  type        = string
}

variable "acr_resource_group_name" {
  description = "Resource group of the existing container registry."
  type        = string
}

variable "grant_acr_pull" {
  description = "true = grant AcrPull on the registry to the AKS kubelet identity. Set to false if the cluster is already attached to this registry (az aks update --attach-acr)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Placement and naming for the resources this Terraform creates
# ---------------------------------------------------------------------------

variable "location" {
  description = "Azure region for the storage account and identity."
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Resource group for the storage account and the workload identity. Created if missing."
  type        = string
  default     = "rg-p1-api-monitor0"
}

variable "name_suffix" {
  description = "Short lowercase suffix for the globally unique storage account name. 3 to 12 letters and digits."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.name_suffix))
    error_message = "name_suffix must be 3 to 12 lowercase letters or digits."
  }
}

variable "storage_account_name" {
  description = "Storage account name, 3 to 24 lowercase letters and digits, globally unique. Empty = stp1apimon<name_suffix>."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags added to the resources this Terraform creates."
  type        = map(string)
  default = {
    application = "p1-api-monitor"
    managed_by  = "terraform"
  }
}

# Storage restrictions (optional). Empty = no network restriction.
variable "storage_allowed_ip_ranges" {
  description = "Public IP ranges allowed to reach the storage account."
  type        = list(string)
  default     = []
}

variable "storage_virtual_network_subnet_ids" {
  description = "Subnet IDs allowed to reach the storage account, for example the AKS node subnet. Empty = not used."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# .env settings (same names as .env.example)
# ---------------------------------------------------------------------------

# ServiceNow (REQUIRED)
variable "sn_instance" {
  description = "SN_INSTANCE: instance name only, for example acmecorp."
  type        = string
}

variable "sn_client_id" {
  description = "SN_CLIENT_ID: OAuth client ID from ServiceNow."
  type        = string
}

variable "sn_client_secret" {
  description = "SN_CLIENT_SECRET: OAuth client secret. Stored in a Kubernetes Secret."
  type        = string
  sensitive   = true
}

# Azure Storage
variable "azure_storage_container" {
  description = "AZURE_STORAGE_CONTAINER: blob container. Created by Terraform."
  type        = string
  default     = "p1-api-monitor"
}

variable "azure_storage_folder" {
  description = "AZURE_STORAGE_FOLDER: folder inside the container."
  type        = string
  default     = "p1-api-monitor"
}

# Teams alerts (OPTIONAL)
variable "teams_webhook_urls" {
  description = "TEAMS_WEBHOOK_URLS: Power Automate webhook URL(s), comma separated. Empty turns Teams off. Stored in a Kubernetes Secret."
  type        = string
  default     = ""
  sensitive   = true
}

variable "teams_verify_ssl" {
  description = "TEAMS_VERIFY_SSL: false only if a corporate TLS proxy breaks the Teams call."
  type        = string
  default     = "true"
}

# Email alerts over SMTP (OPTIONAL)
variable "email_to" {
  description = "EMAIL_TO: comma separated addresses. Empty turns email off."
  type        = string
  default     = ""
}

variable "email_cc" {
  description = "EMAIL_CC: comma separated addresses."
  type        = string
  default     = ""
}

variable "email_bcc" {
  description = "EMAIL_BCC: comma separated addresses."
  type        = string
  default     = ""
}

variable "smtp_host" {
  description = "SMTP_HOST: SMTP server host name."
  type        = string
  default     = ""
}

variable "smtp_port" {
  description = "SMTP_PORT: usually 587 with STARTTLS, or 25 for an internal relay."
  type        = string
  default     = "587"
}

variable "smtp_starttls" {
  description = "SMTP_STARTTLS: true or false."
  type        = string
  default     = "true"
}

variable "smtp_user" {
  description = "SMTP_USER: SMTP login. Empty for an internal relay that needs no login."
  type        = string
  default     = ""
}

variable "smtp_password" {
  description = "SMTP_PASSWORD: SMTP password. Stored in a Kubernetes Secret."
  type        = string
  default     = ""
  sensitive   = true
}

variable "smtp_from" {
  description = "SMTP_FROM: sender address shown on the email."
  type        = string
  default     = ""
}

# Monitor schedule
variable "monitor_interval_minutes" {
  description = "MONITOR_INTERVAL_MINUTES: minutes between checks."
  type        = string
  default     = "15"
}

# SWAT board
variable "swat_board_enabled" {
  description = "SWAT_BOARD_ENABLED: turn the SWAT board on or off."
  type        = string
  default     = "true"
}

variable "swat_board_port" {
  description = "SWAT_BOARD_PORT: port inside the container. Keep 8080: the Service targets it."
  type        = string
  default     = "8080"
}

variable "swat_board_public_url" {
  description = "SWAT_BOARD_PUBLIC_URL: address Teams users open for the board. Leave empty on the first apply, then set it to the board_url output and apply again."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Board exposure (Kubernetes Service)
# ---------------------------------------------------------------------------

variable "board_internal" {
  description = "true = internal load balancer, reachable only from the VNet (recommended). false = public load balancer, restricted by board_allowed_ip_ranges."
  type        = bool
  default     = true
}

variable "board_allowed_ip_ranges" {
  description = "CIDRs allowed to reach the SWAT board, for example [\"10.20.0.0/16\"]. Strongly recommended: the board has no login."
  type        = list(string)
  default     = []
}
