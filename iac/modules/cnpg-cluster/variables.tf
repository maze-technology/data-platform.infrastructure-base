variable "environment" {
  description = "Environment name (local, production)"
  type        = string
}

variable "namespace" {
  description = "Namespace for the PostgreSQL cluster"
  type        = string
}

variable "cluster_name" {
  description = "CloudNativePG Cluster metadata.name (also prefixes -rw service)"
  type        = string
}

variable "database" {
  description = "Application database name"
  type        = string
}

variable "username" {
  description = "Application database owner"
  type        = string
}

variable "password" {
  description = "Application database password"
  type        = string
  sensitive   = true
}

variable "storage_size" {
  description = "PVC size for PostgreSQL data"
  type        = string
  default     = "8Gi"
}

variable "storage_class" {
  description = "StorageClass for PostgreSQL PVCs (empty = cluster default)"
  type        = string
  default     = ""
}

variable "instances" {
  description = "Number of PostgreSQL instances (1 = standalone, 3 = HA)"
  type        = number
  default     = 1
}

variable "resources" {
  description = "Resource requests/limits for each PostgreSQL pod"
  type        = any
  default = {
    requests = {
      cpu    = "100m"
      memory = "256Mi"
    }
    limits = {
      cpu    = "500m"
      memory = "512Mi"
    }
  }
}

variable "labels" {
  description = "Extra labels for Cluster and credentials secret"
  type        = map(string)
  default     = {}
}

variable "operator_ready" {
  description = "Dependency handle ensuring CNPG operator is installed before Cluster CR"
  type        = any
  default     = null
}
