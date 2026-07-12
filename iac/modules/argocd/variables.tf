variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "namespace" {
  description = "Namespace for Argo CD"
  type        = string
  default     = "argocd"
}

variable "replica_count" {
  description = "Number of Argo CD server replicas"
  type        = number
  default     = 2
}

variable "enable_ha" {
  description = "Enable high availability mode"
  type        = bool
  default     = false
}

variable "ingress_enabled" {
  description = "Enable ingress for Argo CD server"
  type        = bool
  default     = true
}

variable "ingress_class" {
  description = "Ingress class to use for Argo CD"
  type        = string
  default     = "nginx"
}

variable "ingress_host" {
  description = "Hostname for Argo CD ingress"
  type        = string
  default     = "argocd.local"
}

variable "enable_tls" {
  description = "Enable TLS for Argo CD ingress (requires cert-manager)"
  type        = bool
  default     = true
}

variable "tls_secret_name" {
  description = "Name of the TLS secret (managed by cert-manager)"
  type        = string
  default     = "argocd-tls"
}

variable "resource_requests" {
  description = "Resource requests for Argo CD components"
  type = object({
    server = object({
      cpu    = string
      memory = string
    })
    repo_server = object({
      cpu    = string
      memory = string
    })
    application_controller = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    server = {
      cpu    = "100m"
      memory = "128Mi"
    }
    repo_server = {
      cpu    = "100m"
      memory = "128Mi"
    }
    application_controller = {
      cpu    = "200m"
      memory = "256Mi"
    }
  }
}

variable "resource_limits" {
  description = "Resource limits for Argo CD components"
  type = object({
    server = object({
      cpu    = string
      memory = string
    })
    repo_server = object({
      cpu    = string
      memory = string
    })
    application_controller = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    server = {
      cpu    = "500m"
      memory = "512Mi"
    }
    repo_server = {
      cpu    = "500m"
      memory = "512Mi"
    }
    application_controller = {
      cpu    = "1000m"
      memory = "1Gi"
    }
  }
}

variable "helm_chart_version" {
  description = "Version of the Argo CD Helm chart"
  type        = string
  default     = "7.6.8"
}

variable "oidc" {
  description = "Keycloak OIDC SSO configuration. When set, Argo CD login uses Keycloak."
  type = object({
    issuer_url    = string
    client_id     = string
    client_secret = string
    redirect_url  = string
  })
  default   = null
  sensitive = true
}

