output "namespace" {
  description = "Kubernetes namespace"
  value       = local.namespace
}

output "hostname" {
  description = "VPN-only Outline hostname"
  value       = local.hostname
}

output "url" {
  description = "Outline public URL (VPN)"
  value       = local.url
}

output "ingress_hosts" {
  description = "Hostnames to inject into CoreDNS (VPN clients)"
  value       = [local.hostname]
}

output "postgres_host" {
  description = "CloudNativePG RW service host"
  value       = local.postgres_host
}

output "postgres_username" {
  description = "Postgres role"
  value       = var.postgres_username
}

output "postgres_database" {
  description = "Postgres database name"
  value       = var.postgres_database
}

output "postgres_password" {
  description = "Postgres password (for backup dump targets)"
  value       = random_password.postgres.result
  sensitive   = true
}

output "s3_bucket" {
  description = "RGW/S3 bucket for Outline attachments"
  value       = var.object_storage.bucket
}
