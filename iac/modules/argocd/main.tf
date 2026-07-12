resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.namespace
    labels = {
      name        = var.namespace
      environment = var.environment
      managed-by  = "opentofu"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  timeout = 600

  values = [
    yamlencode(merge({
      global = {
        image = {
          tag = "v2.9.3"
        }
      }
      controller = {
        replicas = var.enable_ha ? 2 : 1
        resources = {
          requests = var.resource_requests.application_controller
          limits   = var.resource_limits.application_controller
        }
      }
      server = {
        replicas = var.replica_count
        resources = {
          requests = var.resource_requests.server
          limits   = var.resource_limits.server
        }
        ingress = {
          enabled          = var.ingress_enabled
          ingressClassName = var.ingress_class
          hosts            = var.ingress_enabled ? [var.ingress_host] : []
          tls = var.enable_tls && var.ingress_enabled ? [{
            hosts      = [var.ingress_host]
            secretName = var.tls_secret_name
          }] : []
        }
      }
      repoServer = {
        replicas = var.enable_ha ? 2 : 1
        resources = {
          requests = var.resource_requests.repo_server
          limits   = var.resource_limits.repo_server
        }
      }
      applicationSet = {
        replicas = var.enable_ha ? 2 : 1
      }
      # In-cluster Redis — ephemeral cache only; Helm deploys redis or redis-ha automatically
      redis = {
        enabled = !var.enable_ha
      }
      "redis-ha" = {
        enabled = var.enable_ha
      }
      redisSecretInit = {
        enabled = true
      }
      configs = var.oidc != null ? {
        cm = {
          url           = var.enable_tls ? "https://${var.ingress_host}" : "http://${var.ingress_host}"
          "oidc.config" = <<-EOT
            name: Keycloak
            issuer: ${var.oidc.issuer_url}
            clientID: ${var.oidc.client_id}
            clientSecret: ${var.oidc.client_secret}
            requestedScopes:
              - openid
              - profile
              - email
              - groups
            requestedIDTokenClaims:
              groups:
                essential: true
          EOT
        }
        rbac = {
          "policy.csv" = <<-EOT
            g, admins, role:admin
            g, developers, role:readonly
          EOT
          "scopes"     = "[groups]"
        }
      } : {}
    }))
  ]

  depends_on = [kubernetes_namespace.argocd]
}

