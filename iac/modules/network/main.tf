# Network module placeholder
# For local/kind environments, networking is handled by the host
# For cloud environments, this would contain VPC, subnets, routing, etc.
# Actual implementation depends on cloud provider (AWS, Azure, GCP)

locals {
  # Network configuration is environment-specific
  # Local environments don't need cloud networking
  is_local = var.environment == "local"
}

