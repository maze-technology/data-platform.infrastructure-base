variable "environment" {
  description = "Environment name (local, production)"
  type        = string
}

variable "namespace" {
  description = "Namespace for Kyverno"
  type        = string
  default     = "kyverno"
}

variable "helm_chart_version" {
  description = "Kyverno Helm chart version"
  type        = string
  default     = "3.3.7"
}

variable "cosign_public_key" {
  description = "PEM-encoded cosign public key used to verify algo images"
  type        = string
  sensitive   = true
}

variable "registry_hosts" {
  description = "Container registry hostnames whose images must be signed (e.g. registry.scm.maze.local)"
  type        = list(string)
}

variable "namespace_label_key" {
  description = "Namespace label key that opts a namespace into signature enforcement (e.g. maze.local/require-signed-images)"
  type        = string
}

variable "namespace_label_value" {
  description = "Namespace label value that opts a namespace into signature enforcement"
  type        = string
  default     = "true"
}

variable "policy_name" {
  description = "ClusterPolicy name"
  type        = string
  default     = "verify-signed-algo-images"
}

variable "cosign_secret_name" {
  description = "Secret name holding cosign.pub in the Kyverno namespace"
  type        = string
  default     = "cosign-public-key"
}
