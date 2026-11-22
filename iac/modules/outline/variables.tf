variable "environment" {
  description = "Environment name (e.g. production)"
  type        = string
}

variable "cluster_domain" {
  description = "Cluster DNS domain (hostname becomes wiki.<cluster_domain>)"
  type        = string
  default     = "maze.trading"
}

variable "namespace" {
  description = "Kubernetes namespace for Outline"
  type        = string
  default     = "outline"
}

variable "create_namespace" {
  description = "Create the namespace"
  type        = bool
  default     = true
}

variable "hostname" {
  description = "Public hostname (VPN-only Ingress). Empty = wiki.<cluster_domain>"
  type        = string
  default     = ""
}

variable "vpn_cidr" {
  description = "WireGuard VPN CIDR for Ingress whitelist"
  type        = string
  default     = "10.8.0.0/24"
}

variable "restrict_to_vpn" {
  description = "Whitelist Ingress to VPN CIDR (+ cluster/loopback)"
  type        = bool
  default     = true
}

variable "ingress_class" {
  description = "IngressClass name"
  type        = string
  default     = "nginx"
}

variable "ingress_cluster_issuer" {
  description = "cert-manager ClusterIssuer for Ingress TLS"
  type        = string
  default     = "letsencrypt-prod"
}

variable "enable_tls" {
  description = "Terminate TLS on the Ingress (cert-manager)"
  type        = bool
  default     = true
}

variable "outline_helm_chart_version" {
  description = "community-charts/outline Helm chart version"
  type        = string
  default     = "0.9.5"
}

variable "outline_image_tag" {
  description = "Optional Outline image tag override (empty = chart default)"
  type        = string
  default     = ""
}

variable "replica_count" {
  description = "Outline Deployment replicas"
  type        = number
  default     = 1
}

variable "postgres_storage_size" {
  description = "CloudNativePG PVC size"
  type        = string
  default     = "20Gi"
}

variable "postgres_storage_class" {
  description = "StorageClass for Postgres (empty = cluster default)"
  type        = string
  default     = "rook-ceph-block"
}

variable "postgres_username" {
  description = "Postgres role/database owner"
  type        = string
  default     = "outline"
}

variable "postgres_database" {
  description = "Postgres database name"
  type        = string
  default     = "outline"
}

variable "postgres_instances" {
  description = "CloudNativePG instance count"
  type        = number
  default     = 1
}

variable "valkey_helm_chart_version" {
  description = "valkey-io/valkey Helm chart version"
  type        = string
  default     = "0.11.0"
}

variable "valkey_storage_size" {
  description = "PVC size for Valkey"
  type        = string
  default     = "8Gi"
}

variable "valkey_storage_class" {
  description = "StorageClass for Valkey (empty = chart default)"
  type        = string
  default     = "rook-ceph-block"
}

variable "object_storage" {
  description = "S3-compatible storage for Outline attachments (Rook RGW). Required."
  type = object({
    bucket           = string
    region           = optional(string, "us-east-1")
    endpoint         = string # e.g. https://s3.maze.trading (VPN) or in-cluster RGW URL
    access_key       = string
    secret_key       = string
    force_path_style = optional(bool, true)
    acl              = optional(string, "private")
  })
  sensitive = true
}

variable "oidc" {
  description = "Keycloak (or other) OIDC client for Outline sign-in"
  type = object({
    client_id     = string
    client_secret = string
    auth_uri      = string
    token_uri     = string
    userinfo_uri  = string
    logout_uri    = optional(string, "")
    display_name  = optional(string, "Maze SSO")
  })
  sensitive = true
}

variable "cnpg_operator_ready" {
  description = "CloudNativePG operator helm_release id (ordering)"
  type        = string
  default     = ""
}
