variable "rgw_endpoint" {
  description = "RGW endpoint URL"
  type        = string
}

variable "rgw_region" {
  description = "RGW region (for S3 compatibility)"
  type        = string
  default     = "us-east-1"
}

# Option 1: Use existing Rook-Ceph user
variable "use_existing_rook_user" {
  description = "Whether to use existing Rook-Ceph created user or create new one"
  type        = bool
  default     = true
}

variable "rook_rgw_secret_name" {
  description = "Name of Kubernetes secret containing RGW credentials (from Rook-Ceph)"
  type        = string
  default     = "rook-ceph-object-user-rgw-store-s3-user"
}

variable "rook_rgw_secret_namespace" {
  description = "Namespace of Kubernetes secret containing RGW credentials"
  type        = string
  default     = "rook-ceph"
}

# Option 2: Create new user via rissson/rgw
variable "rgw_admin_access_key" {
  description = "RGW admin access key (for creating new users)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "rgw_admin_secret_key" {
  description = "RGW admin secret key (for creating new users)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "rgw_user_uid" {
  description = "UID for new RGW user (if creating new user)"
  type        = string
  default     = "s3-user"
}

variable "rgw_user_display_name" {
  description = "Display name for new RGW user"
  type        = string
  default     = "S3 User"
}

variable "rgw_user_email" {
  description = "Email for new RGW user"
  type        = string
  default     = ""
}

# Vault configuration
variable "vault_kv_mount_path" {
  description = "Vault KV secrets engine mount path"
  type        = string
  default     = "secret"
}

variable "vault_secret_path" {
  description = "Path in Vault where RGW credentials will be stored"
  type        = string
  default     = "rgw/credentials"
}

variable "vault_provider_ready" {
  description = "Vault provider ready flag (for dependency)"
  type        = any
  default     = null
}
