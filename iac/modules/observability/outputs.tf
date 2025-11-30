output "namespace" {
  description = "Namespace where observability stack is installed"
  value       = var.namespace
}

output "prometheus_enabled" {
  description = "Whether Prometheus is enabled"
  value       = var.enable_prometheus
}

output "grafana_enabled" {
  description = "Whether Grafana is enabled"
  value       = var.enable_grafana
}

output "grafana_ingress_host" {
  description = "Hostname for Grafana ingress"
  value       = var.grafana_ingress_enabled ? var.grafana_ingress_host : null
}

