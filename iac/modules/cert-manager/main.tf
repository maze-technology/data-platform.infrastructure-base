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

locals {
  acme_dns01        = var.letsencrypt_email != "" && var.acme_solver == "dns01"
  acme_http01       = var.letsencrypt_email != "" && var.acme_solver == "http01"
  ovh_webhook_group = var.ovh_dns_webhook_group_name != "" ? var.ovh_dns_webhook_group_name : "acme.${var.cluster_name}"
}

resource "kubernetes_secret" "ovh_dns_credentials" {
  count = local.acme_dns01 ? 1 : 0

  metadata {
    name      = "ovh-dns-credentials"
    namespace = kubernetes_namespace.cert_manager.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    applicationKey    = var.ovh_application_key
    applicationSecret = var.ovh_application_secret
    consumerKey       = var.ovh_consumer_key
  }
}

# OVH DNS-01 webhook (no public :80 required — VPN-only clusters).
resource "helm_release" "cert_manager_webhook_ovh" {
  count = local.acme_dns01 ? 1 : 0

  name       = "cert-manager-webhook-ovh"
  repository = "https://aureq.github.io/cert-manager-webhook-ovh/"
  chart      = "cert-manager-webhook-ovh"
  version    = var.ovh_dns_webhook_chart_version
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  values = [
    yamlencode({
      groupName = local.ovh_webhook_group
      certManager = {
        namespace          = kubernetes_namespace.cert_manager.metadata[0].name
        serviceAccountName = "cert-manager"
      }
      # Issuer is managed below as kubernetes_manifest for a stable name (letsencrypt-prod).
      issuers = []
    })
  ]

  depends_on = [
    helm_release.cert_manager,
    kubernetes_secret.ovh_dns_credentials,
  ]
}

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
        acme-solver = var.acme_solver
      }
    }
    spec = {
      acme = {
        server = var.letsencrypt_server
        email  = var.letsencrypt_email
        privateKeySecretRef = {
          name = "letsencrypt-prod"
        }
        # yamldecode erases object-type differences between dns01 and http01 solvers.
        solvers = yamldecode(yamlencode(
          local.acme_dns01 ? [{
            dns01 = {
              webhook = {
                groupName  = local.ovh_webhook_group
                solverName = "ovh"
                config = {
                  endpoint = var.ovh_endpoint_name
                  applicationKeyRef = {
                    name = kubernetes_secret.ovh_dns_credentials[0].metadata[0].name
                    key  = "applicationKey"
                  }
                  applicationSecretRef = {
                    name = kubernetes_secret.ovh_dns_credentials[0].metadata[0].name
                    key  = "applicationSecret"
                  }
                  consumerKeyRef = {
                    name = kubernetes_secret.ovh_dns_credentials[0].metadata[0].name
                    key  = "consumerKey"
                  }
                }
              }
            }
            }] : [{
            http01 = {
              ingress = {
                class = "nginx"
              }
            }
          }]
        ))
      }
    }
  }

  depends_on = [
    helm_release.cert_manager,
    helm_release.cert_manager_webhook_ovh,
  ]
}

# Local / offline CA: same ClusterIssuer pattern as production (cert-manager.io/cluster-issuer),
# but signed by an internal Maze CA instead of Let's Encrypt.
resource "kubernetes_manifest" "selfsigned_bootstrap_issuer" {
  count = var.create_maze_ca ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "maze-ca-bootstrap"
      labels = {
        environment = var.environment
        managed-by  = "opentofu"
      }
    }
    spec = {
      selfSigned = {}
    }
  }

  depends_on = [helm_release.cert_manager]
}

resource "kubernetes_manifest" "maze_ca_certificate" {
  count = var.create_maze_ca ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "maze-ca"
      namespace = kubernetes_namespace.cert_manager.metadata[0].name
      labels = {
        environment = var.environment
        managed-by  = "opentofu"
      }
    }
    spec = {
      isCA        = true
      commonName  = "Maze CA"
      secretName  = "maze-ca"
      duration    = "87600h" # 10y
      renewBefore = "720h"
      privateKey = {
        algorithm = "ECDSA"
        size      = 256
      }
      issuerRef = {
        name  = "maze-ca-bootstrap"
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
    }
  }

  depends_on = [kubernetes_manifest.selfsigned_bootstrap_issuer]
}

resource "kubernetes_manifest" "maze_ca_cluster_issuer" {
  count = var.create_maze_ca ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "maze-ca"
      labels = {
        environment = var.environment
        managed-by  = "opentofu"
      }
    }
    spec = {
      ca = {
        secretName = "maze-ca"
      }
    }
  }

  depends_on = [kubernetes_manifest.maze_ca_certificate]
}
