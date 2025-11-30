variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
}

variable "environment" {
  description = "Environment name (local, dev, preprod, prod)"
  type        = string
}

variable "cluster_type" {
  description = "Type of cluster: 'kind' for local, 'cloud' for managed cloud clusters"
  type        = string
  default     = "cloud"
  validation {
    condition     = contains(["kind", "cloud"], var.cluster_type)
    error_message = "cluster_type must be either 'kind' or 'cloud'"
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version to use"
  type        = string
  default     = "1.28"
}

variable "node_count" {
  description = "Number of worker nodes (for kind clusters)"
  type        = number
  default     = 1
}

variable "kind_config_path" {
  description = "Path to kind cluster configuration file"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to cloud resources"
  type        = map(string)
  default     = {}
}

