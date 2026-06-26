###############################################################################
# Core Cluster Infrastructure Outputs
###############################################################################

output "resource_group_name" {
  description = "The resource group where the cluster and network reside."
  value       = var.resource_group_name
}

output "cluster_name" {
  description = "The deployed AKS Cluster identity name."
  value       = azurerm_kubernetes_cluster.aks.name
}

output "cluster_endpoint" {
  description = "The Kubernetes control plane API server host URL endpoint."
  value       = azurerm_kubernetes_cluster.aks.kube_config.0.host
  sensitive   = true # Marked sensitive to prevent raw passwords from leaking in standard console printouts
}

output "vnet_name" {
  description = "The name of the main Virtual Network."
  value       = azurerm_virtual_network.vnet.name
}

output "aks_subnet_id" {
  description = "The resource ID of the subnet running your AKS components."
  value       = azurerm_subnet.aks_subnet.id
}

###############################################################################
# Container Registry (ACR) Outputs (Replaces AWS ECR Outputs)
###############################################################################

output "acr_name" {
  description = "The name of the Azure Container Registry."
  value       = azurerm_container_registry.acr.name
}

output "acr_login_server" {
  description = "The base login URL server address to tag your Docker images with."
  value       = azurerm_container_registry.acr.login_server
}

output "acr_admin_username" {
  description = "The administrative username for local terminal docker logins."
  value       = azurerm_container_registry.acr.admin_username
}

output "acr_admin_password" {
  description = "The administrative password string for local terminal docker logins."
  value       = azurerm_container_registry.acr.admin_password
  sensitive   = true # Marked sensitive to prevent raw passwords from leaking in standard console printouts
}

###############################################################################
# DevOps & Local Machine Connection Helpers
###############################################################################

output "aks_connect_command" {
  description = "Copy-pasteable Azure CLI command to link your local PowerShell/terminal context to this cluster."
  value       = "az aks get-credentials --resource-group ${var.resource_group_name} --name ${azurerm_kubernetes_cluster.aks.name} --overwrite-existing"
}

output "argocd_admin_password_command" {
  description = "Convenience command to fetch and decode the auto-generated initial ArgoCD admin password token."
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'"
}
