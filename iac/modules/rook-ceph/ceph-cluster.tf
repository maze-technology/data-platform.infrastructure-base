# CephCluster CRD
# Defines the Ceph cluster configuration with MON, MGR, and OSD daemons
# Configured for bare-metal with raw devices and latency-sensitive workloads

locals {
  # Determine storage configuration based on use_all_nodes flag
  storage_config = var.use_all_nodes ? {
    useAllNodes = true
    useAllDevices = false
    deviceFilter = "" # Empty means use devices from storage_devices list
    devices = [
      for device in var.storage_devices : {
        name = device
        config = {
          osdsPerDevice = "1" # One OSD per device as per requirements
        }
      }
    ]
  } : {
    useAllNodes = false
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
        image = "quay.io/ceph/ceph:${var.ceph_version}"
        allowUnsupported = false
      }
      dataDirHostPath = var.data_dir_host_path
      skipUpgradeChecks = false
      continueUpgradeAfterChecksEvenIfNotHealthy = false

      # MON (Monitor) configuration
      # MONs maintain the cluster map and handle quorum
      # With 3 MONs, cluster remains HEALTH_OK with 1 node down
      mon = {
        count                = var.mon_count
        allowMultiplePerNode = false
        volumeClaimTemplate = null # Use hostPath for bare-metal
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
        enabled        = var.monitoring_enabled
        rulesNamespace = var.namespace
      }

      # Storage configuration
      # Uses raw devices (no partitions, no LVM) as per requirements
      storage = merge(local.storage_config, {
        config = {
          # One OSD per dedicated disk per node
          osdsPerDevice = "1"
          # Use raw devices (no LVM)
          deviceFilter = ""
        }
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
      config = {
        global = {
          # Recovery throttling - limits impact on latency during recovery
          osd_recovery_max_active     = tostring(var.osd_recovery_max_active)
          osd_recovery_op_priority   = tostring(var.osd_recovery_op_priority)
          osd_max_backfills          = tostring(var.osd_max_backfills)
          # Ensure cluster remains HEALTH_OK with 1 node down
          mon_osd_down_out_interval = "600" # 10 minutes (default is 300s, increased for stability)
          # Conservative defaults for small cluster
          osd_pool_default_size     = tostring(var.replication_size)
          osd_pool_default_min_size = "2" # Allow writes with 2 replicas (tolerates 1 node down)
          # Network tuning for low latency
          ms_bind_port_min          = "6800"
          ms_bind_port_max          = "7300"
          # Disable features not needed for block/object storage
          rbd_default_features      = "3" # layering, exclusive-lock (no object-map, fast-diff for performance)
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
      # Ensure MONs and MGRs are spread across nodes
      placement = {
        all = {
          podAntiAffinity = {
            preferredDuringSchedulingIgnoredDuringExecution = [
              {
                weight = 100
                podAffinityTerm = {
                  labelSelector = {
                    matchExpressions = [
                      {
                        key      = "ceph_daemon_id"
                        operator = "Exists"
                      }
                    ]
                  }
                  topologyKey = "kubernetes.io/hostname"
                }
              }
            ]
          }
        }
        mon = {
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
        osd = {
          # OSDs are tied to specific nodes via device configuration
          # No additional placement needed
        }
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

  depends_on = concat(
    [
      kubernetes_namespace.rook_ceph,
      kubernetes_manifest.rook_operator,
      null_resource.install_rook_crds
    ],
    var.monitoring_enabled && var.prometheus_operator_dependency != null ? [var.prometheus_operator_dependency] : []
  )

  # Wait for operator to be ready before creating cluster
  wait {
    fields = {
      "status.phase" = "Ready"
    }
  }
}

