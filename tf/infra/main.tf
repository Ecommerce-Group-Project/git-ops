###############################################################################
# Terraform & Backend Configuration
###############################################################################
terraform {
  backend "azurerm" {
    resource_group_name  = "ep-tf-state-rg"
    storage_account_name = "tfstatekarpenter"
    container_name       = "tf-state-files"
    key                  = "aks-cluster.tfstate"
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.78.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0.0"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.5.0"
    }
  }
}

###############################################################################
# Provider Configuration
###############################################################################
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = var.subscription_id
}


###############################################################################
# Resource Group (Equivalent to AWS VPC)
###############################################################################
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

###############################################################################
# Virtual Network (Equivalent to AWS VPC)
###############################################################################
# Azure VNets are simpler than AWS VPCs. We create the main network and a subnet for AKS.
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.cluster_name}-vnet"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "aks_subnet" {
  name                 = "${var.cluster_name}-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.4.0/22"]
}

###############################################################################
# AKS Cluster (Equivalent to AWS EKS)
###############################################################################
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = "1.35.4" # Standard current version

  # The equivalent of EKS Managed Node Group (System Pool)
  default_node_pool {
    name           = "systempool"
    node_count     = 1
    vm_size        = "Standard_D2s_v3" # Equivalent to t3.medium
    vnet_subnet_id = azurerm_subnet.aks_subnet.id

    # Equivalent to your CriticalAddonsOnly taint in AWS
    only_critical_addons_enabled = true
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
    service_cidr   = "192.168.0.0/16"
    dns_service_ip = "192.168.0.10"
  }

  # THIS REPLACES THE ENTIRE KARPENTER HELM CHART!
  # Azure's Node Auto Provisioning is powered by Karpenter natively.
  node_provisioning_profile {
    mode = "Auto"
  }
}




resource "azurerm_role_assignment" "karpenter_network_access" {
  scope                = azurerm_subnet.aks_subnet.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id

  depends_on = [azurerm_kubernetes_cluster.aks]
}

###############################################################################
# Kubernetes Auth Providers (Dynamic Login)
###############################################################################
# Instead of using 'aws eks get-token', we pull the certificates directly from the AKS resource.
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.aks.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = azurerm_kubernetes_cluster.aks.kube_config.0.host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = azurerm_kubernetes_cluster.aks.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.cluster_ca_certificate)
  load_config_file       = false
}

###############################################################################
# Container Registry (Equivalent to AWS ECR)
###############################################################################
# In Azure, you don't create multiple repos. You create ONE registry, 
# and push to folders inside it (e.g., myregistry.azurecr.io/frontend)
resource "azurerm_container_registry" "acr" {
  # Name must be globally unique and alphanumeric only
  name                = replace("${var.project_name}registry", "-", "")
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  sku                 = "Standard"
  admin_enabled       = true
}

# Grant the AKS cluster permission to pull images from this ACR
resource "azurerm_role_assignment" "aks_to_acr" {
  principal_id                     = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.acr.id
  skip_service_principal_aad_check = true
}



###############################################################################
# Karpenter NodePool equivalents (Applying standard YAML)
###############################################################################


resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = templatefile("${path.module}/../../k8s/karpenter/karpenter-node-class.yaml", {
    subnet_id = "${azurerm_subnet.aks_subnet.id}"
  })
  depends_on = [azurerm_kubernetes_cluster.aks, azurerm_role_assignment.karpenter_network_access]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body  = file("${path.module}/../../k8s/karpenter/karpenter-node-pool.yaml")
  depends_on = [kubectl_manifest.karpenter_node_class]
}

# resource "kubectl_manifest" "inflate_deployment" {
#   yaml_body  = file("${path.module}/../../k8s/inflate/inflate-deployment.yaml")
#   depends_on = [kubectl_manifest.karpenter_node_pool]
# }


###############################################################################
# Ingress NGINX (Helm)
###############################################################################
resource "helm_release" "ingress-nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = "4.15.1"
  values           = [file("${path.module}/../../k8s/helm_config/helm-nginx-cofiguration.yaml")]

  depends_on = [azurerm_kubernetes_cluster.aks]

}


###############################################################################
# ArgoCD Installation
###############################################################################
resource "kubernetes_namespace_v1" "app_namespace" {
  metadata { name = "app" }
  depends_on = [azurerm_kubernetes_cluster.aks]
}

resource "kubernetes_namespace_v1" "argocd_namespace" {
  metadata { name = "argocd" }
  depends_on = [azurerm_kubernetes_cluster.aks]
}


resource "kubectl_manifest" "argocd_secret" {
  yaml_body          = file("${path.module}/../../k8s/argocd/secret.yaml")
  override_namespace = "argocd"
  server_side_apply  = true
  force_conflicts    = true
  depends_on         = [kubernetes_namespace_v1.argocd_namespace]
}


data "http" "argocd_manifest" {
  url = "https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
}

locals {
  raw_docs = [for doc in split("---", data.http.argocd_manifest.response_body) : trimspace(doc) if trimspace(doc) != ""]

  decoded_docs = [for doc_str in local.raw_docs : yamldecode(doc_str)]

  argocd_resources = {
    for obj in local.decoded_docs :
    "${lookup(obj, "kind", "Unknown")}/${try(obj.metadata.name, "Unknown")}" =>
    contains(["Deployment", "StatefulSet"], lookup(obj, "kind", "")) ? yamlencode(
      merge(
        obj,
        {
          spec = merge(
            obj.spec,
            {
              template = merge(
                obj.spec.template,
                {
                  spec = merge(
                    obj.spec.template.spec,
                    {
                      tolerations = [
                        {
                          key      = "CriticalAddonsOnly"
                          operator = "Equal"
                          value    = "true"
                          effect   = "NoSchedule"
                        }
                      ]
                    }
                  )
                }
              )
            }
          )
        }
      )
    ) : yamlencode(obj)
  }
}

resource "kubectl_manifest" "argocd" {
  for_each = local.argocd_resources

  yaml_body          = each.value
  override_namespace = "argocd"
  server_side_apply  = true
  force_conflicts    = true
  depends_on         = [kubernetes_namespace_v1.argocd_namespace, kubectl_manifest.argocd_secret]
}


# Patch ArgoCD server service to LoadBalancer (Updated for Azure CLI)
resource "terraform_data" "patch_argocd_service" {
  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]

    command = <<-EOT
      # Update kubeconfig using Azure CLI instead of AWS CLI
      az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name} --overwrite-existing
      
      Start-Sleep -Seconds 20
      
      kubectl patch svc argocd-server -n argocd -p '{\"spec\": {\"type\": \"LoadBalancer\"}}'
    EOT
  }
  depends_on = [kubectl_manifest.argocd]
}

resource "kubectl_manifest" "argocd_project" {
  yaml_body  = file("${path.module}/../../k8s/argocd/project.yaml")
  depends_on = [kubernetes_namespace_v1.app_namespace, kubectl_manifest.argocd]
}

resource "kubectl_manifest" "argocd_application" {
  yaml_body  = file("${path.module}/../../k8s/argocd/root-app.yaml")
  depends_on = [kubernetes_namespace_v1.app_namespace, kubectl_manifest.argocd_project]
}

###############################################################################
# Sealed Secrets
###############################################################################
resource "helm_release" "sealed_secrets" {
  name             = "sealed-secrets"
  chart            = "https://github.com/bitnami-labs/sealed-secrets/releases/download/helm-v2.15.3/sealed-secrets-2.15.3.tgz"
  namespace        = "kube-system"
  create_namespace = false

  values = [
    yamlencode({
      fullnameOverride = "sealed-secrets-controller"
      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]
    })
  ]
  depends_on = [azurerm_kubernetes_cluster.aks]
}




###############################################################################
# PostgreSQL Flexible Server (Equivalent to AWS RDS)
###############################################################################

# Private DNS Zone which map our db server dns name to the private endpoint IP address.(PRIVATE PHONE BOOK)
resource "azurerm_private_dns_zone" "postgres_dns" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

# Create a link between the Private DNS Zone and the VNet where AKS is deployed.(LINK BETWEEN PHONE BOOK AND VNET)
resource "azurerm_private_dns_zone_virtual_network_link" "dns_link" {
  name                  = "pg-dns-vnet-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

# 3. Create the Private Endpoint inside your active App/AKS subnet
resource "azurerm_private_endpoint" "pg_private_endpoint" {
  name                = "${var.project_name}-pg-endpoint"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.aks_subnet.id

  /*

  It tells the Private Endpoint exactly to which resource it should connect to. In this case, it's the PostgreSQL Flexible Server we created earlier. 
  The subresource_names field specifies the type of resource we're connecting to, which is a PostgreSQL server in this case.
  
  */
  private_service_connection {
    name                           = "${var.project_name}-pg-privatelink"
    private_connection_resource_id = azurerm_postgresql_flexible_server.dbserver.id
    is_manual_connection           = false
    subresource_names              = ["postgresqlServer"]
  }


  /*
  When Private Endpoint spins up, it gets a dynamic private IP address from your subnet. This group acts like a receptionist that instantly 
  writes that brand-new private IP address directly into your Private DNS Zone phonebook under your server's name.
  */
  private_dns_zone_group {
    name                 = "pg-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.postgres_dns.id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.dns_link]
}

resource "azurerm_postgresql_flexible_server" "dbserver" {
  name                          = "${var.project_name}-postgresql-server"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = var.location
  version                       = "16"
  public_network_access_enabled = false
  administrator_login           = var.administrator_username
  administrator_password        = var.administrator_password

  storage_mb   = 32768
  storage_tier = "P4"
  zone         = "1"

  sku_name   = "B_Standard_B1ms"
  depends_on = [azurerm_private_dns_zone_virtual_network_link.dns_link]

}
