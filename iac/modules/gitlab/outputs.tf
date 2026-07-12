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
  value       = var.use_external_database ? helm_release.gitlab_external[0] : helm_release.gitlab_bundled[0]
}
