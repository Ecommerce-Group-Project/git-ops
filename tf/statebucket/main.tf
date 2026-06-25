###############################################################################
# Provider
###############################################################################
provider "azurerm" {
  features {}
  subscription_id                 = var.azure_subscription_id
  resource_provider_registrations = "none"
}

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.78.0"
    }
  }
}

###############################################################################
# Resource Group (Mandatory Folder Container)
###############################################################################
resource "azurerm_resource_group" "state_rg" {
  name     = "ep-tf-state-rg"
  location = "East US"
}

###############################################################################
# Storage Account (The Storage Engine Server)
###############################################################################
resource "azurerm_storage_account" "state_sa" {
  name                     = "tfstatekarpenter"
  resource_group_name      = azurerm_resource_group.state_rg.name
  location                 = azurerm_resource_group.state_rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

###############################################################################
# Blob Container (The Actual Folder for your State File)
###############################################################################
resource "azurerm_storage_container" "state_container" {
  name                  = "tf-state-files"
  storage_account_id    = azurerm_storage_account.state_sa.id
  container_access_type = "private"
}
