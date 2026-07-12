variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "namespace" {
  description = "Namespace for Vault"
  type        = string
  default     = "vault"
}

variable "replica_count" {
  description = "Number of Vault server replicas"
  type        = number
  default     = 1
}

variable "enable_ha" {
  description = "Enable high availability mode (requires persistent storage)"
  type        = bool
  default     = false
}

variable "ingress_enabled" {
  description = "Enable ingress for Vault server"
  type        = bool
  default     = true
}

variable "ingress_class" {
  description = "Ingress class to use for Vault"
  type        = string
  default     = "nginx"
}

variable "ingress_host" {
  description = "Hostname for Vault ingress"
  type        = string
  default     = "vault.local"
}

variable "enable_tls" {
  description = "Enable TLS for Vault ingress (requires cert-manager)"
  type        = bool
  default     = true
}

variable "tls_secret_name" {
  description = "Name of the TLS secret (managed by cert-manager)"
  type        = string
  default     = "vault-tls"
}

variable "service_type" {
  description = "Kubernetes service type for Vault"
  type        = string
  default     = "ClusterIP"
}

variable "node_port_http" {
  description = "NodePort for HTTP (when service_type is NodePort)"
  type        = number
  default     = 30082
}

variable "node_port_https" {
  description = "NodePort for HTTPS (when service_type is NodePort)"
  type        = number
  default     = 30443
}

variable "storage_backend" {
  description = "Storage backend for Vault. Options: 'kubernetes' (dev mode), 'file' (persistent), 'raft' (HA)"
  type        = string
  default     = "kubernetes"
  validation {
    condition     = contains(["kubernetes", "file", "raft"], var.storage_backend)
    error_message = "storage_backend must be one of: kubernetes, file, raft"
  }
}

variable "storage_size" {
  description = "Size of persistent volume for Vault data (only used when storage_backend is not 'kubernetes')"
  type        = string
  default     = "10Gi"
}

variable "storage_class" {
  description = "Storage class for persistent volume (only used when storage_backend is not 'kubernetes')"
  type        = string
  default     = ""
}

variable "vault_version" {
  description = "Vault version to deploy"
  type        = string
  default     = "1.15.2"
}

variable "helm_chart_version" {
  description = "Version of the Vault Helm chart"
  type        = string
  default     = "0.25.0"
}

variable "resource_requests" {
  description = "Resource requests for Vault components"
  type = object({
    server = object({
      cpu    = string
      memory = string
    })
    injector = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    server = {
      cpu    = "100m"
      memory = "128Mi"
    }
    injector = {
      cpu    = "50m"
      memory = "64Mi"
    }
  }
}

variable "resource_limits" {
  description = "Resource limits for Vault components"
  type = object({
    server = object({
      cpu    = string
      memory = string
    })
    injector = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    server = {
      cpu    = "500m"
      memory = "512Mi"
    }
    injector = {
      cpu    = "250m"
      memory = "256Mi"
    }
  }
}

variable "vpn_cidr" {
  description = "WireGuard VPN CIDR allowed to reach Vault via ingress whitelist"
  type        = string
  default     = "10.8.0.0/24"
}

variable "restrict_to_vpn" {
  description = "When true, Vault ingress is only reachable from the VPN subnet"
  type        = bool
  default     = true
}
