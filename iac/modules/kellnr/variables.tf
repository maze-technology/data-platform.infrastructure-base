variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "namespace" {
  description = "Namespace for Kellnr"
  type        = string
  default     = "kellnr"
}

variable "helm_chart_version" {
  description = "Kellnr Helm chart version"
  type        = string
  default     = "6.1.4"
}

variable "ingress_class" {
  description = "Ingress class"
  type        = string
  default     = "nginx"
}

variable "hostname" {
  description = "Public hostname (e.g. crates.maze.trading)"
  type        = string
}

variable "enable_tls" {
  description = "Terminate TLS at ingress via cert-manager"
  type        = bool
  default     = true
}

variable "tls_cluster_issuer" {
  description = "cert-manager ClusterIssuer name"
  type        = string
}

variable "vpn_cidr" {
  description = "WireGuard VPN CIDR for ingress whitelist"
  type        = string
}

variable "restrict_to_vpn" {
  description = "Restrict Kellnr ingress to VPN (+ localhost + pod CIDR)"
  type        = bool
  default     = true
}

variable "storage_class" {
  description = "StorageClass for Postgres PVC"
  type        = string
  default     = ""
}

variable "postgresql_storage_size" {
  description = "Bitnami Postgres PVC size"
  type        = string
  default     = "10Gi"
}

variable "postgresql_username" {
  description = "Postgres username for Kellnr"
  type        = string
  default     = "kellnr"
}

variable "postgresql_database" {
  description = "Postgres database name for Kellnr"
  type        = string
  default     = "kellnr"
}

variable "object_storage" {
  description = "S3-compatible storage for crate blobs (Rook RGW)"
  type = object({
    endpoint         = string
    region           = string
    access_key       = string
    secret_key       = string
    force_path_style = bool
    crates_bucket    = string
  })
  sensitive = true
}

variable "oidc" {
  description = "Keycloak OIDC settings (null disables SSO)"
  type = object({
    issuer_url    = string
    client_id     = string
    client_secret = string
  })
  default   = null
  sensitive = true
}

variable "registry_name" {
  description = "Cargo registry name used in config.toml / Cargo.toml (registry = \"…\")"
  type        = string
  default     = "maze"
}

variable "auth_required" {
  description = "Require auth for Kellnr API / crate ops"
  type        = bool
  default     = true
}

variable "replica_count" {
  description = "Kellnr replicas (set cookie signing key is shared automatically)"
  type        = number
  default     = 1
}

variable "resources" {
  description = "Kellnr pod resources"
  type = object({
    requests = object({
      cpu    = string
      memory = string
    })
    limits = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    requests = { cpu = "100m", memory = "256Mi" }
    limits   = { cpu = "500m", memory = "512Mi" }
  }
}
