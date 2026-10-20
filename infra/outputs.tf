# Values you need after the apply. Secrets are never output.

output "namespace" {
  description = "Kubernetes namespace of the monitor."
  value       = kubernetes_namespace_v1.monitor.metadata[0].name
}

output "deployment_name" {
  description = "Deployment to check with: kubectl -n <namespace> get deploy"
  value       = kubernetes_deployment_v1.monitor.metadata[0].name
}

output "board_ip" {
  description = "Internal or public IP of the SWAT board load balancer. Empty until Azure assigns it (a few minutes)."
  value       = try(kubernetes_service_v1.board.status[0].load_balancer[0].ingress[0].ip, "")
}

output "board_url" {
  description = "SWAT board address (http, port 80). Put it in swat_board_public_url and apply again so Teams links point here."
  value       = try("http://${kubernetes_service_v1.board.status[0].load_balancer[0].ingress[0].ip}", "")
}

output "azure_storage_account_url" {
  description = "AZURE_STORAGE_ACCOUNT_URL for local runs."
  value       = trimsuffix(azurerm_storage_account.monitor.primary_blob_endpoint, "/")
}

output "storage_account_name" {
  description = "Storage account name."
  value       = azurerm_storage_account.monitor.name
}

output "managed_identity_client_id" {
  description = "Client ID of the workload identity (the ServiceAccount annotation)."
  value       = azurerm_user_assigned_identity.monitor.client_id
}

output "managed_identity_principal_id" {
  description = "Principal ID of the workload identity. Use it to grant more roles."
  value       = azurerm_user_assigned_identity.monitor.principal_id
}

output "federated_subject" {
  description = "Subject of the federated credential. It must match the ServiceAccount exactly."
  value       = local.federated_subject
}
