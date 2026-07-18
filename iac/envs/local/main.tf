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
  environment  = "local"
  cluster_name = "local"
  # HTTPS on standard 443 via VPN → ClusterIP (no NodePort suffix in URLs)
  ingress_port     = ""
  gitlab_http_port = ""

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

  service_scheme   = "https"
  service_base_url = "${local.service_scheme}://${var.cluster_domain}"

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

  wireguard_peers = var.wireguard_peers != "" ? var.wireguard_peers : var.bootstrap_admin.username

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

  # Prefer the explicit apply-time endpoint (port-forward / env override).
  # Do not read endpoint from Vault here: Vault secrets can be deferred when
  # foundation resources drift, which would make the aws.rgw provider unknown
  # and force every S3 bucket to plan as "create" (BucketAlreadyExists).
  rgw_s3_apply_endpoint = coalesce(
    var.rgw_s3_endpoint != "" ? var.rgw_s3_endpoint : null,
    local.rgw_in_cluster_endpoint,
  )

  vault_apply_address = coalesce(
    var.vault_address != "" ? var.vault_address : null,
    "http://vault.vault.svc.cluster.local:8200",
  )
}

provider "vault" {
  address          = local.vault_apply_address
  token            = var.vault_token
  skip_tls_verify  = var.vault_skip_tls_verify
  skip_child_token = true
}

# AWS provider for S3 bucket management (using RGW endpoint)
provider "aws" {
  alias = "rgw"

  endpoints {
    s3 = local.rgw_s3_apply_endpoint
  }

  # Credentials from environment variables (set after bootstrap)
  # During Stage 1, these won't be set - that's OK, S3 buckets are excluded
  # During Stage 2, these must be set before running apply

  # Region is required by the AWS provider but ignored by RGW. Keep it static so
  # provider config cannot become unknown when Vault credential datasources defer.
  region = "us-east-1"

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
  # Kind/local: per-node loop devices with ROOK_CEPH_ALLOW_LOOP_DEVICES (see rook-operator-config.tf).
  use_all_nodes       = false
  create_loop_devices = true
  allow_loop_devices  = true
  storage_nodes = [
    { name = "local-worker", devices = ["dm-1"], loop_device = "loop10" },
    { name = "local-worker2", devices = ["dm-2"], loop_device = "loop11" },
    { name = "local-worker3", devices = ["dm-0"], loop_device = "loop12" },
  ]
  local_block_osd_devices   = {}
  storage_class_device_sets = []

  # Single MON for kind: with 3 workers and 3 MONs, MGR cannot schedule (daemon ID anti-affinity).
  mon_count        = 1
  mgr_count        = 1
  rgw_instances    = 1
  replication_size = 1 # Local dev only — single replica on small PVC-backed OSDs

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
  letsencrypt_email  = "" # maze.local cannot use public ACME
  letsencrypt_server = "https://acme-staging-v02.api.letsencrypt.org/directory"
  create_maze_ca     = true # same ClusterIssuer pattern as prod, internal Maze CA
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

  depends_on = [module.cert_manager]
}

# Make *.maze.local resolvable inside the cluster (pods don't have client /etc/hosts).
# Required for server-side OIDC (GitLab/Grafana/Argo → Keycloak at auth.maze.local).
# scm + registry are owned by null_resource.coredns_gitlab_envoy (Envoy ClusterIP), not nginx.
module "cluster_dns" {
  source = "../../modules/cluster-dns"

  hosts = [
    for h in values(local.hosts) : h
    if h != local.hosts.scm && h != local.hosts.registry
  ]

  depends_on = [module.ingress]
}

data "kubernetes_secret" "maze_ca" {
  metadata {
    name      = module.cert_manager.maze_ca_secret_name
    namespace = module.cert_manager.namespace
  }

  depends_on = [module.cert_manager]
}

locals {
  # kubernetes provider returns secret data already base64-decoded in .data
  maze_ca_pem = try(data.kubernetes_secret.maze_ca.data["ca.crt"], "")
}

# Keycloak — central identity provider (users, groups, SSO)
module "keycloak" {
  source = "../../modules/keycloak"

  cluster_name = local.cluster_name
  environment  = local.environment

  keycloak_host           = local.hosts.auth
  ingress_port_suffix     = local.ingress_port
  enable_tls              = true
  tls_cluster_issuer      = module.cert_manager.cluster_issuer_name
  vpn_cidr                = "10.8.0.0/24"
  restrict_to_vpn         = true
  admin_username          = var.keycloak_admin_username
  admin_password          = var.keycloak_admin_password
  bootstrap_users         = local.keycloak_bootstrap_users
  storage_class           = "standard" # local-path; rook-ceph-block SC has immutable duplicate fstype param
  postgresql_storage_size = "2Gi"
  production_mode         = true # HTTPS + x-forwarded headers behind ingress

  oidc_clients = {
    gitlab_redirect_uri  = "https://${local.hosts.scm}/users/auth/openid_connect/callback"
    argocd_redirect_uri  = "https://${local.hosts.argocd}/auth/callback"
    grafana_redirect_uri = "https://${local.hosts.grafana}/login/generic_oauth"
  }

  depends_on = [module.ingress, module.cert_manager]
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
  grafana_enable_tls      = true
  tls_cluster_issuer      = module.cert_manager.cluster_issuer_name
  enable_promtail         = true # inotify limits raised in config/kind-config.yaml
  prometheus_storage_size = "3Gi"
  prometheus_retention    = "7d"
  grafana_storage_size    = "1Gi"
  loki_storage_size       = "1Gi"
  tempo_storage_size      = "2Gi"
  storage_class           = "standard"      # local-path; RBD mount fails on kind (sysfs/udev)
  loki_deployment_mode    = "single-binary" # filesystem on kind; scalable/S3 needs schema_config
  # Chart defaults are 8192 / 1024 — /8 for this VPS
  loki_chunks_cache_memory_mb  = 1024
  loki_results_cache_memory_mb = 128
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
  custom_ca_pem = local.maze_ca_pem

  vpn_cidr        = module.wireguard.vpn_subnet
  restrict_to_vpn = true

  depends_on = [module.rook_ceph, module.keycloak, module.wireguard, module.cluster_dns]
}

# ============================================================================
# APPLICATION LAYER
# ============================================================================

# Argo CD
module "argocd" {
  source = "../../modules/argocd"

  cluster_name       = local.cluster_name
  environment        = local.environment
  replica_count      = 1
  enable_ha          = false
  ingress_enabled    = true
  ingress_host       = local.hosts.argocd
  enable_tls         = true
  tls_cluster_issuer = module.cert_manager.cluster_issuer_name

  oidc = {
    issuer_url    = module.keycloak.issuer_url
    client_id     = module.keycloak.client_ids.argocd
    client_secret = module.keycloak.client_secrets.argocd
    redirect_url  = "https://${local.hosts.argocd}/auth/callback"
    root_ca_pem   = local.maze_ca_pem
  }

  vpn_cidr        = module.wireguard.vpn_subnet
  restrict_to_vpn = true

  depends_on = [module.keycloak, module.wireguard, module.cluster_dns]
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
  storage_class = "standard" # local-path; avoid rook-ceph-block until Ceph OSDs are ready
  storage_size  = "512Mi"

  depends_on = [module.rook_ceph]
}

# GitLab CE — primary application for first release
# Local: bundled PostgreSQL + in-cluster Redis
# Production: OVH managed PostgreSQL + in-cluster Redis on Rook-Ceph
# Object storage: Rook-Ceph RGW (S3-compatible)
# Access: VPN-only via Envoy SecurityPolicy (CIDR allowlist)
module "gitlab" {
  source = "../../modules/gitlab"

  cluster_name       = local.cluster_name
  environment        = local.environment
  gitlab_domain      = local.hosts.scm
  registry_domain    = local.hosts.registry
  enable_tls         = true
  tls_cluster_issuer = module.cert_manager.cluster_issuer_name
  vpn_cidr           = module.wireguard.vpn_subnet

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

  # kind nodes mount /sys read-only, so krbd RBD map fails ("Read-only file system").
  # Use local-path for GitLab PVCs locally; production uses rook-ceph-block(+encrypted).
  # Encryption plumbing (SC + Vault + CSI secrets) is still applied for verification.
  storage_class                 = "standard"
  gitaly_storage_class          = "standard"
  storage_encryption_passphrase = module.rook_ceph.rbd_luks_passphrase
  gitaly_storage_size           = "4Gi"
  postgresql_storage_size       = "3Gi"
  valkey_storage_size           = "1Gi"

  install_gitlab_runner  = true
  gitlab_runner_replicas = 1

  # Light local profile — reclaim RAM on a small VPS
  webservice_min_replicas     = 1
  webservice_max_replicas     = 1
  webservice_worker_processes = 1
  shell_min_replicas          = 1
  shell_max_replicas          = 1
  kas_min_replicas            = 1
  kas_max_replicas            = 1
  registry_min_replicas       = 1
  registry_max_replicas       = 1

  oidc = {
    issuer_url    = module.keycloak.issuer_url
    client_id     = module.keycloak.client_ids.gitlab
    client_secret = module.keycloak.client_secrets.gitlab
    redirect_uri  = "https://${local.hosts.scm}/users/auth/openid_connect/callback"
  }
  sso_admin_username = var.bootstrap_admin.username
  sso_admin_email    = var.bootstrap_admin.email
  custom_ca_pem      = local.maze_ca_pem

  depends_on = [
    module.rook_ceph,
    module.ingress,
    module.wireguard,
    module.keycloak,
    module.cert_manager,
    module.cluster_dns,
  ]
}

# GitLab uses Envoy Gateway, not nginx. Own scm + registry DNS → Envoy ClusterIP.
resource "null_resource" "coredns_gitlab_envoy" {
  triggers = {
    gateway_ip = module.gitlab.gateway_cluster_ip
    scm        = local.hosts.scm
    registry   = local.hosts.registry
    generation = "2"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export GW='${module.gitlab.gateway_cluster_ip}'
      export SCM='${local.hosts.scm}'
      export REG='${local.hosts.registry}'
      python3 - <<'PY'
import re, subprocess, json, os
gw, scm, reg = os.environ["GW"], os.environ["SCM"], os.environ["REG"]
if not gw or gw == "None":
    raise SystemExit("coredns_gitlab_envoy: empty gateway IP")
cm = json.loads(subprocess.check_output(["kubectl", "-n", "kube-system", "get", "cm", "coredns", "-o", "json"]))
corefile = cm["data"]["Corefile"]

def upsert(corefile: str, host: str, ip: str) -> str:
    pattern = rf"(?m)^(\s*)[0-9.]+\s+{re.escape(host)}\s*$"
    if re.search(pattern, corefile):
        return re.sub(pattern, rf"\g<1>{ip} {host}", corefile)
    # Insert before "fallthrough" inside hosts { }
    return re.sub(
        r"(?m)^(\s*)fallthrough\s*$",
        rf"\g<1>{ip} {host}\n\g<1>fallthrough",
        corefile,
        count=1,
    )

for host in (scm, reg):
    corefile = upsert(corefile, host, gw)
cm["data"]["Corefile"] = corefile
meta = cm.setdefault("metadata", {})
for k in ("resourceVersion", "uid", "creationTimestamp", "managedFields", "generation"):
    meta.pop(k, None)
subprocess.run(["kubectl", "apply", "-f", "-"], input=json.dumps(cm), text=True, check=True)
print(f"coredns_gitlab_envoy: {scm}, {reg} -> {gw}")
PY
      kubectl -n kube-system rollout restart deploy/coredns
      kubectl -n kube-system rollout status deploy/coredns --timeout=120s
    EOT
  }

  depends_on = [module.cluster_dns, module.gitlab]
}

# HashiCorp Vault - Centralized secret management
module "vault" {
  source = "../../modules/vault"

  cluster_name       = local.cluster_name
  environment        = local.environment
  replica_count      = 1
  enable_ha          = false
  ingress_enabled    = true
  ingress_host       = local.hosts.vault
  enable_tls         = true
  tls_cluster_issuer = module.cert_manager.cluster_issuer_name
  enable_server_tls  = false # TLS terminates at ingress

  # Storage backend - use Kubernetes secrets for dev (ephemeral)
  # For production, use persistent storage with Rook-Ceph RBD
  storage_backend = "kubernetes"
  # Alternative for production: use Rook-Ceph RBD
  # storage_backend = "file"
  # storage_size    = "10Gi"
  # storage_class   = module.rook_ceph.storage_class_name

  vpn_cidr        = module.wireguard.vpn_subnet
  restrict_to_vpn = true

  depends_on = [module.wireguard, module.cert_manager]
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

# Durable copy of the RBD LUKS master passphrase (K8s Secrets are the runtime source for CSI).
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

# Cosign keypair for signing algo images in GitLab Container Registry
module "cosign_keys" {
  source = "../../modules/cosign-keys"

  vault_kv_mount    = "secret"
  vault_secret_path = "cosign/gitlab"

  depends_on = [module.vault]
}

data "vault_kv_secret_v2" "cosign" {
  mount = "secret"
  name  = "cosign/gitlab"

  depends_on = [module.cosign_keys]
}

# Admission: require cosign signatures in namespaces labeled maze.io/require-signed-images=true
module "kyverno" {
  source = "../../modules/kyverno"

  environment       = local.environment
  cosign_public_key = data.vault_kv_secret_v2.cosign.data["public_key"]
  registry_hosts    = [local.hosts.registry]

  depends_on = [module.cosign_keys]
}

# Auto-wire COSIGN_* CI variables onto GitLab group maze/algos (from Vault)
module "gitlab_ci_cosign" {
  source = "../../modules/gitlab-ci-cosign"

  gitlab_namespace  = module.gitlab.namespace
  group_full_path   = "maze/algos"
  vault_kv_mount    = "secret"
  vault_secret_path = "cosign/gitlab"

  depends_on = [
    module.gitlab,
    module.cosign_keys,
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
  provider      = aws.rgw
  bucket        = "loki-logs-local"
  force_destroy = true

  tags = {
    Name        = "loki-logs-local"
    Environment = local.environment
    ManagedBy   = "opentofu"
    Purpose     = "loki-logs"
  }

  depends_on = [module.rgw_bootstrap]
}

resource "aws_s3_bucket" "gitlab_storage" {
  provider      = aws.rgw
  bucket        = "gitlab-storage-local"
  force_destroy = true

  tags = {
    Name        = "gitlab-storage-local"
    Environment = local.environment
    ManagedBy   = "opentofu"
    Purpose     = "gitlab-object-storage"
  }

  depends_on = [module.rgw_bootstrap]
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


