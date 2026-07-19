variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "namespace" {
  description = "Namespace for cert-manager"
  type        = string
  default     = "cert-manager"
}

variable "replica_count" {
  description = "Number of cert-manager controller replicas"
  type        = number
  default     = 2
}

variable "enable_webhook" {
  description = "Enable cert-manager webhook"
  type        = bool
  default     = true
}

variable "enable_cainjector" {
  description = "Enable cert-manager CA injector"
  type        = bool
  default     = true
}

variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt registration"
  type        = string
  default     = ""
}

variable "create_maze_ca" {
  description = "Create an internal Maze CA ClusterIssuer (local/offline TLS). Production uses Let's Encrypt instead."
  type        = bool
  default     = false
}

variable "letsencrypt_server" {
  description = "Let's Encrypt server URL (staging or production)"
  type        = string
  default     = "https://acme-v02.api.letsencrypt.org/directory"
}

variable "resource_requests" {
  description = "Resource requests for cert-manager components"
  type = object({
    controller = object({
      cpu    = string
      memory = string
    })
    webhook = object({
      cpu    = string
      memory = string
    })
    cainjector = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    controller = {
      cpu    = "100m"
      memory = "128Mi"
    }
    webhook = {
      cpu    = "100m"
      memory = "128Mi"
    }
    cainjector = {
      cpu    = "100m"
      memory = "128Mi"
    }
  }
}

variable "resource_limits" {
  description = "Resource limits for cert-manager components"
  type = object({
    controller = object({
      cpu    = string
      memory = string
    })
    webhook = object({
      cpu    = string
      memory = string
    })
    cainjector = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    controller = {
      cpu    = "500m"
      memory = "512Mi"
    }
    webhook = {
      cpu    = "500m"
      memory = "512Mi"
    }
    cainjector = {
      cpu    = "500m"
      memory = "512Mi"
    }
  }
}

variable "helm_chart_version" {
  description = "Version of the cert-manager Helm chart"
  type        = string
  default     = "v1.21.0"
}

