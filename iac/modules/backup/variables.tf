variable "enabled" {
  description = "Install Velero and schedule backups"
  type        = bool
  default     = false
}

variable "environment" {
  description = "Environment name (for labels)"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for Velero"
  type        = string
  default     = "velero"
}

variable "helm_chart_version" {
  description = "Velero Helm chart version (vmware-tanzu/velero)"
  type        = string
  default     = "12.1.0"
}

variable "aws_plugin_image_tag" {
  description = "velero-plugin-for-aws image tag"
  type        = string
  default     = "v1.12.1"
}

# ---------------------------------------------------------------------------
# Object storage (supplied by the composition repo — RGW, OVH, etc.)
# ---------------------------------------------------------------------------

variable "s3_bucket" {
  description = "S3 bucket name for Velero backups"
  type        = string
  default     = ""
}

variable "s3_prefix" {
  description = "Optional prefix inside the bucket"
  type        = string
  default     = "velero"
}

variable "s3_region" {
  description = "S3 region (use a placeholder like us-east-1 for path-style RGW/OVH)"
  type        = string
  default     = "us-east-1"
}

variable "s3_endpoint" {
  description = "S3-compatible endpoint URL (required for non-AWS; e.g. RGW or OVH)"
  type        = string
  default     = ""
}

variable "s3_force_path_style" {
  description = "Use path-style addressing (required for Rook RGW and most S3-compatible APIs)"
  type        = bool
  default     = true
}

variable "s3_insecure_skip_tls_verify" {
  description = "Skip TLS verify for the S3 endpoint (HTTP RGW / lab only)"
  type        = bool
  default     = false
}

variable "s3_access_key" {
  description = "S3 access key for Velero"
  type        = string
  sensitive   = true
  default     = ""
}

variable "s3_secret_key" {
  description = "S3 secret key for Velero"
  type        = string
  sensitive   = true
  default     = ""
}

# ---------------------------------------------------------------------------
# Encryption (Kopia repository password — client-side)
# ---------------------------------------------------------------------------

variable "encryption_password" {
  description = "Shared client-side password for Kopia (Velero) and rclone crypt (RGW object mirror). Required when enabled. Losing it makes encrypted backups unrecoverable."
  type        = string
  sensitive   = true
  default     = ""
}

# ---------------------------------------------------------------------------
# Schedule / retention (composition-configurable)
# ---------------------------------------------------------------------------

variable "schedule_cron" {
  description = "Cron expression for the default backup Schedule (UTC)"
  type        = string
  default     = "0 2 * * *"
}

variable "backup_ttl" {
  description = "Retention TTL for scheduled backups (Go duration, e.g. 168h = 7d, 720h = 30d)"
  type        = string
  default     = "168h"
}

variable "schedule_name" {
  description = "Name of the Velero Schedule resource"
  type        = string
  default     = "cluster-daily"
}

variable "included_namespaces" {
  description = "Namespaces to include (empty = all). Prefer explicit lists in production."
  type        = list(string)
  default     = []
}

variable "excluded_namespaces" {
  description = "Namespaces to exclude from backups"
  type        = list(string)
  default     = ["kube-system", "kube-public", "kube-node-lease", "local-path-storage", "velero"]
}

variable "default_volumes_to_fs_backup" {
  description = "Default PVC data into Kopia filesystem backups (incremental after first full)"
  type        = bool
  default     = true
}

variable "snapshots_enabled" {
  description = "Enable CSI/native volume snapshot locations (optional alongside Kopia FSB)"
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# RGW / S3 object mirror (rclone → same backup bucket as Velero)
# ---------------------------------------------------------------------------

variable "object_sync_enabled" {
  description = "Schedule rclone sync of RGW application buckets into the backup object store (encrypted with rclone crypt)"
  type        = bool
  default     = true
}

variable "object_sync_schedule_cron" {
  description = "Cron for RGW→backup object sync (UTC). Defaults independently of Velero schedule."
  type        = string
  default     = "30 2 * * *"
}

variable "object_sync_dest_prefix" {
  description = "Prefix under the backup bucket for mirrored RGW objects"
  type        = string
  default     = "rgw-mirror"
}

variable "object_sync_rclone_image" {
  description = "rclone container image"
  type        = string
  default     = "rclone/rclone:1.69.1"
}

variable "object_sync_sources" {
  description = "RGW (or other S3) buckets to mirror into the backup store"
  type = list(object({
    name                     = string
    bucket                   = string
    endpoint                 = string
    region                   = optional(string, "us-east-1")
    force_path_style         = optional(bool, true)
    insecure_skip_tls_verify = optional(bool, false)
    access_key               = string
    secret_key               = string
  }))
  default   = []
  sensitive = true
}

# ---------------------------------------------------------------------------
# Logical PostgreSQL dumps (pg_dump → same backup bucket via rclone crypt)
# ---------------------------------------------------------------------------

variable "postgres_dump_enabled" {
  description = "Schedule application-consistent pg_dump of in-cluster Postgres to the backup object store"
  type        = bool
  default     = true
}

variable "postgres_dump_schedule_cron" {
  description = "Cron for logical Postgres dumps (UTC)"
  type        = string
  default     = "0 3 * * *"
}

variable "postgres_dump_prefix" {
  description = "Prefix under the backup bucket for encrypted logical dumps"
  type        = string
  default     = "logical/postgres"
}

variable "postgres_dump_image" {
  description = "Container image providing pg_dump (official postgres client tools)"
  type        = string
  default     = "postgres:16-alpine"
}

variable "postgres_dump_targets" {
  description = "Postgres instances to dump (host/user/db/password)"
  type = list(object({
    name     = string
    host     = string
    port     = optional(number, 5432)
    user     = string
    database = string
    password = string
  }))
  default   = []
  sensitive = true
}

