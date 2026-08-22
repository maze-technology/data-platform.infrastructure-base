#!/usr/bin/env bash
# Ensure namespace has Secret wireguard-config-seed (shared by DaemonSet pods).
# Bootstraps once from a PVC-backed pod when the Secret is missing.
set -euo pipefail

: "${WG_NS:?}"
: "${WG_SERVER_URL:?}"
: "${WG_SERVER_PORT:?}"
: "${WG_PEERS:?}"
: "${WG_VPN_SUBNET:?}"
: "${WG_ALLOWED:?}"
WG_DNS="${WG_DNS:-auto}"

if kubectl -n "${WG_NS}" get secret wireguard-config-seed >/dev/null 2>&1; then
  echo "wireguard-config-seed already present"
  exit 0
fi

echo "bootstrapping wireguard-config-seed from PVC"
kubectl -n "${WG_NS}" delete pod wireguard-seed-bootstrap --ignore-not-found >/dev/null
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: wireguard-seed-bootstrap
  namespace: ${WG_NS}
spec:
  restartPolicy: Never
  containers:
    - name: wireguard
      image: lscr.io/linuxserver/wireguard:latest
      env:
        - name: PUID
          value: "1000"
        - name: PGID
          value: "1000"
        - name: TZ
          value: UTC
        - name: SERVERURL
          value: "${WG_SERVER_URL}"
        - name: SERVERPORT
          value: "${WG_SERVER_PORT}"
        - name: PEERS
          value: "${WG_PEERS}"
        - name: PEERDNS
          value: "${WG_DNS}"
        - name: INTERNAL_SUBNET
          value: "${WG_VPN_SUBNET}"
        - name: ALLOWEDIPS
          value: "${WG_ALLOWED}"
        - name: LOG_CONFS
          value: "true"
      securityContext:
        privileged: true
        capabilities:
          add: ["NET_ADMIN", "SYS_MODULE"]
      volumeMounts:
        - name: config
          mountPath: /config
        - name: lib-modules
          mountPath: /lib/modules
          readOnly: true
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: wireguard-config
    - name: lib-modules
      hostPath:
        path: /lib/modules
        type: Directory
EOF

kubectl -n "${WG_NS}" wait --for=condition=Ready pod/wireguard-seed-bootstrap --timeout=300s
for _ in $(seq 1 60); do
  if kubectl -n "${WG_NS}" exec wireguard-seed-bootstrap -- sh -c 'test -f /config/wg_confs/wg0.conf'; then
    break
  fi
  sleep 2
done

TMP="$(mktemp)"
kubectl -n "${WG_NS}" exec wireguard-seed-bootstrap -- sh -c \
  'cd /config && tar czf - --exclude=lost+found --exclude="*.png" .donoteditthisfile wg_confs server templates peer_* coredns 2>/dev/null' \
  >"${TMP}"
kubectl -n "${WG_NS}" create secret generic wireguard-config-seed --from-file=config.tar.gz="${TMP}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${WG_NS}" label secret wireguard-config-seed app=wireguard managed-by=opentofu --overwrite
rm -f "${TMP}"
kubectl -n "${WG_NS}" delete pod wireguard-seed-bootstrap --ignore-not-found >/dev/null
echo "wireguard-config-seed created"
