# Outputs for Rook-Ceph module
# Provides information needed by CloudNativePG, backup tools, and applications

output "namespace" {
  description = "Namespace where Rook-Ceph is installed"
  value       = kubernetes_namespace.rook_ceph.metadata[0].name
}

output "ceph_cluster_name" {
  description = "Name of the CephCluster resource"
  value       = "rook-ceph"
}

# RBD (Block Storage) outputs
output "rbd_pool_name" {
  description = "Name of the RBD pool for PostgreSQL"
  value       = var.rbd_pool_name
}

output "storage_class_name" {
  description = "Name of the Kubernetes StorageClass for RBD volumes (unencrypted — OHLCV / bulk)"
  value       = kubernetes_storage_class.rbd.metadata[0].name
}

output "encrypted_storage_class_name" {
  description = "Encrypted RBD StorageClass for sensitive PVCs (Gitaly). Empty if encryption disabled."
  value       = var.enable_rbd_encryption ? kubernetes_storage_class.rbd_encrypted[0].metadata[0].name : ""
}

output "encryption_vault_path" {
  description = "Vault path of the RBD LUKS master passphrase"
  value       = var.enable_rbd_encryption ? "secret/${var.encryption_vault_path}" : ""
}

output "encryption_vault_secret_name" {
  description = "Vault KV name (under mount secret/) for the RBD LUKS passphrase"
  value       = var.enable_rbd_encryption ? var.encryption_vault_path : ""
}

output "encryption_kms_id" {
  description = "CSI metadata KMS id for encrypted RBD"
  value       = var.enable_rbd_encryption ? var.encryption_kms_id : ""
}

output "rbd_luks_passphrase" {
  description = "Master passphrase for Ceph-CSI metadata KMS (PVC LUKS)"
  value       = var.enable_rbd_encryption ? random_password.rbd_luks[0].result : ""
  sensitive   = true
}

# RGW (Object Storage) outputs
output "rgw_store_name" {
  description = "Name of the CephObjectStore"
  value       = var.rgw_store_name
}

output "rgw_service_name" {
  description = "Name of the RGW Kubernetes Service"
  value       = kubernetes_service.rgw.metadata[0].name
}

output "rgw_service_namespace" {
  description = "Namespace of the RGW Kubernetes Service"
  value       = kubernetes_service.rgw.metadata[0].namespace
}

output "rgw_endpoint" {
  description = "S3 endpoint URL (ClusterIP service, accessible from within cluster)"
  value       = "http://${kubernetes_service.rgw.metadata[0].name}.${kubernetes_service.rgw.metadata[0].namespace}.svc.cluster.local:${var.rgw_port}"
}

output "rgw_endpoint_host" {
  description = "S3 endpoint hostname (for use in applications)"
  value       = "${kubernetes_service.rgw.metadata[0].name}.${kubernetes_service.rgw.metadata[0].namespace}.svc.cluster.local"
}

output "rgw_endpoint_port" {
  description = "S3 endpoint port"
  value       = var.rgw_port
}

output "rgw_user_name" {
  description = "Name of the RGW user"
  value       = var.rgw_user_name
}

output "rgw_access_key" {
  description = "S3 access key for RGW user (from Kubernetes secret)"
  value       = try(data.kubernetes_secret.rgw_credentials.data["AccessKey"], null)
  sensitive   = true
}

output "rgw_secret_key" {
  description = "S3 secret key for RGW user (from Kubernetes secret)"
  value       = try(data.kubernetes_secret.rgw_credentials.data["SecretKey"], null)
  sensitive   = true
}

output "rgw_secret_name" {
  description = "Name of the Kubernetes secret containing RGW credentials"
  value       = local.rgw_secret_name
}

# Cluster information
output "ceph_version" {
  description = "Ceph version deployed"
  value       = var.ceph_version
}

output "replication_size" {
  description = "Replication size configured for pools"
  value       = var.replication_size
}

output "failure_domain" {
  description = "Failure domain configured for pools"
  value       = var.failure_domain
}

# Resource configuration (for reference)
output "resource_requests" {
  description = "Resource requests configured for Ceph components"
  value       = var.resource_requests
}

output "resource_limits" {
  description = "Resource limits configured for Ceph components"
  value       = var.resource_limits
}


