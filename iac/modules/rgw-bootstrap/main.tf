# RGW Bootstrap Module
# This module handles the bootstrap phase:
# 1. Reads RGW credentials from Rook-Ceph (or creates new user via rissson/rgw)
# 2. Stores credentials in Vault for secure access
# 3. Outputs credentials for use with AWS provider

# Data source to read RGW credentials from Rook-Ceph secret
# This is the default user created by Rook-Ceph module
data "kubernetes_secret" "rook_rgw_credentials" {
  count = var.use_existing_rook_user ? 1 : 0

  metadata {
    name      = var.rook_rgw_secret_name
    namespace = var.rook_rgw_secret_namespace
  }
}

# Extract credentials from Rook secret
locals {
  # Safely check if secret data is available (data might be null)
  secret_data = var.use_existing_rook_user ? (
    try(data.kubernetes_secret.rook_rgw_credentials[0].data, null)
  ) : null
  
  secret_data_available = local.secret_data != null
  
  # If using existing Rook user, get credentials from secret
  # Use try() to handle cases where secret exists but data is not yet populated
  access_key = var.use_existing_rook_user && local.secret_data_available ? (
    try(
      base64decode(
        try(local.secret_data["AccessKey"], "")
      ),
      ""
    )
  ) : (
    var.rgw_admin_access_key # Fallback if creating new user (would need rissson/rgw)
  )
  
  secret_key = var.use_existing_rook_user && local.secret_data_available ? (
    try(
      base64decode(
        try(local.secret_data["SecretKey"], "")
      ),
      ""
    )
  ) : (
    var.rgw_admin_secret_key # Fallback if creating new user
  )
  
  # Check if credentials are available (both keys must be non-empty)
  credentials_available = local.access_key != "" && local.secret_key != ""
}

# Enable KV secrets engine v2 if not already enabled
resource "vault_mount" "kv" {
  count = var.vault_kv_mount_path == "secret" ? 0 : 1
  
  path        = var.vault_kv_mount_path
  type        = "kv-v2"
  description = "KV secrets engine for RGW credentials"
}

# Store credentials in Vault using KV secrets engine v2
# Note: This will fail if credentials aren't available yet
# If this happens, wait for Rook to populate the secret and retry
resource "vault_kv_secret_v2" "rgw_credentials" {
  mount = var.vault_kv_mount_path
  name  = var.vault_secret_path

  data_json = jsonencode({
    access_key = local.access_key
    secret_key = local.secret_key
    endpoint   = var.rgw_endpoint
    region     = var.rgw_region
  })

  depends_on = [
    var.vault_provider_ready,
    vault_mount.kv,
    data.kubernetes_secret.rook_rgw_credentials
  ]
  
  # Ensure we have valid credentials before storing
  lifecycle {
    precondition {
      condition     = local.credentials_available
      error_message = "RGW credentials are not yet available in Kubernetes secret. Wait for Rook operator to populate the secret and retry."
    }
  }
}
