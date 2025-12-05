variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for Temporal"
  type        = string
  default     = "temporal"
}

variable "temporal_namespaces" {
  description = "List of Temporal namespaces to create (logical partitions within Temporal)"
  type        = list(string)
  default     = ["data-platform", "trading-platform"]
}

variable "replica_count" {
  description = "Number of replicas for Temporal services"
  type        = number
  default     = 1
}

variable "enable_ha" {
  description = "Enable high availability mode"
  type        = bool
  default     = false
}

variable "ingress_enabled" {
  description = "Enable ingress for Temporal UI"
  type        = bool
  default     = true
}

variable "ingress_class" {
  description = "Ingress class to use for Temporal"
  type        = string
  default     = "nginx"
}

variable "ingress_host" {
  description = "Hostname for Temporal UI ingress"
  type        = string
  default     = "temporal.local"
}

variable "enable_tls" {
  description = "Enable TLS for Temporal UI ingress (requires cert-manager)"
  type        = bool
  default     = false
}

variable "tls_secret_name" {
  description = "Name of the TLS secret (managed by cert-manager)"
  type        = string
  default     = "temporal-tls"
}

variable "persistence_storage_class" {
  description = "Storage class for Temporal persistence (Cassandra/PostgreSQL)"
  type        = string
  default     = "standard"
}

variable "cassandra_storage_size" {
  description = "Storage size for Cassandra"
  type        = string
  default     = "10Gi"
}

variable "elasticsearch_storage_size" {
  description = "Storage size for Elasticsearch"
  type        = string
  default     = "8Gi"
}

variable "resource_requests" {
  description = "Resource requests for Temporal components"
  type = object({
    frontend = object({
      cpu    = string
      memory = string
    })
    history = object({
      cpu    = string
      memory = string
    })
    matching = object({
      cpu    = string
      memory = string
    })
    worker = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    frontend = {
      cpu    = "200m"
      memory = "256Mi"
    }
    history = {
      cpu    = "200m"
      memory = "256Mi"
    }
    matching = {
      cpu    = "200m"
      memory = "256Mi"
    }
    worker = {
      cpu    = "200m"
      memory = "256Mi"
    }
  }
}

variable "resource_limits" {
  description = "Resource limits for Temporal components"
  type = object({
    frontend = object({
      cpu    = string
      memory = string
    })
    history = object({
      cpu    = string
      memory = string
    })
    matching = object({
      cpu    = string
      memory = string
    })
    worker = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    frontend = {
      cpu    = "1000m"
      memory = "512Mi"
    }
    history = {
      cpu    = "1000m"
      memory = "512Mi"
    }
    matching = {
      cpu    = "1000m"
      memory = "512Mi"
    }
    worker = {
      cpu    = "1000m"
      memory = "512Mi"
    }
  }
}

variable "helm_chart_version" {
  description = "Version of the Temporal Helm chart"
  type        = string
  default     = "0.45.2"
}

variable "use_postgresql" {
  description = "Use PostgreSQL instead of Cassandra for persistence"
  type        = bool
  default     = false
}

variable "postgresql_storage_size" {
  description = "Storage size for PostgreSQL"
  type        = string
  default     = "10Gi"
}
