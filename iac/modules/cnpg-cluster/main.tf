# Single CloudNativePG Cluster (replaces Bitnami postgresql Helm subchart).

terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

locals {
  rw_service = "${var.cluster_name}-rw.${var.namespace}.svc.cluster.local"
}

resource "kubernetes_secret" "app_credentials" {
  metadata {
    name      = "${var.cluster_name}-credentials"
    namespace = var.namespace
    labels = merge(var.labels, {
      environment  = var.environment
      managed-by   = "opentofu"
      cnpg-cluster = var.cluster_name
    })
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = var.username
    password = var.password
  }
}

resource "kubernetes_manifest" "cluster" {
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = var.cluster_name
      namespace = var.namespace
      labels = merge(var.labels, {
        environment  = var.environment
        managed-by   = "opentofu"
        cnpg-cluster = var.cluster_name
      })
    }
    spec = {
      instances = var.instances
      storage = merge(
        {
          size = var.storage_size
        },
        var.storage_class != "" ? { storageClass = var.storage_class } : {}
      )
      bootstrap = {
        initdb = {
          database = var.database
          owner    = var.username
          secret = {
            name = kubernetes_secret.app_credentials.metadata[0].name
          }
        }
      }
      resources = var.resources
    }
  }

  depends_on = [var.operator_ready]
}
