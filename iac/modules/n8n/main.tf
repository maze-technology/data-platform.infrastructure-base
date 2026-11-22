locals {
  url               = var.enable_tls ? "https://${var.hostname}" : "http://${var.hostname}"
  ingress_whitelist = "${var.vpn_cidr},127.0.0.1/32,10.0.0.0/8"
  postgresql_host   = module.n8n_postgresql.rw_host
  valkey_host       = "valkey.${var.namespace}.svc.cluster.local"

  labels = {
    app                         = "n8n"
    environment                 = var.environment
    managed-by                  = "opentofu"
    "app.kubernetes.io/name"    = "n8n"
    "app.kubernetes.io/part-of" = "n8n"
  }

  ingress_annotations = merge(
    var.restrict_to_vpn ? {
      "nginx.ingress.kubernetes.io/whitelist-source-range" = local.ingress_whitelist
    } : {},
    var.enable_tls ? {
      "cert-manager.io/cluster-issuer"                 = var.tls_cluster_issuer
      "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"
      "nginx.ingress.kubernetes.io/ssl-redirect"       = "true"
    } : {},
  )

  shared_extra_env = concat(
    [
      {
        name  = "N8N_DIAGNOSTICS_ENABLED"
        value = "false"
      },
      {
        name  = "N8N_VERSION_NOTIFICATIONS_ENABLED"
        value = "false"
      },
      {
        name  = "N8N_PERSONALIZATION_ENABLED"
        value = "false"
      },
      {
        name  = "N8N_PROXY_HOPS"
        value = "1"
      },
    ],
    var.enable_mcp ? [
      {
        name  = "N8N_MCP_MANAGED_BY_ENV"
        value = "true"
      },
      {
        name  = "N8N_MCP_ACCESS_ENABLED"
        value = "true"
      },
    ] : [],
  )
}

resource "kubernetes_namespace" "n8n" {
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

resource "random_password" "encryption_key" {
  length  = 64
  special = false
}

module "n8n_postgresql" {
  source = "../cnpg-cluster"

  environment    = var.environment
  namespace      = kubernetes_namespace.n8n.metadata[0].name
  cluster_name   = "n8n-pg"
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

  depends_on = [kubernetes_namespace.n8n]
}

resource "kubernetes_secret" "valkey" {
  metadata {
    name      = "n8n-valkey"
    namespace = kubernetes_namespace.n8n.metadata[0].name
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
  namespace  = kubernetes_namespace.n8n.metadata[0].name

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

resource "kubernetes_secret" "db" {
  metadata {
    name      = "n8n-db"
    namespace = kubernetes_namespace.n8n.metadata[0].name
    labels    = local.labels
  }

  data = {
    password = random_password.postgresql.result
  }

  type = "Opaque"
}

resource "kubernetes_secret" "redis" {
  metadata {
    name      = "n8n-redis"
    namespace = kubernetes_namespace.n8n.metadata[0].name
    labels    = local.labels
  }

  data = {
    password = random_password.valkey.result
  }

  type = "Opaque"
}

resource "kubernetes_secret" "core" {
  metadata {
    name      = "n8n-core"
    namespace = kubernetes_namespace.n8n.metadata[0].name
    labels    = local.labels
  }

  # Chart injects N8N_HOST/PORT/PROTOCOL + N8N_ENCRYPTION_KEY from this Secret
  # when secretRefs.existingSecret is set.
  data = {
    N8N_ENCRYPTION_KEY = random_password.encryption_key.result
    N8N_HOST           = var.hostname
    N8N_PORT           = "5678"
    N8N_PROTOCOL       = var.enable_tls ? "https" : "http"
  }

  type = "Opaque"
}

resource "helm_release" "n8n" {
  name       = "n8n"
  repository = "oci://ghcr.io/n8n-io/n8n-helm-chart"
  chart      = "n8n"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.n8n.metadata[0].name

  wait          = true
  wait_for_jobs = true
  timeout       = 900

  values = [
    yamlencode({
      queueMode = {
        enabled            = true
        workerReplicaCount = var.worker_replicas
        workerConcurrency  = var.worker_concurrency
      }

      webhookProcessor = {
        enabled = false
      }

      secretRefs = {
        existingSecret = kubernetes_secret.core.metadata[0].name
      }

      database = {
        type        = "postgresdb"
        useExternal = true
        host        = local.postgresql_host
        port        = 5432
        database    = var.postgresql_database
        schema      = "public"
        user        = var.postgresql_username
        passwordSecret = {
          name = kubernetes_secret.db.metadata[0].name
          key  = "password"
        }
        ssl = {
          enabled = false
        }
      }

      redis = {
        enabled     = true
        useExternal = true
        host        = local.valkey_host
        port        = 6379
        username    = "default"
        passwordSecret = {
          name = kubernetes_secret.redis.metadata[0].name
          key  = "password"
        }
        tls = false
      }

      editor = {
        url = local.url
      }

      webhook = {
        enabled = true
        url     = local.url
      }

      ingress = {
        enabled     = true
        className   = var.ingress_class
        annotations = local.ingress_annotations
        hosts = [
          {
            host = var.hostname
            paths = [
              {
                path     = "/"
                pathType = "Prefix"
              },
            ]
          },
        ]
        tls = var.enable_tls ? [
          {
            secretName = "n8n-tls"
            hosts      = [var.hostname]
          },
        ] : []
      }

      persistence = {
        enabled          = true
        accessModes      = ["ReadWriteOnce"]
        size             = "20Gi"
        storageClassName = var.storage_class
      }

      s3 = {
        enabled = false
      }

      license = {
        enabled = false
      }

      config = {
        timezone = "UTC"
        extraEnv = local.shared_extra_env
      }
    })
  ]

  depends_on = [
    module.n8n_postgresql,
    helm_release.valkey,
    kubernetes_secret.db,
    kubernetes_secret.redis,
    kubernetes_secret.core,
  ]
}
