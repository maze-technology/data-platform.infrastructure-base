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
  description = "Name of the Kubernetes StorageClass for RBD volumes"
  value       = kubernetes_storage_class.rbd.metadata[0].name
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
  value       = try(base64decode(data.kubernetes_secret.rgw_credentials.data["AccessKey"]), null)
  sensitive   = true
}

output "rgw_secret_key" {
  description = "S3 secret key for RGW user (from Kubernetes secret)"
  value       = try(base64decode(data.kubernetes_secret.rgw_credentials.data["SecretKey"]), null)
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

