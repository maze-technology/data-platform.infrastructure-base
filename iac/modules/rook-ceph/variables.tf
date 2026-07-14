variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., production, local)"
  type        = string
}

variable "namespace" {
  description = "Namespace for Rook-Ceph deployment"
  type        = string
  default     = "rook-ceph"
}

# Ceph version configuration
variable "ceph_version" {
  description = "Ceph version image tag"
  type        = string
  default     = "v20.2.2" # Tentacle (stable, recommended with Rook v1.20)
}

variable "rook_operator_version" {
  description = "Rook operator version"
  type        = string
  default     = "v1.20.2"
}

# Storage configuration
# SAFETY: Automatic device discovery is DISABLED. Devices MUST be explicitly specified.
variable "storage_devices" {
  description = "List of raw device paths to use for OSDs (one per node). Format: ['/dev/sdb', '/dev/sdc', '/dev/sdd']. REQUIRED: Devices must be explicitly specified - automatic device discovery is disabled for safety."
  type        = list(string)
  default     = []
}

variable "use_all_nodes" {
  description = "Use all nodes in the cluster for storage (if false, use storage_nodes)"
  type        = bool
  default     = false
}

variable "storage_nodes" {
  description = "List of node names to use for storage. Required if use_all_nodes is false. Use devices for bare metal or directories where supported."
  type = list(object({
    name        = string
    devices     = optional(list(string), [])
    directories = optional(list(string), [])
    loop_device = optional(string) # kind only: loop device basename backing LVM (e.g. loop10)
  }))
  default = []
}

variable "storage_class_device_sets" {
  description = "PVC-backed OSD device sets (Rook storageClassDeviceSets). Use for kind/cloud where raw devices are unavailable."
  type = list(object({
    name      = string
    count     = number
    portable  = optional(bool, true)
    encrypted = optional(bool, false)
    volume_claim_templates = list(object({
      name          = optional(string, "data")
      size          = string
      storage_class = optional(string, "standard")
      volume_mode   = optional(string, "Block")
    }))
  }))
  default = []
}

# Cluster sizing
variable "mon_count" {
  description = "Number of MON daemons (must be odd, typically 3 or 5)"
  type        = number
  default     = 3
}

variable "mgr_count" {
  description = "Number of MGR daemons (typically 1-2)"
  type        = number
  default     = 1
}

variable "rgw_instances" {
  description = "Number of RGW instances"
  type        = number
  default     = 1
}

# Replication and resilience
variable "replication_size" {
  description = "Replication size for pools (must be <= number of OSDs)"
  type        = number
  default     = 3
}

variable "failure_domain" {
  description = "Failure domain for CRUSH rules (host or osd)"
  type        = string
  default     = "host"
  validation {
    condition     = contains(["host", "osd"], var.failure_domain)
    error_message = "Failure domain must be 'host' or 'osd'"
  }
}

# Resource requests and limits
variable "resource_requests" {
  description = "Resource requests for Ceph components"
  type = object({
    operator = object({
      cpu    = string
      memory = string
    })
    mon = object({
      cpu    = string
      memory = string
    })
    mgr = object({
      cpu    = string
      memory = string
    })
    osd = object({
      cpu    = string
      memory = string
    })
    rgw = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    operator = {
      cpu    = "100m"
      memory = "128Mi"
    }
    mon = {
      cpu    = "500m"
      memory = "2Gi"
    }
    mgr = {
      cpu    = "500m"
      memory = "512Mi"
    }
    osd = {
      cpu    = "1"
      memory = "2Gi"
    }
    rgw = {
      cpu    = "500m"
      memory = "512Mi"
    }
  }
}

variable "resource_limits" {
  description = "Resource limits for Ceph components"
  type = object({
    operator = object({
      cpu    = string
      memory = string
    })
    mon = object({
      cpu    = string
      memory = string
    })
    mgr = object({
      cpu    = string
      memory = string
    })
    osd = object({
      cpu    = string
      memory = string
    })
    rgw = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    operator = {
      cpu    = "500m"
      memory = "512Mi"
    }
    mon = {
      cpu    = "1000m"
      memory = "4Gi"
    }
    mgr = {
      cpu    = "1000m"
      memory = "1Gi"
    }
    osd = {
      cpu    = "2"
      memory = "4Gi"
    }
    rgw = {
      cpu    = "1000m"
      memory = "1Gi"
    }
  }
}

# Recovery and backfill throttling (critical for latency-sensitive workloads)
variable "osd_recovery_max_active" {
  description = "Maximum number of active recovery operations per OSD (lower = less impact on latency)"
  type        = number
  default     = 3
}

variable "osd_recovery_op_priority" {
  description = "Priority for recovery operations (lower = less priority, less impact on client I/O)"
  type        = number
  default     = 3
}

variable "osd_max_backfills" {
  description = "Maximum number of backfills per OSD (lower = less impact on latency)"
  type        = number
  default     = 1
}

# RBD configuration
variable "rbd_pool_name" {
  description = "Name of the RBD pool for PostgreSQL"
  type        = string
  default     = "postgresql-pool"
}

variable "storage_class_name" {
  description = "Name of the Kubernetes StorageClass for RBD"
  type        = string
  default     = "rook-ceph-block"
}

# RGW configuration
variable "rgw_store_name" {
  description = "Name of the CephObjectStore"
  type        = string
  default     = "rgw-store"
}

variable "rgw_service_name" {
  description = "Name of the RGW Kubernetes Service"
  type        = string
  default     = "rgw-service"
}

variable "rgw_port" {
  description = "Port for RGW Kubernetes Service (cluster clients connect here)"
  type        = number
  default     = 80
}

variable "rgw_target_port" {
  description = "RGW gateway port inside the pod (Rook defaults to 8080 via beast frontend)"
  type        = number
  default     = 8080
}

variable "rgw_user_name" {
  description = "Name of the RGW user to create"
  type        = string
  default     = "s3-user"
}

variable "rgw_user_display_name" {
  description = "Display name for the RGW user"
  type        = string
  default     = "S3 Application User"
}

# RGW Bucket Management
# Data directory
variable "data_dir_host_path" {
  description = "Host path for Ceph data directory"
  type        = string
  default     = "/var/lib/rook"
}

# Loop device configuration for local kind clusters
# When enabled, creates sparse image files and attaches them as loop devices on kind worker nodes.
# This ensures Rook writes to files instead of real disk partitions (safe for local dev).
variable "allow_loop_devices" {
  description = "Set ROOK_CEPH_ALLOW_LOOP_DEVICES on the operator (required for kind loop-backed Local PV OSDs)."
  type        = bool
  default     = false
}

variable "create_loop_devices" {
  description = "Create loop device-backed OSD images on kind worker nodes. Writes to files, not real disks — safe for local development. Requires storage_nodes to specify the target loop device paths."
  type        = bool
  default     = false
}

variable "loop_device_image_size_gb" {
  description = "Size in GB of each OSD loop device sparse image file (only used when create_loop_devices = true). Sparse files consume no disk space until written."
  type        = number
  default     = 10
}

# Dashboard
variable "dashboard_enabled" {
  description = "Enable Ceph dashboard"
  type        = bool
  default     = true
}

# Monitoring
variable "monitoring_enabled" {
  description = "Enable Prometheus monitoring (requires Prometheus Operator to be installed)"
  type        = bool
  default     = true
}

variable "prometheus_operator_dependency" {
  description = "Optional dependency on Prometheus Operator Helm release (for monitoring_enabled=true). Set to null if not using Prometheus Operator."
  type        = any
  default     = null
}

