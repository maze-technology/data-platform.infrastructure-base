variable "ingress_service_name" {
  description = "Ingress controller Service name (hosts resolve to its ClusterIP)"
  type        = string
  default     = "ingress-nginx-controller"
}

variable "ingress_namespace" {
  description = "Namespace of the ingress controller Service"
  type        = string
  default     = "ingress-nginx"
}

variable "hosts" {
  description = "Hostnames that must resolve inside the cluster (e.g. auth.maze.local)"
  type        = list(string)
}
