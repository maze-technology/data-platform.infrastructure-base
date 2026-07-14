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

# Local value to determine if S3 credentials secret is needed
locals {
  needs_loki_s3_credentials = var.loki_deployment_mode == "scalable" && var.loki_object_storage != null

  ingress_whitelist = "${var.vpn_cidr},127.0.0.1/32,10.0.0.0/8"

  ingress_annotations = var.restrict_to_vpn ? {
    "nginx.ingress.kubernetes.io/whitelist-source-range" = local.ingress_whitelist
  } : {}

  grafana_oauth_ini = var.oidc != null ? {
    auth = {
      disable_login_form = false
    }
    "auth.generic_oauth" = {
      enabled             = true
      name                = "Keycloak"
      allow_sign_up       = true
      client_id           = var.oidc.client_id
      client_secret       = var.oidc.client_secret
      scopes              = "openid profile email groups"
      auth_url            = "${var.oidc.issuer_url}/protocol/openid-connect/auth"
      token_url           = "${var.oidc.issuer_url}/protocol/openid-connect/token"
      api_url             = "${var.oidc.issuer_url}/protocol/openid-connect/userinfo"
      role_attribute_path = "contains(groups[*], 'admins') && 'Admin' || contains(groups[*], 'developers') && 'Editor' || 'Viewer'"
    }
  } : {}
}

# Prometheus Operator (includes Prometheus, Alertmanager, and ServiceMonitor CRDs)
resource "helm_release" "prometheus_operator" {

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.helm_chart_version_prometheus_operator
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  timeout = 600 # 10 minutes

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                accessModes      = ["ReadWriteOnce"]
                storageClassName = var.storage_class != "" ? var.storage_class : null
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
          retention = var.prometheus_retention
        }
      }
      grafana = merge(
        {
          enabled       = true    # Always enabled for unified observability visualization
          adminPassword = "admin" # Should be overridden via secrets in production
          persistence = {
            enabled          = true
            size             = var.grafana_storage_size
            storageClassName = var.storage_class != "" ? var.storage_class : null
          }
          resources = {
            requests = var.resource_requests.grafana
            limits   = var.resource_limits.grafana
          }
          ingress = {
            enabled          = var.grafana_ingress_enabled
            ingressClassName = var.grafana_ingress_class
            hosts            = var.grafana_ingress_enabled ? [var.grafana_ingress_host] : []
            annotations = merge(
              var.grafana_enable_tls ? {
                "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
              } : {},
              local.ingress_annotations
            )
            tls = var.grafana_enable_tls && var.grafana_ingress_enabled ? [{
              hosts      = [var.grafana_ingress_host]
              secretName = "grafana-tls"
            }] : []
          }
          # Enable correlation between metrics, logs, and traces
          ini = merge(
            {
              feature_toggles = {
                enable = "correlations"
              }
            },
            local.grafana_oauth_ini
          )
          # Build additional data sources array
          additionalDataSources = concat(
            # Loki data source (required for unified observability)
            [
              {
                name      = "Loki"
                type      = "loki"
                uid       = "loki"
                url       = "http://loki:3100"
                access    = "proxy"
                isDefault = false
                jsonData = {
                  maxLines = 1000
                }
              }
            ],
            # Tempo data source (required for unified observability)
            [
              {
                name      = "Tempo"
                type      = "tempo"
                uid       = "tempo"
                url       = "http://tempo:3200"
                access    = "proxy"
                isDefault = false
                jsonData = merge(
                  {
                    httpMethod = "GET"
                    # Enable trace-to-logs correlation
                    nodeGraph = {
                      enabled = true
                    }
                    # Enable trace-to-metrics correlation
                    search = {
                      hide = false
                    }
                  },
                  # Enable service map using Prometheus as backend
                  {
                    serviceMap = {
                      datasourceUid = "prometheus"
                    }
                  },
                  # Enable Loki correlation (Loki is always enabled)
                  {
                    tracesToLogs = {
                      datasourceUid = "loki"
                      tags = [
                        {
                          key   = "service.name"
                          value = "service"
                        },
                        {
                          key   = "job"
                          value = "service"
                        }
                      ]
                      mappedTags = [
                        {
                          key   = "service.name"
                          value = "service"
                        }
                      ]
                      mapTagNamesEnabled = false
                      spanStartTimeShift = "1h"
                      spanEndTimeShift   = "1h"
                      filterByTraceID    = false
                      filterBySpanID     = false
                    }
                  },
                  # Enable Prometheus correlation
                  {
                    tracesToMetrics = {
                      datasourceUid = "prometheus"
                      tags = [
                        {
                          key   = "service.name"
                          value = "service"
                        }
                      ]
                      queries = [
                        {
                          name   = "Sample query"
                          query  = "sum(rate(tempo_spanmetrics_latency_bucket{$$__tags}[5m]))"
                          legend = "{{ `{{service.name}}` }}"
                          refId  = "A"
                        }
                      ]
                    }
                  }
                )
              }
            ]
          )
        }
      )
    })
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

# Kubernetes secret for Loki S3 credentials (when using object storage with custom credentials)
resource "kubernetes_secret" "loki_s3_credentials" {
  count = local.needs_loki_s3_credentials ? 1 : 0

  metadata {
    name      = "loki-s3-credentials"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    access-key-id     = base64encode(try(var.loki_object_storage.access_key, "") != null ? try(var.loki_object_storage.access_key, "") : "")
    secret-access-key = base64encode(try(var.loki_object_storage.secret_key, "") != null ? try(var.loki_object_storage.secret_key, "") : "")
  }

  depends_on = [kubernetes_namespace.monitoring]
}

# Loki for log aggregation (required for unified observability)
resource "helm_release" "loki" {

  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.helm_chart_version_loki
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    yamlencode(merge(
      {
        loki = {
          useTestSchema = true
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
      local.needs_loki_s3_credentials ? {
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
          useTestSchema = true
          storage = {
            type = "filesystem"
            bucketNames = {
              chunks = ""
              ruler  = ""
            }
            s3    = {}
            gcs   = {}
            azure = {}
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
          useTestSchema = var.loki_deployment_mode != "scalable"
          storage = var.loki_object_storage != null ? merge(
            {
              type = var.loki_object_storage.type
              bucketNames = {
                chunks = var.loki_object_storage.bucket
                ruler  = var.loki_object_storage.bucket
              }
              s3 = var.loki_object_storage.type == "s3" ? merge(
                var.loki_object_storage.region != null ? { region = var.loki_object_storage.region } : {},
                var.loki_object_storage.endpoint != null ? { endpoint = var.loki_object_storage.endpoint } : {},
                var.loki_object_storage.force_path_style != null ? { s3ForcePathStyle = var.loki_object_storage.force_path_style } : {}
              ) : {}
              gcs   = var.loki_object_storage.type == "gcs" ? {} : {}
              azure = var.loki_object_storage.type == "azure" ? {} : {}
              filesystem = {
                chunksDirectory = ""
                rulesDirectory  = ""
              }
            }
            ) : {
            # Fallback to filesystem if object storage not configured
            type = "filesystem"
            bucketNames = {
              chunks = ""
              ruler  = ""
            }
            s3    = {}
            gcs   = {}
            azure = {}
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

# Promtail for log collection (optional — disabled on kind)
resource "helm_release" "promtail" {
  count = var.enable_promtail ? 1 : 0

  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  version    = var.helm_chart_version_promtail
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

# Tempo for distributed tracing (required for unified observability)
resource "helm_release" "tempo" {

  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = var.helm_chart_version_tempo
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    yamlencode({
      tempo = {
        resources = {
          requests = var.resource_requests.tempo
          limits   = var.resource_limits.tempo
        }
      }
      persistence = {
        enabled          = true
        size             = var.tempo_storage_size
        storageClassName = var.storage_class != "" ? var.storage_class : null
      }
    })
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

# OpenTelemetry Collector for unified telemetry collection
resource "helm_release" "opentelemetry_collector" {

  name       = "opentelemetry-collector"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = var.helm_chart_version_opentelemetry_collector
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    yamlencode({
      mode         = "deployment"
      replicaCount = 2

      resources = {
        requests = var.resource_requests.opentelemetry_collector
        limits   = var.resource_limits.opentelemetry_collector
      }

      config = merge(
        {
          receivers = {
            otlp = {
              protocols = {
                grpc = {
                  endpoint = "0.0.0.0:4317"
                }
                http = {
                  endpoint = "0.0.0.0:4318"
                }
              }
            }
          }

          processors = {
            batch = {
              timeout         = "10s"
              send_batch_size = 1024
            }
            memory_limiter = {
              check_interval         = "1s"
              limit_percentage       = 75
              spike_limit_percentage = 20
            }
            # Filtering processor - example: drop health check traces
            filter = {
              traces = {
                span = [
                  {
                    name   = "health"
                    action = "drop"
                  }
                ]
              }
            }
            # Sampling processor - probabilistic sampling
            probabilistic_sampler = {
              sampling_percentage = 10.0
              hash_seed           = 22
            }
            # Resource processor for enrichment
            resource = {
              attributes = [
                {
                  key    = "environment"
                  value  = var.environment
                  action = "upsert"
                },
                {
                  key    = "cluster"
                  value  = var.cluster_name
                  action = "upsert"
                }
              ]
            }
          }

          exporters = {
            # Prometheus exporter - metrics will be scraped by Prometheus
            prometheus = {
              endpoint = "0.0.0.0:8889"
              const_labels = {
                cluster     = var.cluster_name
                environment = var.environment
              }
            }
            # Loki exporter for logs - required for unified observability
            loki = {
              endpoint = "http://loki:3100/loki/api/v1/push"
              labels = {
                resource = {
                  attributes = {
                    "service.name"      = "service_name"
                    "service.namespace" = "service_namespace"
                  }
                }
              }
            }
            # Tempo exporter for traces - required for unified observability
            "otlp/tempo" = {
              endpoint = "tempo:4317"
              tls = {
                insecure = true
              }
            }
          }

          service = {
            pipelines = {
              # Metrics pipeline - Prometheus exporter
              metrics = {
                receivers  = ["otlp"]
                processors = ["memory_limiter", "resource", "batch"]
                exporters  = ["prometheus"]
              }
              # Logs pipeline - Loki exporter (required for unified observability)
              logs = {
                receivers  = ["otlp"]
                processors = ["memory_limiter", "resource", "batch"]
                exporters  = ["loki"]
              }
              # Traces pipeline - Tempo exporter (required for unified observability)
              traces = {
                receivers  = ["otlp"]
                processors = ["memory_limiter", "probabilistic_sampler", "filter", "resource", "batch"]
                exporters  = ["otlp/tempo"]
              }
            }
          }
        }
      )

      # ServiceMonitor for Prometheus to scrape metrics
      serviceMonitor = {
        enabled        = true
        interval       = "30s"
        scrapeEndpoint = "/metrics"
      }
    })
  ]

  # OpenTelemetry Collector requires Loki and Tempo for unified observability
  depends_on = [
    kubernetes_namespace.monitoring,
    helm_release.tempo,
    helm_release.loki
  ]
}

