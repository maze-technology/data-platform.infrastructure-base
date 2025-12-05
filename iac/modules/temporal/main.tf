resource "kubernetes_namespace" "temporal" {
  metadata {
    name = var.namespace
    labels = {
      name        = var.namespace
      environment = var.environment
      managed-by  = "opentofu"
    }
  }
}

# Temporal Helm chart installation
resource "helm_release" "temporal" {
  name       = "temporal"
  repository = "https://go.temporal.io/helm-charts"
  chart      = "temporal"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.temporal.metadata[0].name

  timeout = 900 # 15 minutes for full deployment

  values = [
    yamlencode({
      # Server configuration
      server = {
        replicaCount = var.replica_count

        frontend = {
          replicaCount = var.enable_ha ? max(2, var.replica_count) : var.replica_count
          resources = {
            requests = var.resource_requests.frontend
            limits   = var.resource_limits.frontend
          }
          service = {
            type = "ClusterIP"
            port = 7233
          }
        }

        history = {
          replicaCount = var.enable_ha ? max(2, var.replica_count) : var.replica_count
          resources = {
            requests = var.resource_requests.history
            limits   = var.resource_limits.history
          }
        }

        matching = {
          replicaCount = var.enable_ha ? max(2, var.replica_count) : var.replica_count
          resources = {
            requests = var.resource_requests.matching
            limits   = var.resource_limits.matching
          }
        }

        worker = {
          replicaCount = var.replica_count
          resources = {
            requests = var.resource_requests.worker
            limits   = var.resource_limits.worker
          }
        }
      }

      # Web UI configuration
      web = {
        enabled      = true
        replicaCount = var.replica_count

        ingress = {
          enabled          = var.ingress_enabled
          ingressClassName = var.ingress_class
          hosts = var.ingress_enabled ? [{
            host = var.ingress_host
            paths = [{
              path     = "/"
              pathType = "Prefix"
            }]
          }] : []
          annotations = var.enable_tls ? {
            "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
          } : {}
          tls = var.enable_tls && var.ingress_enabled ? [{
            hosts      = [var.ingress_host]
            secretName = var.tls_secret_name
          }] : []
        }
      }

      # Persistence configuration - use PostgreSQL or Cassandra
      cassandra = var.use_postgresql ? {
        enabled = false
        } : {
        enabled = true
        persistence = {
          enabled      = true
          storageClass = var.persistence_storage_class
          size         = var.cassandra_storage_size
        }
        resources = {
          requests = {
            cpu    = "200m"
            memory = "512Mi"
          }
          limits = {
            cpu    = "1000m"
            memory = "1Gi"
          }
        }
      }

      # PostgreSQL configuration (alternative to Cassandra)
      postgresql = var.use_postgresql ? {
        enabled = true
        auth = {
          username = "temporal"
          password = "temporal"
          database = "temporal"
        }
        primary = {
          persistence = {
            enabled      = true
            storageClass = var.persistence_storage_class
            size         = var.postgresql_storage_size
          }
        }
        } : {
        enabled = false
      }

      # Elasticsearch for advanced visibility (optional but recommended)
      elasticsearch = {
        enabled  = true
        replicas = var.enable_ha ? 3 : 1
        persistence = {
          enabled = true
          size    = var.elasticsearch_storage_size
        }
        resources = {
          requests = {
            cpu    = "200m"
            memory = "512Mi"
          }
          limits = {
            cpu    = "1000m"
            memory = "1Gi"
          }
        }
      }

      # Prometheus metrics
      prometheus = {
        enabled = true
      }

      # Grafana dashboards
      grafana = {
        enabled = false # Assuming observability module handles Grafana
      }
    })
  ]

  depends_on = [kubernetes_namespace.temporal]
}

# Job to create Temporal namespaces after deployment
# This creates the logical Temporal namespaces (data-platform, trading-platform)
resource "kubernetes_job" "create_temporal_namespaces" {
  count = length(var.temporal_namespaces) > 0 ? 1 : 0

  metadata {
    name      = "create-temporal-namespaces"
    namespace = kubernetes_namespace.temporal.metadata[0].name
    labels = {
      app         = "temporal-namespace-setup"
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  spec {
    template {
      metadata {
        labels = {
          app = "temporal-namespace-setup"
        }
      }

      spec {
        restart_policy = "OnFailure"

        container {
          name  = "tctl"
          image = "temporalio/admin-tools:1.25.0"

          command = ["/bin/sh", "-c"]
          args = [
            <<-EOT
              set -e
              echo "Waiting for Temporal frontend to be ready..."
              
              # Wait for frontend service to be available
              until nc -z temporal-frontend 7233; do
                echo "Waiting for temporal-frontend:7233..."
                sleep 5
              done
              
              echo "Temporal frontend is ready. Creating namespaces..."
              
              # Create each namespace
              ${join("\n              ", [for ns in var.temporal_namespaces :
            "tctl --namespace ${ns} namespace register || echo 'Namespace ${ns} already exists or error occurred'"
      ])}
              
              echo "All namespaces processed successfully"
              
              # List all namespaces
              echo "Current Temporal namespaces:"
              tctl namespace list || true
            EOT
    ]

    env {
      name  = "TEMPORAL_CLI_ADDRESS"
      value = "temporal-frontend:7233"
    }
  }
}
}

backoff_limit = 5
}

wait_for_completion = false

depends_on = [helm_release.temporal]
}
