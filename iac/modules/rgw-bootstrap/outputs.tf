# Outputs for RGW Bootstrap module

output "access_key" {
  description = "RGW access key (sensitive)"
  value       = local.access_key
  sensitive   = true
}

output "secret_key" {
  description = "RGW secret key (sensitive)"
  value       = local.secret_key
  sensitive   = true
}

output "endpoint" {
  description = "RGW endpoint URL"
  value       = var.rgw_endpoint
}

output "region" {
  description = "RGW region"
  value       = var.rgw_region
}

output "vault_secret_path" {
  description = "Path in Vault where credentials are stored"
  value       = "${var.vault_kv_mount_path}/${var.vault_secret_path}"
}
