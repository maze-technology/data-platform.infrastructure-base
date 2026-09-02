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
  access_url          = var.enable_tls ? "https://${var.hostname}" : "http://${var.hostname}"
  ingress_whitelist   = "${var.vpn_cidr},127.0.0.1/32,10.0.0.0/8"
  postgresql_host     = module.coder_postgresql.rw_host
  postgresql_password = random_password.postgresql.result
  pg_connection_url   = "postgres://${var.postgresql_username}:${local.postgresql_password}@${local.postgresql_host}:5432/${var.postgresql_database}?sslmode=disable"

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

  oidc_env = concat(
    [
      {
        name  = "CODER_OIDC_ISSUER_URL"
        value = var.oidc.issuer_url
      },
      {
        name  = "CODER_OIDC_CLIENT_ID"
        value = var.oidc.client_id
      },
      {
        name  = "CODER_OIDC_CLIENT_SECRET"
        value = var.oidc.client_secret
      },
      {
        name  = "CODER_OIDC_SIGN_IN_TEXT"
        value = "Sign in with SSO"
      },
      {
        name  = "CODER_OIDC_ALLOW_SIGNUPS"
        value = "true"
      },
      {
        name  = "CODER_OIDC_GROUP_FIELD"
        value = "groups"
      },
      {
        name  = "CODER_OIDC_ALLOWED_GROUPS"
        value = join(",", var.oidc_allowed_groups)
      },
      {
        name  = "CODER_OIDC_USERNAME_FIELD"
        value = "preferred_username"
      },
    ],
    var.oidc_email_domain != "" ? [{
      name  = "CODER_OIDC_EMAIL_DOMAIN"
      value = var.oidc_email_domain
    }] : [],
    var.disable_password_auth ? [{
      name  = "CODER_DISABLE_PASSWORD_AUTH"
      value = "true"
    }] : [],
  )
}

resource "kubernetes_namespace" "coder" {
  metadata {
    name = var.namespace
    labels = {
      name                        = var.namespace
      environment                 = var.environment
      managed-by                  = "opentofu"
      (var.backup_label_key)      = "true"
      "app.kubernetes.io/part-of" = "coder"
    }
  }
}

resource "kubernetes_namespace" "workspaces" {
  metadata {
    name = var.workspace_namespace
    labels = {
      name                        = var.workspace_namespace
      environment                 = var.environment
      managed-by                  = "opentofu"
      (var.backup_label_key)      = "true"
      "app.kubernetes.io/part-of" = "coder"
    }
  }
}

resource "random_password" "postgresql" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "postgresql" {
  metadata {
    name      = "coder-postgresql-password"
    namespace = kubernetes_namespace.coder.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    password = local.postgresql_password
  }

  type = "Opaque"
}

resource "kubernetes_secret" "db_url" {
  metadata {
    name      = "coder-db-url"
    namespace = kubernetes_namespace.coder.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    url = local.pg_connection_url
  }

  type = "Opaque"
}

module "coder_postgresql" {
  source = "../cnpg-cluster"

  environment    = var.environment
  namespace      = kubernetes_namespace.coder.metadata[0].name
  cluster_name   = "coder-pg"
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

  depends_on = [kubernetes_namespace.coder]
}

resource "helm_release" "coder" {
  name       = "coder"
  repository = "https://helm.coder.com/v2"
  chart      = "coder"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.coder.metadata[0].name

  timeout = 900
  wait    = false

  values = [
    yamlencode({
      coder = {
        envUseClusterAccessURL = false
        env = concat(
          [
            {
              name  = "CODER_ACCESS_URL"
              value = local.access_url
            },
            {
              name = "CODER_PG_CONNECTION_URL"
              valueFrom = {
                secretKeyRef = {
                  name = kubernetes_secret.db_url.metadata[0].name
                  key  = "url"
                }
              }
            },
            {
              name  = "CODER_OAUTH2_GITHUB_DEFAULT_PROVIDER_ENABLE"
              value = "false"
            },
            {
              name  = "CODER_TELEMETRY_ENABLE"
              value = "false"
            },
            {
              name  = "CODER_UPDATE_CHECK"
              value = "false"
            },
            {
              name  = "CODER_PROMETHEUS_ENABLE"
              value = "true"
            },
          ],
          local.oidc_env,
        )

        service = {
          enable          = true
          type            = "ClusterIP"
          sessionAffinity = "None"
        }

        ingress = {
          enable      = true
          className   = var.ingress_class
          host        = var.hostname
          annotations = local.ingress_annotations
          tls = {
            enable     = var.enable_tls
            secretName = "coder-tls"
          }
        }

        serviceAccount = {
          workspacePerms    = true
          enableDeployments = true
          workspaceNamespaces = [
            {
              name              = var.workspace_namespace
              workspacePerms    = true
              enableDeployments = true
            },
          ]
        }

        resources = var.resources
      }
    }),
  ]

  depends_on = [
    kubernetes_namespace.coder,
    kubernetes_namespace.workspaces,
    kubernetes_secret.db_url,
    module.coder_postgresql,
  ]
}
