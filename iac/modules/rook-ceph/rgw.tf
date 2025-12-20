# RGW (Rados Gateway) Configuration
# Provides S3-compatible object storage for PostgreSQL WAL + base backups and application storage

# CephObjectStore (RGW service)
# Exposes S3-compatible API via Rados Gateway
resource "kubernetes_manifest" "ceph_object_store" {
  manifest = {
    apiVersion = "ceph.rook.io/v1"
    kind       = "CephObjectStore"
    metadata = {
      name      = var.rgw_store_name
      namespace = kubernetes_namespace.rook_ceph.metadata[0].name
      labels = {
        environment = var.environment
        managed-by  = "opentofu"
      }
    }
    spec = {
      # Metadata pool for RGW (stores bucket metadata, user info)
      metadataPool = {
        failureDomain = var.failure_domain
        replicated = {
          size                   = var.replication_size
          requireSafeReplicaSize = true
        }
        parameters = {
          # No compression for metadata (small, latency-sensitive)
          compression_mode = "none"
        }
      }
      
      # Data pool for RGW (stores actual object data)
      dataPool = {
        failureDomain = var.failure_domain
        # Replicated pool (not erasure coded) for predictable performance
        # Conservative default suitable for small bare-metal cluster
        replicated = {
          size                   = var.replication_size
          requireSafeReplicaSize = true
        }
        parameters = {
          # Compression can be enabled for data pool to save space
          # 'passive' mode: compress on read if not already compressed
          compression_mode = "passive"
        }
      }
      
      # Preserve pools on delete (prevents accidental data loss)
      preservePoolsOnDelete = true
      
      # Gateway (RGW) configuration
      gateway = {
        type      = "s3"
        port      = var.rgw_port
        instances = var.rgw_instances
        
        # Resource requests and limits
        resources = {
          requests = {
            cpu    = var.resource_requests.rgw.cpu
            memory = var.resource_requests.rgw.memory
          }
          limits = {
            cpu    = var.resource_limits.rgw.cpu
            memory = var.resource_limits.rgw.memory
          }
        }
        
        # Priority class for RGW
        priorityClassName = "system-cluster-critical"
        
        # Placement: spread RGW instances across nodes
        placement = {
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
      }
      
      # Health check configuration
      healthCheck = {
        bucket = {
          disabled = false
          interval = "60s"
        }
      }
      
      # Zone configuration (for multisite, not used in single-region setup)
      zone = null
    }
  }

  depends_on = [
    kubernetes_namespace.rook_ceph,
    kubernetes_manifest.ceph_cluster,
    null_resource.install_rook_crds
  ]

  # Wait for object store to be ready
  wait {
    fields = {
      "status.phase" = "Ready"
    }
  }
}

# CephObjectStoreUser
# Creates an S3 user with access credentials
resource "kubernetes_manifest" "ceph_object_store_user" {
  manifest = {
    apiVersion = "ceph.rook.io/v1"
    kind       = "CephObjectStoreUser"
    metadata = {
      name      = var.rgw_user_name
      namespace = kubernetes_namespace.rook_ceph.metadata[0].name
      labels = {
        environment = var.environment
        managed-by  = "opentofu"
      }
    }
    spec = {
      store = var.rgw_store_name
      displayName = var.rgw_user_display_name
      # Quotas (optional, adjust based on needs)
      quotas = null
    }
  }

  depends_on = [
    kubernetes_namespace.rook_ceph,
    kubernetes_manifest.ceph_object_store
  ]

  # Wait for user to be created and credentials available
  wait {
    fields = {
      "status.phase" = "Ready"
    }
  }
}

# Kubernetes Service for RGW
# Rook automatically creates a service for RGW, but we create our own ClusterIP service
# with a custom name for explicit control and consistency
# The service selector matches Rook's RGW pod labels
resource "kubernetes_service" "rgw" {
  metadata {
    name      = var.rgw_service_name
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
    labels = {
      app            = "rook-ceph-rgw"
      rook_cluster   = "rook-ceph"
      environment    = var.environment
      managed-by     = "opentofu"
    }
  }

  spec {
    type = "ClusterIP"
    
    # Selector matches Rook's RGW pod labels
    selector = {
      app              = "rook-ceph-rgw"
      rook_cluster     = "rook-ceph"
      rook_object_store = var.rgw_store_name
    }
    
    port {
      name        = "http"
      port        = var.rgw_port
      target_port = var.rgw_port
      protocol    = "TCP"
    }
  }

  depends_on = [
    kubernetes_namespace.rook_ceph,
    kubernetes_manifest.ceph_object_store
  ]
}

# Note: Rook also creates an automatic service named "rook-ceph-rgw-<store-name>"
# This service is an alternative that can be used if preferred

# Kubernetes Secret for RGW S3 credentials
# Contains access key and secret key for the RGW user
# This secret is created by the Rook operator, but we'll reference it in outputs
# Note: The secret name follows Rook's convention: rook-ceph-object-user-<store>-<user>
locals {
  rgw_secret_name = "rook-ceph-object-user-${var.rgw_store_name}-${var.rgw_user_name}"
}

# Data source to read the secret created by Rook operator
# This allows us to output the credentials
data "kubernetes_secret" "rgw_credentials" {
  metadata {
    name      = local.rgw_secret_name
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
  }

  depends_on = [
    kubernetes_manifest.ceph_object_store_user
  ]
}

