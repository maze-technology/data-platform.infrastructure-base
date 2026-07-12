# RBD (Rados Block Device) Configuration
# Provides block storage for PostgreSQL PVCs via Kubernetes StorageClass

# CephBlockPool for PostgreSQL
# Replicated pool with size=3 for fault tolerance
# Conservative defaults (no erasure coding) as per requirements
resource "kubernetes_manifest" "ceph_block_pool" {
  manifest = {
    apiVersion = "ceph.rook.io/v1"
    kind       = "CephBlockPool"
    metadata = {
      name      = var.rbd_pool_name
      namespace = kubernetes_namespace.rook_ceph.metadata[0].name
      labels = {
        environment = var.environment
        managed-by  = "opentofu"
        purpose     = "postgresql"
      }
    }
    spec = {
      # Replicated pool (not erasure coded) for predictable performance
      # Conservative default suitable for small bare-metal cluster
      replicated = {
        size = var.replication_size
        # requireSafeReplicaSize must be false when size=1 (Ceph requirement)
        # When size > 1, set to true to prevent unsafe replica size reduction
        requireSafeReplicaSize = var.replication_size > 1
        targetSizeRatio        = null # Let Ceph manage pool size
      }
      # Failure domain: host (ensures replicas on different nodes)
      # This ensures HEALTH_OK with 1 node down
      failureDomain = var.failure_domain
      # Pool parameters
      parameters = {
        # Compression disabled for latency-sensitive workloads
        # PostgreSQL WAL writes benefit from no compression overhead
        compression_mode = "none"
        # Enable application-level snapshots
        application = "rbd"
      }
      # Enable mirroring if needed (disabled by default)
      mirroring = {
        enabled = false
      }
      # Status check
      statusCheck = {
        mirror = {
          disabled = true
        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace.rook_ceph,
    kubernetes_manifest.ceph_cluster,
    null_resource.install_rook_platform
  ]

  # Note: CephBlockPool can take time to become Ready
  # We don't wait here to avoid timeouts - the pool will continue initializing in the background
}

# Kubernetes StorageClass for RBD
# Used by PostgreSQL (CloudNativePG) to provision PVCs
resource "kubernetes_storage_class" "rbd" {
  metadata {
    name = var.storage_class_name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
      purpose     = "postgresql"
    }
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  # RBD CSI provisioner
  storage_provisioner = "rook-ceph.rbd.csi.ceph.com"

  # StorageClass parameters
  parameters = {
    # Cluster and pool configuration
    clusterID = kubernetes_namespace.rook_ceph.metadata[0].name
    pool      = var.rbd_pool_name

    # Image format and features
    # Format 2 supports layering and other advanced features
    imageFormat = "2"
    # Layering: enables snapshots and clones
    # Exclusive-lock: required for RWX volumes
    imageFeatures = "layering,exclusive-lock"

    # CSI driver secrets (created by Rook operator)
    "csi.storage.k8s.io/provisioner-secret-name"            = "rook-csi-rbd-provisioner"
    "csi.storage.k8s.io/provisioner-secret-namespace"       = kubernetes_namespace.rook_ceph.metadata[0].name
    "csi.storage.k8s.io/node-stage-secret-name"             = "rook-csi-rbd-node"
    "csi.storage.k8s.io/node-stage-secret-namespace"        = kubernetes_namespace.rook_ceph.metadata[0].name
    "csi.storage.k8s.io/controller-expand-secret-name"      = "rook-csi-rbd-provisioner"
    "csi.storage.k8s.io/controller-expand-secret-namespace" = kubernetes_namespace.rook_ceph.metadata[0].name

    # Filesystem type
    fsType = "ext4"

    # Volume naming
    "csi.storage.k8s.io/fstype" = "ext4"
  }

  # Retain policy: volumes are not deleted when PVC is deleted
  # Critical for PostgreSQL data protection
  reclaim_policy = "Retain"

  # Allow volume expansion (required for PostgreSQL growth)
  allow_volume_expansion = true

  # Volume binding mode: immediate (provisioned immediately)
  volume_binding_mode = "Immediate"
}

