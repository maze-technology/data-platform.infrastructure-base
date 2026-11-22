terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    helm = {
      source = "hashicorp/helm"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

locals {
  url               = var.enable_tls ? "https://${var.hostname}" : "http://${var.hostname}"
  ingress_whitelist = "${var.vpn_cidr},127.0.0.1/32,10.0.0.0/8"
  postgresql_host   = module.teable_postgresql.rw_host
  valkey_host       = "valkey.${var.namespace}.svc.cluster.local"
  pg_url            = "postgresql://${var.postgresql_username}:${urlencode(random_password.postgresql.result)}@${local.postgresql_host}:5432/${var.postgresql_database}"
  redis_uri         = "redis://default:${urlencode(random_password.valkey.result)}@${local.valkey_host}:6379/0"

  labels = {
    app                         = "teable"
    environment                 = var.environment
    managed-by                  = "opentofu"
    "app.kubernetes.io/name"    = "teable"
    "app.kubernetes.io/part-of" = "teable"
  }
}

resource "kubernetes_namespace" "teable" {
  metadata {
    name = var.namespace
    labels = merge(local.labels, {
      name = var.namespace
    })
  }
}

resource "random_password" "postgresql" {
  length  = 32
  special = false
}

resource "random_password" "valkey" {
  length  = 32
  special = false
}

resource "random_password" "secret_key" {
  length  = 48
  special = false
}

resource "random_id" "storage_encryption_key" {
  byte_length = 8
}

resource "random_id" "storage_encryption_iv" {
  byte_length = 8
}

resource "random_id" "access_token_encryption_key" {
  byte_length = 8
}

resource "random_id" "access_token_encryption_iv" {
  byte_length = 8
}

module "teable_postgresql" {
  source = "../cnpg-cluster"

  environment    = var.environment
  namespace      = kubernetes_namespace.teable.metadata[0].name
  cluster_name   = "teable-pg"
  database       = var.postgresql_database
  username       = var.postgresql_username
  password       = random_password.postgresql.result
  storage_size   = var.postgresql_storage_size
  storage_class  = var.storage_class
  operator_ready = var.cnpg_operator_ready

  resources = {
    requests = {
      cpu    = "100m"
      memory = "256Mi"
    }
    limits = {
      cpu    = "1"
      memory = "1Gi"
    }
  }

  depends_on = [kubernetes_namespace.teable]
}

resource "kubernetes_secret" "valkey" {
  metadata {
    name      = "teable-valkey"
    namespace = kubernetes_namespace.teable.metadata[0].name
    labels    = local.labels
  }

  data = {
    default = random_password.valkey.result
  }

  type = "Opaque"
}

resource "helm_release" "valkey" {
  name       = "valkey"
  repository = "https://valkey.io/valkey-helm/"
  chart      = "valkey"
  version    = var.valkey_helm_chart_version
  namespace  = kubernetes_namespace.teable.metadata[0].name

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      auth = {
        enabled = true
        aclUsers = {
          default = {
            permissions = "~* &* +@all"
            passwordKey = "default"
          }
        }
        usersExistingSecret = kubernetes_secret.valkey.metadata[0].name
      }
      dataStorage = {
        enabled       = true
        requestedSize = var.valkey_storage_size
        className     = var.storage_class
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

  depends_on = [kubernetes_secret.valkey]
}

resource "kubernetes_secret" "app" {
  metadata {
    name      = "teable-app"
    namespace = kubernetes_namespace.teable.metadata[0].name
    labels    = local.labels
  }

  data = {
    SECRET_KEY                          = random_password.secret_key.result
    PRISMA_DATABASE_URL                 = local.pg_url
    BACKEND_CACHE_REDIS_URI             = local.redis_uri
    BACKEND_STORAGE_S3_ACCESS_KEY       = var.object_storage.access_key
    BACKEND_STORAGE_S3_SECRET_KEY       = var.object_storage.secret_key
    BACKEND_OIDC_CLIENT_SECRET          = var.oidc.client_secret
    BACKEND_STORAGE_ENCRYPTION_KEY      = random_id.storage_encryption_key.hex
    BACKEND_STORAGE_ENCRYPTION_IV       = random_id.storage_encryption_iv.hex
    BACKEND_ACCESS_TOKEN_ENCRYPTION_KEY = random_id.access_token_encryption_key.hex
    BACKEND_ACCESS_TOKEN_ENCRYPTION_IV  = random_id.access_token_encryption_iv.hex
  }

  type = "Opaque"
}

resource "kubernetes_deployment" "teable" {
  metadata {
    name      = "teable"
    namespace = kubernetes_namespace.teable.metadata[0].name
    labels    = local.labels
  }

  spec {
    replicas = var.replica_count

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "teable"
      }
    }

    template {
      metadata {
        labels = merge(local.labels, {
          "app.kubernetes.io/name" = "teable"
        })
      }

      spec {
        container {
          name  = "teable"
          image = var.image

          port {
            name           = "http"
            container_port = 3000
            protocol       = "TCP"
          }

          env {
            name  = "PUBLIC_ORIGIN"
            value = local.url
          }
          env {
            name  = "PORT"
            value = "3000"
          }
          env {
            name  = "NEXT_ENV_IMAGES_ALL_REMOTE"
            value = "true"
          }
          env {
            name  = "PASSWORD_LOGIN_DISABLED"
            value = "true"
          }
          env {
            name  = "SOCIAL_AUTH_PROVIDERS"
            value = "oidc"
          }
          env {
            name  = "BACKEND_OIDC_CLIENT_ID"
            value = var.oidc.client_id
          }
          env {
            name  = "BACKEND_OIDC_CALLBACK_URL"
            value = "${local.url}/api/auth/oidc/callback"
          }
          env {
            name  = "BACKEND_OIDC_AUTHORIZATION_URL"
            value = var.oidc.auth_uri
          }
          env {
            name  = "BACKEND_OIDC_TOKEN_URL"
            value = var.oidc.token_uri
          }
          env {
            name  = "BACKEND_OIDC_USER_INFO_URL"
            value = var.oidc.userinfo_uri
          }
          env {
            name  = "BACKEND_OIDC_ISSUER"
            value = var.oidc.issuer
          }
          env {
            name  = "BACKEND_OIDC_OTHER"
            value = jsonencode({ scope = ["openid", "profile", "email"] })
          }
          env {
            name  = "BACKEND_STORAGE_PROVIDER"
            value = "s3"
          }
          env {
            name  = "BACKEND_STORAGE_PUBLIC_BUCKET"
            value = var.object_storage.public_bucket
          }
          env {
            name  = "BACKEND_STORAGE_PRIVATE_BUCKET"
            value = var.object_storage.private_bucket
          }
          env {
            name  = "BACKEND_STORAGE_S3_REGION"
            value = var.object_storage.region
          }
          env {
            name  = "BACKEND_STORAGE_S3_ENDPOINT"
            value = var.object_storage.endpoint
          }
          env {
            name  = "BACKEND_STORAGE_S3_INTERNAL_ENDPOINT"
            value = var.object_storage.internal_endpoint
          }
          env {
            name  = "BACKEND_STORAGE_S3_FORCE_PATH_STYLE"
            value = tostring(var.object_storage.force_path_style)
          }
          env {
            name  = "BACKEND_STORAGE_S3_INTERNAL_FORCE_PATH_STYLE"
            value = "true"
          }
          env {
            name  = "BACKEND_SESSION_COOKIE_SECURE"
            value = "true"
          }
          env {
            name  = "TEABLE_SSRF_PROTECTION_DISABLED"
            value = "true"
          }
          env {
            name  = "TELEMETRY_REPORT_DISABLED"
            value = "true"
          }

          env {
            name = "SECRET_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "SECRET_KEY"
              }
            }
          }
          env {
            name = "PRISMA_DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "PRISMA_DATABASE_URL"
              }
            }
          }
          env {
            name = "BACKEND_CACHE_REDIS_URI"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "BACKEND_CACHE_REDIS_URI"
              }
            }
          }
          env {
            name = "BACKEND_STORAGE_S3_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "BACKEND_STORAGE_S3_ACCESS_KEY"
              }
            }
          }
          env {
            name = "BACKEND_STORAGE_S3_SECRET_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "BACKEND_STORAGE_S3_SECRET_KEY"
              }
            }
          }
          env {
            name = "BACKEND_OIDC_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "BACKEND_OIDC_CLIENT_SECRET"
              }
            }
          }
          env {
            name = "BACKEND_STORAGE_ENCRYPTION_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "BACKEND_STORAGE_ENCRYPTION_KEY"
              }
            }
          }
          env {
            name = "BACKEND_STORAGE_ENCRYPTION_IV"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "BACKEND_STORAGE_ENCRYPTION_IV"
              }
            }
          }
          env {
            name = "BACKEND_ACCESS_TOKEN_ENCRYPTION_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "BACKEND_ACCESS_TOKEN_ENCRYPTION_KEY"
              }
            }
          }
          env {
            name = "BACKEND_ACCESS_TOKEN_ENCRYPTION_IV"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "BACKEND_ACCESS_TOKEN_ENCRYPTION_IV"
              }
            }
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2"
              memory = "2Gi"
            }
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 6
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 60
            period_seconds        = 20
            timeout_seconds       = 5
            failure_threshold     = 6
          }
        }
      }
    }
  }

  depends_on = [
    module.teable_postgresql,
    helm_release.valkey,
    kubernetes_secret.app,
  ]
}

resource "kubernetes_service" "teable" {
  metadata {
    name      = "teable"
    namespace = kubernetes_namespace.teable.metadata[0].name
    labels    = local.labels
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = "teable"
    }

    port {
      name        = "http"
      port        = 80
      target_port = "http"
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_ingress_v1" "teable" {
  metadata {
    name      = "teable"
    namespace = kubernetes_namespace.teable.metadata[0].name
    labels    = local.labels
    annotations = merge(
      var.enable_tls ? {
        "cert-manager.io/cluster-issuer"                 = var.tls_cluster_issuer
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
  }

  spec {
    ingress_class_name = var.ingress_class

    rule {
      host = var.hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.teable.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }

    dynamic "tls" {
      for_each = var.enable_tls ? [1] : []
      content {
        secret_name = "teable-tls"
        hosts       = [var.hostname]
      }
    }
  }
}
