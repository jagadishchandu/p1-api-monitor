terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }

  # Keep the state out of git: it can contain sensitive values.
  # For a team, store it in a locked Azure Storage container instead (uncomment and fill in):
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstatep1apimon"
  #   container_name       = "tfstate"
  #   key                  = "p1-api-monitor-aks.tfstate"
  #   use_azuread_auth     = true
  # }
}

provider "azurerm" {
  features {}

  # The storage account has shared keys disabled, so Terraform reaches its data plane with Entra ID.
  storage_use_azuread = true
}

# The existing AKS cluster. Terraform only reads it; it does not change the cluster.
data "azurerm_kubernetes_cluster" "aks" {
  name                = var.aks_cluster_name
  resource_group_name = var.aks_resource_group_name
}

# Kubernetes provider: signs in with your Azure CLI session through kubelogin (Entra ID auth).
# Install kubelogin first: az aks install-cli
provider "kubernetes" {
  host                   = data.azurerm_kubernetes_cluster.aks.kube_config[0].host
  cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args        = ["get-token", "--login", "azurecli", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
  }
}
