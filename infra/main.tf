# P1 API Monitor on an EXISTING AKS cluster.
#
#   ServiceNow <── monitor pod (AKS namespace, 1 replica) ──> Teams / SMTP
#                    │  Workload Identity: ServiceAccount -> federated credential -> managed identity (no key)
#                    ├── AcrPull (kubelet identity) ───────> Container registry (image)
#                    └── Storage Blob Data Contributor ─────> Storage account / container
#   SWAT users ──> Service (internal or restricted LoadBalancer) ──> pod :8080

locals {
  storage_name = var.storage_account_name != "" ? var.storage_account_name : "stp1apimon${var.name_suffix}"

  # Names used by the Kubernetes objects and the federated credential. They must match exactly.
  service_account_name = "${var.app_name}-sa"
  configmap_name       = "p1-monitor-config"
  secret_name          = "p1-monitor-secrets"
  federated_subject    = "system:serviceaccount:${var.kubernetes_namespace}:${local.service_account_name}"

  # Non-secret settings. Empty values are left out of the ConfigMap.
  plain_settings = {
    SN_INSTANCE              = var.sn_instance
    SN_CLIENT_ID             = var.sn_client_id
    AZURE_STORAGE_CONTAINER  = var.azure_storage_container
    AZURE_STORAGE_FOLDER     = var.azure_storage_folder
    TEAMS_VERIFY_SSL         = var.teams_verify_ssl
    EMAIL_TO                 = var.email_to
    EMAIL_CC                 = var.email_cc
    EMAIL_BCC                = var.email_bcc
    SMTP_HOST                = var.smtp_host
    SMTP_PORT                = var.smtp_port
    SMTP_STARTTLS            = var.smtp_starttls
    SMTP_USER                = var.smtp_user
    SMTP_FROM                = var.smtp_from
    MONITOR_INTERVAL_MINUTES = var.monitor_interval_minutes
    SWAT_BOARD_ENABLED       = var.swat_board_enabled
    SWAT_BOARD_PORT          = var.swat_board_port
    SWAT_BOARD_PUBLIC_URL    = var.swat_board_public_url
    # Set by Terraform from the storage account. monitor.py removes a trailing "/".
    AZURE_STORAGE_ACCOUNT_URL = azurerm_storage_account.monitor.primary_blob_endpoint
  }
}

# ---------------------------------------------------------------------------
# Check the existing cluster is ready for Workload Identity
# ---------------------------------------------------------------------------

resource "terraform_data" "aks_check" {
  lifecycle {
    precondition {
      condition     = data.azurerm_kubernetes_cluster.aks.oidc_issuer_url != ""
      error_message = "The AKS cluster has no OIDC issuer. Run: az aks update -g ${var.aks_resource_group_name} -n ${var.aks_cluster_name} --enable-oidc-issuer --enable-workload-identity"
    }
  }
}

# ---------------------------------------------------------------------------
# Resource group, storage account and container (no keys, no public blob access)
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "monitor" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "monitor" {
  name                            = local.storage_name
  resource_group_name             = azurerm_resource_group.monitor.name
  location                        = azurerm_resource_group.monitor.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  tags                            = var.tags

  network_rules {
    default_action             = length(var.storage_allowed_ip_ranges) + length(var.storage_virtual_network_subnet_ids) > 0 ? "Deny" : "Allow"
    ip_rules                   = var.storage_allowed_ip_ranges
    virtual_network_subnet_ids = var.storage_virtual_network_subnet_ids
    bypass                     = ["AzureServices"]
  }
}

resource "azurerm_storage_container" "monitor" {
  name                  = var.azure_storage_container
  storage_account_id    = azurerm_storage_account.monitor.id
  container_access_type = "private"
}

# ---------------------------------------------------------------------------
# Workload identity: managed identity + federated credential for the ServiceAccount
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "monitor" {
  name                = "id-${var.app_name}"
  resource_group_name = azurerm_resource_group.monitor.name
  location            = azurerm_resource_group.monitor.location
  tags                = var.tags
}

# Trusts tokens that AKS issues to the ServiceAccount below, so the pod can sign in as this identity.
resource "azurerm_federated_identity_credential" "monitor" {
  name                = "fc-${var.app_name}"
  resource_group_name = azurerm_resource_group.monitor.name
  parent_id           = azurerm_user_assigned_identity.monitor.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = data.azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject             = local.federated_subject

  depends_on = [terraform_data.aks_check]
}

# Read and write blobs in the storage account, and nothing else.
resource "azurerm_role_assignment" "storage_blob_contributor" {
  scope                = azurerm_storage_account.monitor.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.monitor.principal_id
  principal_type       = "ServicePrincipal"
}

# ---------------------------------------------------------------------------
# Image pull: the AKS kubelet identity pulls from the existing registry (no password)
# ---------------------------------------------------------------------------

data "azurerm_container_registry" "acr" {
  name                = var.acr_name
  resource_group_name = var.acr_resource_group_name
}

resource "azurerm_role_assignment" "acr_pull" {
  count                = var.grant_acr_pull ? 1 : 0
  scope                = data.azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = data.azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  principal_type       = "ServicePrincipal"
}

# ---------------------------------------------------------------------------
# Kubernetes: namespace, ServiceAccount, configuration, secrets
# ---------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "monitor" {
  metadata {
    name   = var.kubernetes_namespace
    labels = { app = var.app_name }
  }
}

resource "kubernetes_service_account_v1" "monitor" {
  metadata {
    name      = local.service_account_name
    namespace = kubernetes_namespace_v1.monitor.metadata[0].name
    annotations = {
      "azure.workload.identity/client-id" = azurerm_user_assigned_identity.monitor.client_id
    }
  }
}

resource "kubernetes_config_map_v1" "monitor" {
  metadata {
    name      = local.configmap_name
    namespace = kubernetes_namespace_v1.monitor.metadata[0].name
  }
  data = { for k, v in local.plain_settings : k => v if v != "" }
}

resource "kubernetes_secret_v1" "monitor" {
  metadata {
    name      = local.secret_name
    namespace = kubernetes_namespace_v1.monitor.metadata[0].name
  }
  type = "Opaque"
  data = {
    SN_CLIENT_SECRET   = var.sn_client_secret
    TEAMS_WEBHOOK_URLS = var.teams_webhook_urls
    SMTP_PASSWORD      = var.smtp_password
  }
}

# ---------------------------------------------------------------------------
# The monitor: one replica, Recreate strategy (never two copies, so no duplicate alerts)
# ---------------------------------------------------------------------------

resource "kubernetes_deployment_v1" "monitor" {
  metadata {
    name      = var.app_name
    namespace = kubernetes_namespace_v1.monitor.metadata[0].name
    labels    = { app = var.app_name }
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = var.app_name }
    }

    template {
      metadata {
        labels = {
          app = var.app_name
          # Tells the Workload Identity webhook to inject the Azure token for this pod.
          "azure.workload.identity/use" = "true"
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.monitor.metadata[0].name

        security_context {
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name              = var.app_name
          image             = var.container_image
          image_pull_policy = "IfNotPresent"

          port {
            name           = "board"
            container_port = 8080
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.monitor.metadata[0].name
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.monitor.metadata[0].name
            }
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }

          readiness_probe {
            tcp_socket {
              port = "board"
            }
            initial_delay_seconds = 10
            period_seconds        = 15
          }

          liveness_probe {
            tcp_socket {
              port = "board"
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            failure_threshold     = 4
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.storage_blob_contributor,
    azurerm_role_assignment.acr_pull,
    azurerm_federated_identity_credential.monitor,
  ]
}

# ---------------------------------------------------------------------------
# SWAT board: a Service of type LoadBalancer, internal by default
# ---------------------------------------------------------------------------

resource "kubernetes_service_v1" "board" {
  metadata {
    name      = "${var.app_name}-board"
    namespace = kubernetes_namespace_v1.monitor.metadata[0].name
    labels    = { app = var.app_name }
    annotations = var.board_internal ? {
      "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
    } : {}
  }

  spec {
    type     = "LoadBalancer"
    selector = { app = var.app_name }

    port {
      name        = "http"
      port        = 80
      target_port = "board"
      protocol    = "TCP"
    }

    # The board has no login. Limit who can reach the load balancer.
    load_balancer_source_ranges = length(var.board_allowed_ip_ranges) > 0 ? var.board_allowed_ip_ranges : null
  }
}
