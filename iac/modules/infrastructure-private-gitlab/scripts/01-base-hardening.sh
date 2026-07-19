#!/usr/bin/env bash
# 01-base-hardening.sh — Base system hardening for the GitLab bare metal server
#
# What this script does:
#   1. Applies all pending security updates
#   2. Installs essential security tools (fail2ban, ufw, unattended-upgrades)
#   3. Creates a non-root admin user (if ADMIN_USER differs from "ubuntu")
#   4. Hardens SSH daemon configuration
#   5. Configures UFW firewall (allow SSH + WireGuard, deny everything else)
#   6. Configures fail2ban to protect SSH
#   7. Enables automatic security updates
#   8. Sets kernel sysctl parameters (IP forwarding for WireGuard NAT)
#
# Environment variables (sourced from /tmp/gitlab-setup/hardening.env):
#   ADMIN_USER       - Non-root admin username to create (default: ubuntu)
#   WIREGUARD_PORT   - WireGuard UDP port to allow through firewall
#
# Idempotent: safe to run multiple times.

set -euo pipefail

HARDENING_ENV="/tmp/gitlab-setup/hardening.env"
LOG_PREFIX="[01-base-hardening]"

# ─── Load configuration ─────────────────────────────────────────────────────
if [ -f "$HARDENING_ENV" ]; then
  # shellcheck source=/dev/null
  source "$HARDENING_ENV"
  chmod 600 "$HARDENING_ENV" 2>/dev/null || true
else
  echo "$LOG_PREFIX ERROR: $HARDENING_ENV not found" >&2
  exit 1
fi

ADMIN_USER="${ADMIN_USER:-ubuntu}"
WIREGUARD_PORT="${WIREGUARD_PORT:-51820}"

# Cleanup sensitive env file on exit
cleanup() {
  rm -f "$HARDENING_ENV" 2>/dev/null || true
}
trap cleanup EXIT

echo "$LOG_PREFIX Starting base system hardening..."

# ─── 1. System update ────────────────────────────────────────────────────────
echo "$LOG_PREFIX Updating package index and applying security updates..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# Upgrade only security-relevant packages first (faster, safer)
apt-get dist-upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"

# ─── 2. Install essential packages ──────────────────────────────────────────
echo "$LOG_PREFIX Installing essential security packages..."
apt-get install -y \
  fail2ban \
  ufw \
  unattended-upgrades \
  apt-listchanges \
  curl \
  wget \
  gnupg \
  ca-certificates \
  apt-transport-https \
  lsb-release \
  jq \
  vim \
  htop \
  ncdu \
  logrotate \
  chrony

# Ensure chrony (NTP) is running for correct timestamps in logs/backups
systemctl enable --now chrony 2>/dev/null || \
  systemctl enable --now chronyd 2>/dev/null || true

# ─── 3. Create non-root admin user ───────────────────────────────────────────
if [ "$ADMIN_USER" != "ubuntu" ] && ! id "$ADMIN_USER" &>/dev/null; then
  echo "$LOG_PREFIX Creating admin user: $ADMIN_USER"
  useradd -m -s /bin/bash -G sudo "$ADMIN_USER"

  # Copy SSH authorized_keys from ubuntu user (same SSH key, different account)
  if [ -f /home/ubuntu/.ssh/authorized_keys ]; then
    mkdir -p "/home/$ADMIN_USER/.ssh"
    cp /home/ubuntu/.ssh/authorized_keys "/home/$ADMIN_USER/.ssh/authorized_keys"
    chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
    chmod 700 "/home/$ADMIN_USER/.ssh"
    chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
  fi

  # Allow sudo without password for admin user
  echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$ADMIN_USER"
  chmod 440 "/etc/sudoers.d/90-$ADMIN_USER"

  echo "$LOG_PREFIX Admin user $ADMIN_USER created successfully"
elif [ "$ADMIN_USER" != "ubuntu" ]; then
  echo "$LOG_PREFIX Admin user $ADMIN_USER already exists, skipping creation"
fi

# ─── 4. SSH hardening ────────────────────────────────────────────────────────
echo "$LOG_PREFIX Hardening SSH daemon configuration..."

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_OVERRIDE="/etc/ssh/sshd_config.d/99-hardening.conf"

# Write hardening overrides to a drop-in file (doesn't touch the main sshd_config)
cat > "$SSHD_OVERRIDE" << 'EOF'
# GitLab server SSH hardening — managed by OpenTofu
# Drop-in override for /etc/ssh/sshd_config

# Disable root login entirely
PermitRootLogin no

# Disable all password-based authentication (key-only)
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no

# Disable unused authentication methods
GSSAPIAuthentication no
UsePAM yes

# Security settings
X11Forwarding no
AllowTcpForwarding yes    # Needed for WireGuard tunnel establishment via SSH
MaxAuthTries 3
LoginGraceTime 30

# Only allow SSH protocol 2
Protocol 2

# Log all authentication attempts
LogLevel VERBOSE

# Connection timeouts to free idle sessions
ClientAliveInterval 300
ClientAliveCountMax 2

# Limit concurrent unauthenticated connections
MaxStartups 3:50:10
EOF

# Validate the config before reloading
if ! sshd -t 2>/dev/null; then
  echo "$LOG_PREFIX WARNING: sshd_config validation failed, keeping current config" >&2
else
  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
  echo "$LOG_PREFIX SSH daemon hardened and reloaded"
fi

# ─── 5. UFW firewall ─────────────────────────────────────────────────────────
echo "$LOG_PREFIX Configuring UFW firewall..."

# Reset UFW to defaults (idempotent — clears any manual rules)
ufw --force reset

# Default policies: deny all incoming, allow all outgoing
ufw default deny incoming
ufw default allow outgoing

# Allow SSH from anywhere (REQUIRED for emergency access)
# Even with WireGuard, we keep public SSH as an escape hatch.
# Protected by fail2ban (key-only auth means brute force attacks fail).
ufw allow 22/tcp comment "SSH admin access"

# Allow WireGuard VPN
ufw allow "${WIREGUARD_PORT}/udp" comment "WireGuard VPN"

# GitLab ports (80/443/5050) are NOT opened here.
# nginx is bound to the WireGuard VPN IP (10.8.0.1) only, so they're
# unreachable from the public internet regardless of firewall rules.
# Defense-in-depth: explicitly deny them on the public interface.
ufw deny 80/tcp   comment "Block public HTTP — GitLab VPN-only"
ufw deny 443/tcp  comment "Block public HTTPS — GitLab VPN-only"
ufw deny 5050/tcp comment "Block public Registry — GitLab VPN-only"

# Enable UFW (non-interactive)
ufw --force enable

echo "$LOG_PREFIX UFW configured and enabled"
ufw status verbose

# ─── 6. fail2ban ─────────────────────────────────────────────────────────────
echo "$LOG_PREFIX Configuring fail2ban..."

# Write a custom jail.local that extends the defaults
cat > /etc/fail2ban/jail.local << EOF
# fail2ban local configuration — managed by OpenTofu
# Extends /etc/fail2ban/jail.conf defaults

[DEFAULT]
# Ban IPs for 1 hour on first offense
bantime  = 3600
# Look back 10 minutes for repeated failures
findtime = 600
# Allow 3 failures before banning
maxretry = 3
# Use UFW as the ban action (consistent with our firewall)
banaction = ufw
banaction_allports = ufw

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 7200
findtime = 300
EOF

# Create UFW action file for fail2ban (if not already present)
if [ ! -f /etc/fail2ban/action.d/ufw.conf ]; then
  cat > /etc/fail2ban/action.d/ufw.conf << 'EOF'
[Definition]
actionstart =
actionstop  =
actioncheck =
actionban   = ufw insert 1 deny from <ip> to any
actionunban = ufw delete deny from <ip> to any
EOF
fi

systemctl enable --now fail2ban
systemctl restart fail2ban

echo "$LOG_PREFIX fail2ban configured and started"

# ─── 7. Unattended security updates ─────────────────────────────────────────
echo "$LOG_PREFIX Configuring automatic security updates..."

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
// Unattended security upgrades — managed by OpenTofu
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "02:30";
Unattended-Upgrade::Mail "";
Unattended-Upgrade::MailReport "only-on-error";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable --now unattended-upgrades

echo "$LOG_PREFIX Automatic security updates enabled"

# ─── 8. Kernel sysctl — IP forwarding ────────────────────────────────────────
echo "$LOG_PREFIX Configuring kernel sysctl parameters..."

cat > /etc/sysctl.d/99-wireguard.conf << 'EOF'
# IP forwarding required for WireGuard NAT routing — managed by OpenTofu
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Harden network stack
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
EOF

sysctl --system

echo "$LOG_PREFIX Kernel parameters applied"
echo "$LOG_PREFIX Base hardening complete ✓"
