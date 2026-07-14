# Allow loop-backed block devices for local/kind OSD provisioning (Ceph v20+ blocks them by default).
resource "null_resource" "rook_allow_loop_devices" {
  count = var.allow_loop_devices ? 1 : 0

  triggers = {
    namespace          = var.namespace
    allow_loop_devices = "true"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      NS="${var.namespace}"
      KUBECTL=""
      for candidate in kubectl /usr/local/bin/kubectl /usr/bin/kubectl; do
        if command -v "$candidate" &>/dev/null; then KUBECTL="$candidate"; break; fi
      done
      [ -n "$KUBECTL" ] || { echo "kubectl not found"; exit 1; }

      echo "Enabling ROOK_CEPH_ALLOW_LOOP_DEVICES for kind/local loop-backed OSDs..."
      $KUBECTL -n "$NS" patch configmap rook-ceph-operator-config --type merge \
        -p '{"data":{"ROOK_CEPH_ALLOW_LOOP_DEVICES":"true"}}'
      $KUBECTL -n "$NS" rollout restart deployment/rook-ceph-operator
      $KUBECTL -n "$NS" rollout status deployment/rook-ceph-operator --timeout=300s
      echo "✓ Loop devices allowed for OSD provisioning"
    EOT
  }

  depends_on = [null_resource.install_rook_platform]
}
