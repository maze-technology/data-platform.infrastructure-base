resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = var.namespace
    labels = {
      name        = var.namespace
      environment = var.environment
      managed-by  = "opentofu"
    }
  }
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "replicaCount"
    value = var.replica_count
  }

  set {
    name  = "webhook.enabled"
    value = var.enable_webhook
  }

  set {
    name  = "cainjector.enabled"
    value = var.enable_cainjector
  }

  values = [
    yamlencode({
      resources = {
        requests = var.resource_requests.controller
        limits   = var.resource_limits.controller
      }
      webhook = {
        resources = {
          requests = var.resource_requests.webhook
          limits   = var.resource_limits.webhook
        }
      }
      cainjector = {
        resources = {
          requests = var.resource_requests.cainjector
          limits   = var.resource_limits.cainjector
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.cert_manager]
}

# ClusterIssuer for Let's Encrypt (if email is provided)
resource "kubernetes_manifest" "letsencrypt_cluster_issuer" {
  count = var.letsencrypt_email != "" ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
      labels = {
        environment = var.environment
        managed-by  = "opentofu"
      }
    }
    spec = {
      acme = {
        server = var.letsencrypt_server
        email  = var.letsencrypt_email
        privateKeySecretRef = {
          name = "letsencrypt-prod"
        }
        solvers = [{
          http01 = {
            ingress = {
              class = "nginx"
            }
          }
        }]
      }
    }
  }

  depends_on = [helm_release.cert_manager]
}

