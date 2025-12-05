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

# Provider configuration for prod environment
provider "kubernetes" {
  # Configure based on your cloud provider
}

provider "helm" {
  # Inherits configuration from kubernetes provider
}

locals {
  environment  = "prod"
  cluster_name = "prod-cluster"
}

# Network module
module "network" {
  source = "../../modules/network"

  environment          = local.environment
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  enable_nat_gateway   = true
  tags = {
    Environment = local.environment
    ManagedBy   = "opentofu"
  }
}

# Cluster module
module "cluster" {
  source = "../../modules/cluster"

  cluster_name       = local.cluster_name
  environment        = local.environment
  cluster_type       = "cloud"
  kubernetes_version = var.kubernetes_version
  tags = {
    Environment = local.environment
    ManagedBy   = "opentofu"
  }
}

# Cert-manager
module "cert_manager" {
  source = "../../modules/cert-manager"

  cluster_name       = local.cluster_name
  environment        = local.environment
  letsencrypt_email  = var.letsencrypt_email
  letsencrypt_server = "https://acme-v02.api.letsencrypt.org/directory"
  replica_count      = 3
}

# Ingress controller
module "ingress" {
  source = "../../modules/ingress"

  cluster_name   = local.cluster_name
  environment    = local.environment
  service_type   = "LoadBalancer"
  replica_count  = 3
  enable_metrics = true
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
  grafana_ingress_host    = var.grafana_host
  grafana_enable_tls      = true
  prometheus_storage_size = "500Gi"
  grafana_storage_size    = "100Gi"
  loki_storage_size       = "1Ti"
  loki_deployment_mode    = "scalable" # Scalable mode for production (requires object storage)
  # loki_object_storage = {
  #   type   = "s3" # or "gcs", "azure"
  #   bucket = "loki-logs-prod"
  #   region = "us-east-1"
  # }
}

# Argo CD
module "argocd" {
  source = "../../modules/argocd"

  cluster_name    = local.cluster_name
  environment     = local.environment
  replica_count   = 3
  enable_ha       = true
  ingress_enabled = true
  ingress_host    = var.argocd_host
  enable_tls      = true
}

# Temporal
module "temporal" {
  source = "../../modules/temporal"

  cluster_name               = local.cluster_name
  environment                = local.environment
  replica_count              = 3
  enable_ha                  = true
  ingress_enabled            = true
  ingress_host               = var.temporal_host
  enable_tls                 = true
  temporal_namespaces        = ["data-platform", "trading-platform"]
  use_postgresql             = true # Use PostgreSQL for simplicity and alignment with local
  postgresql_storage_size    = "100Gi"
  elasticsearch_storage_size = "50Gi"
}

