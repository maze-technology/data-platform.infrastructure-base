# Rook namespace — operator, RBAC, CSI, and CRDs are installed by rook-install.tf
# from upstream Rook v1.20+ manifests (common.yaml, csi-operator.yaml, operator.yaml).

resource "kubernetes_namespace" "rook_ceph" {
  metadata {
    name = var.namespace
    labels = {
      name        = var.namespace
      environment = var.environment
      managed-by  = "opentofu"
    }
  }
}
