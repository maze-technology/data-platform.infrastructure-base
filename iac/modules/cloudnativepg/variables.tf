variable "environment" {
  description = "Environment name (local, production)"
  type        = string
}

variable "namespace" {
  description = "Namespace for the CloudNativePG operator"
  type        = string
  default     = "cnpg-system"
}

variable "helm_chart_version" {
  description = "cloudnative-pg operator Helm chart version"
  type        = string
  default     = "0.29.0"
}
