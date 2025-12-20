# Rook CRD Installation
# CRDs must be installed before creating CephCluster, CephBlockPool, CephObjectStore, etc.
# This resource ensures CRDs are installed automatically using kubectl
#
# Why CRDs need to exist first:
# - When Terraform/OpenTofu creates kubernetes_manifest resources for CephCluster, etc.,
#   the Kubernetes API validates the manifest against existing CRDs
# - If CRDs don't exist, the API will reject the manifest with "no matches for kind"
# - The operator could install CRDs, but Terraform needs them before it can create resources
#
# This null_resource uses kubectl to install CRDs, ensuring they exist before dependent resources

resource "null_resource" "install_rook_crds" {
  # Trigger re-installation if Rook version changes
  triggers = {
    rook_version = var.rook_operator_version
  }

  # Install CRDs using kubectl
  # This runs before other resources due to depends_on relationships
  provisioner "local-exec" {
    command = <<-EOT
      # Check if kubectl is available
      if ! command -v kubectl &> /dev/null; then
        echo "Error: kubectl is not installed or not in PATH"
        exit 1
      fi

      # Apply CRDs (idempotent operation - safe to run multiple times)
      echo "Installing Rook CRDs (version ${var.rook_operator_version})..."
      kubectl apply --server-side --force-conflicts -f https://github.com/rook/rook/releases/download/${var.rook_operator_version}/crds.yaml 2>/dev/null || \
      kubectl apply -f https://github.com/rook/rook/releases/download/${var.rook_operator_version}/crds.yaml

      # Wait for CRDs to be established (required for Terraform to use them)
      echo "Waiting for CRDs to be established..."
      timeout 60s bash -c 'until kubectl wait --for condition=established --timeout=5s \
        crd/cephclusters.ceph.rook.io \
        crd/cephblockpools.ceph.rook.io \
        crd/cephobjectstores.ceph.rook.io \
        crd/cephobjectstoreusers.ceph.rook.io \
        crd/cephfilesystems.ceph.rook.io \
        crd/cephnfses.ceph.rook.io \
        crd/cephclients.ceph.rook.io \
        crd/volumes.rook.io 2>/dev/null; do sleep 2; done' || true
    EOT
  }

  # Note: CRDs are cluster-scoped and typically not deleted on module destroy
  # This preserves the CRDs even if the module is removed, which is usually desired
}

