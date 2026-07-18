locals {
  ingress_whitelist = "${var.vpn_cidr},127.0.0.1/32,10.0.0.0/8"

  ingress_annotations = merge(
    var.restrict_to_vpn ? {
      "nginx.ingress.kubernetes.io/whitelist-source-range" = local.ingress_whitelist
    } : {},
    var.enable_tls ? {
      "cert-manager.io/cluster-issuer"                 = var.tls_cluster_issuer
      "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"
      "nginx.ingress.kubernetes.io/ssl-redirect"       = "true"
      "nginx.ingress.kubernetes.io/backend-protocol"   = "HTTP"
      } : {
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"
    },
  )
}

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
        domain = var.ingress_host
        image = {
          tag = var.argocd_image_tag
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
          hostname         = var.ingress_host
          annotations      = local.ingress_annotations
          tls              = var.enable_tls && var.ingress_enabled
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
      configs = merge(
        {
          # TLS terminates at ingress; Argo CD serves cleartext behind nginx.
          # Without this, enable_tls causes an HTTPS redirect loop.
          params = {
            "server.insecure" = "true"
          }
        },
        var.oidc != null ? {
          cm = merge(
            {
              url             = var.enable_tls ? "https://${var.ingress_host}" : "http://${var.ingress_host}"
              "admin.enabled" = "false"
              "oidc.config"   = <<-EOT
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
            %{if var.oidc.root_ca_pem != ""~}
            rootCA: |
              ${indent(2, chomp(var.oidc.root_ca_pem))}
            %{endif~}
          EOT
            },
          )
          rbac = {
            "policy.csv" = <<-EOT
            g, admins, role:admin
            g, engineers, role:readonly
          EOT
            "scopes"     = "[groups]"
          }
        } : {},
      )
    }))
  ]

  depends_on = [kubernetes_namespace.argocd]
}

