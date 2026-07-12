# Install Rook v1.20+ platform components from upstream manifests.
# Rook 1.20 delegates CSI driver management to the ceph-csi-operator (csi-operator.yaml).

locals {
  rook_examples_base_url = "https://raw.githubusercontent.com/rook/rook/${var.rook_operator_version}/deploy/examples"
}

resource "null_resource" "install_rook_platform" {
  triggers = {
    rook_version = var.rook_operator_version
    ceph_version = var.ceph_version
    namespace    = var.namespace
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      KUBECTL=""
      for candidate in kubectl /usr/local/bin/kubectl /usr/bin/kubectl /snap/bin/kubectl; do
        if command -v "$candidate" &>/dev/null; then
          KUBECTL="$candidate"
          break
        fi
      done
      if [ -z "$KUBECTL" ]; then
        echo "Error: kubectl not found"
        exit 1
      fi

      NS="${var.namespace}"
      ROOK_VER="${var.rook_operator_version}"
      CEPH_IMAGE="quay.io/ceph/ceph:${var.ceph_version}"
      BASE="${local.rook_examples_base_url}"
      TMPDIR=$(mktemp -d)
      trap 'rm -rf "$TMPDIR"' EXIT

      sed_namespace() {
        sed \
          -e "s/\\(.*\\):.*# namespace:operator/\\1: $NS # namespace:operator/g" \
          -e "s/\\(.*\\):.*# namespace:cluster/\\1: $NS # namespace:cluster/g" \
          -e "s/\\(.*serviceaccount\\):.*:\\(.*\\) # serviceaccount:namespace:operator/\\1:$NS:\\2 # serviceaccount:namespace:operator/g" \
          -e "s/\\(.*serviceaccount\\):.*:\\(.*\\) # serviceaccount:namespace:cluster/\\1:$NS:\\2 # serviceaccount:namespace:cluster/g" \
          -e "s/\\(.*\\): [-_A-Za-z0-9]*\\.\\(.*\\) # driver:namespace:cluster/\\1: $NS.\\2 # driver:namespace:cluster/g"
      }

      echo "Installing Rook CRDs ($ROOK_VER)..."
      curl -fsSL "$BASE/crds.yaml" -o "$TMPDIR/crds.yaml"
      $KUBECTL apply --server-side --force-conflicts -f "$TMPDIR/crds.yaml" || $KUBECTL apply -f "$TMPDIR/crds.yaml"

      CRDS=(
        cephclusters.ceph.rook.io
        cephblockpools.ceph.rook.io
        cephobjectstores.ceph.rook.io
        cephobjectstoreusers.ceph.rook.io
        drivers.csi.ceph.io
        operatorconfigs.csi.ceph.io
      )
      for crd in "$${CRDS[@]}"; do
        echo "Waiting for CRD: $crd"
        $KUBECTL wait --for condition=established --timeout=180s "crd/$crd"
      done

      echo "Applying Rook common RBAC ($ROOK_VER)..."
      curl -fsSL "$BASE/common.yaml" | sed_namespace > "$TMPDIR/common.yaml"
      $KUBECTL apply -f "$TMPDIR/common.yaml"

      echo "Applying ceph-csi-operator ($ROOK_VER)..."
      curl -fsSL "$BASE/csi-operator.yaml" | sed_namespace > "$TMPDIR/csi-operator.yaml"
      $KUBECTL apply -f "$TMPDIR/csi-operator.yaml"

      echo "Applying Rook operator ($ROOK_VER)..."
      curl -fsSL "$BASE/operator.yaml" | sed_namespace > "$TMPDIR/operator.yaml"
      $KUBECTL apply -f "$TMPDIR/operator.yaml"

      echo "Setting Ceph image to $CEPH_IMAGE..."
      $KUBECTL -n "$NS" set env deployment/rook-ceph-operator ROOK_CEPH_IMAGE="$CEPH_IMAGE"

      echo "Waiting for Rook operator rollout..."
      $KUBECTL -n "$NS" rollout status deployment/rook-ceph-operator --timeout=600s
      echo "Rook platform $ROOK_VER is ready"
    EOT
  }

  depends_on = [kubernetes_namespace.rook_ceph]
}
