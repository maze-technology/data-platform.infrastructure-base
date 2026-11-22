output "namespace" {
  value = kubernetes_namespace.n8n.metadata[0].name
}

output "hostname" {
  value = var.hostname
}

output "url" {
  value = local.url
}

output "postgresql_host" {
  value = local.postgresql_host
}

output "postgresql_username" {
  value = var.postgresql_username
}

output "postgresql_database" {
  value = var.postgresql_database
}

output "postgresql_password" {
  value     = random_password.postgresql.result
  sensitive = true
}
