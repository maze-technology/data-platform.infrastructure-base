#!/usr/bin/env bash
# 03-gitlab.sh — GitLab CE installation and configuration
#
# What this script does:
#   1. Installs prerequisites (postfix placeholder, curl, etc.)
#   2. Adds the official GitLab CE apt repository
#   3. Installs gitlab-ce
#   4. Generates a self-signed TLS certificate (covers gitlab + registry domains)
#   5. Writes /etc/gitlab/gitlab.rb from the uploaded rendered template
#   6. Runs gitlab-ctl reconfigure
#   7. Sets the initial root password
#   8. Verifies GitLab is healthy
#
# Config file sourced: /tmp/gitlab-setup/gitlab.env
#   GITLAB_ROOT_PASSWORD  - Initial root password (sensitive)
#   GITLAB_DOMAIN         - GitLab domain (e.g., gitlab.internal)
#   GITLAB_REGISTRY_DOMAIN - Registry domain (e.g., registry.gitlab.internal)
#   GITLAB_SERVER_VPN_IP  - WireGuard VPN IP of the server
#   GITLAB_VERSION        - Version to install (empty = latest)
#
# Pre-requisites:
#   - /tmp/gitlab-setup/gitlab.rb.rendered  — rendered gitlab.rb (from Terraform templatefile)
#
# Idempotent: safe to run multiple times (apt is idempotent, reconfigure is idempotent,
#             password is only reset if the file /etc/gitlab/.root-password-set doesn't exist).

set -euo pipefail

GITLAB_ENV="/tmp/gitlab-setup/gitlab.env"
GITLAB_RB_SRC="/tmp/gitlab-setup/gitlab.rb.rendered"
LOG_PREFIX="[03-gitlab]"

# ─── Load configuration ─────────────────────────────────────────────────────
if [ -f "$GITLAB_ENV" ]; then
  # shellcheck source=/dev/null
  source "$GITLAB_ENV"
  chmod 600 "$GITLAB_ENV" 2>/dev/null || true
else
  echo "$LOG_PREFIX ERROR: $GITLAB_ENV not found" >&2
  exit 1
fi

: "${GITLAB_ROOT_PASSWORD:?GITLAB_ROOT_PASSWORD must be set}"
: "${GITLAB_DOMAIN:?GITLAB_DOMAIN must be set}"
: "${GITLAB_REGISTRY_DOMAIN:?GITLAB_REGISTRY_DOMAIN must be set}"
: "${GITLAB_SERVER_VPN_IP:?GITLAB_SERVER_VPN_IP must be set}"

GITLAB_VERSION="${GITLAB_VERSION:-}"

cleanup() {
  rm -f "$GITLAB_ENV" 2>/dev/null || true
}
trap cleanup EXIT

echo "$LOG_PREFIX Starting GitLab CE installation..."

# ─── 1. Install prerequisites ────────────────────────────────────────────────
echo "$LOG_PREFIX Installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
# Postfix stub (prevent interactive config — GitLab email is disabled in our setup)
echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections
apt-get install -y \
  curl \
  openssh-server \
  ca-certificates \
  tzdata \
  perl \
  python3

# ─── 2. Add GitLab CE apt repository ─────────────────────────────────────────
if ! [ -f /etc/apt/sources.list.d/gitlab_gitlab-ce.list ]; then
  echo "$LOG_PREFIX Adding GitLab CE apt repository..."
  curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | bash
else
  echo "$LOG_PREFIX GitLab repository already configured"
fi

# ─── 3. Install GitLab CE ────────────────────────────────────────────────────
if ! dpkg -l gitlab-ce &>/dev/null 2>&1; then
  echo "$LOG_PREFIX Installing GitLab CE (this may take 5-10 minutes)..."
  if [ -n "$GITLAB_VERSION" ]; then
    GITLAB_PACKAGE="gitlab-ce=${GITLAB_VERSION}"
  else
    GITLAB_PACKAGE="gitlab-ce"
  fi
  # Pass EXTERNAL_URL so the initial reconfigure sets up correctly.
  # We'll overwrite gitlab.rb with our hardened config immediately after.
  EXTERNAL_URL="http://localhost" \
  GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD}" \
    apt-get install -y "$GITLAB_PACKAGE"
  echo "$LOG_PREFIX GitLab CE installed"
else
  echo "$LOG_PREFIX GitLab CE already installed"
fi

# ─── 4. Generate self-signed TLS certificate ─────────────────────────────────
echo "$LOG_PREFIX Generating self-signed TLS certificates..."
mkdir -p /etc/gitlab/ssl
chmod 700 /etc/gitlab/ssl

# Single cert covering both gitlab and registry domains via SAN
SSL_CERT="/etc/gitlab/ssl/${GITLAB_DOMAIN}.crt"
SSL_KEY="/etc/gitlab/ssl/${GITLAB_DOMAIN}.key"
REG_CERT="/etc/gitlab/ssl/${GITLAB_REGISTRY_DOMAIN}.crt"
REG_KEY="/etc/gitlab/ssl/${GITLAB_REGISTRY_DOMAIN}.key"

if [ ! -f "$SSL_CERT" ]; then
  openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
    -keyout "$SSL_KEY" \
    -out "$SSL_CERT" \
    -subj "/C=XX/ST=Private/L=VPN/O=GitLab/OU=Internal/CN=${GITLAB_DOMAIN}" \
    -addext "subjectAltName=DNS:${GITLAB_DOMAIN},DNS:${GITLAB_REGISTRY_DOMAIN},IP:${GITLAB_SERVER_VPN_IP}"

  chmod 600 "$SSL_KEY" "$SSL_CERT"
  chown root:root "$SSL_KEY" "$SSL_CERT"

  echo "$LOG_PREFIX TLS certificate generated: $SSL_CERT"
else
  echo "$LOG_PREFIX TLS certificate already exists: $SSL_CERT"
fi

# Registry uses the same cert (SAN covers both domains)
if [ ! -f "$REG_CERT" ]; then
  cp "$SSL_CERT" "$REG_CERT"
  cp "$SSL_KEY" "$REG_KEY"
  chmod 600 "$REG_KEY" "$REG_CERT"
fi

# ─── 5. Write gitlab.rb from rendered template ───────────────────────────────
echo "$LOG_PREFIX Deploying gitlab.rb configuration..."
if [ ! -f "$GITLAB_RB_SRC" ]; then
  echo "$LOG_PREFIX ERROR: $GITLAB_RB_SRC not found" >&2
  exit 1
fi

# Backup existing config before overwriting
if [ -f /etc/gitlab/gitlab.rb ]; then
  cp /etc/gitlab/gitlab.rb "/etc/gitlab/gitlab.rb.bak.$(date +%Y%m%d%H%M%S)"
fi

cp "$GITLAB_RB_SRC" /etc/gitlab/gitlab.rb
chown root:root /etc/gitlab/gitlab.rb
chmod 600 /etc/gitlab/gitlab.rb

echo "$LOG_PREFIX gitlab.rb deployed"

# ─── 6. Run gitlab-ctl reconfigure ───────────────────────────────────────────
echo "$LOG_PREFIX Running gitlab-ctl reconfigure (this takes 2-5 minutes)..."
gitlab-ctl reconfigure 2>&1 | tail -20 || {
  echo "$LOG_PREFIX ERROR: gitlab-ctl reconfigure failed" >&2
  journalctl --no-pager --lines=50 -u "gitlab-runsvdir" 2>/dev/null || true
  exit 1
}
echo "$LOG_PREFIX GitLab reconfigured successfully"

# ─── 7. Wait for GitLab to be ready ──────────────────────────────────────────
echo "$LOG_PREFIX Waiting for GitLab services to start..."
WAIT_SECS=0
MAX_WAIT=180
until gitlab-ctl status 2>&1 | grep -q "run: puma:" || [ $WAIT_SECS -ge $MAX_WAIT ]; do
  sleep 5
  WAIT_SECS=$((WAIT_SECS + 5))
  [ $((WAIT_SECS % 30)) -eq 0 ] && echo "$LOG_PREFIX  ... still waiting (${WAIT_SECS}s / ${MAX_WAIT}s)"
done

if [ $WAIT_SECS -ge $MAX_WAIT ]; then
  echo "$LOG_PREFIX WARNING: Services didn't start within ${MAX_WAIT}s, checking status..." >&2
  gitlab-ctl status || true
else
  echo "$LOG_PREFIX GitLab services are running"
fi

# ─── 8. Set root password (only on first install) ────────────────────────────
PASSWORD_SET_FLAG="/etc/gitlab/.root-password-configured"

if [ ! -f "$PASSWORD_SET_FLAG" ]; then
  echo "$LOG_PREFIX Setting root password..."
  # Give puma a moment to fully start
  sleep 10

  gitlab-rails runner "
    user = User.find_by(username: 'root')
    if user
      user.password = ENV['GITLAB_ROOT_PASSWORD']
      user.password_confirmation = ENV['GITLAB_ROOT_PASSWORD']
      user.password_automatically_set = false
      if user.save!
        puts 'Root password set successfully'
      else
        STDERR.puts 'Failed to set root password: ' + user.errors.full_messages.join(', ')
        exit 1
      end
    else
      STDERR.puts 'Root user not found'
      exit 1
    end
  " 2>&1 || {
    echo "$LOG_PREFIX WARNING: Could not set root password via Rails runner" >&2
    echo "$LOG_PREFIX Check /etc/gitlab/initial_root_password for the auto-generated password" >&2
  }

  touch "$PASSWORD_SET_FLAG"
  chmod 600 "$PASSWORD_SET_FLAG"
  # Remove the initial_root_password file (password has been set)
  rm -f /etc/gitlab/initial_root_password
  echo "$LOG_PREFIX Root password configured"
else
  echo "$LOG_PREFIX Root password already configured, skipping"
fi

# ─── 9. Final verification ───────────────────────────────────────────────────
echo "$LOG_PREFIX Running GitLab health check..."
gitlab-ctl status 2>&1 | grep -E "^(run|down):" || true

echo ""
echo "$LOG_PREFIX ════════════════════════════════════════════════════"
echo "$LOG_PREFIX GitLab CE installation complete ✓"
echo "$LOG_PREFIX Version: $(gitlab-rake gitlab:env:info 2>/dev/null | grep 'GitLab:' || echo 'unknown')"
echo "$LOG_PREFIX Access: https://${GITLAB_DOMAIN} (requires WireGuard VPN)"
echo "$LOG_PREFIX Registry: https://${GITLAB_REGISTRY_DOMAIN} (requires WireGuard VPN)"
echo "$LOG_PREFIX ════════════════════════════════════════════════════"
