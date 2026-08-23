output "namespace" {
  description = "GitLab namespace name"
  value       = kubernetes_namespace.gitlab.metadata[0].name
}

output "gitlab_url" {
  description = "GitLab web UI URL (accessible via VPN)"
  value       = "http${var.enable_tls ? "s" : ""}://${var.gitlab_domain}"
}

output "registry_url" {
  description = "GitLab Container Registry URL (accessible via VPN)"
  value       = "http${var.enable_tls ? "s" : ""}://${local.registry_domain}"
}

output "helm_release" {
  description = "GitLab Helm release metadata"
  value       = helm_release.gitlab
}

output "gateway_cluster_ip" {
  description = "ClusterIP of the GitLab Envoy Gateway proxy (empty when Gateway API is disabled)"
  value       = try(data.external.gitlab_gateway_ip[0].result.ip, "")
}

output "shell_cluster_ip" {
  description = "ClusterIP of gitlab-gitlab-shell (git SSH over VPN; never public)"
  value       = try(data.kubernetes_service.gitlab_shell.spec[0].cluster_ip, "")
}

output "postgresql_password" {
  description = "Effective GitLab Postgres password (var or generated) for backup dumps"
  sensitive   = true
  value       = local.postgresql_password
}
