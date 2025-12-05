output "namespace" {
  description = "Kubernetes namespace where Temporal is installed"
  value       = kubernetes_namespace.temporal.metadata[0].name
}

output "ingress_host" {
  description = "Hostname for Temporal UI ingress"
  value       = var.ingress_enabled ? var.ingress_host : null
}

output "tls_secret_name" {
  description = "Name of the TLS secret for Temporal"
  value       = var.enable_tls ? var.tls_secret_name : null
}

output "temporal_namespaces" {
  description = "List of Temporal namespaces created"
  value       = var.temporal_namespaces
}

output "frontend_service" {
  description = "Temporal frontend service endpoint"
  value       = "temporal-frontend.${kubernetes_namespace.temporal.metadata[0].name}.svc.cluster.local:7233"
}

output "web_ui_service" {
  description = "Temporal web UI service endpoint"
  value       = "temporal-web.${kubernetes_namespace.temporal.metadata[0].name}.svc.cluster.local:8080"
}
