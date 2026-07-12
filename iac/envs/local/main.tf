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
    rgw = {
      source  = "rissson/rgw"
      version = "~> 0.3.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 3.23"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
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
  ingress_port = ":30080"

  cluster_domain = var.cluster_domain

  # Feature-based hostnames (not technology names)
  hosts = {
    auth     = "auth.${var.cluster_domain}"
    scm      = "scm.${var.cluster_domain}"
    registry = "registry.scm.${var.cluster_domain}"
    grafana  = "grafana.${var.cluster_domain}"
    argocd   = "argocd.${var.cluster_domain}"
    vault    = "vault.${var.cluster_domain}"
    vpn      = "vpn.${var.cluster_domain}"
  }

  service_base_url = "http://${var.cluster_domain}${local.ingress_port}"

  keycloak_bootstrap_users = concat(
    [{
      username           = var.bootstrap_admin.username
      email              = var.bootstrap_admin.email
      password           = var.bootstrap_admin.password
      groups             = ["admins", "vpn-users", "developers"]
      password_temporary = false
    }],
    [
      for user in var.bootstrap_users : {
        username           = user.username
        email              = user.email
        password           = user.password
        groups             = user.groups
        password_temporary = false
      }
    ]
  )

  wireguard_peers = var.wireguard_peers != "" ? var.wireguard_peers : var.bootstrap_admin.username

  # Safely extract credentials from Vault, with fallbacks for plan phase
  # This is defined early so providers can use it
  # Use try() to handle cases where data source doesn't exist or fails
  # Use AWS example credentials format for plan phase (20 char access key, 40 char secret key)
  rgw_credentials = try(
    jsondecode(try(data.vault_kv_secret_v2.rgw_credentials.data_json, "{}")),
    {
      access_key = "AKIAIOSFODNN7EXAMPLE"                     # AWS example format (20 chars)
      secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" # AWS example format (40 chars)
      endpoint   = try(module.rook_ceph.rgw_endpoint, "http://rgw-service.rook-ceph.svc.cluster.local:80")
      region     = "us-east-1"
    }
  )
}

# Vault provider — requires `kubectl port-forward svc/vault 8200:8200 -n vault` during apply
provider "vault" {
  address          = "http://127.0.0.1:8200"
  token            = "root"
  skip_tls_verify  = true
  skip_child_token = true
}

# AWS provider for S3 bucket management (using RGW endpoint)
# Credentials come from environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
# These are set after foundation layer (bootstrap) completes
provider "aws" {
  alias = "rgw"

  # RGW endpoint (ClusterIP service - accessible from within cluster)
  endpoints {
    s3 = local.rgw_credentials.endpoint
  }

  # Credentials from environment variables (set after bootstrap)
  # During Stage 1, these won't be set - that's OK, S3 buckets are excluded
  # During Stage 2, these must be set before running apply

  # Region (required by AWS provider but ignored by RGW)
  region = local.rgw_credentials.region

  # S3-compatible API settings for RGW
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true

  # Prevent credential file lookups and IMDS access
  shared_credentials_files = []
  shared_config_files      = []

  # Explicitly disable EC2 IMDS
  ec2_metadata_service_endpoint      = "http://169.254.169.254"
  ec2_metadata_service_endpoint_mode = "IPv4"
}

# ============================================================================
# DEBUGGING: Comment/uncomment modules as needed for debugging
# ============================================================================
# To disable a module, comment out the entire module block (from "module" to "}")
# To enable it again, uncomment the block.
#
# Recommended order for incremental debugging:
# 1. Foundation Layer: Rook-Ceph (storage), Vault, RGW Bootstrap
# 2. Infrastructure Layer: WireGuard VPN, Ingress, Cert-Manager
# 3. Observability Layer: Prometheus, Grafana, Loki, Tempo
# 4. Application Layer: GitLab, Argo CD
# (Temporal is disabled for first release — uncomment when needed)

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

# ============================================================================
# FOUNDATION LAYER
# ============================================================================

# Rook-Ceph storage - provides block and object storage
# Note: For local/kind, you may need to configure loop devices or mounted volumes
# Example: sudo losetup -fP /path/to/disk.img (creates /dev/loop0, /dev/loop1, etc.)
module "rook_ceph" {
  source = "../../modules/rook-ceph"

  cluster_name = local.cluster_name
  environment  = local.environment

  # SAFETY: use_all_nodes = false + explicit storage_nodes prevents Rook from scanning
  # and accidentally formatting real block devices on the host.
  # Each worker node gets a dedicated loop device backed by a sparse image file
  # (created by the null_resource.setup_osd_loop_devices in rook-data-dir.tf).
  # Image files live at /var/lib/rook/<device-basename>.img (e.g. loop10.img).
  # Rook v1.20+ uses loop devices backed by per-node sparse images (see rook-data-dir.tf).
  use_all_nodes             = false
  create_loop_devices       = true
  loop_device_image_size_gb = 10
  storage_nodes = [
    { name = "local-worker", devices = ["loop10"] },
    { name = "local-worker2", devices = ["loop11"] },
    { name = "local-worker3", devices = ["loop12"] },
  ]

  # Single MON for kind: with 3 workers and 3 MONs, MGR cannot schedule (daemon ID anti-affinity).
  mon_count        = 1
  mgr_count        = 1
  rgw_instances    = 1
  replication_size = 1 # Local dev only — maximises usable space on small VPS loop files

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
  osd_recovery_op_priority = 5
  osd_max_backfills        = 1

  # Dashboard enabled for local debugging
  dashboard_enabled = true
  # Monitoring disabled initially - will be enabled after Prometheus Operator is installed
  # Rook tries to create ServiceMonitors during MGR startup, which fails if Prometheus Operator CRDs don't exist
  # Once observability stack (including Prometheus Operator) is installed, monitoring can be re-enabled
  monitoring_enabled = false
  # Prometheus Operator dependency removed to avoid circular dependency with observability module
  # TODO: Re-enable monitoring_enabled = true after observability stack is installed
  prometheus_operator_dependency = null
}

# ============================================================================
# INFRASTRUCTURE LAYER
# ============================================================================

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

  cluster_name                   = local.cluster_name
  environment                    = local.environment
  service_type                   = "NodePort"
  node_port_http                 = 30080
  node_port_https                = 30443
  replica_count                  = 1
  enable_metrics                 = true
  prometheus_operator_dependency = null # Avoid circular dep with observability/keycloak; enable after stack is up
}

# Keycloak — central identity provider (users, groups, SSO)
module "keycloak" {
  source = "../../modules/keycloak"

  cluster_name = local.cluster_name
  environment  = local.environment

  keycloak_host           = local.hosts.auth
  ingress_port_suffix     = local.ingress_port
  enable_tls              = false
  vpn_cidr                = "10.8.0.0/24"
  restrict_to_vpn         = true
  admin_username          = var.keycloak_admin_username
  admin_password          = var.keycloak_admin_password
  bootstrap_users         = local.keycloak_bootstrap_users
  storage_class           = module.rook_ceph.storage_class_name
  postgresql_storage_size = "2Gi"

  oidc_clients = {
    gitlab_redirect_uri  = "http://${local.hosts.scm}${local.ingress_port}/users/auth/openid_connect/callback"
    argocd_redirect_uri  = "http://${local.hosts.argocd}${local.ingress_port}/auth/callback"
    grafana_redirect_uri = "http://${local.hosts.grafana}${local.ingress_port}/login/generic_oauth"
  }

  depends_on = [module.ingress] # Ingress controller must exist before Keycloak ingress resource
}

# ============================================================================
# OBSERVABILITY LAYER
# ============================================================================

# Observability stack (Prometheus, Grafana, Loki, Tempo)
# Note: S3 buckets should be created using risson/rgw provider or manually via kubectl
# TODO: Use risson/rgw provider for S3 bucket management instead of AWS provider
module "observability" {
  source = "../../modules/observability"

  cluster_name            = local.cluster_name
  environment             = local.environment
  grafana_ingress_enabled = true
  grafana_ingress_host    = local.hosts.grafana
  grafana_enable_tls      = false # TLS not needed for local
  prometheus_storage_size = "3Gi"
  prometheus_retention    = "7d"
  grafana_storage_size    = "1Gi"
  loki_storage_size       = "1Gi"
  tempo_storage_size      = "2Gi"
  storage_class           = module.rook_ceph.storage_class_name
  loki_deployment_mode    = "scalable" # Use scalable mode with Rook-Ceph RGW S3
  loki_object_storage = {
    type             = "s3"
    bucket           = "loki-logs-local"
    region           = "us-east-1"
    endpoint         = module.rook_ceph.rgw_endpoint
    access_key       = nonsensitive(module.rook_ceph.rgw_access_key)
    secret_key       = nonsensitive(module.rook_ceph.rgw_secret_key)
    force_path_style = true
  }

  oidc = {
    issuer_url    = module.keycloak.issuer_url
    client_id     = module.keycloak.client_ids.grafana
    client_secret = module.keycloak.client_secrets.grafana
  }

  vpn_cidr        = module.wireguard.vpn_subnet
  restrict_to_vpn = true

  depends_on = [module.rook_ceph, module.keycloak, module.wireguard]
}

# ============================================================================
# APPLICATION LAYER
# ============================================================================

# Argo CD
module "argocd" {
  source = "../../modules/argocd"

  cluster_name    = local.cluster_name
  environment     = local.environment
  replica_count   = 1
  enable_ha       = false
  ingress_enabled = true
  ingress_host    = local.hosts.argocd
  enable_tls      = false # TLS not needed for local

  oidc = {
    issuer_url    = module.keycloak.issuer_url
    client_id     = module.keycloak.client_ids.argocd
    client_secret = module.keycloak.client_secrets.argocd
    redirect_url  = "http://${local.hosts.argocd}${local.ingress_port}/auth/callback"
  }

  vpn_cidr        = module.wireguard.vpn_subnet
  restrict_to_vpn = true

  depends_on = [module.keycloak, module.wireguard]
}

# Temporal — disabled for first release (workflow orchestration comes later)
# module "temporal" {
#   source = "../../modules/temporal"
#
#   cluster_name               = local.cluster_name
#   environment                = local.environment
#   replica_count              = 1
#   enable_ha                  = false
#   ingress_host               = "temporal.local"
#   enable_tls                 = false
#   temporal_namespaces        = ["data-platform", "trading-platform"]
#   postgresql_storage_size    = "5Gi"
#   elasticsearch_storage_size = "5Gi"
# }

# WireGuard VPN — required for secure access to GitLab and other web services
module "wireguard" {
  source = "../../modules/wireguard"

  cluster_name = local.cluster_name
  environment  = local.environment

  server_url    = local.hosts.vpn # Point vpn.maze.local to VPS IP in /etc/hosts
  service_type  = "NodePort"
  node_port     = 31820
  vpn_subnet    = "10.8.0.0/24"
  peers         = local.wireguard_peers
  storage_class = module.rook_ceph.storage_class_name
  storage_size  = "512Mi"

  depends_on = [module.rook_ceph]
}

# GitLab CE — primary application for first release
# Local: bundled PostgreSQL + in-cluster Redis
# Production: OVH managed PostgreSQL + in-cluster Redis on Rook-Ceph
# Object storage: Rook-Ceph RGW (S3-compatible)
# Access: VPN-only via ingress whitelist
module "gitlab" {
  source = "../../modules/gitlab"

  cluster_name    = local.cluster_name
  environment     = local.environment
  gitlab_domain   = local.hosts.scm
  registry_domain = local.hosts.registry
  enable_tls      = false
  vpn_cidr        = module.wireguard.vpn_subnet

  # Local dev: bundled PostgreSQL + in-cluster Redis (production uses OVH PostgreSQL + in-cluster Redis)
  use_external_postgresql = false

  object_storage = {
    endpoint         = module.rook_ceph.rgw_endpoint
    bucket           = "gitlab-storage-local"
    region           = "us-east-1"
    access_key       = nonsensitive(module.rook_ceph.rgw_access_key)
    secret_key       = nonsensitive(module.rook_ceph.rgw_secret_key)
    force_path_style = true
  }

  storage_class           = module.rook_ceph.storage_class_name
  gitaly_storage_size     = "4Gi"
  postgresql_storage_size = "3Gi"
  redis_storage_size      = "1Gi"

  oidc = {
    issuer_url    = module.keycloak.issuer_url
    client_id     = module.keycloak.client_ids.gitlab
    client_secret = module.keycloak.client_secrets.gitlab
    redirect_uri  = "http://${local.hosts.scm}${local.ingress_port}/users/auth/openid_connect/callback"
  }

  depends_on = [
    module.rook_ceph,
    module.ingress,
    module.wireguard,
    module.keycloak,
  ]
}

# HashiCorp Vault - Centralized secret management
module "vault" {
  source = "../../modules/vault"

  cluster_name    = local.cluster_name
  environment     = local.environment
  replica_count   = 1
  enable_ha       = false
  ingress_enabled = true
  ingress_host    = local.hosts.vault
  enable_tls      = false # TLS not needed for local

  # Storage backend - use Kubernetes secrets for dev (ephemeral)
  # For production, use persistent storage with Rook-Ceph RBD
  storage_backend = "kubernetes"
  # Alternative for production: use Rook-Ceph RBD
  # storage_backend = "file"
  # storage_size    = "10Gi"
  # storage_class   = module.rook_ceph.storage_class_name

  vpn_cidr        = module.wireguard.vpn_subnet
  restrict_to_vpn = true

  depends_on = [module.wireguard]
}

# ============================================================================
# RGW BOOTSTRAP - Create/read RGW credentials and store in Vault
# ============================================================================

# Bootstrap module: Reads RGW credentials from Rook-Ceph and stores in Vault
module "rgw_bootstrap" {
  source = "../../modules/rgw-bootstrap"

  rgw_endpoint = module.rook_ceph.rgw_endpoint
  rgw_region   = "us-east-1"

  # Use existing Rook-Ceph created user
  use_existing_rook_user    = true
  rook_rgw_secret_name      = "rook-ceph-object-user-rgw-store-s3-user"
  rook_rgw_secret_namespace = "rook-ceph"

  # Vault configuration
  vault_kv_mount_path  = "secret"
  vault_secret_path    = "rgw/credentials"
  vault_provider_ready = module.vault.helm_release

  depends_on = [
    module.rook_ceph,
    module.vault
  ]
}

# Data source to read credentials from Vault (for AWS provider)
# This reads the credentials stored by the bootstrap module
# Note: This may not exist during plan phase, so we handle it gracefully in locals
data "vault_kv_secret_v2" "rgw_credentials" {
  mount = "secret"
  name  = "rgw/credentials"

  depends_on = [module.rgw_bootstrap]
}

# ============================================================================
# S3 BUCKET MANAGEMENT (using AWS provider with RGW endpoint)
# ============================================================================
#
# These resources are created in the services layer, after foundation layer
# has stored credentials in Vault and they've been exported to environment variables.
#
# Foundation layer: Apply storage + secrets (excludes S3 buckets)
# Services layer: Export credentials, then apply S3 buckets and rest

# Loki logs bucket for observability stack
# Created using AWS provider configured for RGW S3-compatible storage
# Credentials must be available via AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY env vars
resource "aws_s3_bucket" "loki_logs" {
  provider = aws.rgw
  bucket   = "loki-logs-local"

  tags = {
    Name        = "loki-logs-local"
    Environment = local.environment
    ManagedBy   = "opentofu"
    Purpose     = "loki-logs"
  }

  depends_on = [
    module.rgw_bootstrap,
    data.vault_kv_secret_v2.rgw_credentials
  ]
}

resource "aws_s3_bucket" "gitlab_storage" {
  provider = aws.rgw
  bucket   = "gitlab-storage-local"

  tags = {
    Name        = "gitlab-storage-local"
    Environment = local.environment
    ManagedBy   = "opentofu"
    Purpose     = "gitlab-object-storage"
  }

  depends_on = [
    module.rgw_bootstrap,
    data.vault_kv_secret_v2.rgw_credentials
  ]
}

# Add more buckets as needed:
# resource "aws_s3_bucket" "backups" {
#   provider = aws.rgw
#   bucket   = "backups-local"
#   tags = {
#     Name        = "backups-local"
#     Environment = local.environment
#     ManagedBy   = "opentofu"
#   }
#   depends_on = [module.rgw_bootstrap, data.vault_kv_secret_v2.rgw_credentials]
# }


