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
                  name = "POD_NAMESPACE"
                  valueFrom = {
                    fieldRef = {
                      apiVersion = "v1"
                      fieldPath  = "metadata.namespace"
                    }
                  }
                },
                {
                  name = "POD_NAME"
                  valueFrom = {
                    fieldRef = {
                      apiVersion = "v1"
                      fieldPath  = "metadata.name"
                    }
                  }
                },
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
                },
                {
                  name      = "rook-data-dir"
                  mountPath = var.data_dir_host_path
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
            },
            {
              name = "rook-data-dir"
              hostPath = {
                path = var.data_dir_host_path
                type = "DirectoryOrCreate"
              }
            }
          ]
        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace.rook_ceph,
    null_resource.install_and_verify_rook_crds
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

# ServiceAccount for cmd-reporter (used by version detection jobs)
resource "kubernetes_service_account" "rook_cmd_reporter" {
  metadata {
    name      = "rook-ceph-cmd-reporter"
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
    labels = {
      app       = "rook-ceph-cmd-reporter"
      operator  = "rook"
      component = "cmd-reporter"
    }
  }
}

# ServiceAccount for Ceph daemons (MON, MGR, OSD, etc.)
# Rook expects these ServiceAccounts to exist for daemon pods
# Rook should create them automatically, but we pre-create them to avoid timing issues
resource "kubernetes_service_account" "rook_ceph_default" {
  metadata {
    name      = "rook-ceph-default"
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
    labels = {
      app       = "rook-ceph"
      operator  = "rook"
      component = "daemon"
    }
  }
}

resource "kubernetes_service_account" "rook_ceph_mgr" {
  metadata {
    name      = "rook-ceph-mgr"
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
    labels = {
      app       = "rook-ceph"
      operator  = "rook"
      component = "mgr"
    }
  }
}

resource "kubernetes_service_account" "rook_ceph_osd" {
  metadata {
    name      = "rook-ceph-osd"
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
    labels = {
      app       = "rook-ceph"
      operator  = "rook"
      component = "osd"
    }
  }
}

# RoleBinding for cmd-reporter ServiceAccount
resource "kubernetes_role_binding" "rook_cmd_reporter" {
  metadata {
    name      = "rook-ceph-cmd-reporter"
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "rook-ceph-operator"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.rook_cmd_reporter.metadata[0].name
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
  }

  depends_on = [
    kubernetes_service_account.rook_cmd_reporter,
    kubernetes_manifest.rook_operator_cluster_role
  ]
}

# RoleBinding for Ceph daemons ServiceAccount
# This allows MON, MGR, OSD pods to access necessary resources
resource "kubernetes_role_binding" "rook_ceph_default" {
  metadata {
    name      = "rook-ceph-default"
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "rook-ceph-operator"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.rook_ceph_default.metadata[0].name
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
  }

  depends_on = [
    kubernetes_service_account.rook_ceph_default,
    kubernetes_manifest.rook_operator_cluster_role
  ]
}

# ClusterRoleBinding for MGR ServiceAccount
# Must be ClusterRoleBinding (not RoleBinding) because nodes are cluster-scoped resources
resource "kubernetes_cluster_role_binding" "rook_ceph_mgr" {
  metadata {
    name = "rook-ceph-mgr"
    labels = {
      app       = "rook-ceph"
      operator  = "rook"
      component = "mgr"
    }
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "rook-ceph-operator"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.rook_ceph_mgr.metadata[0].name
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
  }

  depends_on = [
    kubernetes_service_account.rook_ceph_mgr,
    kubernetes_manifest.rook_operator_cluster_role
  ]
}

# ClusterRoleBinding for OSD ServiceAccount
# Must be ClusterRoleBinding (not RoleBinding) because nodes are cluster-scoped resources
resource "kubernetes_cluster_role_binding" "rook_ceph_osd" {
  metadata {
    name = "rook-ceph-osd"
    labels = {
      app       = "rook-ceph"
      operator  = "rook"
      component = "osd"
    }
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "rook-ceph-operator"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.rook_ceph_osd.metadata[0].name
    namespace = kubernetes_namespace.rook_ceph.metadata[0].name
  }

  depends_on = [
    kubernetes_service_account.rook_ceph_osd,
    kubernetes_manifest.rook_operator_cluster_role
  ]
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
        apiGroups = ["batch"]
        resources = [
          "jobs",
          "cronjobs"
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
        verbs     = ["*"]
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
        verbs     = ["*"]
      },
      {
        apiGroups = ["policy"]
        resources = [
          "poddisruptionbudgets"
        ]
        verbs = ["*"]
      },
      {
        apiGroups = ["objectbucket.io"]
        resources = [
          "objectbucketclaims",
          "objectbuckets"
        ]
        verbs = ["*"]
      },
      {
        apiGroups = ["apiextensions.k8s.io"]
        resources = [
          "customresourcedefinitions"
        ]
        verbs = ["get", "list", "watch"]
      }
    ]
  }

  field_manager {
    force_conflicts = true
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
    # Empty config key required by MON pods
    "config" = ""
  }
}

