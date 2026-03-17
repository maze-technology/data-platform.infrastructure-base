# CephCluster CRD
# Defines the Ceph cluster configuration with MON, MGR, and OSD daemons
# Configured for bare-metal with raw devices and latency-sensitive workloads

locals {
  # Determine storage configuration based on use_all_nodes flag
  # SAFETY: Automatic device discovery is FORCED OFF. Devices MUST be explicitly specified.
  # This prevents accidental data loss from Rook formatting disks with existing filesystems.

  storage_config = var.use_all_nodes ? {
    useAllNodes = true
    # FORCED: Always false - automatic device discovery is disabled for safety
    useAllDevices = false
    deviceFilter  = "" # Not used when useAllDevices is false
    devices = [
      for device in var.storage_devices : {
        name = device
        config = {
          osdsPerDevice = "1" # One OSD per device as per requirements
        }
      }
    ]
    nodes = [] # Not used when useAllNodes is true
    } : {
    useAllNodes = false
    # FORCED: Always false - automatic device discovery is disabled for safety
    useAllDevices = false
    deviceFilter  = "" # Not used when useAllDevices is false
    devices       = [] # Not used when useAllNodes is false
    nodes = [
      for node in var.storage_nodes : {
        name = node.name
        devices = [
          for device in node.devices : {
            name = device
            config = {
              osdsPerDevice = "1" # One OSD per device as per requirements
            }
          }
        ]
      }
    ]
  }
}

# CephCluster Custom Resource
# Depends on the Rook data directory being created on Kind nodes
#
# SAFETY: Automatic device discovery is FORCED OFF. Devices MUST be explicitly specified.
# This prevents accidental data loss from Rook formatting disks with existing filesystems.
# If storage_devices is empty, Rook will use directories (safe fallback for Kind clusters).
resource "kubernetes_manifest" "ceph_cluster" {
  manifest = {
    apiVersion = "ceph.rook.io/v1"
    kind       = "CephCluster"
    metadata = {
      name      = "rook-ceph"
      namespace = kubernetes_namespace.rook_ceph.metadata[0].name
      labels = {
        environment = var.environment
        managed-by  = "opentofu"
      }
    }
    spec = {
      cephVersion = {
        image            = "quay.io/ceph/ceph:${var.ceph_version}"
        allowUnsupported = false
      }
      dataDirHostPath                            = var.data_dir_host_path
      skipUpgradeChecks                          = false
      continueUpgradeAfterChecksEvenIfNotHealthy = false

      # MON (Monitor) configuration
      # MONs maintain the cluster map and handle quorum
      # With 3 MONs, cluster remains HEALTH_OK with 1 node down
      mon = {
        count                = var.mon_count
        allowMultiplePerNode = false
        volumeClaimTemplate  = null # Use hostPath for bare-metal
      }

      # MGR (Manager) configuration
      # MGRs provide additional monitoring and management interfaces
      mgr = {
        count                = var.mgr_count
        allowMultiplePerNode = false
        modules = [
          {
            name    = "pg_autoscaler"
            enabled = true
          }
        ]
      }

      # Dashboard configuration
      dashboard = {
        enabled = var.dashboard_enabled
        ssl     = false # SSL handled by ingress/cert-manager if needed
      }

      # Monitoring configuration
      monitoring = {
        enabled = var.monitoring_enabled
        # rulesNamespace is not supported in all Rook versions
        # If omitted, rules are deployed in the same namespace as the cluster
      }

      # Storage configuration
      # Uses raw devices (no partitions, no LVM) as per requirements
      # SAFETY: useAllDevices is FORCED to false - devices MUST be explicitly specified
      # For Kind clusters, if no devices are specified, Rook will use directories (safe fallback)
      storage = merge(local.storage_config, {
        config = {
          # One OSD per dedicated disk per node
          osdsPerDevice = "1"
        }
        # Automatic device discovery is disabled - only explicitly specified devices are used
      })

      # Resource requests and limits for Ceph daemons
      # Critical for predictable performance on bare-metal
      resources = {
        mon = {
          requests = {
            cpu    = var.resource_requests.mon.cpu
            memory = var.resource_requests.mon.memory
          }
          limits = {
            cpu    = var.resource_limits.mon.cpu
            memory = var.resource_limits.mon.memory
          }
        }
        mgr = {
          requests = {
            cpu    = var.resource_requests.mgr.cpu
            memory = var.resource_requests.mgr.memory
          }
          limits = {
            cpu    = var.resource_limits.mgr.cpu
            memory = var.resource_limits.mgr.memory
          }
        }
        osd = {
          requests = {
            cpu    = var.resource_requests.osd.cpu
            memory = var.resource_requests.osd.memory
          }
          limits = {
            cpu    = var.resource_limits.osd.cpu
            memory = var.resource_limits.osd.memory
          }
        }
      }

      # Ceph configuration overrides
      # Critical for latency-sensitive workloads (trading infrastructure)
      # These settings throttle recovery/backfill to protect client I/O latency
      cephConfig = {
        global = {
          # Recovery throttling - limits impact on latency during recovery
          osd_recovery_max_active  = tostring(var.osd_recovery_max_active)
          osd_recovery_op_priority = tostring(var.osd_recovery_op_priority)
          osd_max_backfills        = tostring(var.osd_max_backfills)
          # Ensure cluster remains HEALTH_OK with 1 node down
          mon_osd_down_out_interval = "600" # 10 minutes (default is 300s, increased for stability)
          # Conservative defaults for small cluster
          osd_pool_default_size     = tostring(var.replication_size)
          osd_pool_default_min_size = "2" # Allow writes with 2 replicas (tolerates 1 node down)
          # Network tuning for low latency
          ms_bind_port_min = "6800"
          ms_bind_port_max = "7300"
          # Disable features not needed for block/object storage
          rbd_default_features = "3" # layering, exclusive-lock (no object-map, fast-diff for performance)
        }
        mon = {
          # MON-specific settings
          mon_allow_pool_delete = "true"
        }
        osd = {
          # OSD-specific settings
          osd_journal_size = "5120" # 5GB journal (conservative for small cluster)
        }
      }

      # Placement configuration
      # Production baseline: MONs hard-spread, MGRs spread from each other, MGR can co-locate with MON
      # Note: placement.all is not supported by Rook operator and will be removed
      # Security context is applied to individual placements instead
      placement = {
        # MON placement: hard spread (required) - one MON per node
        mon = {
          # Security context for MON daemons
          # fsGroup ensures pods can write to mounted volumes
          # Using 0 (root) for maximum compatibility with hostPath mounts
          securityContext = {
            fsGroup        = 0
            runAsUser      = 0
            runAsNonRoot   = false
            seLinuxOptions = {}
          }
          podAntiAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = [
              {
                labelSelector = {
                  matchExpressions = [
                    {
                      key      = "ceph_daemon_id"
                      operator = "In"
                      values   = ["a", "b", "c"]
                    }
                  ]
                }
                topologyKey = "kubernetes.io/hostname"
              }
            ]
          }
        }
        # MGR placement: spread MGRs from each other (required), but allow co-location with MON
        # In production, MGR can share a node with MON - this is normal and acceptable
        # Anti-affinity only applies between MGR pods, not between MGR and MON
        mgr = {
          # Security context for MGR daemons
          securityContext = {
            fsGroup        = 0
            runAsUser      = 0
            runAsNonRoot   = false
            seLinuxOptions = {}
          }
          podAntiAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = [
              {
                labelSelector = {
                  matchExpressions = [
                    {
                      key      = "ceph_daemon_type"
                      operator = "In"
                      values   = ["mgr"]
                    }
                  ]
                }
                topologyKey = "kubernetes.io/hostname"
              }
            ]
          }
        }
        # Note: OSD placement is not supported at the cluster level
        # OSDs are tied to specific nodes via device configuration in the storage section
        # Security context for OSDs is managed by the Rook operator automatically
      }

      # Health check configuration
      healthCheck = {
        daemonHealth = {
          mon = {
            interval = "45s"
            timeout  = "600s"
          }
          osd = {
            interval = "60s"
            timeout  = "600s"
          }
          status = {
            interval = "30s"
          }
        }
        livenessProbe = {
          mon = {
            disabled = false
          }
          mgr = {
            disabled = false
          }
        }
      }

      # Priority classes for critical components
      priorityClassNames = {
        mon = "system-cluster-critical"
        mgr = "system-cluster-critical"
        osd = "system-node-critical"
      }
    }
  }

  depends_on = [
    kubernetes_namespace.rook_ceph,
    kubernetes_manifest.rook_operator,
    null_resource.install_and_verify_rook_crds,
    null_resource.create_rook_data_dir
    # Note: We don't pre-create the version detection ConfigMap because the operator
    # deletes manually created ConfigMaps. The operator will create a job to detect
    # the version, which should complete once the Ceph image is pulled.
  ]
  # Note: prometheus_operator_dependency is not included in depends_on to avoid circular
  # dependencies when observability depends on rook_ceph for S3 storage. The CephCluster CRD
  # gracefully handles monitoring being enabled before Prometheus Operator is ready - it will
  # simply not create ServiceMonitors until the Prometheus Operator CRDs are available.

  field_manager {
    force_conflicts = true
  }

  # Note: CephCluster can take 10+ minutes to become Ready
  # We don't wait for Ready status here to avoid timeouts
  # The cluster will continue initializing in the background
  # Dependent resources should check cluster readiness before using it
}

