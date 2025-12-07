output "namespace" {
  description = "Namespace where observability stack is installed"
  value       = var.namespace
}

output "prometheus_enabled" {
  description = "Prometheus is always enabled as part of the unified observability stack"
  value       = true
}

output "grafana_enabled" {
  description = "Grafana is always enabled as the visualization layer for unified observability"
  value       = true
}

output "grafana_ingress_host" {
  description = "Hostname for Grafana ingress"
  value       = var.grafana_ingress_enabled ? var.grafana_ingress_host : null
}

output "prometheus_operator_helm_release" {
  description = "Helm release resource for Prometheus Operator (for dependencies)"
  value       = helm_release.prometheus_operator
}

output "opentelemetry_collector_enabled" {
  description = "OpenTelemetry Collector is always enabled as part of the unified observability stack"
  value       = true
}

output "tempo_enabled" {
  description = "Tempo is always enabled as part of the unified observability stack"
  value       = true
}

output "opentelemetry_collector_helm_release" {
  description = "Helm release resource for OpenTelemetry Collector (for dependencies)"
  value       = helm_release.opentelemetry_collector
}

output "tempo_helm_release" {
  description = "Helm release resource for Tempo (for dependencies)"
  value       = helm_release.tempo
}

