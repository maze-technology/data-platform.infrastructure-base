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
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 3.23"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "kubernetes" {
  config_path    = pathexpand(var.kubeconfig_path)
  config_context = var.kubeconfig_context
}

provider "helm" {
  kubernetes {
    config_path    = pathexpand(var.kubeconfig_path)
    config_context = var.kubeconfig_context
  }
}

locals {
  environment  = "production"
  cluster_name = var.cluster_name

  cluster_domain = var.cluster_domain

  hosts = {
    auth     = "auth.${var.cluster_domain}"
    scm      = "scm.${var.cluster_domain}"
    registry = "registry.scm.${var.cluster_domain}"
    grafana  = "grafana.${var.cluster_domain}"
    argocd   = "argocd.${var.cluster_domain}"
    vault    = "vault.${var.cluster_domain}"
    vpn      = "vpn.${var.cluster_domain}"
  }

  keycloak_bootstrap_users = concat(
    [{
      username           = var.bootstrap_admin.username
      email              = var.bootstrap_admin.email
      password           = var.bootstrap_admin.password
      groups             = ["admins", "vpn-users"]
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

  wireguard_peers  = var.wireguard_peers != "" ? var.wireguard_peers : var.bootstrap_admin.username
  wireguard_server = var.wireguard_server_url != "" ? var.wireguard_server_url : local.hosts.vpn

  rgw_in_cluster_endpoint = try(module.rook_ceph.rgw_endpoint, "http://rgw-service.rook-ceph.svc.cluster.local:80")

  rgw_credentials = try(
    jsondecode(try(data.vault_kv_secret_v2.rgw_credentials.data_json, "{}")),
    {
      access_key = "AKIAIOSFODNN7EXAMPLE"
      secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      endpoint   = local.rgw_in_cluster_endpoint
      region     = "us-east-1"
    }
  )

  # Prefer the explicit apply-time endpoint. Avoid Vault for provider config so
  # deferred credential reads cannot make the aws.rgw provider unknown.
  rgw_s3_apply_endpoint = coalesce(
    var.rgw_s3_endpoint != "" ? var.rgw_s3_endpoint : null,
    local.rgw_in_cluster_endpoint,
  )
}

provider "vault" {
  address          = var.vault_address
  skip_tls_verify  = var.vault_skip_tls_verify
  skip_child_token = true
  token            = var.vault_token
}

provider "aws" {
  alias = "rgw"

  endpoints {
    s3 = local.rgw_s3_apply_endpoint
  }

  # Static region: required by AWS provider, ignored by RGW. Must not come from
  # Vault or provider config becomes unknown when credential datasources defer.
  region                      = "us-east-1"
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  shared_credentials_files    = []
  shared_config_files         = []
}

# ============================================================================
# FOUNDATION LAYER
# ============================================================================

# Rook-Ceph — block + object storage on OVH bare metal
# SAFETY: devices are explicitly listed per node. Never use the OS disk.
# Set storage_nodes in terraform.tfvars to match your 3 server hostnames + disks.
module "rook_ceph" {
  source = "../../modules/rook-ceph"

  cluster_name = local.cluster_name
  environment  = local.environment

  use_all_nodes       = false
  storage_nodes       = var.storage_nodes
  create_loop_devices = false

  mon_count        = 3
  mgr_count        = 1
  rgw_instances    = 2
  replication_size = 3

  osd_recovery_max_active  = 3
  osd_recovery_op_priority = 3
  osd_max_backfills        = 1

  monitoring_enabled             = false
  prometheus_operator_dependency = null
}

module "vault" {
  source = "../../modules/vault"

  cluster_name    = local.cluster_name
  environment     = local.environment
  replica_count   = 3
  enable_ha       = true
  ingress_enabled = true
  ingress_host    = local.hosts.vault
  enable_tls      = true

  storage_backend = "file"
  storage_size    = "10Gi"
  storage_class   = module.rook_ceph.storage_class_name

  vpn_cidr        = var.vpn_subnet
  restrict_to_vpn = true
}

module "rgw_bootstrap" {
  source = "../../modules/rgw-bootstrap"

  rgw_endpoint = module.rook_ceph.rgw_endpoint
  rgw_region   = "us-east-1"

  use_existing_rook_user    = true
  rook_rgw_secret_name      = "rook-ceph-object-user-rgw-store-s3-user"
  rook_rgw_secret_namespace = "rook-ceph"

  vault_kv_mount_path  = "secret"
  vault_secret_path    = "rgw/credentials"
  vault_provider_ready = module.vault.helm_release

  depends_on = [
    module.rook_ceph,
    module.vault,
  ]
}

module "cosign_keys" {
  source = "../../modules/cosign-keys"

  vault_kv_mount    = "secret"
  vault_secret_path = "cosign/gitlab"

  depends_on = [module.vault]
}

resource "vault_kv_secret_v2" "rbd_luks" {
  mount = "secret"
  name  = module.rook_ceph.encryption_vault_secret_name

  data_json = jsonencode({
    encryptionPassphrase = module.rook_ceph.rbd_luks_passphrase
    kms_id               = module.rook_ceph.encryption_kms_id
    note                 = "Master passphrase for Ceph-CSI metadata KMS (PVC LUKS)"
  })

  depends_on = [module.vault, module.rook_ceph]
}

data "vault_kv_secret_v2" "rgw_credentials" {
  mount = "secret"
  name  = "rgw/credentials"

  depends_on = [module.rgw_bootstrap]
}

# ============================================================================
# INFRASTRUCTURE LAYER
# ============================================================================

module "cert_manager" {
  source = "../../modules/cert-manager"

  cluster_name       = local.cluster_name
  environment        = local.environment
  letsencrypt_email  = var.letsencrypt_email
  letsencrypt_server = "https://acme-v02.api.letsencrypt.org/directory"
  replica_count      = 3
}

module "ingress" {
  source = "../../modules/ingress"

  cluster_name                   = local.cluster_name
  environment                    = local.environment
  service_type                   = "LoadBalancer"
  replica_count                  = 3
  enable_metrics                 = true
  prometheus_operator_dependency = null
}

module "keycloak" {
  source = "../../modules/keycloak"

  cluster_name = local.cluster_name
  environment  = local.environment

  keycloak_host   = local.hosts.auth
  enable_tls      = true
  vpn_cidr        = var.vpn_subnet
  restrict_to_vpn = true
  admin_username  = var.keycloak_admin_username
  admin_password  = var.keycloak_admin_password
  bootstrap_users = local.keycloak_bootstrap_users
  replica_count   = 2
  storage_class   = module.rook_ceph.storage_class_name

  use_external_database = true
  postgresql_host       = var.keycloak_postgresql_host
  postgresql_password   = var.keycloak_postgresql_password

  oidc_clients = {
    gitlab_redirect_uri  = "https://${local.hosts.scm}/users/auth/openid_connect/callback"
    argocd_redirect_uri  = "https://${local.hosts.argocd}/auth/callback"
    grafana_redirect_uri = "https://${local.hosts.grafana}/login/generic_oauth"
  }

  depends_on = [module.ingress]
}

module "wireguard" {
  source = "../../modules/wireguard"

  cluster_name = local.cluster_name
  environment  = local.environment

  server_url   = local.wireguard_server
  service_type = "LoadBalancer"
  vpn_subnet   = var.vpn_subnet
  peers        = local.wireguard_peers

  storage_class = module.rook_ceph.storage_class_name

  depends_on = [module.rook_ceph]
}

# ============================================================================
# OBSERVABILITY LAYER
# ============================================================================

module "observability" {
  source = "../../modules/observability"

  cluster_name            = local.cluster_name
  environment             = local.environment
  grafana_ingress_enabled = true
  grafana_ingress_host    = local.hosts.grafana
  grafana_enable_tls      = true
  prometheus_storage_size = "500Gi"
  grafana_storage_size    = "100Gi"
  loki_storage_size       = "1Ti"
  storage_class           = module.rook_ceph.storage_class_name
  loki_deployment_mode    = "scalable"
  loki_object_storage = {
    type             = "s3"
    bucket           = "loki-logs-production"
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

  vpn_cidr        = var.vpn_subnet
  restrict_to_vpn = true

  depends_on = [module.rook_ceph, module.keycloak]
}

# ============================================================================
# APPLICATION LAYER
# ============================================================================

module "argocd" {
  source = "../../modules/argocd"

  cluster_name    = local.cluster_name
  environment     = local.environment
  replica_count   = 3
  enable_ha       = true
  ingress_enabled = true
  ingress_host    = local.hosts.argocd
  enable_tls      = true

  oidc = {
    issuer_url    = module.keycloak.issuer_url
    client_id     = module.keycloak.client_ids.argocd
    client_secret = module.keycloak.client_secrets.argocd
    redirect_url  = "https://${local.hosts.argocd}/auth/callback"
  }

  vpn_cidr        = var.vpn_subnet
  restrict_to_vpn = true

  depends_on = [module.keycloak]
}

module "gitlab" {
  source = "../../modules/gitlab"

  cluster_name    = local.cluster_name
  environment     = local.environment
  gitlab_domain   = local.hosts.scm
  registry_domain = local.hosts.registry
  enable_tls      = true
  vpn_cidr        = var.vpn_subnet

  use_external_postgresql = true
  postgresql_host         = var.gitlab_postgresql_host
  postgresql_password     = var.gitlab_postgresql_password

  object_storage = {
    endpoint         = module.rook_ceph.rgw_endpoint
    bucket           = "gitlab-storage-production"
    region           = "us-east-1"
    access_key       = nonsensitive(module.rook_ceph.rgw_access_key)
    secret_key       = nonsensitive(module.rook_ceph.rgw_secret_key)
    force_path_style = true
  }

  storage_class                  = module.rook_ceph.storage_class_name
  gitaly_storage_class           = module.rook_ceph.encrypted_storage_class_name
  storage_encryption_passphrase  = module.rook_ceph.rbd_luks_passphrase
  gitaly_storage_size            = "100Gi"
  valkey_storage_size     = "8Gi"
  webservice_min_replicas = 2
  webservice_max_replicas = 4

  oidc = {
    issuer_url    = module.keycloak.issuer_url
    client_id     = module.keycloak.client_ids.gitlab
    client_secret = module.keycloak.client_secrets.gitlab
    redirect_uri  = "https://${local.hosts.scm}/users/auth/openid_connect/callback"
  }
  sso_admin_username = var.bootstrap_admin.username
  sso_admin_email    = var.bootstrap_admin.email

  depends_on = [
    module.rook_ceph,
    module.ingress,
    module.wireguard,
    module.keycloak,
  ]
}

# ============================================================================
# S3 BUCKETS (created after foundation layer — use make apply)
# ============================================================================

resource "aws_s3_bucket" "loki_logs" {
  provider = aws.rgw
  bucket   = "loki-logs-production"

  tags = {
    Name        = "loki-logs-production"
    Environment = local.environment
    ManagedBy   = "opentofu"
    Purpose     = "loki-logs"
  }

  depends_on = [module.rgw_bootstrap]
}

resource "aws_s3_bucket" "gitlab_storage" {
  provider = aws.rgw
  bucket   = "gitlab-storage-production"

  tags = {
    Name        = "gitlab-storage-production"
    Environment = local.environment
    ManagedBy   = "opentofu"
    Purpose     = "gitlab-object-storage"
  }

  depends_on = [module.rgw_bootstrap]
}
