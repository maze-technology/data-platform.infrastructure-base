resource "kubernetes_namespace" "gitlab" {
  metadata {
    name = var.namespace
    labels = {
      name        = var.namespace
      environment = var.environment
      managed-by  = "opentofu"
    }
  }
}

locals {
  # gitlab.local → base domain "local"; gitlab.prod.maze.tech → "prod.maze.tech"
  domain_parts    = split(".", var.gitlab_domain)
  base_domain     = length(local.domain_parts) > 1 ? join(".", slice(local.domain_parts, 1, length(local.domain_parts))) : var.gitlab_domain
  registry_domain = var.registry_domain != "" ? var.registry_domain : "registry.${local.base_domain}"

  # VPN-only access: restrict ingress to WireGuard subnet (+ localhost for port-forward debugging)
  ingress_whitelist = "${var.vpn_cidr},127.0.0.1/32,10.0.0.0/8"

  kas_hostname = "kas.${local.base_domain}"

  gitlab_tls_certs = var.enable_tls ? {
    "gitlab-tls"   = [var.gitlab_domain]
    "registry-tls" = [local.registry_domain]
    "kas-tls"      = [local.kas_hostname]
  } : {}

  object_storage_connection = yamlencode({
    provider              = "AWS"
    region                = var.object_storage.region
    endpoint              = var.object_storage.endpoint
    path_style            = var.object_storage.force_path_style
    aws_access_key_id     = var.object_storage.access_key
    aws_secret_access_key = var.object_storage.secret_key
    aws_signature_version = 4
  })

  registry_storage_config = yamlencode({
    s3 = {
      bucket         = var.object_storage.bucket
      region         = var.object_storage.region
      regionendpoint = var.object_storage.endpoint
      accesskey      = var.object_storage.access_key
      secretkey      = var.object_storage.secret_key
      v4auth         = true
      pathstyle      = var.object_storage.force_path_style
    }
  })

  s3cmd_config = <<-EOT
    [default]
    access_key = ${var.object_storage.access_key}
    secret_key = ${var.object_storage.secret_key}
    host_base = ${replace(var.object_storage.endpoint, "https://", "")}
    host_bucket = ${replace(var.object_storage.endpoint, "https://", "")}/${var.object_storage.bucket}
    use_https = false
    signature_v2 = false
  EOT

  global_base = {
    edition = "ce"
    hosts = {
      domain     = local.base_domain
      hostSuffix = ""
      https      = var.enable_tls
      gitlab = {
        name = var.gitlab_domain
      }
      registry = {
        name = local.registry_domain
      }
    }
    certificates = length(var.custom_ca_secret_keys) > 0 ? {
      customCAs = [{
        secret = kubernetes_secret.custom_ca[0].metadata[0].name
        keys   = var.custom_ca_secret_keys
      }]
    } : {}
    ingress = {
      configureCertmanager = false
      class                = var.ingress_class
      annotations = {
        "nginx.ingress.kubernetes.io/whitelist-source-range" = local.ingress_whitelist
      }
      tls = var.enable_tls ? {
        enabled    = true
        secretName = "gitlab-tls"
        } : {
        enabled = false
      }
    }
    minio = {
      enabled = false
    }
    appConfig = merge({
      object_store = {
        enabled = true
        connection = {
          secret = kubernetes_secret.gitlab_object_storage.metadata[0].name
          key    = "connection"
        }
      }
      lfs = {
        bucket = var.object_storage.bucket
      }
      artifacts = {
        bucket = var.object_storage.bucket
      }
      uploads = {
        bucket = var.object_storage.bucket
      }
      packages = {
        bucket = var.object_storage.bucket
      }
      dependencyProxy = {
        bucket = var.object_storage.bucket
      }
      terraformState = {
        bucket = var.object_storage.bucket
      }
      }, var.oidc != null ? {
      omniauth = {
        enabled                 = true
        autoSignInWithProvider  = "openid_connect"
        allowSingleSignOn       = ["openid_connect"]
        autoLinkUser            = ["openid_connect"]
        syncProfileFromProvider = ["openid_connect"]
        syncProfileAttributes   = ["email", "name"]
        blockAutoCreatedUsers   = false
        providers = [{
          secret = kubernetes_secret.gitlab_oidc[0].metadata[0].name
          key    = "provider"
        }]
      }
    } : {})
  }
}

resource "random_password" "gitlab_postgresql" {
  count   = var.postgresql_password != "" ? 0 : 1
  length  = 32
  special = false
}

resource "kubernetes_manifest" "tls_certificates" {
  for_each = local.gitlab_tls_certs

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = each.key
      namespace = kubernetes_namespace.gitlab.metadata[0].name
      labels = {
        environment = var.environment
        managed-by  = "opentofu"
      }
    }
    spec = {
      secretName = each.key
      dnsNames   = each.value
      issuerRef = {
        name  = var.tls_cluster_issuer
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
    }
  }
}

resource "random_password" "gitlab_valkey" {
  length  = 32
  special = false
}

locals {
  postgresql_password = var.postgresql_password != "" ? var.postgresql_password : random_password.gitlab_postgresql[0].result
  postgresql_host     = var.use_external_postgresql ? var.postgresql_host : "gitlab-postgresql.${kubernetes_namespace.gitlab.metadata[0].name}.svc.cluster.local"
  valkey_host         = "gitlab-valkey-primary.${kubernetes_namespace.gitlab.metadata[0].name}.svc.cluster.local"

  gitlab_global = merge(local.global_base, {
    psql = {
      host     = local.postgresql_host
      port     = var.postgresql_port
      database = var.postgresql_database
      username = var.postgresql_username
      password = {
        secret = kubernetes_secret.gitlab_postgresql.metadata[0].name
        key    = "password"
      }
    }
    redis = {
      host = local.valkey_host
      port = 6379
      auth = {
        enabled = true
        secret  = kubernetes_secret.gitlab_redis_password.metadata[0].name
        key     = "redis-password"
      }
    }
    gatewayApi = {
      enabled      = true
      installEnvoy = true
      # Prefer Certificates created below (maze-ca / letsencrypt) over ACME HTTP-01.
      configureCertmanager = false
      httpToHttpsRedirect  = var.enable_tls
    }
  })

  gitlab_helm_chart_values = merge(
    {
      installCertmanager = false
      certmanager-issuer = {
        install = false
        email   = "admin@local.invalid"
      }
      nginx-ingress = {
        enabled = false
      }
      prometheus = {
        install = false
      }
      gitlab-runner = {
        install = false
      }
      gitlab = {
        webservice = {
          minReplicas     = var.webservice_min_replicas
          maxReplicas     = var.webservice_max_replicas
          workerProcesses = var.webservice_worker_processes
          resources = {
            requests = {
              cpu    = "250m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "1"
              memory = "2Gi"
            }
          }
        }
        sidekiq = {
          minReplicas = 1
          maxReplicas = 1
          resources = {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }
        }
        "gitlab-shell" = {
          minReplicas = var.shell_min_replicas
          maxReplicas = var.shell_max_replicas
        }
        kas = {
          minReplicas = var.kas_min_replicas
          maxReplicas = var.kas_max_replicas
        }
        gitaly = {
          persistence = {
            enabled = true
            size    = var.gitaly_storage_size
            storage = var.storage_class != "" ? var.storage_class : null
          }
        }
        toolbox = {
          backups = {
            objectStorage = {
              config = {
                secret = kubernetes_secret.gitlab_backup_storage.metadata[0].name
                key    = "config"
              }
            }
          }
        }
      }
      registry = {
        enabled = true
        hpa = {
          minReplicas = var.registry_min_replicas
          maxReplicas = var.registry_max_replicas
        }
        storage = {
          secret = kubernetes_secret.gitlab_registry_storage.metadata[0].name
          key    = "config"
        }
      }
      gatewayApiResources = {
        gateway = {
          protocol = var.enable_tls ? "HTTPS" : "HTTP"
        }
      }
    },
    var.enable_tls ? {} : {
      gatewayApiResources = {
        gateway = {
          protocol = "HTTP"
        }
        envoy = {
          clientTrafficPolicySpec = {
            path = {
              escapedSlashesAction = "KeepUnchanged"
            }
          }
        }
      }
    },
  )
}

resource "kubernetes_secret" "gitlab_object_storage" {
  metadata {
    name      = "gitlab-object-storage"
    namespace = kubernetes_namespace.gitlab.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    connection = local.object_storage_connection
  }

  type = "Opaque"
}

resource "kubernetes_secret" "gitlab_registry_storage" {
  metadata {
    name      = "gitlab-registry-storage"
    namespace = kubernetes_namespace.gitlab.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    config = local.registry_storage_config
  }

  type = "Opaque"
}

resource "kubernetes_secret" "gitlab_backup_storage" {
  metadata {
    name      = "gitlab-object-storage-s3cmd"
    namespace = kubernetes_namespace.gitlab.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    config = local.s3cmd_config
  }

  type = "Opaque"
}

resource "kubernetes_secret" "gitlab_postgresql" {
  metadata {
    name      = "gitlab-postgresql-password"
    namespace = kubernetes_namespace.gitlab.metadata[0].name
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

resource "helm_release" "gitlab_postgresql" {
  count = var.use_external_postgresql ? 0 : 1

  name       = "gitlab-postgresql"
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "postgresql"
  namespace  = kubernetes_namespace.gitlab.metadata[0].name

  values = [
    yamlencode({
      auth = {
        username = var.postgresql_username
        password = local.postgresql_password
        database = var.postgresql_database
      }
      primary = {
        persistence = {
          enabled      = true
          size         = var.postgresql_storage_size
          storageClass = var.storage_class != "" ? var.storage_class : null
        }
        resources = {
          requests = {
            cpu    = "250m"
            memory = "512Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "1Gi"
          }
        }
      }
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/postgresql"
      }
    })
  ]

  depends_on = [kubernetes_namespace.gitlab]
}

resource "kubernetes_secret" "gitlab_redis_password" {
  metadata {
    name      = "gitlab-redis-password"
    namespace = kubernetes_namespace.gitlab.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    "redis-password" = random_password.gitlab_valkey.result
  }

  type = "Opaque"
}

resource "helm_release" "gitlab_valkey" {
  name       = "gitlab-valkey"
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "valkey"
  namespace  = kubernetes_namespace.gitlab.metadata[0].name

  values = [
    yamlencode({
      auth = {
        password = random_password.gitlab_valkey.result
      }
      architecture = "standalone"
      primary = {
        persistence = {
          enabled      = true
          size         = var.valkey_storage_size
          storageClass = var.storage_class != "" ? var.storage_class : null
        }
      }
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/valkey"
      }
    })
  ]

  depends_on = [kubernetes_namespace.gitlab]
}

resource "kubernetes_secret" "custom_ca" {
  count = var.custom_ca_pem != "" ? 1 : 0

  metadata {
    name      = "maze-ca"
    namespace = kubernetes_namespace.gitlab.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    for key in var.custom_ca_secret_keys : key => var.custom_ca_pem
  }

  type = "Opaque"
}

resource "kubernetes_secret" "gitlab_oidc" {
  count = var.oidc != null ? 1 : 0

  metadata {
    name      = "gitlab-oidc-provider"
    namespace = kubernetes_namespace.gitlab.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    provider = <<-EOT
      name: openid_connect
      label: ${var.oidc.label}
      args:
        name: openid_connect
        scope:
          - openid
          - profile
          - email
          - groups
        response_type: code
        issuer: ${var.oidc.issuer_url}
        discovery: true
        client_auth_method: query
        uid_field: preferred_username
        pkce: true
        client_options:
          identifier: ${var.oidc.client_id}
          secret: ${var.oidc.client_secret}
          redirect_uri: ${var.oidc.redirect_uri}
          gitlab:
            groups_attribute: groups
            required_groups:
              - admins
              - engineers
            admin_groups:
              - admins
    EOT
  }

  type = "Opaque"
}

# Enforce SSO-only web login and ensure the platform admin is a GitLab administrator.
# ApplicationSetting lives in the DB (not helm values), so this runs via toolbox.
resource "null_resource" "gitlab_sso_only" {
  count = var.oidc != null ? 1 : 0

  triggers = {
    namespace   = kubernetes_namespace.gitlab.metadata[0].name
    admin_user  = var.sso_admin_username
    admin_email = var.sso_admin_email
    oidc_issuer = var.oidc.issuer_url
    harden_v1   = "signup-off-webide-fallback-off"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      NS='${kubernetes_namespace.gitlab.metadata[0].name}'
      kubectl -n "$NS" wait --for=condition=available deploy/gitlab-webservice-default --timeout=900s
      kubectl -n "$NS" wait --for=condition=ready pod -l app=toolbox --timeout=300s
      for i in $(seq 1 30); do
        POD="$(kubectl -n "$NS" get pod -l app=toolbox --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        if [ -z "$POD" ]; then
          echo "gitlab_sso_only: no running toolbox pod yet (attempt $i/30)"
          sleep 20
          continue
        fi
        if kubectl -n "$NS" exec "$POD" -- gitlab-rails runner "$(cat <<'RUBY'
# SSO-only + instance hardening (ApplicationSetting is DB-backed, not helm).
# Keycloak username "admin" is reserved in GitLab — link SSO via root email.
ApplicationSetting.current.update!(
  password_authentication_enabled_for_web: false,
  signup_enabled: false,
  vscode_extension_marketplace_single_origin_fallback_enabled: false
)
admin_email = '${var.sso_admin_email}'
root = User.find_by_username('root')
raise 'root user missing' if root.nil?
root.skip_reconfirmation! if root.respond_to?(:skip_reconfirmation!)
root.email = admin_email
root.confirmed_at ||= Time.current
root.save!
s = ApplicationSetting.current
puts "root email=#{root.email} admin=#{root.admin?} password_auth_web=#{s.password_authentication_enabled_for_web} signup=#{s.signup_enabled} webide_fallback=#{s.vscode_extension_marketplace_single_origin_fallback_enabled}"
RUBY
)"; then
          exit 0
        fi
        echo "gitlab_sso_only: attempt $i/30 failed on pod $POD, retrying in 20s..."
        sleep 20
      done
      echo "gitlab_sso_only: failed after retries" >&2
      exit 1
    EOT
  }

  depends_on = [helm_release.gitlab]
}

resource "helm_release" "gitlab" {
  name       = "gitlab"
  repository = "https://charts.gitlab.io"
  chart      = "gitlab"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.gitlab.metadata[0].name

  timeout = 1200
  wait    = false

  values = [
    yamlencode(merge(
      { global = local.gitlab_global },
      local.gitlab_helm_chart_values,
    ))
  ]

  depends_on = [
    kubernetes_namespace.gitlab,
    kubernetes_secret.gitlab_object_storage,
    kubernetes_secret.gitlab_registry_storage,
    kubernetes_secret.gitlab_backup_storage,
    kubernetes_secret.gitlab_postgresql,
    kubernetes_secret.custom_ca,
    helm_release.gitlab_postgresql,
    kubernetes_secret.gitlab_redis_password,
    helm_release.gitlab_valkey,
    kubernetes_manifest.tls_certificates,
  ]
}
