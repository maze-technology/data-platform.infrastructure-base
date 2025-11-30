output "namespace" {
  description = "Namespace where Argo CD is installed"
  value       = var.namespace
}

output "ingress_host" {
  description = "Hostname for Argo CD ingress"
  value       = var.ingress_enabled ? var.ingress_host : null
}

output "tls_secret_name" {
  description = "Name of the TLS secret for Argo CD"
  value       = var.enable_tls ? var.tls_secret_name : null
}

