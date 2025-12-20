# Rook-Ceph Operator Deployment
# The operator manages the lifecycle of Ceph clusters and related resources
# Note: CRDs are automatically installed by crds.tf before this resource

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

# Rook-Ceph Operator Deployment
# Deployed via Kubernetes manifests (not Helm) as per requirements
resource "kubernetes_manifest" "rook_operator" {
  manifest = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "rook-ceph-operator"
      namespace = kubernetes_namespace.rook_ceph.metadata[0].name
      labels = {
        app       = "rook-ceph-operator"
        operator  = "rook"
        component = "operator"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "rook-ceph-operator"
        }
      }
      template = {
        metadata = {
          labels = {
            app       = "rook-ceph-operator"
            operator  = "rook"
            component = "operator"
          }
        }
        spec = {
          serviceAccountName = "rook-ceph-operator"
          containers = [
            {
              name  = "rook-ceph-operator"
              image = "rook/ceph:${var.rook_operator_version}"
              args = [
                "ceph",
                "operator"
              ]
              env = [
                {
                  name  = "ROOK_CURRENT_NAMESPACE_ONLY"
                  value = "false"
                },
                {
                  name  = "ROOK_LOG_LEVEL"
                  value = "INFO"
                },
                {
                  name  = "ROOK_CEPH_IMAGE"
                  value = "quay.io/ceph/ceph:${var.ceph_version}"
                },
                {
                  name  = "ROOK_CSI_ENABLE_CEPHFS"
                  value = "true"
                },
                {
                  name  = "ROOK_CSI_ENABLE_RBD"
                  value = "true"
                },
                {
                  name  = "ROOK_CSI_ENABLE_GRPC_METRICS"
                  value = "true"
                },
                {
                  name  = "ROOK_CSI_RBD_IMAGE"
                  value = "quay.io/cephcsi/cephcsi:v3.11.0"
                },
                {
                  name  = "ROOK_CSI_CEPHFS_IMAGE"
                  value = "quay.io/cephcsi/cephcsi:v3.11.0"
                },
                {
                  name  = "ROOK_CSI_REGISTRAR_IMAGE"
                  value = "registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.10.0"
                },
                {
                  name  = "ROOK_CSI_PROVISIONER_IMAGE"
                  value = "registry.k8s.io/sig-storage/csi-provisioner:v3.6.0"
                },
                {
                  name  = "ROOK_CSI_ATTACHER_IMAGE"
                  value = "registry.k8s.io/sig-storage/csi-attacher:v4.4.0"
                },
                {
                  name  = "ROOK_CSI_RESIZER_IMAGE"
                  value = "registry.k8s.io/sig-storage/csi-resizer:v1.9.1"
                },
                {
                  name  = "ROOK_CSI_SNAPSHOTTER_IMAGE"
                  value = "registry.k8s.io/sig-storage/csi-snapshotter:v6.3.0"
                }
              ]
              resources = {
                requests = {
                  cpu    = var.resource_requests.operator.cpu
                  memory = var.resource_requests.operator.memory
                }
                limits = {
                  cpu    = var.resource_limits.operator.cpu
                  memory = var.resource_limits.operator.memory
                }
              }
              volumeMounts = [
                {
                  name      = "rook-config"
                  mountPath = "/etc/rook"
                }
              ]
            }
          ]
          volumes = [
            {
              name = "rook-config"
              configMap = {
                name = "rook-config-override"
              }
            }
          ]
        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace.rook_ceph,
    null_resource.install_rook_crds
  ]
}

# ServiceAccount for the operator
resource "kubernetes_service_account" "rook_operator" {
  metadata {
    name      = "rook-ceph-operator"
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
    labels = {
      app       = "rook-ceph-operator"
      operator  = "rook"
      component = "operator"
    }
  }
}

# ClusterRole for the operator
resource "kubernetes_manifest" "rook_operator_cluster_role" {
  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "rook-ceph-operator"
      labels = {
        operator = "rook"
      }
    }
    rules = [
      {
        apiGroups = [""]
        resources = [
          "pods",
          "configmaps",
          "services",
          "serviceaccounts",
          "persistentvolumeclaims",
          "events",
          "limitranges",
          "namespaces",
          "nodes",
          "secrets"
        ]
        verbs = ["*"]
      },
      {
        apiGroups = ["apps"]
        resources = [
          "deployments",
          "daemonsets",
          "replicasets",
          "statefulsets"
        ]
        verbs = ["*"]
      },
      {
        apiGroups = ["monitoring.coreos.com"]
        resources = [
          "servicemonitors",
          "prometheusrules"
        ]
        verbs = ["*"]
      },
      {
        apiGroups = ["ceph.rook.io"]
        resources = ["*"]
        verbs = ["*"]
      },
      {
        apiGroups = ["storage.k8s.io"]
        resources = [
          "storageclasses",
          "volumeattachments"
        ]
        verbs = ["*"]
      },
      {
        apiGroups = ["snapshot.storage.k8s.io"]
        resources = ["*"]
        verbs = ["*"]
      }
    ]
  }
}

# ClusterRoleBinding for the operator
resource "kubernetes_manifest" "rook_operator_cluster_role_binding" {
  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name = "rook-ceph-operator"
      labels = {
        operator = "rook"
      }
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "rook-ceph-operator"
    }
    subjects = [
      {
        kind      = "ServiceAccount"
        name      = kubernetes_service_account.rook_operator.metadata[0].name
        namespace = kubernetes_namespace.rook_ceph.metadata[0].name
      }
    ]
  }

  depends_on = [
    kubernetes_service_account.rook_operator,
    kubernetes_manifest.rook_operator_cluster_role
  ]
}

# ConfigMap for operator configuration
resource "kubernetes_config_map" "rook_config" {
  metadata {
    name      = "rook-config-override"
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
  }
  data = {
    "ROOK_CSI_ENABLE_CEPHFS" = "true"
    "ROOK_CSI_ENABLE_RBD"    = "true"
  }
}

