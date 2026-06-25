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
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

###############################################################################
# Provider Configuration
###############################################################################
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

###############################################################################
# Virtual Network (Equivalent to AWS VPC)
###############################################################################
# Azure VNets are simpler than AWS VPCs. We create the main network and a subnet for AKS.
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.cluster_name}-vnet"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "aks_subnet" {
  name                 = "${var.cluster_name}-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

###############################################################################
# AKS Cluster (Equivalent to AWS EKS)
###############################################################################
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = "1.30" # Standard current version

  # The equivalent of EKS Managed Node Group (System Pool)
  default_node_pool {
    name           = "systempool"
    node_count     = 3
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
    network_policy = "calico"
  }

  # THIS REPLACES THE ENTIRE KARPENTER HELM CHART!
  # Azure's Node Auto Provisioning is powered by Karpenter natively.
  node_provisioning_profile {
    mode = "Auto"
  }
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
  kubernetes {
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
  resource_group_name = var.resource_group_name
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
}

###############################################################################
# Karpenter NodePool equivalents (Applying standard YAML)
###############################################################################
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body  = file("${path.module}/../../k8s/karpenter/karpenter-node-pool.yaml")
  depends_on = [azurerm_kubernetes_cluster.aks]
}

resource "kubectl_manifest" "inflate_deployment" {
  yaml_body  = file("${path.module}/../../k8s/inflate/inflate-deployment.yaml")
  depends_on = [kubectl_manifest.karpenter_node_pool]
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

data "http" "argocd_manifest" {
  url = "https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
}

resource "kubectl_manifest" "argocd" {
  for_each = { for doc in split("---", data.http.argocd_manifest.response_body) :
    sha256(doc) => doc if trimspace(doc) != ""
  }

  yaml_body          = each.value
  override_namespace = "argocd"
  server_side_apply  = true
  force_conflicts    = true
  depends_on         = [kubernetes_namespace_v1.argocd_namespace]
}

# Patch ArgoCD server service to LoadBalancer (Updated for Azure CLI)
resource "terraform_data" "patch_argocd_service" {
  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]

    command = <<-EOT
      # Update kubeconfig using Azure CLI instead of AWS CLI
      az aks get-credentials --resource-group ${var.resource_group_name} --name ${azurerm_kubernetes_cluster.aks.name} --overwrite-existing
      
      Start-Sleep -Seconds 20
      
      kubectl patch svc argocd-server -n argocd -p '{\"spec\": {\"type\": \"LoadBalancer\"}}'
    EOT
  }
  depends_on = [kubectl_manifest.argocd]
}

resource "kubectl_manifest" "argocd_project" {
  yaml_body  = file("${path.module}/../../k8s/argocd/argocd-project.yaml")
  depends_on = [kubernetes_namespace_v1.app_namespace, kubectl_manifest.argocd]
}

resource "kubectl_manifest" "argocd_application" {
  yaml_body  = file("${path.module}/../../k8s/argocd/argocd-app.yaml")
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
