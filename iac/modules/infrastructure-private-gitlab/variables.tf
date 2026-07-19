# ─────────────────────────────────────────────────────────────────────────────
# Environment
# ─────────────────────────────────────────────────────────────────────────────

variable "environment" {
  description = "Environment name (e.g., production, staging)"
  type        = string
  default     = "production"
}

# ─────────────────────────────────────────────────────────────────────────────
# OVH Dedicated Server
# ─────────────────────────────────────────────────────────────────────────────

variable "server_service_name" {
  description = "OVH dedicated server service name (e.g., ns12345.ip-1-2-3-4.eu). Find it in the OVH control panel under Bare Metal Cloud → Dedicated Servers."
  type        = string
}

variable "hostname" {
  description = "Hostname to set on the bare metal server during OS installation"
  type        = string
  default     = "gitlab"
}

variable "os_template" {
  description = "OVH OS installation template name for Ubuntu 24.04 LTS. List available templates via: curl -s 'https://eu.api.ovh.com/1.0/dedicated/installationTemplate' | jq '.[]'"
  type        = string
  default     = "ubuntu2404-server_64"
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH Access
# ─────────────────────────────────────────────────────────────────────────────

variable "ssh_public_key" {
  description = "SSH public key to inject into the server during OS installation. This key will be added to the ubuntu user's authorized_keys."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path on the Terraform executor to the SSH private key used to connect to the server. Must correspond to ssh_public_key."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "ssh_user" {
  description = "SSH username for initial connection. OVH Ubuntu 24.04 templates use 'ubuntu' by default."
  type        = string
  default     = "ubuntu"
}

variable "admin_username" {
  description = "Non-root admin user to create on the server. Set to 'ubuntu' to skip creation (keep default OVH user). A different value creates a dedicated operator account."
  type        = string
  default     = "ubuntu"
}

# ─────────────────────────────────────────────────────────────────────────────
# WireGuard VPN
# ─────────────────────────────────────────────────────────────────────────────

variable "wireguard_port" {
  description = "UDP port for WireGuard VPN server"
  type        = number
  default     = 51820
}

variable "wireguard_vpn_subnet" {
  description = "CIDR for the WireGuard VPN subnet (e.g., 10.8.0.0/24)"
  type        = string
  default     = "10.8.0.0/24"
}

variable "wireguard_server_vpn_ip" {
  description = "VPN IP address assigned to the server's WireGuard interface"
  type        = string
  default     = "10.8.0.1"
}

variable "wireguard_server_private_key" {
  description = <<-EOT
    WireGuard server private key (sensitive). Generate with:
      wg genkey
    Then derive the corresponding public key with:
      echo "<private_key>" | wg pubkey
  EOT
  type        = string
  sensitive   = true
}

variable "wireguard_server_public_key" {
  description = <<-EOT
    WireGuard server public key. Derive from the private key with:
      echo "<wireguard_server_private_key>" | wg pubkey
    This is used in client configuration files.
  EOT
  type        = string
}

variable "wireguard_peers" {
  description = <<-EOT
    List of WireGuard peers (operator clients). Each peer needs:
    - name: Human-readable label (used in comments)
    - public_key: The peer's WireGuard public key (from the client device)
    - vpn_ip: The VPN IP to assign to this peer (e.g., 10.8.0.2)
    - Generate keys on the client: wg genkey | tee privkey | wg pubkey > pubkey
  EOT
  type = list(object({
    name       = string
    public_key = string
    vpn_ip     = string
  }))
  default = []
}

# ─────────────────────────────────────────────────────────────────────────────
# GitLab
# ─────────────────────────────────────────────────────────────────────────────

variable "gitlab_domain" {
  description = "Internal domain for GitLab (accessible via VPN only). Add to /etc/hosts on each client: <server_vpn_ip> <gitlab_domain>"
  type        = string
  default     = "gitlab.internal"
}

variable "gitlab_registry_domain" {
  description = "Internal domain for GitLab Container Registry (accessible via VPN only)"
  type        = string
  default     = "registry.gitlab.internal"
}

variable "gitlab_root_password" {
  description = <<-EOT
    Initial root password for GitLab (sensitive, min 8 chars, GitLab requires ≥8 chars with mixed case).
    Change immediately after first login: Admin Area → Users → root → Edit.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.gitlab_root_password) >= 12
    error_message = "GitLab root password must be at least 12 characters for security."
  }
}

variable "gitlab_version" {
  description = "GitLab CE version to install. Leave empty to install the latest available."
  type        = string
  default     = ""
}

variable "gitlab_puma_workers" {
  description = "Number of Puma worker processes. For ECO servers with ≤16GB RAM, 2 is recommended."
  type        = number
  default     = 2
}

variable "gitlab_sidekiq_concurrency" {
  description = "Sidekiq background job concurrency. Lower values reduce RAM usage."
  type        = number
  default     = 10
}

# ─────────────────────────────────────────────────────────────────────────────
# Backups
# ─────────────────────────────────────────────────────────────────────────────

variable "backup_age_public_key" {
  description = <<-EOT
    age public key for backup encryption (sensitive).
    Generate key pair with: age-keygen -o key.txt
    Use the public key here. Store the private key (key.txt) securely offline.
    Format: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  EOT
  type        = string
  sensitive   = true
}

variable "backup_retention_days" {
  description = "Number of days to retain encrypted local backups before deletion"
  type        = number
  default     = 7
}

variable "backup_cron_hour" {
  description = "Hour (UTC) at which the daily backup cron runs (0-23)"
  type        = number
  default     = 2
}

variable "backup_cron_minute" {
  description = "Minute at which the daily backup cron runs (0-59)"
  type        = number
  default     = 0
}

variable "backup_s3_enabled" {
  description = "Enable remote S3 backup upload via rclone. Requires backup_s3_* variables."
  type        = bool
  default     = false
}

variable "backup_s3_bucket" {
  description = "S3 bucket name for remote backup storage (used when backup_s3_enabled = true)"
  type        = string
  default     = ""
}

variable "backup_s3_endpoint" {
  description = "S3-compatible endpoint URL (e.g., https://s3.gra.io.cloud.ovh.net for OVH Object Storage)"
  type        = string
  default     = ""
}

variable "backup_s3_region" {
  description = "S3 region (e.g., gra for OVH Gravelines)"
  type        = string
  default     = "gra"
}

variable "backup_s3_access_key" {
  description = "S3 access key for remote backup storage (sensitive)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "backup_s3_secret_key" {
  description = "S3 secret key for remote backup storage (sensitive)"
  type        = string
  sensitive   = true
  default     = ""
}
