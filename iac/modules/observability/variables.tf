variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "namespace" {
  description = "Namespace for observability stack"
  type        = string
  default     = "monitoring"
}

variable "enable_prometheus" {
  description = "Enable Prometheus"
  type        = bool
  default     = true
}

variable "enable_grafana" {
  description = "Enable Grafana"
  type        = bool
  default     = true
}

variable "enable_loki" {
  description = "Enable Loki for logging"
  type        = bool
  default     = true
}

variable "enable_promtail" {
  description = "Enable Promtail for log collection"
  type        = bool
  default     = true
}

variable "prometheus_storage_size" {
  description = "Storage size for Prometheus"
  type        = string
  default     = "50Gi"
}

variable "grafana_storage_size" {
  description = "Storage size for Grafana"
  type        = string
  default     = "10Gi"
}

variable "loki_storage_size" {
  description = "Storage size for Loki"
  type        = string
  default     = "100Gi"
}

variable "loki_deployment_mode" {
  description = "Loki deployment mode: 'single-binary' for local/dev (no object storage) or 'scalable' for prod (requires object storage)"
  type        = string
  default     = "single-binary"
  validation {
    condition     = contains(["single-binary", "scalable"], var.loki_deployment_mode)
    error_message = "loki_deployment_mode must be either 'single-binary' or 'scalable'"
  }
}

variable "loki_object_storage" {
  description = "Object storage configuration for Loki (required when deployment_mode is 'scalable')"
  type = object({
    type        = string         # s3, gcs, azure, etc.
    bucket      = string
    region      = optional(string)
    endpoint    = optional(string) # For LocalStack or custom S3-compatible endpoints
    access_key  = optional(string) # For LocalStack or custom credentials
    secret_key  = optional(string) # For LocalStack or custom credentials
    force_path_style = optional(bool) # For LocalStack (default: false for AWS, true for LocalStack)
  })
  default = null
}

variable "grafana_ingress_enabled" {
  description = "Enable ingress for Grafana"
  type        = bool
  default     = true
}

variable "grafana_ingress_class" {
  description = "Ingress class for Grafana"
  type        = string
  default     = "nginx"
}

variable "grafana_ingress_host" {
  description = "Hostname for Grafana ingress"
  type        = string
  default     = "grafana.local"
}

variable "grafana_enable_tls" {
  description = "Enable TLS for Grafana ingress"
  type        = bool
  default     = true
}

variable "resource_requests" {
  description = "Resource requests for observability components"
  type = object({
    prometheus = object({
      cpu    = string
      memory = string
    })
    grafana = object({
      cpu    = string
      memory = string
    })
    loki = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    prometheus = {
      cpu    = "500m"
      memory = "2Gi"
    }
    grafana = {
      cpu    = "100m"
      memory = "128Mi"
    }
    loki = {
      cpu    = "200m"
      memory = "512Mi"
    }
  }
}

variable "resource_limits" {
  description = "Resource limits for observability components"
  type = object({
    prometheus = object({
      cpu    = string
      memory = string
    })
    grafana = object({
      cpu    = string
      memory = string
    })
    loki = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    prometheus = {
      cpu    = "2000m"
      memory = "4Gi"
    }
    grafana = {
      cpu    = "500m"
      memory = "512Mi"
    }
    loki = {
      cpu    = "1000m"
      memory = "2Gi"
    }
  }
}

