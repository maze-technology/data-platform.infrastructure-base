# Pre-create the version detection ConfigMap to skip the job
# The Rook operator expects a ConfigMap named "rook-ceph-detect-version" with stdout containing the version output
# Format: stdout should contain the output of "ceph --version" command
#
# NOTE: Pre-creating the version detection ConfigMap doesn't work because the operator
# deletes manually created ConfigMaps. The operator will create a job to detect the version.
# The job should complete once the Ceph image (quay.io/ceph/ceph:v18.2.0) is pulled.
#
# This file is kept for reference but the resource is disabled.

locals {
  # Extract version from image tag (e.g., "18.2.0" from "v18.2.0")
  ceph_version_tag = replace(var.ceph_version, "/^v/", "") # Remove 'v' prefix if present
  # The stdout should contain the actual ceph --version output format
  # Format: "ceph version X.Y.Z (commit-hash) codename (release)"
  # For v18.2.0 (Pacific), the format is typically:
  # "ceph version 18.2.0 (1234567890abcdef1234567890abcdef12345678) pacific (stable)"
  # We'll use a format that Rook can parse - the commit hash can be a placeholder
  ceph_version_output = "ceph version ${local.ceph_version_tag} (0000000000000000000000000000000000000000) pacific (stable)"
}

# DISABLED: Operator deletes manually created ConfigMaps
# The operator will create a job (rook-ceph-detect-version) to detect the version.
# The job runs "ceph --version" in the Ceph container and stores the result in the ConfigMap.
# 
# resource "kubernetes_manifest" "ceph_version_detection" {
#   manifest = {
#     apiVersion = "v1"
#     kind       = "ConfigMap"
#     metadata = {
#       name      = "rook-ceph-detect-version"
#       namespace = kubernetes_namespace.rook_ceph.metadata[0].name
#       labels = {
#         app       = "rook-ceph"
#         component = "version-detection"
#         managed-by = "opentofu"
#       }
#     }
#     data = {
#       # The cmd-reporter expects stdout, stderr, and retcode (not returnCode!)
#       # Format must match exactly what the job would produce
#       # The operator parses stdout to extract version info
#       stdout  = local.ceph_version_output
#       stderr  = ""
#       retcode = "0"
#     }
#   }
#
#   # Use field_manager to maintain ownership and prevent operator from overwriting
#   field_manager {
#     name            = "opentofu"
#     force_conflicts = true
#   }
#
#   # Ensure this is created before the CephCluster
#   # The operator checks for this ConfigMap early in the reconciliation
#   depends_on = [
#     kubernetes_namespace.rook_ceph
#   ]
# }
