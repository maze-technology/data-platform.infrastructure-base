resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.namespace
    labels = {
      name        = var.namespace
      environment = var.environment
      managed-by  = "opentofu"
    }
  }
}

# Prometheus Operator (includes Prometheus, Alertmanager, and ServiceMonitor CRDs)
resource "helm_release" "prometheus_operator" {
  count = var.enable_prometheus ? 1 : 0

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "55.5.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                accessModes = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = var.prometheus_storage_size
                  }
                }
              }
            }
          }
          resources = {
            requests = var.resource_requests.prometheus
            limits   = var.resource_limits.prometheus
          }
          retention = "30d"
        }
      }
      grafana = {
        enabled = var.enable_grafana
        adminPassword = "admin" # Should be overridden via secrets in production
        persistence = {
          enabled = true
          size    = var.grafana_storage_size
        }
        resources = {
          requests = var.resource_requests.grafana
          limits   = var.resource_limits.grafana
        }
        ingress = {
          enabled          = var.grafana_ingress_enabled
          ingressClassName = var.grafana_ingress_class
          hosts            = var.grafana_ingress_enabled ? [var.grafana_ingress_host] : []
          annotations = var.grafana_enable_tls ? {
            "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
          } : {}
          tls = var.grafana_enable_tls && var.grafana_ingress_enabled ? [{
            hosts      = [var.grafana_ingress_host]
            secretName = "grafana-tls"
          }] : []
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

# Loki for log aggregation
resource "helm_release" "loki" {
  count = var.enable_loki ? 1 : 0

  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "5.42.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    yamlencode({
      loki = {
        resources = {
          requests = var.resource_requests.loki
          limits   = var.resource_limits.loki
        }
        storage = {
          type = "filesystem"
          filesystem = {
            chunksDirectory = "/loki/chunks"
            rulesDirectory  = "/loki/rules"
          }
        }
        persistence = {
          enabled = true
          size    = var.loki_storage_size
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

# Promtail for log collection
resource "helm_release" "promtail" {
  count = var.enable_promtail && var.enable_loki ? 1 : 0

  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  version    = "6.15.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    yamlencode({
      config = {
        clients = [{
          url = "http://loki:3100/loki/api/v1/push"
        }]
      }
    })
  ]

  depends_on = [kubernetes_namespace.monitoring, helm_release.loki]
}

