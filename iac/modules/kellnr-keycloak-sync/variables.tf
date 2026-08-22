variable "environment" {
  description = "Environment name"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for the sync service (typically kellnr)"
  type        = string
  default     = "kellnr"
}

variable "keycloak_realm" {
  description = "Keycloak realm to sync group membership from"
  type        = string
  default     = "maze"
}

variable "keycloak_admin_base_url" {
  description = "Keycloak base URL reachable from the cluster (in-cluster or VPN)"
  type        = string
}

variable "keycloak_admin_username" {
  description = "Keycloak master-realm admin username for Admin API access"
  type        = string
}

variable "keycloak_admin_password" {
  description = "Keycloak master-realm admin password"
  type        = string
  sensitive   = true
}

variable "kellnr_postgresql_host" {
  description = "Kellnr PostgreSQL host"
  type        = string
}

variable "kellnr_postgresql_database" {
  description = "Kellnr PostgreSQL database"
  type        = string
  default     = "kellnr"
}

variable "kellnr_postgresql_username" {
  description = "Kellnr PostgreSQL username"
  type        = string
  default     = "kellnr"
}

variable "kellnr_postgresql_password" {
  description = "Kellnr PostgreSQL password"
  type        = string
  sensitive   = true
}

variable "sync_group_names" {
  description = "Keycloak/Kellnr group names kept in sync (direct membership only)"
  type        = list(string)
  default     = []
}

variable "webhook_secret" {
  description = "Shared secret for Keycloak ext-event-webhook HMAC (WEBHOOK_SECRET)"
  type        = string
  sensitive   = true
}

variable "image" {
  description = "Container image for the sync service"
  type        = string
  default     = "python:3.12-slim-bookworm"
}

variable "reconcile_interval_seconds" {
  description = "Background full reconcile interval (0 disables periodic reconcile)"
  type        = number
  default     = 300
}
