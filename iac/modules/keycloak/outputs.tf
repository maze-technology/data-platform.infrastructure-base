output "namespace" {
  description = "Keycloak namespace"
  value       = kubernetes_namespace.keycloak.metadata[0].name
}

output "realm" {
  description = "Keycloak realm name"
  value       = var.realm
}

output "issuer_url" {
  description = "OIDC issuer URL for integrated services"
  value       = local.issuer_url
}

output "admin_username" {
  description = "Keycloak master realm admin username"
  value       = var.admin_username
}

output "admin_console_url" {
  description = "Keycloak admin console URL"
  value       = "${local.admin_base_url}/admin"
}

output "internal_http_url" {
  description = "In-cluster Keycloak HTTP base URL (keycloakx service port 80)"
  value       = "http://${helm_release.keycloak.name}-keycloakx-http.${kubernetes_namespace.keycloak.metadata[0].name}.svc.cluster.local"
}

output "client_ids" {
  description = "OIDC client IDs for integrated services"
  value = {
    gitlab  = "gitlab"
    argocd  = "argocd"
    grafana = "grafana"
    kellnr  = "kellnr"
  }
}

output "client_secrets" {
  description = "OIDC client secrets (auto-generated, stored in Terraform state)"
  sensitive   = true
  value = {
    gitlab  = random_password.gitlab_client_secret.result
    argocd  = random_password.argocd_client_secret.result
    grafana = random_password.grafana_client_secret.result
    kellnr  = random_password.kellnr_client_secret.result
  }
}

output "vpn_peer_usernames" {
  description = "Usernames in the vpn-users group — WireGuard peer names must match these"
  value       = local.vpn_peer_usernames
}

output "vpn_peers_csv" {
  description = "Comma-separated WireGuard peer names derived from vpn-users group"
  value       = join(",", local.vpn_peer_usernames)
}

output "groups" {
  description = "Keycloak groups used for access control"
  value = {
    vpn       = "vpn-users"
    engineers = "engineers"
    admins    = "admins"
  }
}

output "postgresql_password" {
  description = "In-cluster PostgreSQL password (CloudNativePG); null when use_external_database"
  value       = var.use_external_database ? null : random_password.postgresql_password[0].result
  sensitive   = true
}

output "postgresql_rw_host" {
  description = "In-cluster PostgreSQL read-write service host; empty when use_external_database"
  value       = var.use_external_database ? "" : module.keycloak_postgresql[0].rw_host
}
