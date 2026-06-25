###############################################################################
# Storage Container
###############################################################################
output "state_bucket_name" {
  value = azurerm_storage_container.state_container.name
}

output "state_bucket_id" {
  value = azurerm_storage_container.state_container.id
}

output "state_bucket_region" {
  value = azurerm_storage_account.state_sa.location
}
