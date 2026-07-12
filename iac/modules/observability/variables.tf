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

# All components are always enabled for unified observability:
# - Prometheus (metrics)
# - Grafana (visualization)
# - Loki (logs)
# - Tempo (traces)
# - OpenTelemetry Collector (unified collection)
# - Promtail (log collection)

variable "storage_class" {
  description = "StorageClass for Prometheus and Grafana PVCs (e.g. rook-ceph-block). Empty uses cluster default."
  type        = string
  default     = ""
}

variable "prometheus_storage_size" {
  description = "Storage size for Prometheus"
  type        = string
  default     = "50Gi"
}

variable "prometheus_retention" {
  description = "Prometheus TSDB retention period (e.g. 7d, 30d)"
  type        = string
  default     = "30d"
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

variable "tempo_storage_size" {
  description = "Storage size for Tempo"
  type        = string
  default     = "50Gi"
}

variable "loki_deployment_mode" {
  description = "Loki deployment mode: 'single-binary' for local/dev (no object storage) or 'scalable' for production (requires object storage)"
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
    type             = string # s3, gcs, azure, etc.
    bucket           = string
    region           = optional(string)
    endpoint         = optional(string) # For LocalStack or custom S3-compatible endpoints
    access_key       = optional(string) # For LocalStack or custom credentials
    secret_key       = optional(string) # For LocalStack or custom credentials
    force_path_style = optional(bool)   # For LocalStack (default: false for AWS, true for LocalStack)
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
    opentelemetry_collector = object({
      cpu    = string
      memory = string
    })
    tempo = object({
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
    opentelemetry_collector = {
      cpu    = "200m"
      memory = "512Mi"
    }
    tempo = {
      cpu    = "500m"
      memory = "1Gi"
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
    opentelemetry_collector = object({
      cpu    = string
      memory = string
    })
    tempo = object({
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
    opentelemetry_collector = {
      cpu    = "1000m"
      memory = "2Gi"
    }
    tempo = {
      cpu    = "2000m"
      memory = "4Gi"
    }
  }
}

variable "helm_chart_version_prometheus_operator" {
  description = "Helm chart version for kube-prometheus-stack"
  type        = string
  default     = "55.5.0"
}

variable "helm_chart_version_loki" {
  description = "Helm chart version for Loki"
  type        = string
  default     = "5.42.0"
}

variable "helm_chart_version_promtail" {
  description = "Helm chart version for Promtail"
  type        = string
  default     = "6.15.0"
}

variable "helm_chart_version_tempo" {
  description = "Helm chart version for Tempo"
  type        = string
  default     = "1.7.0"
}

variable "helm_chart_version_opentelemetry_collector" {
  description = "Helm chart version for OpenTelemetry Collector"
  type        = string
  default     = "0.103.0"
}

variable "oidc" {
  description = "Keycloak OIDC SSO configuration for Grafana login"
  type = object({
    issuer_url    = string
    client_id     = string
    client_secret = string
  })
  default   = null
  sensitive = true
}

variable "vpn_cidr" {
  description = "WireGuard VPN CIDR allowed to reach Grafana via ingress whitelist"
  type        = string
  default     = "10.8.0.0/24"
}

variable "restrict_to_vpn" {
  description = "When true, Grafana ingress is only reachable from the VPN subnet"
  type        = bool
  default     = true
}

