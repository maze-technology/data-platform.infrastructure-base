output "namespace" {
  description = "Paperclip control plane namespace"
  value       = kubernetes_namespace.paperclip.metadata[0].name
}

output "hostname" {
  description = "Paperclip public hostname"
  value       = var.hostname
}

output "url" {
  description = "Paperclip web UI URL"
  value       = local.access_url
}

output "postgresql_host" {
  description = "In-cluster Postgres service hostname"
  value       = local.postgresql_host
}

output "postgresql_username" {
  description = "Paperclip Postgres username"
  value       = var.postgresql_username
}

output "postgresql_database" {
  description = "Paperclip Postgres database name"
  value       = var.postgresql_database
}

output "postgresql_password" {
  description = "Paperclip Postgres password (for logical backup dumps)"
  value       = local.postgresql_password
  sensitive   = true
}

output "image" {
  description = "Deployed Paperclip image"
  value       = var.image
}
