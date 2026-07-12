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
  default     = "8.8.2"
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
  description = "Enable TLS on GitLab ingress (requires cert-manager in production)"
  type        = bool
  default     = false
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

variable "redis_storage_size" {
  description = "Persistent volume size for in-cluster Redis"
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
  description = "StorageClass for GitLab PVCs (Gitaly, etc.). Empty uses cluster default."
  type        = string
  default     = ""
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
