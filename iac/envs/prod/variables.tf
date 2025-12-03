variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.3.1.0/24", "10.3.2.0/24", "10.3.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.3.10.0/24", "10.3.11.0/24", "10.3.12.0/24"]
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.28"
}

variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt"
  type        = string
  sensitive   = true
}

variable "grafana_host" {
  description = "Hostname for Grafana ingress"
  type        = string
  default     = "grafana.prod.example.com"
}

variable "argocd_host" {
  description = "Hostname for Argo CD ingress"
  type        = string
  default     = "argocd.prod.example.com"
}

variable "temporal_host" {
  description = "Hostname for Temporal UI ingress"
  type        = string
  default     = "temporal.prod.example.com"
}

