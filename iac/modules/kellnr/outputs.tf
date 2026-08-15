output "namespace" {
  description = "Kellnr namespace"
  value       = kubernetes_namespace.kellnr.metadata[0].name
}

output "hostname" {
  description = "Kellnr public hostname"
  value       = var.hostname
}

output "url" {
  description = "Kellnr base URL"
  value       = var.enable_tls ? "https://${var.hostname}" : "http://${var.hostname}"
}

output "sparse_index" {
  description = "Cargo sparse index URL (use with registries.<name>.index)"
  value       = local.sparse_index
}

output "registry_name" {
  description = "Suggested Cargo registry name for Cargo.toml / config.toml"
  value       = var.registry_name
}

output "admin_password" {
  description = "Bootstrap admin UI password (also create users via SSO)"
  value       = random_password.admin_pwd.result
  sensitive   = true
}

output "admin_token" {
  description = "Bootstrap Cargo admin token (prefer per-user tokens from UI for CI)"
  value       = random_password.admin_token.result
  sensitive   = true
}

output "postgresql_host" {
  description = "In-cluster Postgres service hostname"
  value       = local.postgresql_host
}

output "postgresql_password" {
  description = "Kellnr Postgres password (for backup dumps)"
  value       = random_password.postgresql.result
  sensitive   = true
}

output "postgresql_username" {
  description = "Kellnr Postgres username"
  value       = var.postgresql_username
}

output "postgresql_database" {
  description = "Kellnr Postgres database name"
  value       = var.postgresql_database
}

output "oauth2_callback_url" {
  description = "Keycloak redirect URI for the Kellnr OIDC client"
  value       = "${var.enable_tls ? "https" : "http"}://${var.hostname}/api/v1/oauth2/callback"
}
