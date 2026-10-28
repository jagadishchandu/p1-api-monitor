# ---------------------------------------------------------------------------
# Where and how the resources are named
# ---------------------------------------------------------------------------
variable "subscription_id" {
  description = "Subscription that holds every resource."
  type        = string
}

variable "location" {
  description = "Azure region, for example eastus2."
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Resource group for everything in this stack. Created if missing."
  type        = string
  default     = "rg-p1-api-monitor"
}

variable "name_suffix" {
  description = "Short lowercase suffix (3-12 letters or digits). Makes the registry and storage account names globally unique."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.name_suffix))
    error_message = "name_suffix must be 3-12 lowercase letters or digits."
  }
}

variable "app_name" {
  description = "Container App name. Also the start of its public address."
  type        = string
  default     = "p1-api-monitor"
}

variable "environment_name" {
  description = "Container Apps environment name."
  type        = string
  default     = "cae-p1-api-monitor"
}

variable "tags" {
  description = "Tags added to every resource."
  type        = map(string)
  default = {
    project = "p1-api-monitor"
    managed = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Container image. Terraform cannot create the image; the PowerShell script builds it,
# pushes it to the registry created here, and then passes the tag in.
# ---------------------------------------------------------------------------
variable "image_tag" {
  description = "Tag of the image pushed to the registry, for example 1.0.0 or a build number. Set by Deploy-ContainerApp.ps1."
  type        = string
  default     = "latest"
}

variable "image_name" {
  description = "Repository name in the registry."
  type        = string
  default     = "p1-api-monitor"
}

variable "container_cpu" {
  description = "vCPU for the monitor (0.25, 0.5, 1 ...)."
  type        = number
  default     = 0.25
}

variable "container_memory" {
  description = "Memory for the monitor, for example 0.5Gi."
  type        = string
  default     = "0.5Gi"
}

# ---------------------------------------------------------------------------
# Storage (where incidents.json, swat_status.json and swat_details/ are kept)
# ---------------------------------------------------------------------------
variable "storage_container" {
  description = "Blob container that holds the data files (AZURE_STORAGE_CONTAINER)."
  type        = string
  default     = "p1-api-monitor"
}

variable "storage_folder" {
  description = "Folder inside the container (AZURE_STORAGE_FOLDER). Use a different folder for test and production."
  type        = string
  default     = "p1-api-monitor"
}

# ---------------------------------------------------------------------------
# ServiceNow (REQUIRED). The client secret is sensitive and is passed as TF_VAR_sn_client_secret.
# ---------------------------------------------------------------------------
variable "sn_instance" {
  description = "ServiceNow instance name only, for example acmecorp (SN_INSTANCE)."
  type        = string
}

variable "sn_client_id" {
  description = "ServiceNow OAuth client ID (SN_CLIENT_ID). Not needed when sn_use_username_password is true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "sn_client_secret" {
  description = "ServiceNow OAuth client secret (SN_CLIENT_SECRET). Not needed when sn_use_username_password is true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "sn_use_username_password" {
  description = "SN_USE_USERNAME_PASSWORD. true: sign in to ServiceNow with sn_username and sn_password (HTTP Basic). false: OAuth."
  type        = bool
  default     = false
}

variable "sn_username" {
  description = "SN_USERNAME, used when sn_use_username_password is true."
  type        = string
  default     = ""
}

variable "sn_password" {
  description = "SN_PASSWORD, used when sn_use_username_password is true. Passed as TF_VAR_sn_password."
  type        = string
  default     = ""
  sensitive   = true
}

variable "sn_verify_ssl" {
  description = "SN_VERIFY_SSL. false skips the certificate check for ServiceNow calls."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Teams and email alerts (OPTIONAL)
# ---------------------------------------------------------------------------
variable "teams_webhook_urls" {
  description = "Power Automate webhook URL(s), comma separated. Empty turns Teams alerts off (TEAMS_WEBHOOK_URLS)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "teams_verify_ssl" {
  description = "TEAMS_VERIFY_SSL. Set false only if a corporate TLS proxy breaks the Teams call."
  type        = bool
  default     = true
}

variable "email_to" {
  description = "Alert recipients, comma separated (EMAIL_TO). Empty turns email off."
  type        = string
  default     = ""
}

variable "email_cc" {
  description = "EMAIL_CC."
  type        = string
  default     = ""
}

variable "email_bcc" {
  description = "EMAIL_BCC."
  type        = string
  default     = ""
}

variable "smtp_host" {
  description = "SMTP_HOST."
  type        = string
  default     = ""
}

variable "smtp_port" {
  description = "SMTP_PORT."
  type        = number
  default     = 587
}

variable "smtp_starttls" {
  description = "SMTP_STARTTLS."
  type        = bool
  default     = true
}

variable "smtp_user" {
  description = "SMTP_USER. Leave empty for an internal relay with no login."
  type        = string
  default     = ""
}

variable "smtp_password" {
  description = "SMTP_PASSWORD. Passed as TF_VAR_smtp_password."
  type        = string
  default     = ""
  sensitive   = true
}

variable "smtp_from" {
  description = "SMTP_FROM. Defaults to SMTP_USER in the app when empty."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Monitor schedule and SWAT board
# ---------------------------------------------------------------------------
variable "monitor_interval_minutes" {
  description = "MONITOR_INTERVAL_MINUTES."
  type        = number
  default     = 15
}

variable "swat_board_enabled" {
  description = "SWAT_BOARD_ENABLED."
  type        = bool
  default     = true
}

variable "swat_board_port" {
  description = "SWAT_BOARD_PORT. Keep 8080 unless you also change the Dockerfile."
  type        = number
  default     = 8080
}

variable "swat_board_public_url" {
  description = "Address the Teams cards use for the 'Open SWAT board' button. Empty uses the container app's own https address."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------
variable "registry_sku" {
  description = "Container registry SKU. Basic is enough for this app."
  type        = string
  default     = "Basic"
}
