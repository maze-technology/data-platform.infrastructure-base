# =============================================================================
# Core
# =============================================================================

variable "environment" {
  description = "Environment name (e.g. local, production). Used for tagging and default bucket names."
  type        = string
}

variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
}

variable "cluster_domain" {
  description = "Base domain for all cluster services (e.g. maze.local, maze.tech)"
  type        = string
}

variable "cluster_public_ip" {
  description = "Public IP of the host — used in etc_hosts output helper. Leave empty to omit ready-to-paste lines."
  type        = string
  default     = ""
}

# =============================================================================
# Feature flags (local vs production)
# =============================================================================

variable "enable_kind_cluster" {
  description = "Create/verify the kind cluster module (local only). Production assumes an existing cluster."
  type        = bool
  default     = false
}

variable "enable_cluster_dns" {
  description = "Patch CoreDNS so *.cluster_domain resolves inside the cluster (needed for kind/local OIDC)."
  type        = bool
  default     = false
}

variable "create_maze_ca" {
  description = "Create an internal Maze CA ClusterIssuer (local/offline TLS). Production uses Let's Encrypt."
  type        = bool
  default     = false
}

variable "restrict_to_vpn" {
  description = "Restrict web UIs to the WireGuard VPN CIDR"
  type        = bool
  default     = true
}

# =============================================================================
# Rook-Ceph
# =============================================================================

variable "storage_nodes" {
  description = "Rook-Ceph OSD nodes. NEVER include the OS disk. For kind, include loop_device basenames."
  type = list(object({
    name        = string
    devices     = optional(list(string), [])
    directories = optional(list(string), [])
    loop_device = optional(string)
  }))
  default = []
}

variable "create_loop_devices" {
  description = "Create loop device-backed OSD images (kind/local only)"
  type        = bool
  default     = false
}

variable "allow_loop_devices" {
  description = "Set ROOK_CEPH_ALLOW_LOOP_DEVICES on the operator (kind/local)"
  type        = bool
  default     = false
}

variable "local_block_osd_devices" {
  description = "Map of kind node name to loop device basename for static Block Local PVs"
  type        = map(string)
  default     = {}
}

variable "storage_class_device_sets" {
  description = "PVC-backed OSD device sets (unused when using raw/loop devices)"
  type = list(object({
    name      = string
    count     = number
    portable  = optional(bool, true)
    encrypted = optional(bool, false)
    volume_claim_templates = list(object({
      name          = optional(string, "data")
      size          = string
      storage_class = optional(string, "standard")
      volume_mode   = optional(string, "Block")
    }))
  }))
  default = []
}

variable "use_all_nodes" {
  description = "Use all nodes for Rook storage (unsafe — prefer explicit storage_nodes)"
  type        = bool
  default     = false
}

variable "mon_count" {
  description = "Ceph MON count (must be odd)"
  type        = number
  default     = 3
}

variable "mgr_count" {
  description = "Ceph MGR count"
  type        = number
  default     = 1
}

variable "rgw_instances" {
  description = "Number of RGW instances"
  type        = number
  default     = 2
}

variable "replication_size" {
  description = "Ceph pool replication size"
  type        = number
  default     = 3
}

variable "rook_resource_requests" {
  description = "Resource requests for Ceph components (null = module defaults)"
  type = object({
    operator = object({ cpu = string, memory = string })
    mon      = object({ cpu = string, memory = string })
    mgr      = object({ cpu = string, memory = string })
    osd      = object({ cpu = string, memory = string })
    rgw      = object({ cpu = string, memory = string })
  })
  default = null
}

variable "rook_resource_limits" {
  description = "Resource limits for Ceph components (null = module defaults)"
  type = object({
    operator = object({ cpu = string, memory = string })
    mon      = object({ cpu = string, memory = string })
    mgr      = object({ cpu = string, memory = string })
    osd      = object({ cpu = string, memory = string })
    rgw      = object({ cpu = string, memory = string })
  })
  default = null
}

variable "osd_recovery_max_active" {
  description = "Max active recovery ops per OSD"
  type        = number
  default     = 3
}

variable "osd_recovery_op_priority" {
  description = "OSD recovery op priority"
  type        = number
  default     = 3
}

variable "osd_max_backfills" {
  description = "Max backfills per OSD"
  type        = number
  default     = 1
}

variable "rook_dashboard_enabled" {
  description = "Enable Ceph dashboard"
  type        = bool
  default     = false
}

variable "rook_monitoring_enabled" {
  description = "Enable Rook ServiceMonitors (requires Prometheus Operator CRDs)"
  type        = bool
  default     = false
}

# =============================================================================
# Cert-manager / Ingress
# =============================================================================

variable "letsencrypt_email" {
  description = "Email for Let's Encrypt registration (empty when using Maze CA only)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "letsencrypt_server" {
  description = "ACME server URL (staging or production)"
  type        = string
  default     = "https://acme-v02.api.letsencrypt.org/directory"
}

variable "cert_manager_replica_count" {
  description = "cert-manager controller replicas"
  type        = number
  default     = 3
}

variable "ingress_service_type" {
  description = "Ingress controller Service type (NodePort for kind, LoadBalancer for production)"
  type        = string
  default     = "LoadBalancer"
}

variable "ingress_node_port_http" {
  description = "HTTP NodePort when ingress_service_type is NodePort"
  type        = number
  default     = 30080
}

variable "ingress_node_port_https" {
  description = "HTTPS NodePort when ingress_service_type is NodePort"
  type        = number
  default     = 30443
}

variable "ingress_replica_count" {
  description = "Ingress controller replicas"
  type        = number
  default     = 3
}

variable "ingress_port_suffix" {
  description = "Port suffix for Keycloak URLs when not on 443 (usually empty with HTTPS NodePort)"
  type        = string
  default     = ""
}

variable "enable_ingress_metrics" {
  description = "Enable ingress controller metrics"
  type        = bool
  default     = true
}

# =============================================================================
# WireGuard
# =============================================================================

variable "vpn_subnet" {
  description = "WireGuard VPN subnet CIDR"
  type        = string
  default     = "10.8.0.0/24"
}

variable "wireguard_server_url" {
  description = "WireGuard endpoint hostname or IP (defaults to vpn.<cluster_domain>)"
  type        = string
  default     = ""
}

variable "wireguard_peers" {
  description = "WireGuard peer names (defaults to bootstrap_admin.username)"
  type        = string
  default     = ""
}

variable "wireguard_service_type" {
  description = "WireGuard Service type"
  type        = string
  default     = "LoadBalancer"
}

variable "wireguard_node_port" {
  description = "WireGuard UDP NodePort when service_type is NodePort"
  type        = number
  default     = 31820
}

variable "wireguard_storage_class" {
  description = "StorageClass for WireGuard config PVC. Empty uses Rook RBD class."
  type        = string
  default     = ""
}

variable "wireguard_storage_size" {
  description = "WireGuard config PVC size"
  type        = string
  default     = "1Gi"
}

# =============================================================================
# Identity (Keycloak)
# =============================================================================

variable "keycloak_admin_username" {
  description = "Keycloak master realm admin username"
  type        = string
  default     = "admin"
}

variable "keycloak_admin_password" {
  description = "Keycloak master realm admin password"
  type        = string
  sensitive   = true
}

variable "bootstrap_admin" {
  description = "Root platform admin in the maze realm (SSO + VPN). WireGuard peer name matches username."
  type = object({
    username = string
    password = string
    email    = string
  })
  sensitive = true
}

variable "bootstrap_users" {
  description = "Additional Keycloak users created at bootstrap"
  type = list(object({
    username = string
    password = string
    email    = string
    groups   = list(string)
  }))
  sensitive = true
  default   = []
}

variable "keycloak_replica_count" {
  description = "Keycloak replicas"
  type        = number
  default     = 2
}

variable "keycloak_storage_class" {
  description = "StorageClass for Keycloak PostgreSQL PVC. Empty uses Rook RBD class."
  type        = string
  default     = ""
}

variable "keycloak_postgresql_storage_size" {
  description = "Bundled Keycloak PostgreSQL PVC size (ignored when using external DB)"
  type        = string
  default     = "8Gi"
}

variable "keycloak_production_mode" {
  description = "Run Keycloak in production mode (HTTPS + x-forwarded headers)"
  type        = bool
  default     = true
}

variable "use_external_keycloak_database" {
  description = "Use external PostgreSQL for Keycloak (OVH managed in production)"
  type        = bool
  default     = false
}

variable "keycloak_postgresql_host" {
  description = "External PostgreSQL host for Keycloak"
  type        = string
  default     = ""
}

variable "keycloak_postgresql_password" {
  description = "External PostgreSQL password for Keycloak"
  type        = string
  sensitive   = true
  default     = ""
}

# =============================================================================
# Vault
# =============================================================================

variable "vault_replica_count" {
  description = "Vault server replicas"
  type        = number
  default     = 3
}

variable "vault_enable_ha" {
  description = "Enable Vault HA"
  type        = bool
  default     = true
}

variable "vault_storage_backend" {
  description = "Vault storage backend (kubernetes for local, file for production)"
  type        = string
  default     = "file"
}

variable "vault_storage_size" {
  description = "Vault PVC size when using file backend"
  type        = string
  default     = "10Gi"
}

variable "vault_storage_class" {
  description = "StorageClass for Vault PVC. Empty uses Rook RBD class."
  type        = string
  default     = ""
}

variable "vault_enable_server_tls" {
  description = "Enable Vault server TLS (usually false when TLS terminates at ingress)"
  type        = bool
  default     = false
}

# =============================================================================
# Observability
# =============================================================================

variable "prometheus_storage_size" {
  description = "Prometheus PVC size"
  type        = string
  default     = "500Gi"
}

variable "prometheus_retention" {
  description = "Prometheus retention period"
  type        = string
  default     = "30d"
}

variable "grafana_storage_size" {
  description = "Grafana PVC size"
  type        = string
  default     = "100Gi"
}

variable "loki_storage_size" {
  description = "Loki PVC size"
  type        = string
  default     = "1Ti"
}

variable "tempo_storage_size" {
  description = "Tempo PVC size"
  type        = string
  default     = "100Gi"
}

variable "observability_storage_class" {
  description = "StorageClass for observability PVCs. Empty uses Rook RBD class."
  type        = string
  default     = ""
}

variable "loki_deployment_mode" {
  description = "Loki deployment mode (SingleBinary locally, Scalable in production)"
  type        = string
  default     = "scalable"
}

variable "loki_chunks_cache_memory_mb" {
  description = "Loki chunks cache memory (MB)"
  type        = number
  default     = 8192
}

variable "loki_results_cache_memory_mb" {
  description = "Loki results cache memory (MB)"
  type        = number
  default     = 1024
}

variable "enable_promtail" {
  description = "Enable Promtail DaemonSet"
  type        = bool
  default     = true
}

variable "loki_bucket_name" {
  description = "S3 bucket name for Loki logs. Empty defaults to loki-logs-<environment>."
  type        = string
  default     = ""
}

# =============================================================================
# Argo CD
# =============================================================================

variable "argocd_replica_count" {
  description = "Argo CD replicas"
  type        = number
  default     = 3
}

variable "argocd_enable_ha" {
  description = "Enable Argo CD HA"
  type        = bool
  default     = true
}

# =============================================================================
# GitLab
# =============================================================================

variable "use_external_gitlab_postgresql" {
  description = "Use external PostgreSQL for GitLab (OVH managed in production)"
  type        = bool
  default     = false
}

variable "gitlab_postgresql_host" {
  description = "External PostgreSQL host for GitLab"
  type        = string
  default     = ""
}

variable "gitlab_postgresql_password" {
  description = "External PostgreSQL password for GitLab"
  type        = string
  sensitive   = true
  default     = ""
}

variable "gitlab_storage_class" {
  description = "StorageClass for GitLab PVCs. Empty uses Rook RBD class."
  type        = string
  default     = ""
}

variable "gitaly_storage_class" {
  description = "StorageClass for Gitaly. Empty uses encrypted Rook RBD class."
  type        = string
  default     = ""
}

variable "gitaly_storage_size" {
  description = "Gitaly PVC size"
  type        = string
  default     = "100Gi"
}

variable "gitlab_postgresql_storage_size" {
  description = "Bundled GitLab PostgreSQL PVC size (ignored when using external DB)"
  type        = string
  default     = "8Gi"
}

variable "valkey_storage_size" {
  description = "GitLab Valkey/Redis PVC size"
  type        = string
  default     = "8Gi"
}

variable "gitlab_bucket_name" {
  description = "S3 bucket name for GitLab object storage. Empty defaults to gitlab-storage-<environment>."
  type        = string
  default     = ""
}

variable "s3_force_destroy" {
  description = "Allow OpenTofu to destroy non-empty S3 buckets (local only)"
  type        = bool
  default     = false
}

variable "install_gitlab_runner" {
  description = "Install the GitLab Runner chart subchart"
  type        = bool
  default     = true
}

variable "gitlab_runner_replicas" {
  description = "GitLab Runner replicas"
  type        = number
  default     = 1
}

variable "webservice_min_replicas" {
  description = "GitLab webservice HPA min replicas"
  type        = number
  default     = 2
}

variable "webservice_max_replicas" {
  description = "GitLab webservice HPA max replicas"
  type        = number
  default     = 4
}

variable "webservice_worker_processes" {
  description = "Puma worker processes per webservice pod"
  type        = number
  default     = 2
}

variable "shell_min_replicas" {
  description = "GitLab shell min replicas"
  type        = number
  default     = 2
}

variable "shell_max_replicas" {
  description = "GitLab shell max replicas"
  type        = number
  default     = 2
}

variable "kas_min_replicas" {
  description = "GitLab KAS min replicas"
  type        = number
  default     = 2
}

variable "kas_max_replicas" {
  description = "GitLab KAS max replicas"
  type        = number
  default     = 2
}

variable "registry_min_replicas" {
  description = "GitLab registry min replicas"
  type        = number
  default     = 2
}

variable "registry_max_replicas" {
  description = "GitLab registry max replicas"
  type        = number
  default     = 2
}

# =============================================================================
# Backup (Velero + Kopia → S3-compatible store chosen by composition)
# =============================================================================

variable "backup_enabled" {
  description = "Install Velero and schedule Kopia filesystem backups to the configured S3 bucket"
  type        = bool
  default     = false
}

variable "backup_s3_bucket" {
  description = "S3 bucket for Velero backups (composition provides — RGW locally, OVH in production)"
  type        = string
  default     = ""
}

variable "backup_s3_prefix" {
  description = "Prefix inside the backup bucket"
  type        = string
  default     = "velero"
}

variable "backup_s3_region" {
  description = "S3 region string for the backup store"
  type        = string
  default     = "us-east-1"
}

variable "backup_s3_endpoint" {
  description = "S3-compatible endpoint URL for backups"
  type        = string
  default     = ""
}

variable "backup_s3_force_path_style" {
  description = "Path-style S3 addressing for the backup store"
  type        = bool
  default     = true
}

variable "backup_s3_insecure_skip_tls_verify" {
  description = "Skip TLS verify for backup S3 endpoint (local HTTP RGW only)"
  type        = bool
  default     = false
}

variable "backup_s3_access_key" {
  description = "Access key for the backup object store"
  type        = string
  sensitive   = true
  default     = ""
}

variable "backup_s3_secret_key" {
  description = "Secret key for the backup object store"
  type        = string
  sensitive   = true
  default     = ""
}

variable "backup_encryption_password" {
  description = "Shared client-side password for Kopia (Velero) and rclone crypt (RGW object mirror). Min 16 chars when backup_enabled. Store offline — required to restore."
  type        = string
  sensitive   = true
  default     = ""
}

variable "backup_schedule_cron" {
  description = "Cron schedule for cluster backups (UTC)"
  type        = string
  default     = "0 2 * * *"
}

variable "backup_ttl" {
  description = "Backup retention TTL (Go duration, e.g. 168h, 720h)"
  type        = string
  default     = "168h"
}

variable "backup_included_namespaces" {
  description = "Namespaces to include (empty = all except excluded)"
  type        = list(string)
  default     = []
}

variable "backup_excluded_namespaces" {
  description = "Namespaces to exclude from backups"
  type        = list(string)
  default     = ["kube-system", "kube-public", "kube-node-lease", "local-path-storage", "velero"]
}

variable "backup_object_sync_enabled" {
  description = "Mirror RGW application buckets (GitLab, Loki, …) into the backup store via rclone crypt (same encryption password as Kopia)"
  type        = bool
  default     = true
}

variable "backup_object_sync_schedule_cron" {
  description = "Cron for RGW→backup object mirror (UTC)"
  type        = string
  default     = "30 2 * * *"
}

variable "backup_object_sync_dest_prefix" {
  description = "Prefix under the backup bucket for crypt-mirrored RGW objects"
  type        = string
  default     = "rgw-mirror"
}
