# Static Local PVs backed by per-node loop block devices (kind/local only).
# Rook storageClassDeviceSets require volumeMode=Block; local-path only supports Filesystem.
# Each worker gets a dedicated loop device and a node-affine Local PV for OSD PVC binding.

variable "local_block_osd_devices" {
  description = "Map of kind node name to loop device basename (e.g. loop10). Creates static Block Local PVs when non-empty."
  type        = map(string)
  default     = {}
}

locals {
  local_block_osd_devices = {
    for node_name, device in var.local_block_osd_devices :
    node_name => "/dev/${replace(device, "/^\\/dev\\//", "")}"
  }
}

resource "kubernetes_storage_class" "local_block" {
  count = length(local.local_block_osd_devices) > 0 ? 1 : 0

  metadata {
    name = "local-block"
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
      purpose     = "rook-osd"
    }
  }

  storage_provisioner    = "kubernetes.io/no-provisioner"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = false
}

resource "kubernetes_persistent_volume" "local_block_osd" {
  for_each = local.local_block_osd_devices

  metadata {
    name = "local-block-${each.key}"
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
      purpose     = "rook-osd"
      node        = each.key
    }
  }

  spec {
    capacity = {
      storage = "${var.loop_device_image_size_gb}Gi"
    }

    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = kubernetes_storage_class.local_block[0].metadata[0].name
    volume_mode                      = "Block"

    persistent_volume_source {
      local {
        path = each.value
      }
    }

    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key      = "kubernetes.io/hostname"
            operator = "In"
            values   = [each.key]
          }
        }
      }
    }
  }

  depends_on = [
    null_resource.setup_osd_loop_devices,
    kubernetes_storage_class.local_block,
  ]
}
