###############################################################################
# Environment
###############################################################################
variable "location" {
  description = "Azure region"
  type        = string
}

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Microsoft Entra (Azure AD) Tenant ID"
  type        = string
}

variable "client_id" {
  description = "Service Principal Client ID"
  type        = string
}

variable "client_secret" {
  description = "Service Principal Client Secret"
  type        = string
  sensitive   = true
}

###############################################################################
# Resource Group
###############################################################################
variable "resource_group_name" {
  description = "Azure Resource Group"
  type        = string
}

###############################################################################
# AKS Cluster
###############################################################################
variable "cluster_name" {
  description = "AKS Cluster Name"
  type        = string
}

variable "project_name" {
  description = "Project Name"
  type        = string
}

###############################################################################
# Database (Azure Database for PostgreSQL/MySQL)
###############################################################################
variable "administrator_login" {
  description = "Database administrator username"
  type        = string
}

variable "administrator_password" {
  description = "Database administrator password"
  type        = string
  sensitive   = true
}
