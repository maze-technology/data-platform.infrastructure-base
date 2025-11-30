variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "ingress_class" {
  description = "Ingress class name"
  type        = string
  default     = "nginx"
}

variable "ingress_controller_type" {
  description = "Type of ingress controller: nginx, traefik, etc."
  type        = string
  default     = "nginx"
  validation {
    condition     = contains(["nginx", "traefik"], var.ingress_controller_type)
    error_message = "ingress_controller_type must be 'nginx' or 'traefik'"
  }
}

variable "namespace" {
  description = "Namespace for ingress controller"
  type        = string
  default     = "ingress-nginx"
}

variable "replica_count" {
  description = "Number of ingress controller replicas"
  type        = number
  default     = 2
}

variable "enable_metrics" {
  description = "Enable Prometheus metrics for ingress controller"
  type        = bool
  default     = true
}

variable "service_type" {
  description = "Service type for ingress controller (LoadBalancer, NodePort, etc.)"
  type        = string
  default     = "LoadBalancer"
}

variable "node_port_http" {
  description = "NodePort for HTTP (used when service_type is NodePort)"
  type        = number
  default     = 30080
}

variable "node_port_https" {
  description = "NodePort for HTTPS (used when service_type is NodePort)"
  type        = number
  default     = 30443
}

variable "resource_requests" {
  description = "Resource requests for ingress controller pods"
  type = object({
    cpu    = string
    memory = string
  })
  default = {
    cpu    = "100m"
    memory = "128Mi"
  }
}

variable "resource_limits" {
  description = "Resource limits for ingress controller pods"
  type = object({
    cpu    = string
    memory = string
  })
  default = {
    cpu    = "500m"
    memory = "512Mi"
  }
}

variable "helm_chart_version" {
  description = "Version of the ingress-nginx Helm chart"
  type        = string
  default     = "4.8.3"
}

