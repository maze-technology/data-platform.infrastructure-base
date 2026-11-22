variable "environment" {
  description = "Environment name"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "n8n"
}

variable "hostname" {
  description = "Public hostname (VPN-only Ingress), e.g. automation.maze.trading"
  type        = string
}

variable "vpn_cidr" {
  description = "WireGuard VPN CIDR for Ingress whitelist"
  type        = string
}

variable "restrict_to_vpn" {
  type    = bool
  default = true
}

variable "enable_tls" {
  type    = bool
  default = true
}

variable "tls_cluster_issuer" {
  type    = string
  default = "letsencrypt-prod"
}

variable "ingress_class" {
  type    = string
  default = "nginx"
}

variable "helm_chart_version" {
  description = "Official n8n Helm chart version (oci://ghcr.io/n8n-io/n8n-helm-chart/n8n)"
  type        = string
  default     = "1.20.0"
}

variable "storage_class" {
  type    = string
  default = "rook-ceph-block"
}

variable "postgresql_storage_size" {
  type    = string
  default = "20Gi"
}

variable "postgresql_username" {
  type    = string
  default = "n8n"
}

variable "postgresql_database" {
  type    = string
  default = "n8n"
}

variable "valkey_helm_chart_version" {
  type    = string
  default = "0.11.0"
}

variable "valkey_storage_size" {
  type    = string
  default = "8Gi"
}

variable "cnpg_operator_ready" {
  type = string
}

variable "worker_replicas" {
  description = "n8n queue-mode worker replicas"
  type        = number
  default     = 1
}

variable "worker_concurrency" {
  type    = number
  default = 5
}

variable "enable_mcp" {
  description = "Enable instance-level MCP access (agents can execute enabled workflows)"
  type        = bool
  default     = true
}
