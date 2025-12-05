resource "kubernetes_namespace" "ingress" {
  metadata {
    name = var.namespace
    labels = {
      name               = var.namespace
      environment        = var.environment
      managed-by         = "opentofu"
      ingress-controller = var.ingress_controller_type
    }
  }
}

locals {
  # Only enable ServiceMonitor if dependency is provided (CRDs must exist)
  enable_service_monitor = var.enable_metrics && var.prometheus_operator_dependency != null
}

resource "helm_release" "ingress_nginx" {
  count = var.ingress_controller_type == "nginx" ? 1 : 0

  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.ingress.metadata[0].name

  values = [
    yamlencode({
      controller = {
        replicaCount = var.replica_count
        ingressClass = var.ingress_class
        service = {
          type = var.service_type
          nodePorts = var.service_type == "NodePort" ? {
            http  = var.node_port_http
            https = var.node_port_https
          } : null
        }
        metrics = {
          enabled = var.enable_metrics
          serviceMonitor = {
            enabled = local.enable_service_monitor
          }
        }
        resources = {
          requests = var.resource_requests
          limits   = var.resource_limits
        }
        podLabels = {
          environment = var.environment
          managed-by  = "opentofu"
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.ingress]

  # Wait for Prometheus Operator CRDs to be available when ServiceMonitor is enabled
  # This is handled via module dependency ordering in the root module
}

