variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "namespace" {
  description = "Namespace for Keycloak"
  type        = string
  default     = "keycloak"
}

variable "helm_chart_version" {
  description = "Bitnami Keycloak Helm chart version"
  type        = string
  default     = "25.2.0"
}

variable "keycloak_image_tag" {
  description = "Bitnami Legacy Keycloak image tag (bitnami/* images moved to bitnamilegacy/*)"
  type        = string
  default     = "26.2.0-debian-12-r0"
}

variable "production_mode" {
  description = "Run Keycloak in production mode (requires TLS or proxyHeaders)"
  type        = bool
  default     = true
}

variable "realm" {
  description = "Keycloak realm name"
  type        = string
  default     = "maze"
}

variable "keycloak_host" {
  description = "Public hostname for Keycloak (used in OIDC issuer URL and ingress)"
  type        = string
}

variable "ingress_class" {
  description = "Ingress class for Keycloak"
  type        = string
  default     = "nginx"
}

variable "enable_tls" {
  description = "Enable TLS on Keycloak ingress"
  type        = bool
  default     = false
}

variable "tls_cluster_issuer" {
  description = "cert-manager ClusterIssuer name (maze-ca locally, letsencrypt-prod in production)"
  type        = string
  default     = "letsencrypt-prod"
}

variable "tls_secret_name" {
  description = "TLS secret name for Keycloak ingress (issued by cert-manager)"
  type        = string
  default     = "keycloak-tls"
}

variable "ingress_port_suffix" {
  description = "Port suffix for local HTTP access (e.g. ':30080' for kind NodePort). Empty for standard 443."
  type        = string
  default     = ""
}

variable "vpn_cidr" {
  description = "WireGuard VPN CIDR — Keycloak ingress is restricted to VPN clients"
  type        = string
  default     = "10.8.0.0/24"
}

variable "restrict_to_vpn" {
  description = "When true, Keycloak ingress is only reachable from the VPN subnet. Set false for local bootstrap (Keycloak must be reachable before VPN is up)."
  type        = bool
  default     = false
}

variable "admin_username" {
  description = "Keycloak master realm admin username (bootstrap — used to access /admin console)"
  type        = string
  default     = "admin"
}

variable "admin_password" {
  description = "Keycloak master realm admin password (bootstrap only)"
  type        = string
  sensitive   = true
}

variable "bootstrap_users" {
  description = "Initial users created in the maze realm. Usernames in vpn-users group get WireGuard peer configs."
  type = list(object({
    username           = string
    email              = string
    password           = string
    groups             = list(string)
    password_temporary = optional(bool, false)
  }))
  sensitive = true
  default   = []
}

variable "oidc_clients" {
  description = "OIDC client redirect URIs for integrated services"
  type = object({
    gitlab_redirect_uri  = string
    argocd_redirect_uri  = string
    grafana_redirect_uri = string
    kellnr_redirect_uri  = string
  })
}

variable "use_external_database" {
  description = "Use external PostgreSQL (OVH managed) instead of bundled subchart"
  type        = bool
  default     = false
}

variable "postgresql_host" {
  description = "External PostgreSQL host (when use_external_database = true)"
  type        = string
  default     = ""
}

variable "postgresql_port" {
  description = "External PostgreSQL port"
  type        = number
  default     = 5432
}

variable "postgresql_database" {
  description = "External PostgreSQL database name for Keycloak"
  type        = string
  default     = "keycloak"
}

variable "postgresql_username" {
  description = "External PostgreSQL username"
  type        = string
  default     = "keycloak"
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

variable "replica_count" {
  description = "Number of Keycloak replicas"
  type        = number
  default     = 1
}

variable "storage_class" {
  description = "StorageClass for Keycloak and bundled PostgreSQL PVCs"
  type        = string
  default     = ""
}

variable "postgresql_storage_size" {
  description = "Persistent volume size for bundled PostgreSQL"
  type        = string
  default     = "8Gi"
}

variable "event_webhook_uri" {
  description = "Optional catch-all Keycloak event webhook URL (p2-inc/keycloak-events WEBHOOK_URI). Empty disables."
  type        = string
  default     = ""
}

variable "event_webhook_secret" {
  description = "HMAC secret for Keycloak event webhook (WEBHOOK_SECRET)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "keycloak_events_jar_url" {
  description = "Download URL for p2-inc/keycloak-events provider JAR when event_webhook_uri is set (Maven Central; GitHub releases have no assets)"
  type        = string
  default     = "https://repo1.maven.org/maven2/io/phasetwo/keycloak/keycloak-events/0.50/keycloak-events-0.50.jar"
}
