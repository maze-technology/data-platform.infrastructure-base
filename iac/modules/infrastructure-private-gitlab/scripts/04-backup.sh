#!/usr/bin/env bash
# 04-backup.sh — GitLab backup system setup
#
# What this script does:
#   1. Installs age (encryption tool) and rclone (S3 sync, optional)
#   2. Writes the backup script to /usr/local/bin/gitlab-backup-full
#   3. Installs cron job for daily backups
#   4. Configures rclone for S3 remote (optional)
#   5. Creates backup directory with correct permissions
#   6. Runs a test backup (optional, only on first install)
#
# Config file sourced: /tmp/gitlab-setup/backup.env
#   BACKUP_AGE_PUBLIC_KEY   - age public key for encrypting backups
#   BACKUP_RETENTION_DAYS   - days to keep local encrypted backups
#   BACKUP_CRON_HOUR        - cron hour for daily backup (default: 2)
#   BACKUP_CRON_MINUTE      - cron minute for daily backup (default: 0)
#   BACKUP_S3_ENABLED       - "true" to enable S3 remote upload
#   BACKUP_S3_BUCKET        - S3 bucket name
#   BACKUP_S3_ENDPOINT      - S3 endpoint URL
#   BACKUP_S3_REGION        - S3 region
#   BACKUP_S3_ACCESS_KEY    - S3 access key (sensitive)
#   BACKUP_S3_SECRET_KEY    - S3 secret key (sensitive)
#
# Idempotent: safe to run multiple times.

set -euo pipefail

BACKUP_ENV="/tmp/gitlab-setup/backup.env"
LOG_PREFIX="[04-backup]"

# ─── Load configuration ─────────────────────────────────────────────────────
if [ -f "$BACKUP_ENV" ]; then
  # shellcheck source=/dev/null
  source "$BACKUP_ENV"
  chmod 600 "$BACKUP_ENV" 2>/dev/null || true
else
  echo "$LOG_PREFIX ERROR: $BACKUP_ENV not found" >&2
  exit 1
fi

: "${BACKUP_AGE_PUBLIC_KEY:?BACKUP_AGE_PUBLIC_KEY must be set}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_CRON_HOUR="${BACKUP_CRON_HOUR:-2}"
BACKUP_CRON_MINUTE="${BACKUP_CRON_MINUTE:-0}"
BACKUP_S3_ENABLED="${BACKUP_S3_ENABLED:-false}"

cleanup() {
  rm -f "$BACKUP_ENV" 2>/dev/null || true
}
trap cleanup EXIT

echo "$LOG_PREFIX Setting up GitLab backup system..."

# ─── 1. Install age ──────────────────────────────────────────────────────────
if ! command -v age &>/dev/null; then
  echo "$LOG_PREFIX Installing age (encryption tool)..."
  # Install latest age release
  AGE_VERSION=$(curl -fsSL "https://api.github.com/repos/FiloSottile/age/releases/latest" \
    | python3 -c "import sys, json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null \
    || echo "v1.1.1")
  AGE_URL="https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz"

  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' RETURN
  curl -fsSL "$AGE_URL" | tar -xz -C "$TMP_DIR"
  mv "$TMP_DIR/age/age" /usr/local/bin/age
  mv "$TMP_DIR/age/age-keygen" /usr/local/bin/age-keygen
  chmod 755 /usr/local/bin/age /usr/local/bin/age-keygen
  echo "$LOG_PREFIX age ${AGE_VERSION} installed"
else
  echo "$LOG_PREFIX age already installed: $(age --version 2>&1)"
fi

# ─── 2. Install rclone (if S3 is enabled) ────────────────────────────────────
if [ "$BACKUP_S3_ENABLED" = "true" ]; then
  if ! command -v rclone &>/dev/null; then
    echo "$LOG_PREFIX Installing rclone for S3 uploads..."
    curl -fsSL https://rclone.org/install.sh | bash
    echo "$LOG_PREFIX rclone installed: $(rclone version 2>&1 | head -1)"
  else
    echo "$LOG_PREFIX rclone already installed"
  fi

  # Configure rclone S3 remote
  RCLONE_CONFIG_DIR="/root/.config/rclone"
  mkdir -p "$RCLONE_CONFIG_DIR"
  chmod 700 "$RCLONE_CONFIG_DIR"

  cat > "$RCLONE_CONFIG_DIR/rclone.conf" << EOF
# rclone config for GitLab backup S3 remote — managed by OpenTofu
[gitlab-backup-s3]
type = s3
provider = Other
access_key_id = ${BACKUP_S3_ACCESS_KEY:-}
secret_access_key = ${BACKUP_S3_SECRET_KEY:-}
endpoint = ${BACKUP_S3_ENDPOINT:-}
region = ${BACKUP_S3_REGION:-gra}
acl = private
no_check_bucket = false
# server_side_encryption = AES256
EOF
  chmod 600 "$RCLONE_CONFIG_DIR/rclone.conf"
  echo "$LOG_PREFIX rclone configured for S3 remote: gitlab-backup-s3"
fi

# ─── 3. Create backup directories ─────────────────────────────────────────────
echo "$LOG_PREFIX Setting up backup directories..."
BACKUP_DIR="/var/opt/gitlab/backups"
BACKUP_ENCRYPTED_DIR="/var/opt/gitlab/backups/encrypted"
CONFIG_BACKUP_DIR="/var/opt/gitlab/backups/config"

mkdir -p "$BACKUP_ENCRYPTED_DIR" "$CONFIG_BACKUP_DIR"
chown git:git "$BACKUP_DIR" "$BACKUP_ENCRYPTED_DIR" 2>/dev/null || \
  chown root:root "$BACKUP_ENCRYPTED_DIR"
chmod 750 "$BACKUP_DIR" "$BACKUP_ENCRYPTED_DIR" "$CONFIG_BACKUP_DIR"

# ─── 4. Store the age public key ─────────────────────────────────────────────
echo "$LOG_PREFIX Storing backup encryption key reference..."
mkdir -p /etc/gitlab/backup
echo "$BACKUP_AGE_PUBLIC_KEY" > /etc/gitlab/backup/age-public-key.txt
chmod 640 /etc/gitlab/backup/age-public-key.txt
chown root:root /etc/gitlab/backup/age-public-key.txt

# ─── 5. Write the backup script ──────────────────────────────────────────────
echo "$LOG_PREFIX Writing backup script to /usr/local/bin/gitlab-backup-full..."

cat > /usr/local/bin/gitlab-backup-full << 'BACKUP_SCRIPT'
#!/usr/bin/env bash
# GitLab full backup script — managed by OpenTofu
# Runs daily via cron. Creates a GitLab backup, encrypts it with age,
# stores it locally, and optionally uploads to S3.
#
# Usage: sudo /usr/local/bin/gitlab-backup-full [--test]
#   --test  Run a quick connectivity test only (no actual backup)

set -euo pipefail

BACKUP_LOG="/var/log/gitlab/gitlab-backup.log"
BACKUP_DIR="/var/opt/gitlab/backups"
ENCRYPTED_DIR="${BACKUP_DIR}/encrypted"
CONFIG_BACKUP_DIR="${BACKUP_DIR}/config"
AGE_PUBLIC_KEY_FILE="/etc/gitlab/backup/age-public-key.txt"
RETENTION_DAYS=7  # Overridden by /etc/gitlab/backup/retention.conf if present
S3_ENABLED=false  # Overridden by /etc/gitlab/backup/s3.conf if present

# Load optional config files
[ -f /etc/gitlab/backup/retention.conf ] && source /etc/gitlab/backup/retention.conf
[ -f /etc/gitlab/backup/s3.conf ]        && source /etc/gitlab/backup/s3.conf

TIMESTAMP=$(date +%Y%m%d%H%M%S)
LOG_PREFIX="[gitlab-backup][${TIMESTAMP}]"

# Ensure log file exists
mkdir -p "$(dirname "$BACKUP_LOG")"
touch "$BACKUP_LOG"
exec > >(tee -a "$BACKUP_LOG") 2>&1

echo "${LOG_PREFIX} ─────────────────────────────────────────────────"
echo "${LOG_PREFIX} Starting GitLab full backup"
echo "${LOG_PREFIX} Hostname: $(hostname)"
echo "${LOG_PREFIX} ─────────────────────────────────────────────────"

# ─── Validate dependencies ──────────────────────────────────────────────────
if ! command -v age &>/dev/null; then
  echo "${LOG_PREFIX} ERROR: age not found. Run 04-backup.sh to reinstall." >&2
  exit 1
fi

if ! [ -f "$AGE_PUBLIC_KEY_FILE" ]; then
  echo "${LOG_PREFIX} ERROR: age public key not found at $AGE_PUBLIC_KEY_FILE" >&2
  exit 1
fi

AGE_PUBLIC_KEY=$(cat "$AGE_PUBLIC_KEY_FILE")

# ─── Test mode ──────────────────────────────────────────────────────────────
if [ "${1:-}" = "--test" ]; then
  echo "${LOG_PREFIX} Test mode: checking dependencies only"
  echo "${LOG_PREFIX}  ✓ age: $(age --version 2>&1)"
  echo "${LOG_PREFIX}  ✓ gitlab-backup: $(which gitlab-backup)"
  echo "${LOG_PREFIX}  ✓ age public key loaded (${#AGE_PUBLIC_KEY} chars)"
  if [ "$S3_ENABLED" = "true" ] && command -v rclone &>/dev/null; then
    echo "${LOG_PREFIX}  ✓ rclone: $(rclone version 2>&1 | head -1)"
    rclone lsd gitlab-backup-s3: 2>/dev/null && echo "${LOG_PREFIX}  ✓ S3 connectivity OK" \
      || echo "${LOG_PREFIX}  ⚠ S3 connectivity failed (check rclone config)"
  fi
  echo "${LOG_PREFIX} Test complete"
  exit 0
fi

# ─── Step 1: GitLab application backup ──────────────────────────────────────
echo "${LOG_PREFIX} Creating GitLab application backup..."
# STRATEGY=copy prevents issues with active files being modified during backup
# SKIP=artifacts skips CI artifacts to keep backup size manageable (comment to include)
gitlab-backup create STRATEGY=copy 2>&1

# Find the latest backup tar (GitLab creates: EPOCH_YYYY_MM_DD_VERSION_gitlab_backup.tar)
LATEST_BACKUP=$(ls -t "${BACKUP_DIR}"/*.tar 2>/dev/null | head -1)
if [ -z "$LATEST_BACKUP" ]; then
  echo "${LOG_PREFIX} ERROR: No backup tar found in ${BACKUP_DIR}" >&2
  exit 1
fi
BACKUP_BASENAME=$(basename "$LATEST_BACKUP")
echo "${LOG_PREFIX} Backup created: ${BACKUP_BASENAME}"

# ─── Step 2: Encrypt the backup with age ────────────────────────────────────
echo "${LOG_PREFIX} Encrypting backup with age..."
ENCRYPTED_FILE="${ENCRYPTED_DIR}/${BACKUP_BASENAME}.age"
age -r "$AGE_PUBLIC_KEY" -o "$ENCRYPTED_FILE" "$LATEST_BACKUP"
chmod 640 "$ENCRYPTED_FILE"
echo "${LOG_PREFIX} Encrypted: ${ENCRYPTED_FILE}"
echo "${LOG_PREFIX} Encrypted size: $(du -h "$ENCRYPTED_FILE" | cut -f1)"

# Remove unencrypted backup immediately after encryption
rm -f "$LATEST_BACKUP"
echo "${LOG_PREFIX} Unencrypted backup removed"

# ─── Step 3: Backup GitLab configuration ─────────────────────────────────────
echo "${LOG_PREFIX} Backing up /etc/gitlab configuration..."
CONFIG_TAR="/tmp/gitlab-config-${TIMESTAMP}.tar.gz"
tar -czf "$CONFIG_TAR" /etc/gitlab 2>/dev/null || \
  tar -czf "$CONFIG_TAR" --warning=no-file-changed /etc/gitlab || true

CONFIG_ENCRYPTED="${CONFIG_BACKUP_DIR}/gitlab-config-${TIMESTAMP}.tar.gz.age"
age -r "$AGE_PUBLIC_KEY" -o "$CONFIG_ENCRYPTED" "$CONFIG_TAR"
chmod 640 "$CONFIG_ENCRYPTED"
rm -f "$CONFIG_TAR"
echo "${LOG_PREFIX} Config backup encrypted: ${CONFIG_ENCRYPTED}"

# ─── Step 4: Upload to S3 (optional) ─────────────────────────────────────────
if [ "$S3_ENABLED" = "true" ] && command -v rclone &>/dev/null; then
  echo "${LOG_PREFIX} Uploading backups to S3..."
  rclone copy "$ENCRYPTED_DIR" "gitlab-backup-s3:${S3_BUCKET:-gitlab-backups}/backups/" \
    --include "*.age" \
    --transfers 1 \
    --stats 60s \
    2>&1 || echo "${LOG_PREFIX} WARNING: S3 upload failed (local backup still intact)"
  rclone copy "$CONFIG_BACKUP_DIR" "gitlab-backup-s3:${S3_BUCKET:-gitlab-backups}/config/" \
    --include "*.age" \
    --transfers 1 \
    2>&1 || echo "${LOG_PREFIX} WARNING: S3 config upload failed"
  echo "${LOG_PREFIX} S3 upload complete"
else
  echo "${LOG_PREFIX} S3 upload: disabled"
fi

# ─── Step 5: Prune old local backups ─────────────────────────────────────────
echo "${LOG_PREFIX} Pruning backups older than ${RETENTION_DAYS} days..."
find "$ENCRYPTED_DIR" -name "*.tar.age" -mtime "+${RETENTION_DAYS}" -delete -print | \
  sed "s/^/${LOG_PREFIX} Deleted: /"
find "$CONFIG_BACKUP_DIR" -name "*.age" -mtime "+${RETENTION_DAYS}" -delete -print | \
  sed "s/^/${LOG_PREFIX} Deleted config: /"

# ─── Done ─────────────────────────────────────────────────────────────────────
echo "${LOG_PREFIX} ─────────────────────────────────────────────────"
echo "${LOG_PREFIX} Backup complete ✓"
echo "${LOG_PREFIX} Local encrypted backup: ${ENCRYPTED_FILE}"
echo "${LOG_PREFIX} ─────────────────────────────────────────────────"
BACKUP_SCRIPT

chmod 755 /usr/local/bin/gitlab-backup-full

# ─── 6. Write retention config ────────────────────────────────────────────────
cat > /etc/gitlab/backup/retention.conf << EOF
# Backup retention configuration — managed by OpenTofu
RETENTION_DAYS=${BACKUP_RETENTION_DAYS}
EOF

# ─── 7. Write S3 config (if enabled) ─────────────────────────────────────────
if [ "$BACKUP_S3_ENABLED" = "true" ]; then
  cat > /etc/gitlab/backup/s3.conf << EOF
# S3 backup configuration — managed by OpenTofu (sensitive — chmod 600)
S3_ENABLED=true
S3_BUCKET=${BACKUP_S3_BUCKET:-}
EOF
  chmod 600 /etc/gitlab/backup/s3.conf
fi

# ─── 8. Install cron job ──────────────────────────────────────────────────────
echo "$LOG_PREFIX Installing backup cron job..."

CRON_FILE="/etc/cron.d/gitlab-backup"
cat > "$CRON_FILE" << EOF
# GitLab full backup — managed by OpenTofu
# Runs daily at ${BACKUP_CRON_HOUR}:$(printf '%02d' "$BACKUP_CRON_MINUTE") UTC
# Backups are age-encrypted and stored at /var/opt/gitlab/backups/encrypted/
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
$(printf '%02d' "$BACKUP_CRON_MINUTE") ${BACKUP_CRON_HOUR} * * * root /usr/local/bin/gitlab-backup-full >> /var/log/gitlab/gitlab-backup-cron.log 2>&1
EOF
chmod 644 "$CRON_FILE"
echo "$LOG_PREFIX Backup cron installed: daily at ${BACKUP_CRON_HOUR}:$(printf '%02d' "$BACKUP_CRON_MINUTE") UTC"

# ─── 9. Set up log rotation for backup logs ──────────────────────────────────
cat > /etc/logrotate.d/gitlab-backup << 'EOF'
/var/log/gitlab/gitlab-backup*.log {
  daily
  missingok
  rotate 30
  compress
  delaycompress
  notifempty
  create 640 root root
}
EOF

echo "$LOG_PREFIX Backup system configured ✓"
echo "$LOG_PREFIX Schedule: ${BACKUP_CRON_HOUR}:$(printf '%02d' "$BACKUP_CRON_MINUTE") UTC daily"
echo "$LOG_PREFIX Retention: ${BACKUP_RETENTION_DAYS} days locally"
echo "$LOG_PREFIX Encryption: age (public key from /etc/gitlab/backup/age-public-key.txt)"
if [ "$BACKUP_S3_ENABLED" = "true" ]; then
  echo "$LOG_PREFIX S3 remote: enabled → ${BACKUP_S3_BUCKET:-<not configured>}"
fi
echo ""
echo "$LOG_PREFIX ⚠  IMPORTANT: Store your age PRIVATE KEY offline and securely!"
echo "$LOG_PREFIX    Without it, encrypted backups CANNOT be restored."
echo "$LOG_PREFIX    Test restore procedure: age -d -i age-private.key backup.tar.age"
