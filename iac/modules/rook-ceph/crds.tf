# Rook CRD Installation and Verification
# CRDs must be installed and established before creating CephCluster, CephBlockPool, etc.
# This resource ensures CRDs are installed and fully established before dependent resources
#
# Why CRDs need to exist first:
# - When Terraform/OpenTofu creates kubernetes_manifest resources for CephCluster, etc.,
#   the Kubernetes API validates the manifest against existing CRDs
# - If CRDs don't exist, the API will reject the manifest with "no matches for kind"
# - The operator could install CRDs, but Terraform needs them before it can create resources
#
# This null_resource installs CRDs and waits for them to be established in a single step
# It automatically detects if CRDs are missing (e.g., after cluster recreation) and re-installs them

# Data source to check if CRDs exist - used in trigger to detect cluster recreation
data "external" "crd_check" {
  program = ["/bin/bash", "-c", <<-EOT
    if kubectl get crd cephclusters.ceph.rook.io >/dev/null 2>&1; then
      echo '{"exists":"yes"}'
    else
      echo '{"exists":"no"}'
    fi
  EOT
  ]
}

resource "null_resource" "install_and_verify_rook_crds" {
  # Trigger re-installation if Rook version changes OR if CRDs are missing
  # This ensures CRDs are re-installed automatically if cluster is recreated (e.g., kind-down/kind-up)
  triggers = {
    rook_version = var.rook_operator_version
    crd_exists   = data.external.crd_check.result.exists
  }

  # Ensure this resource is created before any kubernetes_manifest resources
  # This is critical because kubernetes_manifest validates during plan/apply
  lifecycle {
    create_before_destroy = true
  }

  # Install and verify CRDs in one step
  # This ensures CRDs are fully established before any dependent resources try to validate
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e

      # Find kubectl in PATH or common locations
      KUBECTL=""
      if command -v kubectl &> /dev/null; then
        KUBECTL="kubectl"
      elif [ -f /snap/bin/kubectl ]; then
        KUBECTL="/snap/bin/kubectl"
      elif [ -f /usr/local/bin/kubectl ]; then
        KUBECTL="/usr/local/bin/kubectl"
      elif [ -f /usr/bin/kubectl ]; then
        KUBECTL="/usr/bin/kubectl"
      else
        echo "Error: kubectl is not installed or not found in PATH or common locations"
        echo "Please ensure kubectl is installed and accessible"
        exit 1
      fi

      # Check if CRDs already exist and are established
      CRD_CHECK="cephclusters.ceph.rook.io"
      if $${KUBECTL} get crd "$${CRD_CHECK}" >/dev/null 2>&1; then
        if $${KUBECTL} wait --for condition=established --timeout=5s "crd/$${CRD_CHECK}" >/dev/null 2>&1; then
          echo "CRDs already exist and are established, skipping installation"
          exit 0
        fi
      fi

      # Apply CRDs (idempotent operation - safe to run multiple times)
      # CRDs are located in the repository at deploy/examples/crds.yaml
      # Use raw.githubusercontent.com for direct file access
      echo "Installing Rook CRDs (version ${var.rook_operator_version})..."
      CRD_URL="https://raw.githubusercontent.com/rook/rook/${var.rook_operator_version}/deploy/examples/crds.yaml"
      if ! $${KUBECTL} apply --server-side --force-conflicts -f "$${CRD_URL}" 2>/dev/null; then
        $${KUBECTL} apply -f "$${CRD_URL}"
      fi

      echo "Waiting for CRDs to be established..."

      # Wait for each CRD to be established with proper error handling
      # Note: volumes.rook.io may not exist in all Rook versions, so we only check essential CRDs
      CRDS=(
        "cephclusters.ceph.rook.io"
        "cephblockpools.ceph.rook.io"
        "cephobjectstores.ceph.rook.io"
        "cephobjectstoreusers.ceph.rook.io"
        "cephfilesystems.ceph.rook.io"
        "cephnfses.ceph.rook.io"
        "cephclients.ceph.rook.io"
      )

      for crd in "$${CRDS[@]}"; do
        echo "Waiting for CRD: $${crd}"
        if ! $${KUBECTL} wait --for condition=established --timeout=120s "crd/$${crd}" 2>/dev/null; then
          echo "Error: CRD $${crd} failed to become established within 120 seconds"
          echo "Checking CRD status..."
          $${KUBECTL} get "crd/$${crd}" -o yaml || {
            echo "Error: CRD $${crd} does not exist"
            exit 1
          }
          exit 1
        fi
        echo "CRD $${crd} is established"
      done

      echo "All Rook CRDs are installed and established"
    EOT
  }

  # Note: CRDs are cluster-scoped and typically not deleted on module destroy
  # This preserves the CRDs even if the module is removed, which is usually desired
}

