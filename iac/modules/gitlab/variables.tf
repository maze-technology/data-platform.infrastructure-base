variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., local, production)"
  type        = string
}

variable "namespace" {
  description = "Namespace for GitLab deployment"
  type        = string
  default     = "gitlab"
}

variable "helm_chart_version" {
  description = "Version of the GitLab Helm chart"
  type        = string
  default     = "10.1.6"
}

variable "gitlab_domain" {
  description = "Hostname for GitLab web UI"
  type        = string
}

variable "registry_domain" {
  description = "Hostname for GitLab Container Registry"
  type        = string
  default     = ""
}

variable "root_password" {
  description = "Initial GitLab root password (min 8 chars). Ignored when use_external_postgresql is true and secret is pre-provisioned."
  type        = string
  sensitive   = true
  default     = ""
}

variable "ingress_class" {
  description = "Ingress class for GitLab ingress resources"
  type        = string
  default     = "nginx"
}

variable "enable_tls" {
  description = "Enable TLS on GitLab Gateway (requires cert-manager issuer)"
  type        = bool
  default     = false
}

variable "tls_cluster_issuer" {
  description = "cert-manager ClusterIssuer name (maze-ca locally, letsencrypt-prod in production)"
  type        = string
  default     = "letsencrypt-prod"
}

variable "vpn_cidr" {
  description = "WireGuard VPN CIDR allowed to reach GitLab via ingress whitelist"
  type        = string
  default     = "10.8.0.0/24"
}

variable "use_external_postgresql" {
  description = "Use external PostgreSQL (OVH managed). When false, bundled PostgreSQL subchart is used (local dev). Redis is always in-cluster."
  type        = bool
  default     = false
}

variable "postgresql_host" {
  description = "External PostgreSQL host (required when use_external_postgresql = true)"
  type        = string
  default     = ""
}

variable "postgresql_port" {
  description = "External PostgreSQL port"
  type        = number
  default     = 5432
}

variable "postgresql_database" {
  description = "External PostgreSQL database name"
  type        = string
  default     = "gitlabhq_production"
}

variable "postgresql_username" {
  description = "External PostgreSQL username"
  type        = string
  default     = "gitlab"
}

variable "postgresql_password" {
  description = "External PostgreSQL password"
  type        = string
  sensitive   = true
  default     = ""
}

variable "postgresql_ssl" {
  description = "Require TLS for external PostgreSQL (e.g. OVH managed)"
  type        = bool
  default     = false
}

variable "valkey_storage_size" {
  description = "Persistent volume size for in-cluster Valkey (Redis protocol)"
  type        = string
  default     = "8Gi"
}

variable "postgresql_storage_size" {
  description = "Persistent volume size for bundled PostgreSQL"
  type        = string
  default     = "8Gi"
}

variable "object_storage" {
  description = "S3-compatible object storage configuration (Rook-Ceph RGW or OVH Object Storage)"
  type = object({
    endpoint         = string
    bucket           = string
    region           = string
    access_key       = string
    secret_key       = string
    force_path_style = bool
  })
  sensitive = true
}

variable "storage_class" {
  description = "StorageClass for GitLab PVCs (Postgres/Valkey/etc.). Empty uses cluster default."
  type        = string
  default     = ""
}

variable "gitaly_storage_class" {
  description = "StorageClass for Gitaly only (use encrypted RBD for algo source). Empty falls back to storage_class."
  type        = string
  default     = ""
}

variable "storage_encryption_passphrase" {
  description = "Passphrase for Ceph-CSI metadata KMS Secret (required when gitaly uses encrypted RBD). Empty skips Secret."
  type        = string
  default     = ""
  sensitive   = true
}

variable "storage_encryption_secret_name" {
  description = "Kubernetes Secret name expected by rook-ceph-block-encrypted CSI metadata KMS"
  type        = string
  default     = "storage-encryption-secret"
}

variable "gitaly_storage_size" {
  description = "Persistent volume size for Gitaly repositories"
  type        = string
  default     = "10Gi"
}

variable "webservice_min_replicas" {
  description = "Minimum webservice replicas"
  type        = number
  default     = 1
}

variable "webservice_max_replicas" {
  description = "Maximum webservice replicas"
  type        = number
  default     = 1
}

variable "webservice_worker_processes" {
  description = "Puma WORKER_PROCESSES inside each webservice pod (chart default 2)"
  type        = number
  default     = 2
}

variable "shell_min_replicas" {
  description = "Minimum gitlab-shell replicas"
  type        = number
  default     = 2
}

variable "shell_max_replicas" {
  description = "Maximum gitlab-shell replicas"
  type        = number
  default     = 2
}

variable "kas_min_replicas" {
  description = "Minimum GitLab KAS replicas"
  type        = number
  default     = 2
}

variable "kas_max_replicas" {
  description = "Maximum GitLab KAS replicas"
  type        = number
  default     = 2
}

variable "registry_min_replicas" {
  description = "Minimum registry replicas"
  type        = number
  default     = 2
}

variable "registry_max_replicas" {
  description = "Maximum registry replicas"
  type        = number
  default     = 2
}

variable "oidc" {
  description = "Keycloak OIDC SSO configuration. When set, GitLab login uses Keycloak."
  type = object({
    issuer_url    = string
    client_id     = string
    client_secret = string
    redirect_uri  = string
    label         = optional(string, "Keycloak")
  })
  default   = null
  sensitive = true
}

variable "oidc_extra_required_groups" {
  description = "Additional Keycloak group names allowed to sign in via GitLab OIDC (e.g. maze-specific algorithm subgroups under engineers). OIDC tokens include direct membership only — parent engineers is not inferred."
  type        = list(string)
  default     = []
}

variable "sso_admin_username" {
  description = "Platform SSO username to promote as GitLab administrator when OIDC is enabled"
  type        = string
  default     = "admin"
}

variable "sso_admin_email" {
  description = "Email for the SSO admin GitLab user (used for OmniAuth auto-link to root)"
  type        = string
  default     = "admin@maze.tech"
}

variable "custom_ca_pem" {
  description = "Optional PEM-encoded CA to trust (e.g. Maze CA for local HTTPS OIDC to Keycloak)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "custom_ca_secret_keys" {
  description = "Keys written into the custom CA secret (must end in .crt for GitLab update-ca-certificates)"
  type        = list(string)
  default     = ["maze-ca.crt"]
}

variable "install_gitlab_runner" {
  description = "Install one in-cluster GitLab Runner (Kubernetes executor) for CI"
  type        = bool
  default     = true
}

variable "gitlab_runner_replicas" {
  description = "Number of GitLab Runner pods"
  type        = number
  default     = 1
}

