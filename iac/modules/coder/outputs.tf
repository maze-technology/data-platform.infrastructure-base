output "namespace" {
  description = "Coder control plane namespace"
  value       = kubernetes_namespace.coder.metadata[0].name
}

output "workspace_namespace" {
  description = "Namespace for developer workspaces"
  value       = kubernetes_namespace.workspaces.metadata[0].name
}

output "hostname" {
  description = "Coder public hostname"
  value       = var.hostname
}

output "url" {
  description = "Coder web UI URL"
  value       = local.access_url
}

output "postgresql_host" {
  description = "In-cluster Postgres service hostname"
  value       = local.postgresql_host
}

output "postgresql_username" {
  description = "Coder Postgres username"
  value       = var.postgresql_username
}

output "postgresql_database" {
  description = "Coder Postgres database name"
  value       = var.postgresql_database
}

output "postgresql_password" {
  description = "Coder Postgres password (for logical backup dumps)"
  value       = local.postgresql_password
  sensitive   = true
}

output "template_path" {
  description = "Path to the default Kubernetes workspace template (push after first admin OIDC login)"
  value       = "${path.module}/templates/kubernetes-dev"
}

output "push_template_command" {
  description = "Run on a machine with VPN + coder CLI after logging in as admin"
  value       = "coder login ${local.access_url} && coder templates push maze-dev ${path.module}/templates/kubernetes-dev --variable namespace=${var.workspace_namespace} --variable storage_class=${var.storage_class} --yes"
}
