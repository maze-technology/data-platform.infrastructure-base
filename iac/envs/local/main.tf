terraform {
  required_version = ">= 1.5.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kind-local"
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "kind-local"
  }
}

locals {
  environment  = "local"
  cluster_name = "local"
}

# Cluster module (kind cluster assumed to be created via scripts)
module "cluster" {
  source = "../../modules/cluster"

  cluster_name = local.cluster_name
  environment  = local.environment
  cluster_type = "kind"
  node_count   = 1
}

# Network module (not needed for local/kind)
# module "network" {
#   source = "../../modules/network"
#   ...
# }

# Cert-manager (installed first as other components may depend on it)
module "cert_manager" {
  source = "../../modules/cert-manager"

  cluster_name       = local.cluster_name
  environment        = local.environment
  letsencrypt_email  = "" # Not configured for local
  letsencrypt_server = "https://acme-staging-v02.api.letsencrypt.org/directory"
  replica_count      = 1
}

# Ingress controller
module "ingress" {
  source = "../../modules/ingress"

  cluster_name    = local.cluster_name
  environment     = local.environment
  service_type    = "NodePort"
  node_port_http  = 30080
  node_port_https = 30443
  replica_count   = 1
  enable_metrics  = true
}

# Observability stack
module "observability" {
  source = "../../modules/observability"

  cluster_name            = local.cluster_name
  environment             = local.environment
  enable_prometheus       = true
  enable_grafana          = true
  enable_loki             = true
  enable_promtail         = true
  grafana_ingress_enabled = true
  grafana_ingress_host    = "grafana.local"
  grafana_enable_tls      = false # TLS not needed for local
  prometheus_storage_size = "20Gi"
  grafana_storage_size    = "5Gi"
  loki_storage_size       = "20Gi"
}

# Argo CD
module "argocd" {
  source = "../../modules/argocd"

  cluster_name    = local.cluster_name
  environment     = local.environment
  replica_count   = 1
  enable_ha       = false
  ingress_enabled = true
  ingress_host    = "argocd.local"
  enable_tls      = false # TLS not needed for local
}

