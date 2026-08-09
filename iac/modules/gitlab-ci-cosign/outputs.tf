output "org_group_path" {
  description = "Optional GitLab org group path (empty when not managed)"
  value       = var.org_group_path
}

output "cosign_scope" {
  description = "Where COSIGN_* CI variables are stored"
  value       = "instance"
}
