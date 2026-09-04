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
    null = {
      source = "hashicorp/null"
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

  # Distinct usernames/emails that should be site Owners (OSS substitute for Premium IdP role sync).
  site_owners = distinct([for v in var.site_owners : trimspace(v) if trimspace(v) != ""])
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

# Coder redirects all routes to /setup until at least one user exists; OIDC login
# is only offered on /login after that. Bootstrap a break-glass owner (random password).
resource "random_password" "bootstrap_owner" {
  count   = var.bootstrap_owner != null ? 1 : 0
  length  = 32
  special = false
}

resource "kubernetes_secret" "bootstrap_owner" {
  count = var.bootstrap_owner != null ? 1 : 0

  metadata {
    name      = "coder-bootstrap-owner"
    namespace = kubernetes_namespace.coder.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    username = var.bootstrap_owner.username
    email    = var.bootstrap_owner.email
    password = random_password.bootstrap_owner[0].result
  }

  type = "Opaque"

  depends_on = [helm_release.coder]
}

resource "null_resource" "bootstrap_owner" {
  count = var.bootstrap_owner != null ? 1 : 0

  triggers = {
    username   = var.bootstrap_owner.username
    email      = var.bootstrap_owner.email
    password   = random_password.bootstrap_owner[0].result
    deployment = helm_release.coder.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      for i in $(seq 1 60); do
        kubectl -n ${kubernetes_namespace.coder.metadata[0].name} get deploy/coder >/dev/null 2>&1 && \
          kubectl -n ${kubernetes_namespace.coder.metadata[0].name} wait --for=condition=available deploy/coder --timeout=120s && break
        sleep 5
      done
      kubectl -n ${kubernetes_namespace.coder.metadata[0].name} exec deploy/coder -- \
        coder server create-admin-user \
          --username '${var.bootstrap_owner.username}' \
          --email '${var.bootstrap_owner.email}' \
          --password '${random_password.bootstrap_owner[0].result}' \
        2>&1 | grep -qE 'User created successfully|duplicate key value violates unique constraint' \
        || { echo "bootstrap owner: user may already exist"; exit 0; }
    EOT
  }

  depends_on = [
    helm_release.coder,
    kubernetes_secret.bootstrap_owner,
    module.coder_postgresql,
  ]
}

# Premium IdP role sync is unavailable on unlicensed Coder. Promote Keycloak admins
# (declared via site_owners) to site Owner + organization-admin after they SSO in.
resource "kubernetes_config_map_v1" "site_owner_sync" {
  count = length(local.site_owners) > 0 ? 1 : 0

  metadata {
    name      = "coder-site-owner-sync"
    namespace = kubernetes_namespace.coder.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
      purpose     = "coder-site-owner-sync"
    }
  }

  data = {
    "sync.sql" = <<-SQL
      -- Identifiers are baked by OpenTofu from Keycloak admins (username + email).
      WITH owners(ident) AS (
        VALUES
          ${join(",\n          ", [for o in local.site_owners : "('${replace(o, "'", "''")}')"])}
      ),
      matched AS (
        SELECT u.id
        FROM users u
        JOIN owners o ON u.username = o.ident OR u.email = o.ident
      )
      UPDATE users u
      SET rbac_roles = '{owner}'
      FROM matched m
      WHERE u.id = m.id
        AND u.rbac_roles IS DISTINCT FROM '{owner}'::text[];

      WITH owners(ident) AS (
        VALUES
          ${join(",\n          ", [for o in local.site_owners : "('${replace(o, "'", "''")}')"])}
      ),
      matched AS (
        SELECT u.id
        FROM users u
        JOIN owners o ON u.username = o.ident OR u.email = o.ident
      )
      UPDATE organization_members om
      SET roles = '{organization-admin}'
      FROM matched m
      WHERE om.user_id = m.id
        AND om.roles IS DISTINCT FROM '{organization-admin}'::text[];
    SQL
  }
}

resource "kubernetes_cron_job_v1" "site_owner_sync" {
  count = length(local.site_owners) > 0 ? 1 : 0

  metadata {
    name      = "coder-site-owner-sync"
    namespace = kubernetes_namespace.coder.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
      purpose     = "coder-site-owner-sync"
    }
  }

  spec {
    schedule                      = var.site_owner_sync_schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 120

    job_template {
      metadata {
        labels = {
          app     = "coder-site-owner-sync"
          purpose = "coder-site-owner-sync"
        }
      }

      spec {
        backoff_limit = 1
        template {
          metadata {
            labels = {
              app     = "coder-site-owner-sync"
              purpose = "coder-site-owner-sync"
            }
          }

          spec {
            restart_policy = "OnFailure"

            security_context {
              run_as_non_root = true
              run_as_user     = 999
              fs_group        = 999
              seccomp_profile {
                type = "RuntimeDefault"
              }
            }

            container {
              name    = "sync"
              image   = var.site_owner_sync_image
              command = ["/bin/sh", "-c"]
              args = [
                "echo \"Promoting Coder site owners\"; psql -v ON_ERROR_STOP=1 -f /scripts/sync.sql",
              ]

              env {
                name  = "PGHOST"
                value = local.postgresql_host
              }
              env {
                name  = "PGUSER"
                value = var.postgresql_username
              }
              env {
                name  = "PGDATABASE"
                value = var.postgresql_database
              }
              env {
                name = "PGPASSWORD"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.postgresql.metadata[0].name
                    key  = "password"
                  }
                }
              }

              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }

              security_context {
                allow_privilege_escalation = false
                read_only_root_filesystem  = true
                capabilities {
                  drop = ["ALL"]
                }
              }
            }

            volume {
              name = "scripts"
              config_map {
                name = kubernetes_config_map_v1.site_owner_sync[0].metadata[0].name
                items {
                  key  = "sync.sql"
                  path = "sync.sql"
                }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    module.coder_postgresql,
    helm_release.coder,
  ]
}
