# CloudNativePG operator — cluster-wide PostgreSQL management (replaces Bitnami postgresql charts).

terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    helm = {
      source = "hashicorp/helm"
    }
  }
}

resource "kubernetes_namespace" "cnpg_system" {
  metadata {
    name = var.namespace
    labels = {
      name        = var.namespace
      environment = var.environment
      managed-by  = "opentofu"
    }
  }
}

resource "helm_release" "cloudnativepg" {
  name       = "cloudnative-pg"
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cloudnative-pg"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.cnpg_system.metadata[0].name

  timeout = 600

  values = [
    yamlencode({
      crds = {
        create = true
      }
      config = {
        clusterWide = true
      }
      monitoring = {
        podMonitorEnabled = false
      }
      resources = {
        requests = {
          cpu    = "50m"
          memory = "128Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "512Mi"
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.cnpg_system]
}
