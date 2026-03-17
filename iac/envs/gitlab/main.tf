terraform {
  required_version = ">= 1.5.0"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 0.47"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }

  # ─── REQUIRED: Configure remote state backend to prevent accidental reinstalls ───
  # Uncomment and configure before first apply.
  # Losing local state will cause Terraform to try to re-create the OS install task
  # which WIPES the server. A remote backend with locking prevents this.
  #
  # Example: OVH Object Storage (S3-compatible)
  # backend "s3" {
  #   bucket                      = "maze-tech-terraform-state"
  #   key                         = "gitlab/terraform.tfstate"
  #   region                      = "gra"
  #   endpoint                    = "https://s3.gra.io.cloud.ovh.net"
  #   access_key                  = "<OVH_SWIFT_ACCESS_KEY>"
  #   secret_key                  = "<OVH_SWIFT_SECRET_KEY>"
  #   skip_credentials_validation = true
  #   skip_region_validation      = true
  #   skip_metadata_api_check     = true
  #   skip_requesting_account_id  = true
  #   force_path_style            = true
  # }
}

# ─── OVH provider ─────────────────────────────────────────────────────────────
# Credentials can also be supplied via environment variables:
#   export OVH_ENDPOINT=ovh-eu
#   export OVH_APPLICATION_KEY=xxxx
#   export OVH_APPLICATION_SECRET=xxxx
#   export OVH_CONSUMER_KEY=xxxx
# See: https://api.ovh.com/createToken/
provider "ovh" {
  endpoint           = var.ovh_endpoint
  application_key    = var.ovh_application_key
  application_secret = var.ovh_application_secret
  consumer_key       = var.ovh_consumer_key
}

# ─── GitLab module ────────────────────────────────────────────────────────────
module "gitlab" {
  source = "../../modules/infrastructure-private-gitlab"

  environment = "production"

  # ── OVH Server ────────────────────────────────────────────────────────────
  server_service_name = var.server_service_name
  hostname            = var.hostname
  os_template         = var.os_template

  # ── SSH Access ────────────────────────────────────────────────────────────
  ssh_public_key       = var.ssh_public_key
  ssh_private_key_path = var.ssh_private_key_path
  ssh_user             = var.ssh_user
  admin_username       = var.admin_username

  # ── WireGuard VPN ─────────────────────────────────────────────────────────
  wireguard_port               = var.wireguard_port
  wireguard_vpn_subnet         = var.wireguard_vpn_subnet
  wireguard_server_vpn_ip      = var.wireguard_server_vpn_ip
  wireguard_server_private_key = var.wireguard_server_private_key
  wireguard_server_public_key  = var.wireguard_server_public_key
  wireguard_peers              = var.wireguard_peers

  # ── GitLab CE ─────────────────────────────────────────────────────────────
  gitlab_domain              = var.gitlab_domain
  gitlab_registry_domain     = var.gitlab_registry_domain
  gitlab_root_password       = var.gitlab_root_password
  gitlab_version             = var.gitlab_version
  gitlab_puma_workers        = var.gitlab_puma_workers
  gitlab_sidekiq_concurrency = var.gitlab_sidekiq_concurrency

  # ── Backups ───────────────────────────────────────────────────────────────
  backup_age_public_key = var.backup_age_public_key
  backup_retention_days = var.backup_retention_days
  backup_cron_hour      = var.backup_cron_hour
  backup_cron_minute    = var.backup_cron_minute
  backup_s3_enabled     = var.backup_s3_enabled
  backup_s3_bucket      = var.backup_s3_bucket
  backup_s3_endpoint    = var.backup_s3_endpoint
  backup_s3_region      = var.backup_s3_region
  backup_s3_access_key  = var.backup_s3_access_key
  backup_s3_secret_key  = var.backup_s3_secret_key
}
