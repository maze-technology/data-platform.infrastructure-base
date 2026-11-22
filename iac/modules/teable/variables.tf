variable "environment" {
  description = "Environment name"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "teable"
}

variable "hostname" {
  description = "Public hostname (VPN-only Ingress)"
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

variable "image" {
  description = "Teable container image"
  type        = string
  default     = "ghcr.io/teableio/teable:latest"
}

variable "replica_count" {
  type    = number
  default = 1
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
  default = "teable"
}

variable "postgresql_database" {
  type    = string
  default = "teable"
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

variable "object_storage" {
  type = object({
    endpoint          = string
    internal_endpoint = string
    region            = optional(string, "us-east-1")
    access_key        = string
    secret_key        = string
    force_path_style  = optional(bool, true)
    public_bucket     = string
    private_bucket    = string
  })
  sensitive = true
}

variable "oidc" {
  type = object({
    client_id     = string
    client_secret = string
    auth_uri      = string
    token_uri     = string
    userinfo_uri  = string
    issuer        = string
  })
  sensitive = true
}
