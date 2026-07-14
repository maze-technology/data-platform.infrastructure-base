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

  values = [
    yamlencode({
      installCRDs  = true
      replicaCount = var.replica_count
      webhook = {
        replicaCount = var.enable_webhook ? 1 : 0
        resources = {
          requests = var.resource_requests.webhook
          limits   = var.resource_limits.webhook
        }
      }
      cainjector = {
        enabled = var.enable_cainjector
        resources = {
          requests = var.resource_requests.cainjector
          limits   = var.resource_limits.cainjector
        }
      }
      resources = {
        requests = var.resource_requests.controller
        limits   = var.resource_limits.controller
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

