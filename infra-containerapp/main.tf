# P1 API Monitor on Azure Container Apps. Creates every resource it needs:
#   resource group, storage account and container, container registry, managed identity with its role
#   assignments, Log Analytics workspace, Container Apps environment and the container app.
#
# Deployment runs in two steps (Deploy-ContainerApp.ps1 does both):
#   1. terraform apply -target=... creates the resource group and the registry. The script then pushes the image.
#   2. terraform apply (everything) creates the rest and starts the app with that image.

locals {
  # Names: lowercase, no dashes where Azure does not allow them.
  storage_account_name = "stp1apimon${var.name_suffix}"
  registry_name        = "acrp1apimon${var.name_suffix}"
  workspace_name       = "log-${var.app_name}-${var.name_suffix}"
  identity_name        = "id-${var.app_name}-${var.name_suffix}"

  # The app's own public address: <app>.<environment default domain>. Used for the SWAT board link in Teams cards.
  app_url = "https://${var.app_name}.${azurerm_container_app_environment.env.default_domain}"

  # Secret values. Empty values are left out, so an unused alert channel has no secret at all.
  secrets = {
    for k, v in {
      "sn-client-id"       = var.sn_client_id
      "sn-client-secret"   = var.sn_client_secret
      "sn-password"        = var.sn_password
      "teams-webhook-urls" = var.teams_webhook_urls
      "smtp-password"      = var.smtp_password
    } : k => v if v != ""
  }

  # Environment variables that hold a secret: name -> secret name.
  secret_env = {
    SN_CLIENT_ID       = "sn-client-id"
    SN_CLIENT_SECRET   = "sn-client-secret"
    SN_PASSWORD        = "sn-password"
    TEAMS_WEBHOOK_URLS = "teams-webhook-urls"
    SMTP_PASSWORD      = "smtp-password"
  }

  # Environment variables that are not secret. Each name matches the .env setting.
  plain_env = {
    SN_INSTANCE               = var.sn_instance
    SN_USE_USERNAME_PASSWORD  = tostring(var.sn_use_username_password)
    SN_USERNAME               = var.sn_username
    SN_VERIFY_SSL             = tostring(var.sn_verify_ssl)
    AZURE_STORAGE_ACCOUNT_URL = azurerm_storage_account.monitor.primary_blob_endpoint
    AZURE_STORAGE_CONTAINER   = var.storage_container
    AZURE_STORAGE_FOLDER      = var.storage_folder
    # Tells DefaultAzureCredential which user-assigned identity to use for storage.
    AZURE_CLIENT_ID          = azurerm_user_assigned_identity.app.client_id
    TEAMS_VERIFY_SSL         = tostring(var.teams_verify_ssl)
    EMAIL_TO                 = var.email_to
    EMAIL_CC                 = var.email_cc
    EMAIL_BCC                = var.email_bcc
    SMTP_HOST                = var.smtp_host
    SMTP_PORT                = tostring(var.smtp_port)
    SMTP_STARTTLS            = tostring(var.smtp_starttls)
    SMTP_USER                = var.smtp_user
    SMTP_FROM                = var.smtp_from
    MONITOR_INTERVAL_MINUTES = tostring(var.monitor_interval_minutes)
    SWAT_BOARD_ENABLED       = tostring(var.swat_board_enabled)
    SWAT_BOARD_PORT          = tostring(var.swat_board_port)
    SWAT_BOARD_PUBLIC_URL    = var.swat_board_public_url != "" ? var.swat_board_public_url : local.app_url
  }

  image = "${azurerm_container_registry.acr.login_server}/${var.image_name}:${var.image_tag}"
}

# ---------------------------------------------------------------------------
# Resource group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Storage: incidents.json, swat_status.json and swat_details/. The app signs in with its identity, not a key.
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "monitor" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

resource "azurerm_storage_container" "monitor" {
  name                  = var.storage_container
  storage_account_id    = azurerm_storage_account.monitor.id
  container_access_type = "private"
}

# ---------------------------------------------------------------------------
# Container registry. The admin user is on so the PowerShell script can push the image with a user name and
# password. The container app pulls the image with its managed identity (AcrPull), not the password.
# ---------------------------------------------------------------------------
resource "azurerm_container_registry" "acr" {
  name                = local.registry_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = var.registry_sku
  admin_enabled       = true
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Identity and roles
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "app" {
  name                = local.identity_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "storage_blob_contributor" {
  scope                = azurerm_storage_account.monitor.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# ---------------------------------------------------------------------------
# Logs and the Container Apps environment
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "logs" {
  name                = local.workspace_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_container_app_environment" "env" {
  name                       = var.environment_name
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id
  tags                       = var.tags
}

# ---------------------------------------------------------------------------
# The monitor and the SWAT board. One replica, always running: the monitor is a loop.
# ---------------------------------------------------------------------------
resource "azurerm_container_app" "app" {
  name                         = var.app_name
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  dynamic "secret" {
    for_each = local.secrets
    content {
      name  = secret.key
      value = secret.value
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "monitor"
      image  = local.image
      cpu    = var.container_cpu
      memory = var.container_memory

      dynamic "env" {
        for_each = local.plain_env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = { for name, secret in local.secret_env : name => secret if contains(keys(local.secrets), secret) }
        content {
          name        = env.key
          secret_name = env.value
        }
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = var.swat_board_port
    transport        = "http"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.storage_blob_contributor,
  ]
}
