# Selective RBD PVC LUKS encryption.
#
# - Unencrypted SC: rook-ceph-block (OHLCV / bulk data)
# - Encrypted SC:   rook-ceph-block-encrypted (Gitaly / sensitive)
#
# Master passphrase: Vault secret/ceph/rbd-luks
# CSI metadata KMS also needs the same value as a Secret in each PVC namespace.

variable "enable_rbd_encryption" {
  description = "Enable CSI RBD LUKS encryption support + encrypted StorageClass"
  type        = bool
  default     = true
}

variable "encrypted_storage_class_name" {
  description = "Name of the encrypted RBD StorageClass"
  type        = string
  default     = "rook-ceph-block-encrypted"
}

variable "encryption_kms_id" {
  description = "KMS ID key inside rook-ceph-csi-kms-config"
  type        = string
  default     = "vault-backed-metadata"
}

variable "encryption_secret_name" {
  description = "Kubernetes Secret name required by CSI metadata KMS in each PVC namespace"
  type        = string
  default     = "storage-encryption-secret"
}

variable "encryption_pvc_namespaces" {
  description = "Namespaces allowed to create encrypted PVCs (Secret mirrored here)"
  type        = list(string)
  default     = ["gitlab"]
}

variable "encryption_vault_path" {
  description = "Vault KV path for the LUKS master passphrase (under mount secret/)"
  type        = string
  default     = "ceph/rbd-luks"
}

resource "random_password" "rbd_luks" {
  count   = var.enable_rbd_encryption ? 1 : 0
  length  = 64
  special = false
}

resource "kubernetes_config_map" "csi_kms" {
  count = var.enable_rbd_encryption ? 1 : 0

  metadata {
    name      = "rook-ceph-csi-kms-config"
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    "config.json" = jsonencode({
      (var.encryption_kms_id) = {
        encryptionKMSType = "metadata"
        secretName        = var.encryption_secret_name
      }
    })
  }

  depends_on = [null_resource.install_rook_platform]
}

resource "null_resource" "csi_enable_encryption" {
  count = var.enable_rbd_encryption ? 1 : 0

  triggers = {
    namespace = var.namespace
    enabled   = "true"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      kubectl -n "${var.namespace}" patch configmap rook-ceph-operator-config --type merge \
        -p '{"data":{"CSI_ENABLE_ENCRYPTION":"true"}}'
      # Operator may already be restarting from a concurrent change; retry restart.
      for i in 1 2 3 4 5; do
        if kubectl -n "${var.namespace}" rollout restart deployment/rook-ceph-operator; then
          break
        fi
        sleep 3
      done
      kubectl -n "${var.namespace}" rollout status deployment/rook-ceph-operator --timeout=300s
    EOT
  }

  depends_on = [
    null_resource.install_rook_platform,
    kubernetes_config_map.csi_kms,
  ]
}

resource "kubernetes_storage_class" "rbd_encrypted" {
  count = var.enable_rbd_encryption ? 1 : 0

  metadata {
    name = var.encrypted_storage_class_name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
      purpose     = "encrypted-rbd"
    }
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  storage_provisioner = "rook-ceph.rbd.csi.ceph.com"

  parameters = {
    clusterID     = kubernetes_namespace.rook_ceph.metadata[0].name
    pool          = var.rbd_pool_name
    imageFormat   = "2"
    imageFeatures = "layering,exclusive-lock"

    encrypted       = "true"
    encryptionKMSID = var.encryption_kms_id

    "csi.storage.k8s.io/provisioner-secret-name"            = "rook-csi-rbd-provisioner"
    "csi.storage.k8s.io/provisioner-secret-namespace"       = kubernetes_namespace.rook_ceph.metadata[0].name
    "csi.storage.k8s.io/node-stage-secret-name"             = "rook-csi-rbd-node"
    "csi.storage.k8s.io/node-stage-secret-namespace"        = kubernetes_namespace.rook_ceph.metadata[0].name
    "csi.storage.k8s.io/controller-expand-secret-name"      = "rook-csi-rbd-provisioner"
    "csi.storage.k8s.io/controller-expand-secret-namespace" = kubernetes_namespace.rook_ceph.metadata[0].name
    "csi.storage.k8s.io/fstype"                             = "ext4"
  }

  reclaim_policy         = "Retain"
  allow_volume_expansion = true
  volume_binding_mode    = "Immediate"

  depends_on = [
    kubernetes_manifest.ceph_block_pool,
    kubernetes_config_map.csi_kms,
    null_resource.csi_enable_encryption,
  ]
}

# CSI metadata KMS reads this Secret in the PVC namespace at attach time.
# Rook-Ceph gets the source copy here; consumer namespaces (e.g. gitlab) mirror
# via their own modules. Vault backup is written at the env layer after Vault is up.
resource "kubernetes_secret" "rbd_luks" {
  count = var.enable_rbd_encryption ? 1 : 0

  metadata {
    name      = var.encryption_secret_name
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
    labels = {
      managed-by  = "opentofu"
      purpose     = "rbd-luks"
      environment = var.environment
    }
  }

  data = {
    encryptionPassphrase = random_password.rbd_luks[0].result
  }

  type = "Opaque"

  depends_on = [
    null_resource.install_rook_platform,
    kubernetes_config_map.csi_kms,
  ]
}
