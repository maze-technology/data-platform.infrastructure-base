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

# Provider configuration for production environment
provider "kubernetes" {
  # Configure based on your cloud provider
}

provider "helm" {
  # Inherits configuration from kubernetes provider
}

locals {
  environment  = "production"
  cluster_name = "production-cluster"
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

# TODO: Storage like in local
# module "rook_ceph" {
#   source = "../../modules/rook-ceph"

#   cluster_name = "production-cluster"
#   environment  = "production"

#     # Storage devices (one per node, minimum 3 nodes)
# SAFETY: Devices MUST be explicitly specified - automatic device discovery is disabled
#   storage_devices = ["/dev/sdb", "/dev/sdc", "/dev/sdd"]
#   use_all_nodes   = false
#   storage_nodes = [
#     {
#       name    = "node1"
#       devices = ["/dev/sdb"]
#     },
#     {
#       name    = "node2"
#       devices = ["/dev/sdb"]
#     },
#     {
#       name    = "node3"
#       devices = ["/dev/sdb"]
#     }
#   ]

#   # Cluster sizing
#   mon_count = 3
#   mgr_count = 1
#   rgw_instances = 2

#   # Replication
#   replication_size = 3
#   failure_domain   = "host"

#   # Resource limits (adjust based on node capacity)
#   resource_requests = {
#     operator = { cpu = "100m", memory = "128Mi" }
#     mon      = { cpu = "500m", memory = "2Gi" }
#     mgr      = { cpu = "500m", memory = "512Mi" }
#     osd      = { cpu = "1", memory = "2Gi" }
#     rgw      = { cpu = "500m", memory = "512Mi" }
#   }

#   resource_limits = {
#     operator = { cpu = "500m", memory = "512Mi" }
#     mon      = { cpu = "1000m", memory = "4Gi" }
#     mgr      = { cpu = "1000m", memory = "1Gi" }
#     osd      = { cpu = "2", memory = "4Gi" }
#     rgw      = { cpu = "1000m", memory = "1Gi" }
#   }

#   # Recovery throttling (critical for latency-sensitive workloads)
#   osd_recovery_max_active   = 3
#   osd_recovery_op_priority  = 3
#   osd_max_backfills         = 1
# }

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
  grafana_ingress_enabled = true
  grafana_ingress_host    = var.grafana_host
  grafana_enable_tls      = true
  prometheus_storage_size = "500Gi"
  grafana_storage_size    = "100Gi"
  loki_storage_size       = "1Ti"
  loki_deployment_mode    = "scalable" # Scalable mode for production (requires object storage)
  # loki_object_storage = {
  #   type   = "s3" # or "gcs", "azure"
  #   bucket = "loki-logs-production"
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
  ingress_host               = var.temporal_host
  enable_tls                 = true
  temporal_namespaces        = ["data-platform", "trading-platform"]
  postgresql_storage_size    = "100Gi"
  elasticsearch_storage_size = "50Gi"
}

