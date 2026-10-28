terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # Local state by default. For a team, store the state in a private backend, for example:
  # backend "azurerm" {
  #   resource_group_name  = "rg-terraform-state"
  #   storage_account_name = "sttfstate..."
  #   container_name       = "tfstate"
  #   key                  = "p1-api-monitor.tfstate"
  # }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}
