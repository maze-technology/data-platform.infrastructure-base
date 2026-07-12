variable "cluster_domain" {
  description = "Base domain for all cluster services (e.g. maze.local). Add entries to /etc/hosts pointing to your VPS IP."
  type        = string
  default     = "maze.local"
}

variable "cluster_public_ip" {
  description = "Public IP of the VPS/bare-metal host — used in /etc/hosts output helper. Leave empty to omit from output."
  type        = string
  default     = ""
}

variable "keycloak_admin_username" {
  description = "Keycloak master realm admin username (bootstrap — access /admin console to manage users)"
  type        = string
  default     = "admin"
}

variable "keycloak_admin_password" {
  description = "Keycloak master realm admin password"
  type        = string
  sensitive   = true
  default     = "ChangeMe-Keycloak-Admin-123!"
}

variable "bootstrap_admin" {
  description = "Root platform admin in the maze realm (SSO login + VPN access). WireGuard peer name matches username."
  type = object({
    username = string
    password = string
    email    = string
  })
  sensitive = true
  default = {
    username = "admin"
    password = "ChangeMe-Platform-Admin-123!"
    email    = "admin@maze.tech"
  }
}

variable "bootstrap_users" {
  description = "Additional users created in Keycloak at bootstrap (optional)"
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
  description = "WireGuard peer names for bootstrap VPN access. Defaults to bootstrap_admin.username. Must match Keycloak usernames in vpn-users group."
  type        = string
  default     = ""
}
