output "namespace" {
  description = "Namespace where cert-manager is installed"
  value       = var.namespace
}

output "cluster_issuer_name" {
  description = "Name of the default ClusterIssuer (if created)"
  value       = var.letsencrypt_email != "" ? "letsencrypt-prod" : null
}

