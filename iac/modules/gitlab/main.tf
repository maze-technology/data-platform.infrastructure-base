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
      bucket    = var.object_storage.bucket
      region    = var.object_storage.region
      endpoint  = var.object_storage.endpoint
      accesskey = var.object_storage.access_key
      secretkey = var.object_storage.secret_key
      v4auth    = true
      pathstyle = var.object_storage.force_path_style
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
        enabled               = true
        allowSingleSignOn     = ["openid_connect"]
        blockAutoCreatedUsers = false
        providers = [{
          secret = kubernetes_secret.gitlab_oidc[0].metadata[0].name
          key    = "provider"
        }]
      }
    } : {})
  }

  gitlab_helm_chart_values = {
    certmanager-issuer = {
      install = false
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
    postgresql = {
      install = !var.use_external_postgresql
      primary = {
        persistence = {
          enabled      = true
          size         = var.postgresql_storage_size
          storageClass = var.storage_class != "" ? var.storage_class : null
        }
      }
    }
    redis = {
      install = true
      master = {
        persistence = {
          enabled      = true
          size         = var.redis_storage_size
          storageClass = var.storage_class != "" ? var.storage_class : null
        }
      }
    }
    gitlab = {
      webservice = {
        minReplicas = var.webservice_min_replicas
        maxReplicas = var.webservice_max_replicas
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
      storage = {
        secret = kubernetes_secret.gitlab_registry_storage.metadata[0].name
        key    = "config"
      }
    }
  }
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
  count = var.use_external_postgresql ? 1 : 0

  metadata {
    name      = "gitlab-postgresql-password"
    namespace = kubernetes_namespace.gitlab.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    password = var.postgresql_password
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
    EOT
  }

  type = "Opaque"
}

resource "helm_release" "gitlab_bundled" {
  count = var.use_external_postgresql ? 0 : 1

  name       = "gitlab"
  repository = "https://charts.gitlab.io"
  chart      = "gitlab"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.gitlab.metadata[0].name

  timeout = 1200

  values = [
    yamlencode(merge(
      { global = local.global_base },
      local.gitlab_helm_chart_values,
    ))
  ]

  depends_on = [
    kubernetes_namespace.gitlab,
    kubernetes_secret.gitlab_object_storage,
    kubernetes_secret.gitlab_registry_storage,
    kubernetes_secret.gitlab_backup_storage,
  ]
}

resource "helm_release" "gitlab_external" {
  count = var.use_external_postgresql ? 1 : 0

  name       = "gitlab"
  repository = "https://charts.gitlab.io"
  chart      = "gitlab"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.gitlab.metadata[0].name

  timeout = 1200

  values = [
    yamlencode(merge(
      {
        global = merge(local.global_base, {
          psql = {
            host     = var.postgresql_host
            port     = var.postgresql_port
            database = var.postgresql_database
            username = var.postgresql_username
            password = {
              secret = kubernetes_secret.gitlab_postgresql[0].metadata[0].name
              key    = "password"
            }
          }
        })
      },
      local.gitlab_helm_chart_values,
    ))
  ]

  depends_on = [
    kubernetes_namespace.gitlab,
    kubernetes_secret.gitlab_object_storage,
    kubernetes_secret.gitlab_registry_storage,
    kubernetes_secret.gitlab_backup_storage,
    kubernetes_secret.gitlab_postgresql,
  ]
}
