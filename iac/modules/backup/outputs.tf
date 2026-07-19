output "namespace" {
  description = "Velero namespace (empty when disabled)"
  value       = var.enabled ? kubernetes_namespace.velero[0].metadata[0].name : ""
}

output "schedule_name" {
  description = "Velero Schedule name (empty when disabled)"
  value       = var.enabled ? var.schedule_name : ""
}

output "s3_bucket" {
  description = "Backup object-storage bucket"
  value       = var.enabled ? var.s3_bucket : ""
}

output "s3_prefix" {
  description = "Prefix inside the backup bucket"
  value       = var.enabled ? var.s3_prefix : ""
}

output "backup_ttl" {
  description = "Configured backup retention TTL"
  value       = var.enabled ? var.backup_ttl : ""
}

output "schedule_cron" {
  description = "Configured backup cron schedule"
  value       = var.enabled ? var.schedule_cron : ""
}

output "object_sync_enabled" {
  description = "Whether RGW→backup rclone crypt mirror is scheduled"
  value       = local.object_sync_active
}

output "object_sync_schedule_cron" {
  description = "RGW object mirror cron (empty when inactive)"
  value       = local.object_sync_active ? var.object_sync_schedule_cron : ""
}

output "object_sync_dest_prefix" {
  description = "Prefix under the backup bucket for crypt-mirrored RGW objects"
  value       = local.object_sync_active ? var.object_sync_dest_prefix : ""
}

output "object_sync_source_names" {
  description = "RGW bucket mirror source names"
  value       = local.object_sync_active ? [for s in var.object_sync_sources : s.name] : []
}

