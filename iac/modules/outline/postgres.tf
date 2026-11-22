resource "random_password" "postgres" {
  length  = 32
  special = true
}

resource "kubernetes_secret_v1" "postgres_credentials" {
  metadata {
    name      = "${local.postgres_cluster_name}-credentials"
    namespace = local.namespace
    labels = merge(local.labels, {
      "cnpg-cluster" = local.postgres_cluster_name
    })
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = var.postgres_username
    password = random_password.postgres.result
  }

  depends_on = [kubernetes_namespace_v1.outline]
}

# Chart externalPostgresql.existingSecret expects key postgres-password.
resource "kubernetes_secret_v1" "postgres_password" {
  metadata {
    name      = "outline-postgresql"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    postgres-password = random_password.postgres.result
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.outline]
}

resource "kubernetes_manifest" "postgres_cluster" {
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = local.postgres_cluster_name
      namespace = local.namespace
      labels = merge(local.labels, {
        "cnpg-cluster" = local.postgres_cluster_name
      })
    }
    spec = {
      instances = var.postgres_instances
      storage = merge(
        {
          size = var.postgres_storage_size
        },
        var.postgres_storage_class != "" ? { storageClass = var.postgres_storage_class } : {},
      )
      bootstrap = {
        initdb = {
          database = var.postgres_database
          owner    = var.postgres_username
          secret = {
            name = kubernetes_secret_v1.postgres_credentials.metadata[0].name
          }
        }
      }
      resources = {
        requests = {
          cpu    = "100m"
          memory = "256Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "512Mi"
        }
      }
    }
  }

  depends_on = [
    kubernetes_secret_v1.postgres_credentials,
    var.cnpg_operator_ready,
  ]
}
