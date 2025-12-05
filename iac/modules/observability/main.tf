resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.namespace
    labels = {
      name        = var.namespace
      environment = var.environment
      managed-by  = "opentofu"
    }
  }
}

# Prometheus Operator (includes Prometheus, Alertmanager, and ServiceMonitor CRDs)
resource "helm_release" "prometheus_operator" {
  count = var.enable_prometheus ? 1 : 0

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "55.5.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  timeout = 600 # 10 minutes

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                accessModes = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = var.prometheus_storage_size
                  }
                }
              }
            }
          }
          resources = {
            requests = var.resource_requests.prometheus
            limits   = var.resource_limits.prometheus
          }
          retention = "30d"
        }
      }
      grafana = {
        enabled       = var.enable_grafana
        adminPassword = "admin" # Should be overridden via secrets in production
        persistence = {
          enabled = true
          size    = var.grafana_storage_size
        }
        resources = {
          requests = var.resource_requests.grafana
          limits   = var.resource_limits.grafana
        }
        ingress = {
          enabled          = var.grafana_ingress_enabled
          ingressClassName = var.grafana_ingress_class
          hosts            = var.grafana_ingress_enabled ? [var.grafana_ingress_host] : []
          annotations = var.grafana_enable_tls ? {
            "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
          } : {}
          tls = var.grafana_enable_tls && var.grafana_ingress_enabled ? [{
            hosts      = [var.grafana_ingress_host]
            secretName = "grafana-tls"
          }] : []
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

# Kubernetes secret for Loki S3 credentials (when using object storage with custom credentials)
resource "kubernetes_secret" "loki_s3_credentials" {
  count = var.enable_loki && var.loki_deployment_mode == "scalable" && var.loki_object_storage != null && var.loki_object_storage.access_key != null ? 1 : 0

  metadata {
    name      = "loki-s3-credentials"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    access-key-id     = base64encode(var.loki_object_storage.access_key)
    secret-access-key = base64encode(var.loki_object_storage.secret_key)
  }

  depends_on = [kubernetes_namespace.monitoring]
}

# Loki for log aggregation
resource "helm_release" "loki" {
  count = var.enable_loki ? 1 : 0

  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "5.42.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    yamlencode(merge(
      {
        loki = {
          resources = {
            requests = var.resource_requests.loki
            limits   = var.resource_limits.loki
          }
          persistence = {
            enabled = true
            size    = var.loki_storage_size
          }
        }
      },
      # Add S3 credentials from secret if provided
      var.loki_deployment_mode == "scalable" && var.loki_object_storage != null && var.loki_object_storage.access_key != null ? {
        loki = {
          env = [
            {
              name = "AWS_ACCESS_KEY_ID"
              valueFrom = {
                secretKeyRef = {
                  name = kubernetes_secret.loki_s3_credentials[0].metadata[0].name
                  key  = "access-key-id"
                }
              }
            },
            {
              name = "AWS_SECRET_ACCESS_KEY"
              valueFrom = {
                secretKeyRef = {
                  name = kubernetes_secret.loki_s3_credentials[0].metadata[0].name
                  key  = "secret-access-key"
                }
              }
            }
          ]
        }
        backend = {
          env = [
            {
              name = "AWS_ACCESS_KEY_ID"
              valueFrom = {
                secretKeyRef = {
                  name = kubernetes_secret.loki_s3_credentials[0].metadata[0].name
                  key  = "access-key-id"
                }
              }
            },
            {
              name = "AWS_SECRET_ACCESS_KEY"
              valueFrom = {
                secretKeyRef = {
                  name = kubernetes_secret.loki_s3_credentials[0].metadata[0].name
                  key  = "secret-access-key"
                }
              }
            }
          ]
        }
        read = {
          env = [
            {
              name = "AWS_ACCESS_KEY_ID"
              valueFrom = {
                secretKeyRef = {
                  name = kubernetes_secret.loki_s3_credentials[0].metadata[0].name
                  key  = "access-key-id"
                }
              }
            },
            {
              name = "AWS_SECRET_ACCESS_KEY"
              valueFrom = {
                secretKeyRef = {
                  name = kubernetes_secret.loki_s3_credentials[0].metadata[0].name
                  key  = "secret-access-key"
                }
              }
            }
          ]
        }
        write = {
          env = [
            {
              name = "AWS_ACCESS_KEY_ID"
              valueFrom = {
                secretKeyRef = {
                  name = kubernetes_secret.loki_s3_credentials[0].metadata[0].name
                  key  = "access-key-id"
                }
              }
            },
            {
              name = "AWS_SECRET_ACCESS_KEY"
              valueFrom = {
                secretKeyRef = {
                  name = kubernetes_secret.loki_s3_credentials[0].metadata[0].name
                  key  = "secret-access-key"
                }
              }
            }
          ]
        }
      } : {},
      var.loki_deployment_mode == "single-binary" ? {
        # Single binary mode: all-in-one deployment (suitable for local/dev)
        loki = {
          storage = {
            type = "filesystem"
            filesystem = {
              chunksDirectory = "/loki/chunks"
              rulesDirectory  = "/loki/rules"
            }
          }
        }
        singleBinary = {
          replicas = 1
        }
        # Disable scalable mode components
        backend = {
          replicas = 0
        }
        read = {
          replicas = 0
        }
        write = {
          replicas = 0
        }
        } : {
        # Scalable mode: separate components for production (requires object storage)
        loki = {
          storage = var.loki_object_storage != null ? merge(
            {
              type = var.loki_object_storage.type
              bucketNames = {
                chunks = var.loki_object_storage.bucket
                ruler  = var.loki_object_storage.bucket
              }
            },
            var.loki_object_storage.type == "s3" ? {
              s3 = merge(
                var.loki_object_storage.region != null ? { region = var.loki_object_storage.region } : {},
                var.loki_object_storage.endpoint != null ? { endpoint = var.loki_object_storage.endpoint } : {},
                var.loki_object_storage.force_path_style != null ? { s3ForcePathStyle = var.loki_object_storage.force_path_style } : {}
              )
            } : {},
            var.loki_object_storage.type == "gcs" ? { gcs = {} } : {},
            var.loki_object_storage.type == "azure" ? { azure = {} } : {}
            ) : {
            # Fallback to filesystem if object storage not configured
            type = "filesystem"
            filesystem = {
              chunksDirectory = "/loki/chunks"
              rulesDirectory  = "/loki/rules"
            }
          }
        }
        # Disable single binary mode
        singleBinary = {
          replicas = 0
        }
        # Enable scalable mode components (can be configured per environment)
        backend = {
          replicas = 1
        }
        read = {
          replicas = 2
        }
        write = {
          replicas = 2
        }
      }
    ))
  ]

  # Dependencies: namespace is always required, secret is conditionally created
  # Terraform will handle the dependency automatically through resource references in values
  depends_on = [kubernetes_namespace.monitoring]
}

# Promtail for log collection
resource "helm_release" "promtail" {
  count = var.enable_promtail && var.enable_loki ? 1 : 0

  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  version    = "6.15.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    yamlencode({
      config = {
        clients = [{
          url = "http://loki:3100/loki/api/v1/push"
        }]
      }
    })
  ]

  depends_on = [kubernetes_namespace.monitoring, helm_release.loki]
}

