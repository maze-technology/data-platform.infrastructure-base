output "cluster_name" {
  description = "Name of the Kubernetes cluster"
  value       = var.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes cluster API endpoint"
  value       = var.cluster_type == "kind" ? "https://127.0.0.1:6443" : null
  sensitive   = false
}

output "cluster_ca_certificate" {
  description = "Base64 encoded CA certificate for the cluster"
  value       = var.cluster_type == "kind" ? null : null
  sensitive   = true
}

output "cluster_type" {
  description = "Type of cluster (kind or cloud)"
  value       = var.cluster_type
}

output "environment" {
  description = "Environment name"
  value       = var.environment
}

