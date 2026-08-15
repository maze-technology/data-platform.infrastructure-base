# =============================================================================
# Locals — hosts, bootstrap users, resolved storage classes / bucket names
# =============================================================================

locals {
  hosts = {
    auth     = "auth.${var.cluster_domain}"
    scm      = "scm.${var.cluster_domain}"
    registry = "registry.scm.${var.cluster_domain}"
    crates   = "crates.${var.cluster_domain}"
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

  rook_resource_requests = var.rook_resource_requests != null ? var.rook_resource_requests : {
    operator = { cpu = "100m", memory = "128Mi" }
    mon      = { cpu = "500m", memory = "2Gi" }
    mgr      = { cpu = "500m", memory = "512Mi" }
    osd      = { cpu = "1", memory = "2Gi" }
    rgw      = { cpu = "500m", memory = "512Mi" }
  }

  rook_resource_limits = var.rook_resource_limits != null ? var.rook_resource_limits : {
    operator = { cpu = "500m", memory = "512Mi" }
    mon      = { cpu = "1000m", memory = "4Gi" }
    mgr      = { cpu = "1000m", memory = "1Gi" }
    osd      = { cpu = "2", memory = "4Gi" }
    rgw      = { cpu = "1000m", memory = "1Gi" }
  }

  rook_storage_class           = module.rook_ceph.storage_class_name
  rook_encrypted_storage_class = module.rook_ceph.encrypted_storage_class_name

  wireguard_storage_class     = var.wireguard_storage_class != "" ? var.wireguard_storage_class : local.rook_storage_class
  keycloak_storage_class      = var.keycloak_storage_class != "" ? var.keycloak_storage_class : local.rook_storage_class
  vault_storage_class         = var.vault_storage_class != "" ? var.vault_storage_class : local.rook_storage_class
  observability_storage_class = var.observability_storage_class != "" ? var.observability_storage_class : local.rook_storage_class
  gitlab_storage_class        = var.gitlab_storage_class != "" ? var.gitlab_storage_class : local.rook_storage_class
  gitaly_storage_class        = var.gitaly_storage_class != "" ? var.gitaly_storage_class : local.rook_encrypted_storage_class

  loki_bucket_name     = var.loki_bucket_name != "" ? var.loki_bucket_name : "loki-logs-${var.environment}"
  gitlab_bucket_name   = var.gitlab_bucket_name != "" ? var.gitlab_bucket_name : "gitlab-storage-${var.environment}"
  kellnr_bucket_name   = var.kellnr_bucket_name != "" ? var.kellnr_bucket_name : "kellnr-crates-${var.environment}"
  kellnr_storage_class = var.kellnr_storage_class != "" ? var.kellnr_storage_class : local.rook_storage_class

  # kubernetes provider returns secret data already base64-decoded in .data
  maze_ca_pem = var.create_maze_ca ? try(data.kubernetes_secret.maze_ca[0].data["ca.crt"], "") : ""
}

# ============================================================================
# OPTIONAL: kind cluster probe (local only)
# ============================================================================

module "cluster" {
  count  = var.enable_kind_cluster ? 1 : 0
  source = "./iac/modules/cluster"

  cluster_name = var.cluster_name
  environment  = var.environment
  cluster_type = "kind"
  node_count   = 1
}

# ============================================================================
# FOUNDATION LAYER
# ============================================================================

module "rook_ceph" {
  source = "./iac/modules/rook-ceph"

  cluster_name = var.cluster_name
  environment  = var.environment

  use_all_nodes             = var.use_all_nodes
  create_loop_devices       = var.create_loop_devices
  allow_loop_devices        = var.allow_loop_devices
  storage_nodes             = var.storage_nodes
  local_block_osd_devices   = var.local_block_osd_devices
  storage_class_device_sets = var.storage_class_device_sets

  mon_count        = var.mon_count
  mgr_count        = var.mgr_count
  rgw_instances    = var.rgw_instances
  replication_size = var.replication_size

  resource_requests = local.rook_resource_requests
  resource_limits   = local.rook_resource_limits

  osd_recovery_max_active  = var.osd_recovery_max_active
  osd_recovery_op_priority = var.osd_recovery_op_priority
  osd_max_backfills        = var.osd_max_backfills

  dashboard_enabled              = var.rook_dashboard_enabled
  monitoring_enabled             = var.rook_monitoring_enabled
  prometheus_operator_dependency = null
}

module "vault" {
  source = "./iac/modules/vault"

  cluster_name       = var.cluster_name
  environment        = var.environment
  replica_count      = var.vault_replica_count
  enable_ha          = var.vault_enable_ha
  ingress_enabled    = true
  ingress_host       = local.hosts.vault
  enable_tls         = true
  tls_cluster_issuer = module.cert_manager.cluster_issuer_name
  enable_server_tls  = var.vault_enable_server_tls

  storage_backend = var.vault_storage_backend
  storage_size    = var.vault_storage_size
  storage_class   = local.vault_storage_class

  vpn_cidr        = module.wireguard.vpn_subnet
  restrict_to_vpn = var.restrict_to_vpn

  depends_on = [module.wireguard, module.cert_manager]
}

module "rgw_bootstrap" {
  source = "./iac/modules/rgw-bootstrap"

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

module "cosign_keys" {
  source = "./iac/modules/cosign-keys"

  vault_kv_mount    = "secret"
  vault_secret_path = "cosign/gitlab"

  depends_on = [module.vault]
}

data "vault_kv_secret_v2" "cosign" {
  mount = "secret"
  name  = "cosign/gitlab"

  depends_on = [module.cosign_keys]
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
  source = "./iac/modules/cert-manager"

  cluster_name       = var.cluster_name
  environment        = var.environment
  letsencrypt_email  = var.letsencrypt_email
  letsencrypt_server = var.letsencrypt_server
  create_maze_ca     = var.create_maze_ca
  replica_count      = var.cert_manager_replica_count

  acme_solver                   = var.acme_solver
  ovh_application_key           = var.ovh_dns_application_key
  ovh_application_secret        = var.ovh_dns_application_secret
  ovh_consumer_key              = var.ovh_dns_consumer_key
  ovh_endpoint_name             = var.ovh_dns_endpoint_name
  ovh_dns_webhook_group_name    = var.ovh_dns_webhook_group_name
  ovh_dns_webhook_chart_version = var.ovh_dns_webhook_chart_version
}

module "ingress" {
  source = "./iac/modules/ingress"

  cluster_name                   = var.cluster_name
  environment                    = var.environment
  service_type                   = var.ingress_service_type
  node_port_http                 = var.ingress_node_port_http
  node_port_https                = var.ingress_node_port_https
  replica_count                  = var.ingress_replica_count
  enable_metrics                 = var.enable_ingress_metrics
  prometheus_operator_dependency = null

  depends_on = [module.cert_manager]
}

# Make *.<cluster_domain> resolvable inside the cluster and for WireGuard clients
# (peer DNS = CoreDNS). All app hostnames map to ingress-nginx ClusterIP.
# When GitLab Envoy Gateway is enabled, coredns_gitlab_envoy overrides scm/registry.
module "cluster_dns" {
  count  = var.enable_cluster_dns ? 1 : 0
  source = "./iac/modules/cluster-dns"

  # Never map vpn.<domain> to the ingress ClusterIP — peers resolve the WireGuard
  # endpoint via public DNS; CoreDNS overriding it to 10.x breaks the tunnel once
  # clients switch DNS to CoreDNS (exclusive resolvconf), which kills all internet.
  hosts = [for h in values(local.hosts) : h if h != local.hosts.vpn]

  depends_on = [module.ingress]
}

data "kubernetes_secret" "maze_ca" {
  count = var.create_maze_ca ? 1 : 0

  metadata {
    name      = module.cert_manager.maze_ca_secret_name
    namespace = module.cert_manager.namespace
  }

  depends_on = [module.cert_manager]
}

module "keycloak" {
  source = "./iac/modules/keycloak"

  cluster_name = var.cluster_name
  environment  = var.environment

  keycloak_host           = local.hosts.auth
  ingress_port_suffix     = var.ingress_port_suffix
  enable_tls              = true
  tls_cluster_issuer      = module.cert_manager.cluster_issuer_name
  vpn_cidr                = var.vpn_subnet
  restrict_to_vpn         = var.restrict_to_vpn
  admin_username          = var.keycloak_admin_username
  admin_password          = var.keycloak_admin_password
  bootstrap_users         = local.keycloak_bootstrap_users
  replica_count           = var.keycloak_replica_count
  storage_class           = local.keycloak_storage_class
  postgresql_storage_size = var.keycloak_postgresql_storage_size
  production_mode         = var.keycloak_production_mode

  use_external_database = var.use_external_keycloak_database
  postgresql_host       = var.keycloak_postgresql_host
  postgresql_port       = var.keycloak_postgresql_port
  postgresql_username   = var.keycloak_postgresql_username
  postgresql_database   = var.keycloak_postgresql_database
  postgresql_password   = var.keycloak_postgresql_password
  postgresql_ssl        = var.keycloak_postgresql_ssl

  oidc_clients = {
    gitlab_redirect_uri  = "https://${local.hosts.scm}/users/auth/openid_connect/callback"
    argocd_redirect_uri  = "https://${local.hosts.argocd}/auth/callback"
    grafana_redirect_uri = "https://${local.hosts.grafana}/login/generic_oauth"
    kellnr_redirect_uri  = "https://${local.hosts.crates}/api/v1/oauth2/callback"
  }

  depends_on = [module.ingress, module.cert_manager]
}

module "wireguard" {
  source = "./iac/modules/wireguard"

  cluster_name = var.cluster_name
  environment  = var.environment

  server_url       = local.wireguard_server
  service_type     = var.wireguard_service_type
  node_port        = var.wireguard_node_port
  vpn_subnet       = var.vpn_subnet
  allowed_ips      = var.wireguard_allowed_ips
  peers            = local.wireguard_peers
  storage_class    = local.wireguard_storage_class
  storage_size     = var.wireguard_storage_size
  peer_dns_domain  = var.cluster_domain

  depends_on = [module.rook_ceph]
}

# ============================================================================
# OBSERVABILITY LAYER
# ============================================================================

module "observability" {
  source = "./iac/modules/observability"

  cluster_name                 = var.cluster_name
  environment                  = var.environment
  grafana_ingress_enabled      = true
  grafana_ingress_host         = local.hosts.grafana
  grafana_enable_tls           = true
  tls_cluster_issuer           = module.cert_manager.cluster_issuer_name
  enable_promtail              = var.enable_promtail
  prometheus_storage_size      = var.prometheus_storage_size
  prometheus_retention         = var.prometheus_retention
  grafana_storage_size         = var.grafana_storage_size
  loki_storage_size            = var.loki_storage_size
  tempo_storage_size           = var.tempo_storage_size
  storage_class                = local.observability_storage_class
  loki_deployment_mode         = var.loki_deployment_mode
  loki_chunks_cache_memory_mb  = var.loki_chunks_cache_memory_mb
  loki_results_cache_memory_mb = var.loki_results_cache_memory_mb
  loki_object_storage = {
    type             = "s3"
    bucket           = local.loki_bucket_name
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
  restrict_to_vpn = var.restrict_to_vpn

  depends_on = [module.rook_ceph, module.keycloak, module.wireguard, module.cluster_dns]
}

# ============================================================================
# APPLICATION LAYER
# ============================================================================

module "argocd" {
  source = "./iac/modules/argocd"

  cluster_name       = var.cluster_name
  environment        = var.environment
  replica_count      = var.argocd_replica_count
  enable_ha          = var.argocd_enable_ha
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
  restrict_to_vpn = var.restrict_to_vpn

  depends_on = [module.keycloak, module.wireguard, module.cluster_dns]
}

# Temporal — disabled for first release (workflow orchestration comes later)
# module "temporal" {
#   source = "./iac/modules/temporal"
#   ...
# }

module "gitlab" {
  source = "./iac/modules/gitlab"

  cluster_name       = var.cluster_name
  environment        = var.environment
  gitlab_domain      = local.hosts.scm
  registry_domain    = local.hosts.registry
  enable_tls         = true
  tls_cluster_issuer = module.cert_manager.cluster_issuer_name
  vpn_cidr           = module.wireguard.vpn_subnet

  use_external_postgresql = var.use_external_gitlab_postgresql
  postgresql_host         = var.gitlab_postgresql_host
  postgresql_port         = var.gitlab_postgresql_port
  postgresql_username     = var.gitlab_postgresql_username
  postgresql_database     = var.gitlab_postgresql_database
  postgresql_password     = var.gitlab_postgresql_password
  postgresql_ssl          = var.gitlab_postgresql_ssl

  object_storage = {
    endpoint         = module.rook_ceph.rgw_endpoint
    bucket           = local.gitlab_bucket_name
    region           = "us-east-1"
    access_key       = nonsensitive(module.rook_ceph.rgw_access_key)
    secret_key       = nonsensitive(module.rook_ceph.rgw_secret_key)
    force_path_style = true
  }

  storage_class                 = local.gitlab_storage_class
  gitaly_storage_class          = local.gitaly_storage_class
  storage_encryption_passphrase = module.rook_ceph.rbd_luks_passphrase
  gitaly_storage_size           = var.gitaly_storage_size
  postgresql_storage_size       = var.gitlab_postgresql_storage_size
  valkey_storage_size           = var.valkey_storage_size

  install_gitlab_runner  = var.install_gitlab_runner
  gitlab_runner_replicas = var.gitlab_runner_replicas

  webservice_min_replicas     = var.webservice_min_replicas
  webservice_max_replicas     = var.webservice_max_replicas
  webservice_worker_processes = var.webservice_worker_processes
  shell_min_replicas          = var.shell_min_replicas
  shell_max_replicas          = var.shell_max_replicas
  kas_min_replicas            = var.kas_min_replicas
  kas_max_replicas            = var.kas_max_replicas
  registry_min_replicas       = var.registry_min_replicas
  registry_max_replicas       = var.registry_max_replicas

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

module "kellnr" {
  count  = var.enable_kellnr ? 1 : 0
  source = "./iac/modules/kellnr"

  cluster_name            = var.cluster_name
  environment             = var.environment
  hostname                = local.hosts.crates
  enable_tls              = true
  tls_cluster_issuer      = module.cert_manager.cluster_issuer_name
  vpn_cidr                = module.wireguard.vpn_subnet
  restrict_to_vpn         = var.restrict_to_vpn
  storage_class           = local.kellnr_storage_class
  postgresql_storage_size = var.kellnr_postgresql_storage_size
  replica_count           = var.kellnr_replica_count

  object_storage = {
    endpoint         = module.rook_ceph.rgw_endpoint
    region           = "us-east-1"
    access_key       = nonsensitive(module.rook_ceph.rgw_access_key)
    secret_key       = nonsensitive(module.rook_ceph.rgw_secret_key)
    force_path_style = true
    crates_bucket    = local.kellnr_bucket_name
  }

  oidc = {
    issuer_url    = module.keycloak.issuer_url
    client_id     = module.keycloak.client_ids.kellnr
    client_secret = module.keycloak.client_secrets.kellnr
  }

  depends_on = [
    module.rook_ceph,
    module.ingress,
    module.wireguard,
    module.keycloak,
    module.cert_manager,
    module.cluster_dns,
    aws_s3_bucket.kellnr_crates,
  ]
}

# GitLab Envoy Gateway path: override scm + registry DNS → Envoy ClusterIP.
# Skipped when Gateway API is disabled (nginx ingress serves scm/registry).
resource "null_resource" "coredns_gitlab_envoy" {
  count = var.enable_cluster_dns && module.gitlab.gateway_cluster_ip != "" ? 1 : 0

  triggers = {
    gateway_ip = module.gitlab.gateway_cluster_ip
    scm        = local.hosts.scm
    registry   = local.hosts.registry
    # Re-patch whenever cluster_dns rewrites Corefile (it omits scm/registry → nginx).
    corefile   = module.cluster_dns[0].corefile
    generation = "3"
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

module "kyverno" {
  source = "./iac/modules/kyverno"

  environment         = var.environment
  cosign_public_key   = data.vault_kv_secret_v2.cosign.data["public_key"]
  registry_hosts      = [local.hosts.registry]
  namespace_label_key = "${var.cluster_domain}/require-signed-images"

  depends_on = [module.cosign_keys]
}

module "gitlab_ci_cosign" {
  source = "./iac/modules/gitlab-ci-cosign"

  gitlab_namespace  = module.gitlab.namespace
  vault_kv_mount    = "secret"
  vault_secret_path = "cosign/gitlab"
  # No default org group (maze removed). Product groups (data-platform, templates)
  # are created outside OpenTofu.

  depends_on = [
    module.gitlab,
    module.cosign_keys,
  ]
}

# ============================================================================
# S3 BUCKETS (AWS provider alias aws.rgw — configured by the consumer)
# ============================================================================

resource "aws_s3_bucket" "loki_logs" {
  provider      = aws.rgw
  bucket        = local.loki_bucket_name
  force_destroy = var.s3_force_destroy

  tags = {
    Name        = local.loki_bucket_name
    Environment = var.environment
    ManagedBy   = "opentofu"
    Purpose     = "loki-logs"
  }

  depends_on = [module.rgw_bootstrap]
}

resource "aws_s3_bucket" "gitlab_storage" {
  provider      = aws.rgw
  bucket        = local.gitlab_bucket_name
  force_destroy = var.s3_force_destroy

  tags = {
    Name        = local.gitlab_bucket_name
    Environment = var.environment
    ManagedBy   = "opentofu"
    Purpose     = "gitlab-object-storage"
  }

  depends_on = [module.rgw_bootstrap]
}

resource "aws_s3_bucket" "kellnr_crates" {
  count = var.enable_kellnr ? 1 : 0

  provider      = aws.rgw
  bucket        = local.kellnr_bucket_name
  force_destroy = var.s3_force_destroy

  tags = {
    Name        = local.kellnr_bucket_name
    Environment = var.environment
    ManagedBy   = "opentofu"
    Purpose     = "kellnr-crates"
  }

  depends_on = [module.rgw_bootstrap]
}

resource "aws_s3_bucket_versioning" "loki_logs" {
  provider = aws.rgw
  bucket   = aws_s3_bucket.loki_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "gitlab_storage" {
  provider = aws.rgw
  bucket   = aws_s3_bucket.gitlab_storage.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ============================================================================
# BACKUP (Velero + Kopia + RGW object mirror — object store chosen by composition)
# ============================================================================

locals {
  backup_rgw_insecure = startswith(module.rook_ceph.rgw_endpoint, "http://")

  backup_object_sync_sources = var.backup_enabled && var.backup_object_sync_enabled ? concat(
    [
      {
        name                     = "gitlab-storage"
        bucket                   = aws_s3_bucket.gitlab_storage.id
        endpoint                 = module.rook_ceph.rgw_endpoint
        region                   = "us-east-1"
        force_path_style         = true
        insecure_skip_tls_verify = local.backup_rgw_insecure
        access_key               = data.vault_kv_secret_v2.rgw_credentials.data["access_key"]
        secret_key               = data.vault_kv_secret_v2.rgw_credentials.data["secret_key"]
      },
      {
        name                     = "loki-logs"
        bucket                   = aws_s3_bucket.loki_logs.id
        endpoint                 = module.rook_ceph.rgw_endpoint
        region                   = "us-east-1"
        force_path_style         = true
        insecure_skip_tls_verify = local.backup_rgw_insecure
        access_key               = data.vault_kv_secret_v2.rgw_credentials.data["access_key"]
        secret_key               = data.vault_kv_secret_v2.rgw_credentials.data["secret_key"]
      },
    ],
    var.enable_kellnr ? [
      {
        name                     = "kellnr-crates"
        bucket                   = aws_s3_bucket.kellnr_crates[0].id
        endpoint                 = module.rook_ceph.rgw_endpoint
        region                   = "us-east-1"
        force_path_style         = true
        insecure_skip_tls_verify = local.backup_rgw_insecure
        access_key               = data.vault_kv_secret_v2.rgw_credentials.data["access_key"]
        secret_key               = data.vault_kv_secret_v2.rgw_credentials.data["secret_key"]
      },
    ] : [],
  ) : []
}

module "backup" {
  source = "./iac/modules/backup"

  enabled     = var.backup_enabled
  environment = var.environment

  s3_bucket                   = var.backup_s3_bucket
  s3_prefix                   = var.backup_s3_prefix
  s3_region                   = var.backup_s3_region
  s3_endpoint                 = var.backup_s3_endpoint
  s3_force_path_style         = var.backup_s3_force_path_style
  s3_insecure_skip_tls_verify = var.backup_s3_insecure_skip_tls_verify
  s3_access_key               = var.backup_s3_access_key
  s3_secret_key               = var.backup_s3_secret_key

  encryption_password = var.backup_encryption_password
  schedule_cron       = var.backup_schedule_cron
  backup_ttl          = var.backup_ttl
  included_namespaces = var.backup_included_namespaces
  excluded_namespaces = var.backup_excluded_namespaces

  # Kopia FSB = incremental after first full; CSI snapshots optional later
  default_volumes_to_fs_backup = true
  snapshots_enabled            = false

  object_sync_enabled       = var.backup_object_sync_enabled
  object_sync_schedule_cron = var.backup_object_sync_schedule_cron
  object_sync_dest_prefix   = var.backup_object_sync_dest_prefix
  object_sync_sources       = local.backup_object_sync_sources

  postgres_dump_enabled       = var.backup_postgres_dump_enabled
  postgres_dump_schedule_cron = var.backup_postgres_dump_schedule_cron
  postgres_dump_prefix        = var.backup_postgres_dump_prefix
  postgres_dump_targets       = var.backup_postgres_dump_targets
}
