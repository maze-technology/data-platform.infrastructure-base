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

output "prometheus_operator_helm_release" {
  description = "Helm release resource for Prometheus Operator (for dependencies)"
  value       = var.enable_prometheus ? helm_release.prometheus_operator[0] : null
}

