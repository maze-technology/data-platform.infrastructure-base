terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    random = {
      source = "hashicorp/random"
    }
    null = {
      source = "hashicorp/null"
    }
  }
}

locals {
  access_url          = var.enable_tls ? "https://${var.hostname}" : "http://${var.hostname}"
  ingress_whitelist   = "${var.vpn_cidr},127.0.0.1/32,10.0.0.0/8"
  postgresql_host     = module.paperclip_postgresql.rw_host
  postgresql_password = random_password.postgresql.result
  pg_connection_url   = "postgres://${var.postgresql_username}:${local.postgresql_password}@${local.postgresql_host}:5432/${var.postgresql_database}?sslmode=disable"

  labels = {
    app                         = "paperclip"
    environment                 = var.environment
    managed-by                  = "opentofu"
    "app.kubernetes.io/name"    = "paperclip"
    "app.kubernetes.io/part-of" = "paperclip"
  }

  # Seeded once into PAPERCLIP_HOME; DATABASE_URL + deployment env vars override at runtime.
  # Do not put credentials in this ConfigMap — only non-secret defaults.
  seed_config = {
    database = {
      mode = "postgres"
      backup = {
        enabled         = false
        intervalMinutes = 60
        retentionDays   = 7
        dir             = "/paperclip/instances/default/data/backups"
      }
    }
    logging = {
      mode   = "file"
      logDir = "/paperclip/instances/default/logs"
    }
    server = {
      deploymentMode   = "authenticated"
      exposure         = "private"
      bind             = "custom"
      customBindHost   = "0.0.0.0"
      host             = "0.0.0.0"
      port             = 3100
      allowedHostnames = [var.hostname]
      serveUi          = true
    }
    auth = {
      baseUrlMode   = "explicit"
      publicBaseUrl = local.access_url
      disableSignUp = false
    }
    storage = {
      provider = "s3"
      localDisk = {
        baseDir = "/paperclip/instances/default/data/storage"
      }
      s3 = {
        bucket         = var.object_storage.bucket
        region         = var.object_storage.region
        endpoint       = var.object_storage.endpoint
        prefix         = "paperclip/"
        forcePathStyle = var.object_storage.force_path_style
      }
    }
    secrets = {
      provider   = "local_encrypted"
      strictMode = false
      localEncrypted = {
        keyFilePath = "/paperclip/instances/default/secrets/master.key"
      }
    }
    telemetry = {
      enabled = false
    }
    updates = {
      checkEnabled = false
    }
  }

  ingress_annotations = merge(
    var.restrict_to_vpn ? {
      "nginx.ingress.kubernetes.io/whitelist-source-range" = local.ingress_whitelist
    } : {},
    var.enable_tls ? {
      "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"
      "nginx.ingress.kubernetes.io/ssl-redirect"       = "true"
    } : {},
    {
      # Agent runner / UI websockets
      "nginx.ingress.kubernetes.io/proxy-read-timeout" = "3600"
      "nginx.ingress.kubernetes.io/proxy-send-timeout" = "3600"
      "nginx.ingress.kubernetes.io/proxy-body-size"    = "64m"
    },
  )
}

resource "kubernetes_namespace" "paperclip" {
  metadata {
    name = var.namespace
    labels = merge(local.labels, {
      name                   = var.namespace
      (var.backup_label_key) = "true"
    })
  }
}

resource "random_password" "postgresql" {
  length  = 32
  special = false
}

resource "random_password" "better_auth_secret" {
  length  = 64
  special = false
}

resource "random_password" "tool_action_signing_secret" {
  length  = 64
  special = false
}

# 32 raw bytes as base64 for PAPERCLIP_SECRETS_MASTER_KEY
resource "random_id" "secrets_master_key" {
  byte_length = 32
}

resource "kubernetes_secret" "postgresql" {
  metadata {
    name      = "paperclip-postgresql-password"
    namespace = kubernetes_namespace.paperclip.metadata[0].name
    labels    = local.labels
  }

  data = {
    password = local.postgresql_password
  }

  type = "Opaque"
}

resource "kubernetes_secret" "app" {
  metadata {
    name      = "paperclip-app"
    namespace = kubernetes_namespace.paperclip.metadata[0].name
    labels    = local.labels
  }

  data = {
    DATABASE_URL                         = local.pg_connection_url
    BETTER_AUTH_SECRET                   = random_password.better_auth_secret.result
    PAPERCLIP_TOOL_ACTION_SIGNING_SECRET = random_password.tool_action_signing_secret.result
    PAPERCLIP_SECRETS_MASTER_KEY         = random_id.secrets_master_key.b64_std
    AWS_ACCESS_KEY_ID                    = var.object_storage.access_key
    AWS_SECRET_ACCESS_KEY                = var.object_storage.secret_key
  }

  type = "Opaque"
}

resource "kubernetes_config_map" "seed_config" {
  metadata {
    name      = "paperclip-seed-config"
    namespace = kubernetes_namespace.paperclip.metadata[0].name
    labels    = local.labels
  }

  data = {
    "config.json" = jsonencode(local.seed_config)
  }
}

module "paperclip_postgresql" {
  source = "../cnpg-cluster"

  environment    = var.environment
  namespace      = kubernetes_namespace.paperclip.metadata[0].name
  cluster_name   = "paperclip-pg"
  database       = var.postgresql_database
  username       = var.postgresql_username
  password       = local.postgresql_password
  storage_size   = var.postgresql_storage_size
  storage_class  = var.storage_class
  operator_ready = var.cnpg_operator_ready

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

  depends_on = [kubernetes_namespace.paperclip]
}

resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "paperclip-home"
    namespace = kubernetes_namespace.paperclip.metadata[0].name
    labels    = local.labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class != "" ? var.storage_class : null
    resources {
      requests = {
        storage = var.home_storage_size
      }
    }
  }

  wait_until_bound = false

  depends_on = [kubernetes_namespace.paperclip]
}

resource "kubernetes_service_account" "paperclip" {
  metadata {
    name      = "paperclip"
    namespace = kubernetes_namespace.paperclip.metadata[0].name
    labels    = local.labels
  }
}

# Permissions for @paperclipai/plugin-kubernetes (tenant namespaces + sandbox-cr / jobs).
resource "kubernetes_cluster_role" "paperclip" {
  metadata {
    name   = "paperclip-sandbox-orchestrator"
    labels = local.labels
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = [""]
    resources = [
      "serviceaccounts",
      "secrets",
      "pods",
      "pods/log",
      "pods/exec",
      "resourcequotas",
      "limitranges",
      "events",
      "persistentvolumeclaims",
      "configmaps",
    ]
    verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["roles", "rolebindings"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["networkpolicies"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["agents.x-k8s.io"]
    resources  = ["sandboxes"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_cluster_role_binding" "paperclip" {
  metadata {
    name   = "paperclip-sandbox-orchestrator"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.paperclip.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.paperclip.metadata[0].name
    namespace = kubernetes_namespace.paperclip.metadata[0].name
  }
}

resource "kubernetes_deployment" "paperclip" {
  metadata {
    name      = "paperclip"
    namespace = kubernetes_namespace.paperclip.metadata[0].name
    labels    = local.labels
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        app = "paperclip"
      }
    }

    template {
      metadata {
        labels = local.labels
        annotations = {
          "checksum/seed-config" = sha256(jsonencode(local.seed_config))
          "checksum/app-secret"  = sha256("${random_password.better_auth_secret.result}:${random_id.secrets_master_key.b64_std}:${var.object_storage.bucket}")
        }
      }

      spec {
        service_account_name = kubernetes_service_account.paperclip.metadata[0].name

        security_context {
          fs_group               = 1000
          run_as_user            = 1000
          run_as_group           = 1000
          run_as_non_root        = true
          fs_group_change_policy = "OnRootMismatch"
        }

        init_container {
          name    = "seed-home"
          image   = "busybox:1.37"
          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            set -euo pipefail
            mkdir -p /paperclip/instances/default/secrets \
                     /paperclip/instances/default/data/storage \
                     /paperclip/instances/default/data/backups \
                     /paperclip/instances/default/logs
            if [ ! -f /paperclip/instances/default/config.json ]; then
              cp /seed/config.json /paperclip/instances/default/config.json
              echo "seeded paperclip config.json"
            else
              echo "paperclip config.json already present; leaving unchanged"
            fi
            chown -R 1000:1000 /paperclip
          EOT
          ]

          security_context {
            run_as_user     = 0
            run_as_group    = 0
            run_as_non_root = false
          }

          volume_mount {
            name       = "home"
            mount_path = "/paperclip"
          }

          volume_mount {
            name       = "seed-config"
            mount_path = "/seed"
            read_only  = true
          }
        }

        init_container {
          name    = "install-k8s-plugin"
          image   = "node:24-bookworm-slim"
          command = ["/bin/bash", "-c"]
          args = [<<-EOT
            set -euo pipefail
            PLUGIN_ROOT="/plugins/sandbox-providers/kubernetes"
            mkdir -p "$PLUGIN_ROOT"
            cd /tmp
            npm pack "@paperclipai/plugin-kubernetes@${var.plugin_version}" --silent
            tar -xzf paperclipai-plugin-kubernetes-*.tgz
            rm -rf "$PLUGIN_ROOT"/*
            cp -a package/. "$PLUGIN_ROOT/"
            cd "$PLUGIN_ROOT"
            npm install --omit=dev --no-fund --no-audit
            echo "staged @paperclipai/plugin-kubernetes@${var.plugin_version}"
          EOT
          ]

          volume_mount {
            name       = "plugins"
            mount_path = "/plugins"
          }
        }

        container {
          name  = "paperclip"
          image = var.image

          port {
            name           = "http"
            container_port = 3100
            protocol       = "TCP"
          }

          env {
            name  = "NODE_ENV"
            value = "production"
          }
          env {
            name  = "HOST"
            value = "0.0.0.0"
          }
          env {
            name  = "PORT"
            value = "3100"
          }
          env {
            name  = "SERVE_UI"
            value = "true"
          }
          env {
            name  = "PAPERCLIP_HOME"
            value = "/paperclip"
          }
          env {
            name  = "PAPERCLIP_INSTANCE_ID"
            value = "default"
          }
          env {
            name  = "PAPERCLIP_CONFIG"
            value = "/paperclip/instances/default/config.json"
          }
          env {
            name  = "PAPERCLIP_DEPLOYMENT_MODE"
            value = "authenticated"
          }
          env {
            name  = "PAPERCLIP_DEPLOYMENT_EXPOSURE"
            value = "private"
          }
          env {
            name  = "PAPERCLIP_BIND"
            value = "custom"
          }
          env {
            name  = "PAPERCLIP_BIND_HOST"
            value = "0.0.0.0"
          }
          env {
            name  = "PAPERCLIP_PUBLIC_URL"
            value = local.access_url
          }
          env {
            name  = "PAPERCLIP_API_URL"
            value = local.access_url
          }
          env {
            name  = "PAPERCLIP_MIGRATION_AUTO_APPLY"
            value = "true"
          }
          env {
            name  = "PAPERCLIP_BUNDLED_PLUGIN_ROOT"
            value = "/plugins"
          }
          env {
            name  = "AWS_REGION"
            value = var.object_storage.region
          }
          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "DATABASE_URL"
              }
            }
          }
          env {
            name = "BETTER_AUTH_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "BETTER_AUTH_SECRET"
              }
            }
          }
          env {
            name = "PAPERCLIP_TOOL_ACTION_SIGNING_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "PAPERCLIP_TOOL_ACTION_SIGNING_SECRET"
              }
            }
          }
          env {
            name = "PAPERCLIP_SECRETS_MASTER_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "PAPERCLIP_SECRETS_MASTER_KEY"
              }
            }
          }
          env {
            name = "AWS_ACCESS_KEY_ID"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "AWS_ACCESS_KEY_ID"
              }
            }
          }
          env {
            name = "AWS_SECRET_ACCESS_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "AWS_SECRET_ACCESS_KEY"
              }
            }
          }

          volume_mount {
            name       = "home"
            mount_path = "/paperclip"
          }

          volume_mount {
            name       = "plugins"
            mount_path = "/plugins"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = var.resources.requests.cpu
              memory = var.resources.requests.memory
            }
            limits = {
              cpu    = var.resources.limits.cpu
              memory = var.resources.limits.memory
            }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = "http"
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 6
          }

          liveness_probe {
            http_get {
              path = "/"
              port = "http"
            }
            initial_delay_seconds = 60
            period_seconds        = 20
            timeout_seconds       = 5
            failure_threshold     = 6
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.home.metadata[0].name
          }
        }

        volume {
          name = "plugins"
          empty_dir {}
        }

        volume {
          name = "seed-config"
          config_map {
            name = kubernetes_config_map.seed_config.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    module.paperclip_postgresql,
    kubernetes_secret.app,
    kubernetes_cluster_role_binding.paperclip,
    null_resource.agent_sandbox,
  ]
}

resource "kubernetes_service" "paperclip" {
  metadata {
    name      = "paperclip"
    namespace = kubernetes_namespace.paperclip.metadata[0].name
    labels    = local.labels
  }

  spec {
    type = "ClusterIP"
    selector = {
      app = "paperclip"
    }
    port {
      name        = "http"
      port        = 80
      target_port = "http"
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_manifest" "tls_certificate" {
  count = var.enable_tls ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "paperclip-tls"
      namespace = kubernetes_namespace.paperclip.metadata[0].name
      labels    = local.labels
    }
    spec = {
      secretName = "paperclip-tls"
      dnsNames   = [var.hostname]
      issuerRef = {
        name  = var.tls_cluster_issuer
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
    }
  }
}

resource "kubernetes_ingress_v1" "paperclip" {
  metadata {
    name        = "paperclip"
    namespace   = kubernetes_namespace.paperclip.metadata[0].name
    labels      = local.labels
    annotations = local.ingress_annotations
  }

  spec {
    ingress_class_name = var.ingress_class

    dynamic "tls" {
      for_each = var.enable_tls ? [1] : []
      content {
        hosts       = [var.hostname]
        secret_name = "paperclip-tls"
      }
    }

    rule {
      host = var.hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.paperclip.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_service.paperclip,
    kubernetes_manifest.tls_certificate,
  ]
}
