output "namespace" {
  description = "CloudNativePG operator namespace"
  value       = kubernetes_namespace.cnpg_system.metadata[0].name
}

output "helm_release_id" {
  description = "Helm release id (for depends_on from app modules)"
  value       = helm_release.cloudnativepg.id
}
