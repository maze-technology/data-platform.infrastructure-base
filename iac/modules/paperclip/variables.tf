variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "namespace" {
  description = "Namespace for the Paperclip control plane"
  type        = string
  default     = "paperclip"
}

variable "hostname" {
  description = "Public hostname (e.g. paperclip.maze.trading)"
  type        = string
}

variable "image" {
  description = "Paperclip server container image"
  type        = string
  default     = "ghcr.io/paperclipai/paperclip:2026.831.1"
}

variable "plugin_version" {
  description = "npm version of @paperclipai/plugin-kubernetes to stage into the bundled catalog"
  type        = string
  default     = "2026.831.1"
}

variable "agent_sandbox_version" {
  description = "kubernetes-sigs/agent-sandbox release tag (sandbox-cr backend)"
  type        = string
  default     = "v1.0.1"
}

variable "ingress_class" {
  description = "Ingress class"
  type        = string
  default     = "nginx"
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
  description = "Restrict Paperclip ingress to VPN (+ localhost + pod CIDR)"
  type        = bool
  default     = true
}

variable "storage_class" {
  description = "StorageClass for Postgres and PAPERCLIP_HOME PVC"
  type        = string
  default     = ""
}

variable "cnpg_operator_ready" {
  description = "Dependency handle from module.cloudnativepg"
  type        = any
  default     = null
}

variable "postgresql_storage_size" {
  description = "CloudNativePG Postgres PVC size"
  type        = string
  default     = "10Gi"
}

variable "postgresql_username" {
  description = "Postgres username for Paperclip"
  type        = string
  default     = "paperclip"
}

variable "postgresql_database" {
  description = "Postgres database name for Paperclip"
  type        = string
  default     = "paperclip"
}

variable "home_storage_size" {
  description = "PVC size for PAPERCLIP_HOME (secrets master key, config, plugin state)"
  type        = string
  default     = "10Gi"
}

variable "object_storage" {
  description = "S3-compatible storage for attachments (Rook RGW)"
  type = object({
    endpoint         = string
    region           = string
    access_key       = string
    secret_key       = string
    force_path_style = bool
    bucket           = string
  })
  sensitive = true
}

variable "resources" {
  description = "Paperclip control plane resource requests/limits"
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
    requests = {
      cpu    = "250m"
      memory = "512Mi"
    }
    limits = {
      cpu    = "2"
      memory = "2Gi"
    }
  }
}

variable "backup_label_key" {
  description = "Label key marking namespaces included in platform backup runbooks"
  type        = string
  default     = "backup.maze.trading/enabled"
}
