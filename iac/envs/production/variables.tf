variable "cluster_name" {
  description = "Kubernetes cluster name (must match kubeconfig context naming)"
  type        = string
  default     = "production"
}

variable "cluster_domain" {
  description = "Base domain for all cluster services (e.g. maze.tech). DNS must resolve auth.<domain>, scm.<domain>, etc. to the cluster."
  type        = string
  default     = "maze.tech"
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig for the OVH bare metal Kubernetes cluster"
  type        = string
  default     = "~/.kube/config"
}

variable "kubeconfig_context" {
  description = "kubectl context for the production cluster (set after K8s bootstrap on bare metal)"
  type        = string
}

variable "storage_nodes" {
  description = "Rook-Ceph OSD nodes — one dedicated disk per OVH bare metal server. NEVER include the OS disk."
  type = list(object({
    name    = string
    devices = list(string)
  }))
  default = [
    { name = "node1", devices = ["/dev/sdb"] },
    { name = "node2", devices = ["/dev/sdb"] },
    { name = "node3", devices = ["/dev/sdb"] },
  ]
}

variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt certificates"
  type        = string
  sensitive   = true
}

variable "vault_address" {
  description = "Vault API address (in-cluster or external)"
  type        = string
  default     = "http://vault.vault.svc.cluster.local:8200"
}

variable "vault_token" {
  description = "Vault authentication token (required for production)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "vault_skip_tls_verify" {
  description = "Skip TLS verification for Vault (set false in production with proper TLS)"
  type        = bool
  default     = true
}

variable "rgw_s3_endpoint" {
  description = "S3 endpoint reachable from where OpenTofu runs; empty falls back to in-cluster URL from Vault"
  type        = string
  default     = ""
}

variable "vpn_subnet" {
  description = "WireGuard VPN subnet CIDR — used for ingress whitelisting"
  type        = string
  default     = "10.8.0.0/24"
}

variable "wireguard_server_url" {
  description = "WireGuard endpoint hostname or IP (defaults to vpn.<cluster_domain> if empty)"
  type        = string
  default     = ""
}

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

variable "wireguard_peers" {
  description = "WireGuard peer names (defaults to bootstrap_admin.username)"
  type        = string
  default     = ""
}

variable "keycloak_postgresql_host" {
  description = "OVH managed PostgreSQL endpoint for Keycloak"
  type        = string
}

variable "keycloak_postgresql_password" {
  description = "OVH managed PostgreSQL password for Keycloak"
  type        = string
  sensitive   = true
}

variable "gitlab_postgresql_host" {
  description = "OVH managed PostgreSQL endpoint for GitLab"
  type        = string
}

variable "gitlab_postgresql_password" {
  description = "OVH managed PostgreSQL password for GitLab"
  type        = string
  sensitive   = true
}
