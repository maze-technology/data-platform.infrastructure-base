# ─────────────────────────────────────────────────────────────────────────────
# OVH API credentials
# ─────────────────────────────────────────────────────────────────────────────
# Set these via environment variables to avoid storing credentials in files:
#   export TF_VAR_ovh_application_key=xxxx
#   export TF_VAR_ovh_application_secret=xxxx
#   export TF_VAR_ovh_consumer_key=xxxx

variable "ovh_endpoint" {
  description = "OVH API endpoint. Use 'ovh-eu' for Europe, 'ovh-ca' for Canada, 'ovh-us' for US."
  type        = string
  default     = "ovh-eu"
}

variable "ovh_application_key" {
  description = "OVH API application key. Create at https://api.ovh.com/createToken/"
  type        = string
  sensitive   = true
}

variable "ovh_application_secret" {
  description = "OVH API application secret"
  type        = string
  sensitive   = true
}

variable "ovh_consumer_key" {
  description = "OVH API consumer key (obtained during token creation)"
  type        = string
  sensitive   = true
}

# ─────────────────────────────────────────────────────────────────────────────
# Server
# ─────────────────────────────────────────────────────────────────────────────

variable "server_service_name" {
  description = "OVH dedicated server service name (e.g., ns12345.ip-1-2-3-4.eu). Find in OVH Control Panel → Bare Metal Cloud → Dedicated Servers."
  type        = string
}

variable "hostname" {
  description = "Hostname to assign to the server during OS installation"
  type        = string
  default     = "gitlab"
}

variable "os_template" {
  description = "OVH OS installation template name for Ubuntu 24.04"
  type        = string
  default     = "ubuntu2404-server_64"
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH
# ─────────────────────────────────────────────────────────────────────────────

variable "ssh_public_key" {
  description = "SSH public key content to inject during OS installation (the full key string, not a file path)"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key on the machine running Terraform"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "ssh_user" {
  description = "SSH username for initial server connection (default user for OVH Ubuntu)"
  type        = string
  default     = "ubuntu"
}

variable "admin_username" {
  description = "Admin username to create. Set to 'ubuntu' to skip extra user creation."
  type        = string
  default     = "ubuntu"
}

# ─────────────────────────────────────────────────────────────────────────────
# WireGuard VPN
# ─────────────────────────────────────────────────────────────────────────────

variable "wireguard_port" {
  description = "WireGuard UDP listen port on the server"
  type        = number
  default     = 51820
}

variable "wireguard_vpn_subnet" {
  description = "WireGuard VPN subnet CIDR"
  type        = string
  default     = "10.8.0.0/24"
}

variable "wireguard_server_vpn_ip" {
  description = "VPN IP address for the server's WireGuard interface"
  type        = string
  default     = "10.8.0.1"
}

variable "wireguard_server_private_key" {
  description = "WireGuard server private key. Generate with: wg genkey"
  type        = string
  sensitive   = true
}

variable "wireguard_server_public_key" {
  description = "WireGuard server public key. Derive with: echo \"<private_key>\" | wg pubkey"
  type        = string
}

variable "wireguard_peers" {
  description = "WireGuard peer (client) configurations. Each peer needs a name, public_key, and vpn_ip."
  type = list(object({
    name       = string
    public_key = string
    vpn_ip     = string
  }))
}

# ─────────────────────────────────────────────────────────────────────────────
# GitLab CE
# ─────────────────────────────────────────────────────────────────────────────

variable "gitlab_domain" {
  description = "Internal domain for GitLab (VPN-only access). Add to /etc/hosts on clients."
  type        = string
  default     = "gitlab.internal"
}

variable "gitlab_registry_domain" {
  description = "Internal domain for the GitLab Container Registry"
  type        = string
  default     = "registry.gitlab.internal"
}

variable "gitlab_root_password" {
  description = "Initial GitLab root password (min 12 chars). Change on first login."
  type        = string
  sensitive   = true
}

variable "gitlab_version" {
  description = "GitLab CE version to pin (empty = latest). Example: '17.5.1-ce.0'"
  type        = string
  default     = ""
}

variable "gitlab_puma_workers" {
  description = "Puma web server worker processes (2 recommended for ECO servers)"
  type        = number
  default     = 2
}

variable "gitlab_sidekiq_concurrency" {
  description = "Sidekiq background job concurrency"
  type        = number
  default     = 10
}

# ─────────────────────────────────────────────────────────────────────────────
# Backups
# ─────────────────────────────────────────────────────────────────────────────

variable "backup_age_public_key" {
  description = "age public key for encrypting backups. Generate with: age-keygen"
  type        = string
  sensitive   = true
}

variable "backup_retention_days" {
  description = "Days to keep encrypted local backups"
  type        = number
  default     = 7
}

variable "backup_cron_hour" {
  description = "Hour (UTC) for daily backup cron"
  type        = number
  default     = 2
}

variable "backup_cron_minute" {
  description = "Minute for daily backup cron"
  type        = number
  default     = 0
}

variable "backup_s3_enabled" {
  description = "Enable S3 remote backup uploads"
  type        = bool
  default     = false
}

variable "backup_s3_bucket" {
  description = "S3 bucket name for remote backups"
  type        = string
  default     = ""
}

variable "backup_s3_endpoint" {
  description = "S3-compatible endpoint (e.g., OVH Object Storage)"
  type        = string
  default     = ""
}

variable "backup_s3_region" {
  description = "S3 region"
  type        = string
  default     = "gra"
}

variable "backup_s3_access_key" {
  description = "S3 access key"
  type        = string
  sensitive   = true
  default     = ""
}

variable "backup_s3_secret_key" {
  description = "S3 secret key"
  type        = string
  sensitive   = true
  default     = ""
}
