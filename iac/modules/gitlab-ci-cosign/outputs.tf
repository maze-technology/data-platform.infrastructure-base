output "org_group_path" {
  description = "GitLab org group shared with engineers"
  value       = var.org_group_path
}

output "cosign_scope" {
  description = "Where COSIGN_* CI variables are stored"
  value       = "instance"
}
