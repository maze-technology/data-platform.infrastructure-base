resource "random_password" "valkey" {
  length  = 32
  special = true
}

resource "kubernetes_secret_v1" "valkey" {
  metadata {
    name      = "outline-valkey"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    default = random_password.valkey.result
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.outline]
}

# community-charts/outline externalRedis.existingSecret keys.
resource "kubernetes_secret_v1" "redis_chart" {
  metadata {
    name      = "outline-redis"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    redis-username = "default"
    redis-password = random_password.valkey.result
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.outline]
}

resource "helm_release" "valkey" {
  name       = local.valkey_release_name
  repository = "https://valkey.io/valkey-helm/"
  chart      = "valkey"
  version    = var.valkey_helm_chart_version
  namespace  = local.namespace

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
        usersExistingSecret = kubernetes_secret_v1.valkey.metadata[0].name
      }
      dataStorage = merge(
        {
          enabled       = true
          requestedSize = var.valkey_storage_size
        },
        var.valkey_storage_class != "" ? { className = var.valkey_storage_class } : {},
      )
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

  depends_on = [kubernetes_secret_v1.valkey]
}
