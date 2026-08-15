#!/usr/bin/env bash
# Patch linuxserver/wireguard peer template + generated confs after deploy.
# Invoked by OpenTofu null_resource; expects WG_* env vars.
set -euo pipefail

: "${WG_NS:?}"
: "${WG_LISTEN:?}"
: "${WG_NODEPORT:?}"
: "${WG_ALLOWED:?}"
: "${WG_SERVICE_TYPE:?}"
WG_DNS="${WG_DNS:-10.96.0.10}"
WG_DNS_DOMAIN="${WG_DNS_DOMAIN:-maze.trading}"
WG_PEER_MTU="${WG_PEER_MTU:-1280}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl -n "${WG_NS}" rollout status deploy/wireguard --timeout=300s
for _ in $(seq 1 60); do
  if kubectl -n "${WG_NS}" exec deploy/wireguard -- sh -c 'ls /config/peer_*/*.conf >/dev/null 2>&1'; then
    break
  fi
  sleep 2
done

POD="$(kubectl -n "${WG_NS}" get pod -l app=wireguard -o jsonpath='{.items[0].metadata.name}')"

# Bake split-DNS template (no DNS= — avoids resolvconf -x killing internet).
kubectl -n "${WG_NS}" exec "${POD}" -- mkdir -p /config/templates
sed -e "s/MTU = .*/MTU = ${WG_PEER_MTU}/" \
    -e "s/REPLACE_DNS_DOMAIN/${WG_DNS_DOMAIN}/g" \
    "${SCRIPT_DIR}/templates/peer.conf" \
  | kubectl -n "${WG_NS}" exec -i "${POD}" -- tee /config/templates/peer.conf >/dev/null

kubectl -n "${WG_NS}" exec "${POD}" -- /bin/sh -c "
set -e
conf=/config/wg_confs/wg0.conf
if [ -f \"\$conf\" ] && ! grep -q TCPMSS \"\$conf\"; then
  sed -i 's|^PostUp = \(.*\)|PostUp = \1; iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${WG_PEER_MTU}; iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${WG_PEER_MTU}|' \"\$conf\"
  sed -i 's|^PostDown = \(.*\)|PostDown = \1; iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true; iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${WG_PEER_MTU} 2>/dev/null || true; iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${WG_PEER_MTU} 2>/dev/null || true|' \"\$conf\"
fi
for f in /config/peer_*/*.conf; do
  [ -f \"\$f\" ] || continue
  if [ \"${WG_SERVICE_TYPE}\" = NodePort ]; then
    sed -i \"s/:${WG_LISTEN}\$/:${WG_NODEPORT}/\" \"\$f\"
  fi
  # Avoid '|' delimiter — ALLOWEDIPS may confuse some seds; use '#'
  sed -i \"s#^AllowedIPs = .*#AllowedIPs = ${WG_ALLOWED}#\" \"\$f\"
  sed -i '/^ListenPort = /d' \"\$f\"
  if grep -q '^MTU' \"\$f\"; then
    sed -i \"s/^MTU = .*/MTU = ${WG_PEER_MTU}/\" \"\$f\"
  else
    awk -v mtu=\"${WG_PEER_MTU}\" '
      /^Address = / { print; print \"MTU = \" mtu; next }
      { print }
    ' \"\$f\" > \"\$f.tmp\" && mv \"\$f.tmp\" \"\$f\"
  fi

  # Split-DNS: drop DNS= (resolvconf -x) and install resolvectl hooks.
  sed -i '/^DNS = /d' \"\$f\"
  sed -i '/^PostUp = resolvectl/d' \"\$f\"
  sed -i '/^PostDown = resolvectl/d' \"\$f\"
  # Insert after MTU (or Address if no MTU)
  if grep -q '^MTU = ' \"\$f\"; then
    sed -i \"/^MTU = /a PostUp = resolvectl dns %i ${WG_DNS}; resolvectl domain %i ~${WG_DNS_DOMAIN}; resolvectl default-route %i false\\nPostDown = resolvectl revert %i\" \"\$f\"
  else
    sed -i \"/^Address = /a PostUp = resolvectl dns %i ${WG_DNS}; resolvectl domain %i ~${WG_DNS_DOMAIN}; resolvectl default-route %i false\\nPostDown = resolvectl revert %i\" \"\$f\"
  fi

  echo patched \"\$f\"
  grep -E '^(Address|DNS|Endpoint|AllowedIPs|MTU|PostUp|PostDown)' \"\$f\" || true
done
"
