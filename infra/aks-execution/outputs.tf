output "cluster_name" { value = azurerm_kubernetes_cluster.this.name }
output "resource_group_name" { value = var.resource_group_name }
output "worker_client_id" { value = azurerm_user_assigned_identity.worker.client_id }
output "helm_service_account_annotation" {
  value = {
    "azure.workload.identity/client-id" = azurerm_user_assigned_identity.worker.client_id
  }
}
