# infrastructure-private-gitlab
# ─────────────────────────────────────────────────────────────────────────────
# Provisions and configures a private GitLab CE instance on an OVH bare metal
# server (ECO range). GitLab is accessible ONLY via WireGuard VPN — no public
# exposure. Designed for solo operators running proprietary trading code.
#
# Provisioning flow:
#   1. Inject SSH key into OVH account
#   2. Install Ubuntu 24.04 on the bare metal server
#   3. Wait for SSH to become available
#   4. Upload provisioning scripts
#   5. Phase 1: Base hardening (UFW, fail2ban, SSH lockdown)
#   6. Phase 2: WireGuard VPN server
#   7. Phase 3: GitLab CE (VPN-only, self-signed TLS)
#   8. Phase 4: Encrypted daily backups (age + optional S3)
#
# ⚠  WARNING: This module installs a full OS on the target server.
#    The ovh_dedicated_server_install_task resource is lifecycle-ignored
#    after creation. If you accidentally destroy and re-create it, the OS
#    will be reinstalled and all data will be lost.
#    Use a remote state backend and enable state locking in production.

# ─────────────────────────────────────────────────────────────────────────────
# SSH Key injection into OVH account
# ─────────────────────────────────────────────────────────────────────────────

resource "ovh_me_ssh_key" "gitlab" {
  key_label = "gitlab-server-${var.environment}"
  key       = var.ssh_public_key
}

# ─────────────────────────────────────────────────────────────────────────────
# Reference the existing OVH dedicated server
# The server must already exist in your OVH account (order it via the control
# panel first). Terraform only manages the OS installation and configuration.
# ─────────────────────────────────────────────────────────────────────────────

data "ovh_dedicated_server" "gitlab" {
  service_name = var.server_service_name
}

# ─────────────────────────────────────────────────────────────────────────────
# OS installation (Ubuntu 24.04 LTS)
# ─────────────────────────────────────────────────────────────────────────────

resource "ovh_dedicated_server_install_task" "os_install" {
  service_name          = data.ovh_dedicated_server.gitlab.service_name
  template_name         = var.os_template
  partition_scheme_name = "default"

  details {
    custom_hostname = var.hostname
    ssh_key_name    = ovh_me_ssh_key.gitlab.key_label
    language        = "en"
  }

  # CRITICAL: After the OS is installed, this resource must NOT be recreated.
  # Recreating it reinstalls the OS and destroys all data.
  # To force reinstall: tofu taint module.<name>.ovh_dedicated_server_install_task.os_install
  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
  }

  depends_on = [ovh_me_ssh_key.gitlab]
}

# ─────────────────────────────────────────────────────────────────────────────
# Wait for the OS installation to complete and SSH to become available.
# OVH OS installation typically takes 10-25 minutes.
# Terraform's SSH retry mechanism handles the wait — it retries every 10s for
# up to 30 minutes until the connection succeeds.
# ─────────────────────────────────────────────────────────────────────────────

resource "null_resource" "wait_for_ssh" {
  triggers = {
    install_task_id = ovh_dedicated_server_install_task.os_install.id
  }

  connection {
    type        = "ssh"
    host        = data.ovh_dedicated_server.gitlab.ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "30m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'SSH connection established — server is ready'",
      # Brief sleep to ensure all services started during boot are stable
      "sleep 10",
      "uname -a",
    ]
  }

  depends_on = [ovh_dedicated_server_install_task.os_install]
}

# ─────────────────────────────────────────────────────────────────────────────
# Upload provisioning scripts to the server
# ─────────────────────────────────────────────────────────────────────────────

resource "null_resource" "upload_scripts" {
  triggers = {
    ssh_ready        = null_resource.wait_for_ssh.id
    hardening_script = filesha256("${path.module}/scripts/01-base-hardening.sh")
    wireguard_script = filesha256("${path.module}/scripts/02-wireguard.sh")
    gitlab_script    = filesha256("${path.module}/scripts/03-gitlab.sh")
    backup_script    = filesha256("${path.module}/scripts/04-backup.sh")
  }

  connection {
    type        = "ssh"
    host        = data.ovh_dedicated_server.gitlab.ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p /tmp/gitlab-setup"]
  }

  # Copy all scripts to the server
  provisioner "file" {
    source      = "${path.module}/scripts/"
    destination = "/tmp/gitlab-setup"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/gitlab-setup/*.sh",
      "ls -la /tmp/gitlab-setup/",
    ]
  }

  depends_on = [null_resource.wait_for_ssh]
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Base system hardening
# UFW firewall, fail2ban, SSH lockdown, automatic updates, sysctl
# ─────────────────────────────────────────────────────────────────────────────

resource "null_resource" "base_hardening" {
  triggers = {
    scripts_uploaded = null_resource.upload_scripts.id
    script_hash      = filesha256("${path.module}/scripts/01-base-hardening.sh")
    admin_user       = var.admin_username
    wireguard_port   = var.wireguard_port
  }

  connection {
    type        = "ssh"
    host        = data.ovh_dedicated_server.gitlab.ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "20m"
  }

  # Upload hardening config (non-sensitive — just usernames and ports)
  provisioner "file" {
    content     = <<-EOT
      ADMIN_USER="${var.admin_username}"
      WIREGUARD_PORT="${var.wireguard_port}"
    EOT
    destination = "/tmp/gitlab-setup/hardening.env"
  }

  provisioner "remote-exec" {
    inline = ["chmod 600 /tmp/gitlab-setup/hardening.env && sudo /tmp/gitlab-setup/01-base-hardening.sh"]
  }

  depends_on = [null_resource.upload_scripts]
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: WireGuard VPN server
# Generates wg0.conf, starts the service, opens UFW port
# ─────────────────────────────────────────────────────────────────────────────

resource "null_resource" "wireguard_setup" {
  triggers = {
    hardening_done = null_resource.base_hardening.id
    script_hash    = filesha256("${path.module}/scripts/02-wireguard.sh")
    wg_server_key  = sha256(var.wireguard_server_private_key)
    wg_peers       = jsonencode(var.wireguard_peers)
    vpn_subnet     = var.wireguard_vpn_subnet
    wg_port        = var.wireguard_port
  }

  connection {
    type        = "ssh"
    host        = data.ovh_dedicated_server.gitlab.ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  # Upload WireGuard config (contains private key — permissions set immediately)
  provisioner "file" {
    content = sensitive(<<-EOT
      WG_SERVER_PRIVATE_KEY="${var.wireguard_server_private_key}"
      WG_SERVER_VPN_IP="${var.wireguard_server_vpn_ip}"
      WG_VPN_SUBNET="${var.wireguard_vpn_subnet}"
      WG_PORT="${var.wireguard_port}"
      WG_PEERS_JSON='${jsonencode(var.wireguard_peers)}'
    EOT
    )
    destination = "/tmp/gitlab-setup/wg.env"
  }

  provisioner "remote-exec" {
    inline = ["chmod 600 /tmp/gitlab-setup/wg.env && sudo /tmp/gitlab-setup/02-wireguard.sh"]
  }

  depends_on = [null_resource.base_hardening]
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: GitLab CE installation
# Installs gitlab-ce, writes hardened gitlab.rb, generates self-signed TLS,
# runs reconfigure, sets root password.
# ─────────────────────────────────────────────────────────────────────────────

resource "null_resource" "gitlab_install" {
  triggers = {
    wireguard_done = null_resource.wireguard_setup.id
    script_hash    = filesha256("${path.module}/scripts/03-gitlab.sh")
    gitlab_domain  = var.gitlab_domain
    gitlab_rb_hash = sha256(templatefile("${path.module}/templates/gitlab.rb.tpl", {
      environment         = var.environment
      gitlab_domain       = var.gitlab_domain
      registry_domain     = var.gitlab_registry_domain
      server_vpn_ip       = var.wireguard_server_vpn_ip
      puma_workers        = var.gitlab_puma_workers
      sidekiq_concurrency = var.gitlab_sidekiq_concurrency
    }))
  }

  connection {
    type        = "ssh"
    host        = data.ovh_dedicated_server.gitlab.ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "90m" # GitLab installation + reconfigure can take up to 30 min
  }

  # Upload rendered gitlab.rb
  provisioner "file" {
    content = templatefile("${path.module}/templates/gitlab.rb.tpl", {
      environment         = var.environment
      gitlab_domain       = var.gitlab_domain
      registry_domain     = var.gitlab_registry_domain
      server_vpn_ip       = var.wireguard_server_vpn_ip
      puma_workers        = var.gitlab_puma_workers
      sidekiq_concurrency = var.gitlab_sidekiq_concurrency
    })
    destination = "/tmp/gitlab-setup/gitlab.rb.rendered"
  }

  # Upload GitLab install config (contains sensitive root password)
  provisioner "file" {
    content = sensitive(<<-EOT
      GITLAB_ROOT_PASSWORD="${var.gitlab_root_password}"
      GITLAB_DOMAIN="${var.gitlab_domain}"
      GITLAB_REGISTRY_DOMAIN="${var.gitlab_registry_domain}"
      GITLAB_SERVER_VPN_IP="${var.wireguard_server_vpn_ip}"
      GITLAB_VERSION="${var.gitlab_version}"
    EOT
    )
    destination = "/tmp/gitlab-setup/gitlab.env"
  }

  provisioner "remote-exec" {
    inline = ["chmod 600 /tmp/gitlab-setup/gitlab.env && sudo /tmp/gitlab-setup/03-gitlab.sh"]
  }

  depends_on = [null_resource.wireguard_setup]
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4: Backup configuration
# Installs age, writes backup script, configures cron, optional S3 via rclone
# ─────────────────────────────────────────────────────────────────────────────

resource "null_resource" "backup_setup" {
  triggers = {
    gitlab_done    = null_resource.gitlab_install.id
    script_hash    = filesha256("${path.module}/scripts/04-backup.sh")
    age_key_hash   = sha256(var.backup_age_public_key)
    s3_enabled     = var.backup_s3_enabled
    retention_days = var.backup_retention_days
    cron_schedule  = "${var.backup_cron_hour}:${var.backup_cron_minute}"
  }

  connection {
    type        = "ssh"
    host        = data.ovh_dedicated_server.gitlab.ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "15m"
  }

  # Upload backup config (contains S3 credentials if enabled)
  provisioner "file" {
    content = sensitive(<<-EOT
      BACKUP_AGE_PUBLIC_KEY="${var.backup_age_public_key}"
      BACKUP_RETENTION_DAYS="${var.backup_retention_days}"
      BACKUP_CRON_HOUR="${var.backup_cron_hour}"
      BACKUP_CRON_MINUTE="${var.backup_cron_minute}"
      BACKUP_S3_ENABLED="${var.backup_s3_enabled}"
      BACKUP_S3_BUCKET="${var.backup_s3_bucket}"
      BACKUP_S3_ENDPOINT="${var.backup_s3_endpoint}"
      BACKUP_S3_REGION="${var.backup_s3_region}"
      BACKUP_S3_ACCESS_KEY="${var.backup_s3_access_key}"
      BACKUP_S3_SECRET_KEY="${var.backup_s3_secret_key}"
    EOT
    )
    destination = "/tmp/gitlab-setup/backup.env"
  }

  provisioner "remote-exec" {
    inline = ["chmod 600 /tmp/gitlab-setup/backup.env && sudo /tmp/gitlab-setup/04-backup.sh"]
  }

  depends_on = [null_resource.gitlab_install]
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup: Remove setup files from the server after provisioning is complete
# ─────────────────────────────────────────────────────────────────────────────

resource "null_resource" "cleanup_setup_files" {
  triggers = {
    backup_done = null_resource.backup_setup.id
  }

  connection {
    type        = "ssh"
    host        = data.ovh_dedicated_server.gitlab.ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "2m"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo rm -rf /tmp/gitlab-setup",
      "echo 'Setup files cleaned up ✓'",
    ]
  }

  depends_on = [null_resource.backup_setup]
}
