output "cluster_name" {
  description = "CloudNativePG Cluster name"
  value       = var.cluster_name
}

output "rw_host" {
  description = "Read-write PostgreSQL service DNS name"
  value       = local.rw_service
}

output "port" {
  description = "PostgreSQL port"
  value       = 5432
}

output "database" {
  description = "Application database name"
  value       = var.database
}

output "username" {
  description = "Application database username"
  value       = var.username
}

output "credentials_secret_name" {
  description = "Secret containing username/password (kubernetes.io/basic-auth)"
  value       = kubernetes_secret.app_credentials.metadata[0].name
}

output "cluster_id" {
  description = "Cluster manifest id (for depends_on)"
  value       = kubernetes_manifest.cluster.manifest.metadata.name
}
