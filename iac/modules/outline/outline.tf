# Outline requires exactly 64 hex chars (openssl rand -hex 32). random_id.hex is importable as-is.
resource "random_id" "secret_key" {
  byte_length = 32
}

resource "random_id" "utils_secret" {
  byte_length = 32
}

resource "kubernetes_secret_v1" "outline_secrets" {
  metadata {
    name      = "outline-secrets"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    secret-key   = random_id.secret_key.hex
    utils-secret = random_id.utils_secret.hex
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.outline]
}

resource "helm_release" "outline" {
  name       = "outline"
  repository = "https://community-charts.github.io/helm-charts"
  chart      = "outline"
  version    = var.outline_helm_chart_version
  namespace  = local.namespace

  wait    = false
  timeout = 600

  values = [
    yamlencode({
      replicaCount = var.replica_count

      strategy = {
        type = "Recreate"
      }

      secretKeyExternalSecret = {
        name = kubernetes_secret_v1.outline_secrets.metadata[0].name
        key  = "secret-key"
      }
      utilsSecretExternalSecret = {
        name = kubernetes_secret_v1.outline_secrets.metadata[0].name
        key  = "utils-secret"
      }

      url = local.url

      web = {
        # TLS terminates at ingress-nginx
        forceHttps          = false
        skipSSLVerification = false
        concurrency         = 1
      }

      database = {
        connectionPoolMin = "2"
        connectionPoolMax = "20"
        sslMode           = "disable"
      }

      postgresql = {
        enabled = false
      }
      redis = {
        enabled = false
      }
      minio = {
        enabled = false
      }

      externalPostgresql = {
        host              = local.postgres_host
        port              = 5432
        database          = var.postgres_database
        username          = var.postgres_username
        existingSecret    = kubernetes_secret_v1.postgres_password.metadata[0].name
        passwordSecretKey = "postgres-password"
      }

      externalRedis = {
        host              = local.valkey_host
        port              = 6379
        existingSecret    = kubernetes_secret_v1.redis_chart.metadata[0].name
        usernameSecretKey = "redis-username"
        passwordSecretKey = "redis-password"
      }

      fileStorage = {
        mode = "s3"
        local = {
          persistence = {
            enabled = false
          }
        }
        s3 = {
          bucket                   = var.object_storage.bucket
          region                   = var.object_storage.region
          bucketUrl                = var.object_storage.endpoint
          forcePathStyle           = var.object_storage.force_path_style
          acl                      = var.object_storage.acl
          existingSecret           = kubernetes_secret_v1.s3.metadata[0].name
          accessKeyIdSecretKey     = "access-key-id"
          secretAccessKeySecretKey = "secret-access-key"
        }
      }

      auth = {
        oidc = merge(
          {
            enabled       = true
            clientId      = var.oidc.client_id
            clientSecret  = var.oidc.client_secret
            authUri       = var.oidc.auth_uri
            tokenUri      = var.oidc.token_uri
            userInfoUri   = var.oidc.userinfo_uri
            usernameClaim = "preferred_username"
            displayName   = var.oidc.display_name
            scopes        = ["openid", "profile", "email"]
          },
          var.oidc.logout_uri != "" ? { logoutUri = var.oidc.logout_uri } : {},
        )
      }

      ingress = {
        enabled   = true
        className = var.ingress_class
        annotations = merge(
          var.enable_tls ? {
            "cert-manager.io/cluster-issuer"                 = var.ingress_cluster_issuer
            "nginx.ingress.kubernetes.io/ssl-redirect"       = "true"
            "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"
          } : {},
          var.restrict_to_vpn ? {
            "nginx.ingress.kubernetes.io/whitelist-source-range" = local.ingress_whitelist
          } : {},
          {
            "nginx.ingress.kubernetes.io/proxy-body-size"    = "256m"
            "nginx.ingress.kubernetes.io/proxy-read-timeout" = "3600"
            "nginx.ingress.kubernetes.io/proxy-send-timeout" = "3600"
          },
        )
        hosts = [
          {
            host = local.hostname
            paths = [
              {
                path     = "/"
                pathType = "Prefix"
              }
            ]
          }
        ]
        tls = var.enable_tls ? [
          {
            secretName = "outline-tls"
            hosts      = [local.hostname]
          }
        ] : []
      }

      resources = {
        requests = {
          cpu    = "200m"
          memory = "512Mi"
        }
        limits = {
          cpu    = "2"
          memory = "2Gi"
        }
      }
    })
  ]

  depends_on = [
    kubernetes_manifest.postgres_cluster,
    helm_release.valkey,
    kubernetes_secret_v1.outline_secrets,
    kubernetes_secret_v1.postgres_password,
    kubernetes_secret_v1.redis_chart,
    kubernetes_secret_v1.s3,
  ]
}
