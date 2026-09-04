variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "namespace" {
  description = "Namespace for the Coder control plane"
  type        = string
  default     = "coder"
}

variable "workspace_namespace" {
  description = "Namespace where developer workspaces are provisioned"
  type        = string
  default     = "coder-workspaces"
}

variable "hostname" {
  description = "Public hostname (e.g. coder.maze.trading)"
  type        = string
}

variable "helm_chart_version" {
  description = "Coder Helm chart version (matches ghcr.io/coder/coder tag)"
  type        = string
  default     = "2.35.7"
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
  description = "Restrict Coder ingress to VPN (+ localhost + pod CIDR)"
  type        = bool
  default     = true
}

variable "storage_class" {
  description = "StorageClass for Postgres and workspace PVCs"
  type        = string
  default     = ""
}

variable "cnpg_operator_ready" {
  description = "Dependency handle from module.cloudnativepg"
  type        = any
  default     = null
}

variable "postgresql_storage_size" {
  description = "CloudNativePG Postgres PVC size for Coder metadata"
  type        = string
  default     = "10Gi"
}

variable "postgresql_username" {
  description = "Postgres username for Coder"
  type        = string
  default     = "coder"
}

variable "postgresql_database" {
  description = "Postgres database name for Coder"
  type        = string
  default     = "coder"
}

variable "oidc" {
  description = "Keycloak OIDC settings"
  type = object({
    issuer_url    = string
    client_id     = string
    client_secret = string
  })
}

variable "oidc_allowed_groups" {
  description = "Keycloak groups allowed to sign in via OIDC (comma-separated in Coder env)"
  type        = list(string)
  default     = ["engineers", "admins"]
}

variable "oidc_email_domain" {
  description = "Optional email domain restriction for OIDC sign-in (empty = any)"
  type        = string
  default     = ""
}

variable "disable_password_auth" {
  description = "Disable email/password login (OIDC only; owners retain password fallback)"
  type        = bool
  default     = true
}

variable "resources" {
  description = "Coder control plane resource requests/limits"
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
      cpu    = "500m"
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

variable "bootstrap_owner" {
  description = "Create a break-glass Coder owner (password login) so /login shows OIDC. Use a system email that does not overlap Keycloak users."
  type = object({
    username = string
    email    = string
  })
  default = null
}

variable "keycloak_owner_sync" {
  description = <<-EOT
    Live Keycloak → Coder Owner sync (CronJob; same idea as kellnr-keycloak-sync).
    Queries the Keycloak Admin API for members of admin_group (default admins) and
    promotes matching Coder users to Owner; demotes OIDC owners who left that group.
    engineers stay ordinary Members. Premium CODER_OIDC_USER_ROLE_* is not used.
    Keycloak WEBHOOK_URI is left free (single-slot provider).
  EOT
  type = object({
    realm          = optional(string, "maze")
    admin_base_url = string
    admin_username = string
    admin_password = string
    admin_group    = optional(string, "admins")
    image          = optional(string, "python:3.12-slim-bookworm")
    schedule       = optional(string, "*/15 * * * *")
  })
  default   = null
  sensitive = true
}
