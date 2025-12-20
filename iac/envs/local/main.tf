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
  # Construct absolute path to kubeconfig using pathexpand to expand ~
  config_path    = pathexpand("~/.kube/config")
  config_context = "kind-local"
}

provider "helm" {
  kubernetes {
    config_path    = pathexpand("~/.kube/config")
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

# Observability stack (installed first to provide Prometheus Operator for Rook-Ceph monitoring)
module "observability" {
  source = "../../modules/observability"

  cluster_name            = local.cluster_name
  environment             = local.environment
  grafana_ingress_enabled = true
  grafana_ingress_host    = "grafana.local"
  grafana_enable_tls      = false # TLS not needed for local
  prometheus_storage_size = "20Gi"
  grafana_storage_size    = "5Gi"
  loki_storage_size       = "20Gi"
  loki_deployment_mode    = "scalable" # Use scalable mode with LocalStack S3 (same as production)
  loki_object_storage = {
    type             = "s3"
    bucket           = "loki-logs-local"
    region           = "us-east-1"
    endpoint         = "http://host.docker.internal:4566" # LocalStack endpoint accessible from Kubernetes
    access_key       = "test"                             # LocalStack default credentials
    secret_key       = "test"                             # LocalStack default credentials
    force_path_style = true                               # Required for LocalStack
  }
}

# Rook-Ceph storage (installed after observability for Prometheus monitoring support)
# Note: For local/kind, you may need to configure loop devices or mounted volumes
# Example: sudo losetup -fP /path/to/disk.img (creates /dev/loop0, /dev/loop1, etc.)
module "rook_ceph" {
  source = "../../modules/rook-ceph"

  cluster_name = local.cluster_name
  environment  = local.environment

  # For local/kind: use all nodes, configure devices based on your setup
  # Adjust storage_devices based on your kind node configuration
  use_all_nodes   = true
  storage_devices = [] # Configure based on your local setup (e.g., ["/dev/loop0"])

  # Reduced sizing for local development
  mon_count        = 1
  mgr_count        = 1
  rgw_instances    = 1
  replication_size = 1 # Single node local setup (increase if you have multiple nodes)

  # Reduced resource requests for local
  resource_requests = {
    operator = { cpu = "50m", memory = "64Mi" }
    mon      = { cpu = "250m", memory = "1Gi" }
    mgr      = { cpu = "250m", memory = "256Mi" }
    osd      = { cpu = "500m", memory = "1Gi" }
    rgw      = { cpu = "250m", memory = "256Mi" }
  }

  resource_limits = {
    operator = { cpu = "250m", memory = "256Mi" }
    mon      = { cpu = "500m", memory = "2Gi" }
    mgr      = { cpu = "500m", memory = "512Mi" }
    osd      = { cpu = "1", memory = "2Gi" }
    rgw      = { cpu = "500m", memory = "512Mi" }
  }

  # Recovery throttling (less aggressive for local)
  osd_recovery_max_active  = 2
  osd_recovery_op_priority  = 5
  osd_max_backfills        = 1

  # Dashboard enabled for local debugging
  dashboard_enabled = true
  # Enable Prometheus monitoring (requires Prometheus Operator from observability module)
  monitoring_enabled            = true
  prometheus_operator_dependency = module.observability.prometheus_operator_helm_release
}


# Ingress controller (depends on observability for ServiceMonitor CRD when metrics enabled)
module "ingress" {
  source = "../../modules/ingress"

  cluster_name                   = local.cluster_name
  environment                    = local.environment
  service_type                   = "NodePort"
  node_port_http                 = 30080
  node_port_https                = 30443
  replica_count                  = 1
  enable_metrics                 = true
  prometheus_operator_dependency = module.observability.prometheus_operator_helm_release
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

# Temporal
module "temporal" {
  source = "../../modules/temporal"

  cluster_name               = local.cluster_name
  environment                = local.environment
  replica_count              = 1
  enable_ha                  = false
  ingress_host               = "temporal.local"
  enable_tls                 = false # TLS not needed for local
  temporal_namespaces        = ["data-platform", "trading-platform"]
  postgresql_storage_size    = "5Gi"
  elasticsearch_storage_size = "5Gi"
}

