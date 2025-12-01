locals {
  kind_port = 6443
}

# For kind clusters, we assume the cluster is created externally via scripts
# This module primarily provides configuration and outputs
# For cloud clusters, this would be extended with actual cloud provider resources

resource "null_resource" "cluster_validation" {
  count = var.cluster_type == "kind" ? 1 : 0

  provisioner "local-exec" {
    command = "kubectl cluster-info --context kind-${var.cluster_name} || (echo 'Kind cluster ${var.cluster_name} not found. Please run \"make kind-up\" first.' && exit 1)"
  }
}

