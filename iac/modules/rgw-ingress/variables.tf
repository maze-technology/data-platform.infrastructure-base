variable "namespace" {
  description = "Namespace of the RGW service"
  type        = string
  default     = "rook-ceph"
}

variable "service_name" {
  description = "RGW Kubernetes Service name"
  type        = string
  default     = "rgw-service"
}

variable "service_port" {
  description = "RGW Service port"
  type        = number
  default     = 80
}

variable "hostname" {
  description = "Public (VPN) hostname for the S3 API (e.g. s3.maze.trading)"
  type        = string
}

variable "ingress_class" {
  description = "IngressClass name"
  type        = string
  default     = "nginx"
}

variable "enable_tls" {
  description = "Terminate TLS at ingress via cert-manager"
  type        = bool
  default     = true
}

variable "tls_cluster_issuer" {
  description = "cert-manager ClusterIssuer name"
  type        = string
  default     = ""
}

variable "tls_secret_name" {
  description = "TLS secret name for the RGW ingress"
  type        = string
  default     = "rgw-s3-tls"
}

variable "vpn_cidr" {
  description = "WireGuard VPN CIDR for ingress whitelist"
  type        = string
  default     = "10.8.0.0/24"
}

variable "restrict_to_vpn" {
  description = "Restrict the S3 ingress to the VPN CIDR (+ cluster RFC1918)"
  type        = bool
  default     = true
}

variable "environment" {
  description = "Environment label"
  type        = string
}
