output "vpc_id" {
  description = "ID of the VPC"
  value       = null # Placeholder - will be populated by cloud provider resources
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = []
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = []
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = var.vpc_cidr
}

