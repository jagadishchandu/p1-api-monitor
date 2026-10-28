output "resource_group_name" {
  description = "Resource group that holds everything."
  value       = azurerm_resource_group.main.name
}

output "registry_name" {
  description = "Container registry name. Its admin user name is the same name."
  value       = azurerm_container_registry.acr.name
}

output "registry_login_server" {
  description = "Registry address for docker login and push."
  value       = azurerm_container_registry.acr.login_server
}

output "storage_account_name" {
  description = "Storage account that holds the data files."
  value       = azurerm_storage_account.monitor.name
}

output "azure_storage_account_url" {
  description = "AZURE_STORAGE_ACCOUNT_URL for .env."
  value       = azurerm_storage_account.monitor.primary_blob_endpoint
}

output "managed_identity_client_id" {
  description = "Client ID of the app's identity (AZURE_CLIENT_ID)."
  value       = azurerm_user_assigned_identity.app.client_id
}

output "container_app_name" {
  description = "Container App name."
  value       = azurerm_container_app.app.name
}

output "app_url" {
  description = "Public address of the SWAT board (also the Teams button address unless swat_board_public_url is set)."
  value       = local.app_url
}
