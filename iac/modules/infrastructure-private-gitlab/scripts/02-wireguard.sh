#!/usr/bin/env bash
# 02-wireguard.sh — WireGuard VPN server setup
#
# What this script does:
#   1. Installs WireGuard
#   2. Writes the server WireGuard config (/etc/wireguard/wg0.conf)
#   3. Adds iptables PostUp/PostDown rules for NAT routing
#   4. Starts and enables the wg-quick@wg0 service
#
# Environment variables (sourced from /tmp/gitlab-setup/wg.env):
#   WG_SERVER_PRIVATE_KEY  - WireGuard server private key (sensitive)
#   WG_SERVER_VPN_IP       - VPN IP of the server (e.g., 10.8.0.1)
#   WG_VPN_SUBNET          - VPN subnet in CIDR (e.g., 10.8.0.0/24)
#   WG_PORT                - WireGuard UDP listen port
#   WG_PEERS_JSON          - JSON array of peers: [{"name":"...","public_key":"...","vpn_ip":"..."}]
#
# Idempotent: Re-running updates the WireGuard config and reloads the service.

set -euo pipefail

WG_ENV="/tmp/gitlab-setup/wg.env"
LOG_PREFIX="[02-wireguard]"

# ─── Load configuration ─────────────────────────────────────────────────────
if [ -f "$WG_ENV" ]; then
  # shellcheck source=/dev/null
  source "$WG_ENV"
  chmod 600 "$WG_ENV" 2>/dev/null || true
else
  echo "$LOG_PREFIX ERROR: $WG_ENV not found" >&2
  exit 1
fi

# Validate required variables
: "${WG_SERVER_PRIVATE_KEY:?WG_SERVER_PRIVATE_KEY must be set}"
: "${WG_SERVER_VPN_IP:?WG_SERVER_VPN_IP must be set}"
: "${WG_VPN_SUBNET:?WG_VPN_SUBNET must be set}"
: "${WG_PORT:?WG_PORT must be set}"

# Cleanup sensitive env file on exit
cleanup() {
  rm -f "$WG_ENV" 2>/dev/null || true
}
trap cleanup EXIT

echo "$LOG_PREFIX Setting up WireGuard VPN server..."

# ─── 1. Install WireGuard ────────────────────────────────────────────────────
echo "$LOG_PREFIX Installing WireGuard..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y wireguard wireguard-tools iptables

# ─── 2. Detect default network interface ─────────────────────────────────────
# Used for iptables NAT rules (PostUp/PostDown)
DEFAULT_IFACE=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
if [ -z "$DEFAULT_IFACE" ]; then
  # Fallback: pick the first non-loopback interface
  DEFAULT_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | head -1)
fi
echo "$LOG_PREFIX Default network interface: $DEFAULT_IFACE"

# ─── 3. Write WireGuard server configuration ─────────────────────────────────
echo "$LOG_PREFIX Writing WireGuard server config..."
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

# Build peer section from JSON (passed as escaped JSON string in env var)
PEERS_SECTION=""
if [ -n "${WG_PEERS_JSON:-}" ]; then
  # Parse each peer from JSON array using awk (no jq dependency required here)
  PEER_COUNT=$(echo "$WG_PEERS_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data))")
  for i in $(seq 0 $((PEER_COUNT - 1))); do
    PEER_NAME=$(echo "$WG_PEERS_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data[$i]['name'])")
    PEER_PUBKEY=$(echo "$WG_PEERS_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data[$i]['public_key'])")
    PEER_VPN_IP=$(echo "$WG_PEERS_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data[$i]['vpn_ip'])")
    PEERS_SECTION="${PEERS_SECTION}
# Peer: ${PEER_NAME}
[Peer]
PublicKey = ${PEER_PUBKEY}
AllowedIPs = ${PEER_VPN_IP}/32
"
  done
fi

# Write the full WireGuard config atomically (temp file then move)
WG_CONFIG_TMP=$(mktemp)
cat > "$WG_CONFIG_TMP" << EOF
# WireGuard VPN server configuration
# Interface: wg0
# Managed by OpenTofu — manual edits will be overwritten on re-provision

[Interface]
PrivateKey = ${WG_SERVER_PRIVATE_KEY}
Address = ${WG_SERVER_VPN_IP}/24
ListenPort = ${WG_PORT}

# NAT rules: route VPN traffic through the default interface
# DEFAULT_IFACE=${DEFAULT_IFACE}
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
${PEERS_SECTION}
EOF

# Move atomically, set restrictive permissions (private key is in this file)
mv "$WG_CONFIG_TMP" /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf
chown root:root /etc/wireguard/wg0.conf

echo "$LOG_PREFIX WireGuard config written to /etc/wireguard/wg0.conf"

# ─── 4. Enable and start WireGuard ───────────────────────────────────────────
echo "$LOG_PREFIX Enabling and starting WireGuard service..."

systemctl enable wg-quick@wg0

# If service is running, reload config; otherwise start fresh
if systemctl is-active --quiet wg-quick@wg0; then
  echo "$LOG_PREFIX WireGuard is running — syncing config..."
  wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || {
    echo "$LOG_PREFIX syncconf failed, restarting service..."
    systemctl restart wg-quick@wg0
  }
else
  echo "$LOG_PREFIX Starting WireGuard..."
  systemctl start wg-quick@wg0
fi

# Wait for interface to come up
sleep 2
if ip link show wg0 &>/dev/null; then
  echo "$LOG_PREFIX WireGuard interface wg0 is UP"
  wg show wg0
else
  echo "$LOG_PREFIX ERROR: wg0 interface did not come up" >&2
  journalctl -u "wg-quick@wg0" --no-pager --lines=20 >&2 || true
  exit 1
fi

# ─── 5. Update UFW to allow VPN traffic ──────────────────────────────────────
# The WireGuard port was already opened in 01-base-hardening.sh.
# Allow forwarded traffic through wg0 (for NAT routing).
# These iptables rules are managed by wg-quick PostUp/PostDown, not UFW,
# so no additional UFW rules are needed.

echo "$LOG_PREFIX WireGuard VPN server configured successfully ✓"
echo "$LOG_PREFIX Server VPN IP: ${WG_SERVER_VPN_IP}"
echo "$LOG_PREFIX Listening on port: ${WG_PORT}/udp"
