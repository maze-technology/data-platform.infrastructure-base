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

# Required in the PVC namespace for rook-ceph-block-encrypted (CSI metadata KMS).
resource "kubernetes_secret" "storage_encryption" {
  count = var.storage_encryption_passphrase != "" ? 1 : 0

  metadata {
    name      = var.storage_encryption_secret_name
    namespace = kubernetes_namespace.gitlab.metadata[0].name
    labels = {
      managed-by  = "opentofu"
      purpose     = "rbd-luks"
      environment = var.environment
    }
  }

  data = {
    encryptionPassphrase = var.storage_encryption_passphrase
  }

  type = "Opaque"
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
    # Gate on PEM presence (same as kubernetes_secret.custom_ca count), not keys alone —
    # keys default to ["maze-ca.crt"] even when no CA is configured.
    certificates = var.custom_ca_pem != "" ? {
      customCAs = [{
        secret = kubernetes_secret.custom_ca[0].metadata[0].name
        keys   = var.custom_ca_secret_keys
      }]
    } : {}
    ingress = {
      enabled              = true
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
  postgresql_port     = var.use_external_postgresql ? var.postgresql_port : 5432
  postgresql_ssl      = var.use_external_postgresql ? var.postgresql_ssl : false
  valkey_host         = "gitlab-valkey-primary.${kubernetes_namespace.gitlab.metadata[0].name}.svc.cluster.local"

  gitlab_global = merge(local.global_base, {
    # OVH Web Cloud / managed Postgres enforce TLS without client certs.
    # GitLab chart global.psql.ssl is mutual-TLS only and requires a secret —
    # use libpq PGSSLMODE instead.
    extraEnv = local.postgresql_ssl ? {
      PGSSLMODE = "require"
    } : {}
    psql = {
      host     = local.postgresql_host
      port     = local.postgresql_port
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
    # Use cluster ingress-nginx (NodePort behind OVH LB). Envoy Gateway certgen
    # has been unreliable on this cluster and is unnecessary for that path.
    gatewayApi = {
      enabled              = false
      installEnvoy         = false
      configureCertmanager = false
      httpToHttpsRedirect  = false
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
        install  = var.install_gitlab_runner
        replicas = var.gitlab_runner_replicas
        # Trust Maze CA when verifying https://scm… (self-signed ClusterIssuer).
        certsSecretName = var.custom_ca_pem != "" ? kubernetes_secret.custom_ca[0].metadata[0].name : null
        rbac = {
          create = true
        }
        runners = {
          # Required for authentication-token (glrt-) registration workflow.
          locked     = null
          privileged = true
          secret     = "gitlab-gitlab-runner-secret"
          config     = <<-EOT
            [[runners]]
              tls-ca-file = "/home/gitlab-runner/.gitlab-runner/certs/maze-ca.crt"
              [runners.kubernetes]
                namespace = "${kubernetes_namespace.gitlab.metadata[0].name}"
                image = "alpine:3.20"
                privileged = true
                poll_timeout = 180
                cpu_request = "100m"
                memory_request = "128Mi"
                memory_limit = "1536Mi"
                service_cpu_request = "50m"
                service_memory_request = "64Mi"
          EOT
        }
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
      }
      gitlab = {
        webservice = {
          minReplicas     = var.webservice_min_replicas
          maxReplicas     = var.webservice_max_replicas
          workerProcesses = var.webservice_worker_processes
          # 2 Puma workers alone ~900Mi RSS each at idle; 2Gi limit OOMs under API load.
          resources = {
            requests = {
              cpu    = "500m"
              memory = "2Gi"
            }
            limits = {
              cpu    = "2"
              memory = "4Gi"
            }
          }
        }
        sidekiq = {
          minReplicas = 1
          maxReplicas = 1
          resources = {
            requests = {
              cpu    = "200m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "1"
              memory = "2Gi"
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
            # GitLab chart key is storageClass (not "storage").
            storageClass = (
              var.gitaly_storage_class != "" ? var.gitaly_storage_class :
              var.storage_class != "" ? var.storage_class : null
            )
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
    harden_v2   = "signup-off-webide-fallback-off-git-password-off"
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
# Git over HTTP(S): no account passwords (SSH keys or personal access tokens).
ApplicationSetting.current.update!(
  password_authentication_enabled_for_web: false,
  password_authentication_enabled_for_git: false,
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
puts "root email=#{root.email} admin=#{root.admin?} password_auth_web=#{s.password_authentication_enabled_for_web} password_auth_git=#{s.password_authentication_enabled_for_git} signup=#{s.signup_enabled} webide_fallback=#{s.vscode_extension_marketplace_single_origin_fallback_enabled}"
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
    kubernetes_secret.gitlab_runner_token,
    helm_release.gitlab_postgresql,
    kubernetes_secret.gitlab_redis_password,
    helm_release.gitlab_valkey,
    kubernetes_manifest.tls_certificates,
  ]
}

# When Gateway API / Envoy is disabled, skip the wait and leave gateway IP empty.
resource "null_resource" "gitlab_gateway_ready" {
  count = try(local.gitlab_global.gatewayApi.enabled, false) ? 1 : 0

  triggers = {
    release = helm_release.gitlab.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      NS='${kubernetes_namespace.gitlab.metadata[0].name}'
      for i in $(seq 1 60); do
        IP="$(kubectl -n "$NS" get svc -l gateway.envoyproxy.io/owning-gateway-name=gitlab-gw -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null || true)"
        if [ -n "$IP" ]; then
          echo "gitlab gateway ClusterIP=$IP"
          exit 0
        fi
        echo "gitlab_gateway_ready: waiting for envoy service (attempt $i/60)"
        sleep 5
      done
      echo "gitlab_gateway_ready: envoy service not found" >&2
      exit 1
    EOT
  }

  depends_on = [helm_release.gitlab]
}

data "external" "gitlab_gateway_ip" {
  count = try(local.gitlab_global.gatewayApi.enabled, false) ? 1 : 0

  program = [
    "bash",
    "-c",
    <<-EOT
      set -euo pipefail
      IP="$(kubectl -n '${kubernetes_namespace.gitlab.metadata[0].name}' get svc -l gateway.envoyproxy.io/owning-gateway-name=gitlab-gw -o jsonpath='{.items[0].spec.clusterIP}')"
      printf '{"ip":"%s"}\n' "$IP"
    EOT
  ]

  depends_on = [null_resource.gitlab_gateway_ready]
}

# Placeholder until rails creates a real glrt- token (auth-token workflow).
resource "kubernetes_secret" "gitlab_runner_token" {
  count = var.install_gitlab_runner ? 1 : 0

  metadata {
    name      = "gitlab-gitlab-runner-secret"
    namespace = kubernetes_namespace.gitlab.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    "runner-registration-token" = ""
    "runner-token"              = "pending-replace-me"
  }

  type = "Opaque"

  lifecycle {
    ignore_changes = [data]
  }
}

# Create an instance runner (glrt-) and write the token into the runner secret.
resource "null_resource" "gitlab_runner_register" {
  count = var.install_gitlab_runner ? 1 : 0

  triggers = {
    release = helm_release.gitlab.id
    secret  = try(kubernetes_secret.gitlab_runner_token[0].metadata[0].name, "")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      NS='${kubernetes_namespace.gitlab.metadata[0].name}'
      kubectl -n "$NS" wait --for=condition=available deploy/gitlab-webservice-default --timeout=900s
      kubectl -n "$NS" wait --for=condition=ready pod -l app=toolbox --timeout=300s
      for i in $(seq 1 30); do
        POD="$(kubectl -n "$NS" get pod -l app=toolbox --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        if [ -z "$POD" ]; then
          echo "gitlab_runner_register: no toolbox yet (attempt $i/30)"
          sleep 20
          continue
        fi
        TOKEN="$(kubectl -n "$NS" exec "$POD" -- gitlab-rails runner "$(cat <<'RUBY'
user = User.find_by_username('root')
raise 'root missing' if user.nil?
existing = Ci::Runner.find_by(description: 'maze-k8s')
if existing
  # Token is only shown once at create — recreate if we cannot register.
  existing.destroy!
end
result = Ci::Runners::CreateRunnerService.new(
  user: user,
  params: {
    runner_type: 'instance_type',
    description: 'maze-k8s',
    run_untagged: true,
    tag_list: %w[kubernetes docker maze],
  }
).execute
raise result.message unless result.success?
runner = result.payload[:runner] || result.payload[:ci_runner]
puts runner.token
RUBY
)" 2>/dev/null | tail -n 1 | tr -d '\r')"
        if [[ "$TOKEN" == glrt-* ]] || [[ "$${#TOKEN}" -gt 20 ]]; then
          kubectl -n "$NS" create secret generic gitlab-gitlab-runner-secret \
            --from-literal=runner-registration-token="" \
            --from-literal=runner-token="$TOKEN" \
            --dry-run=client -o yaml | kubectl apply -f -
          kubectl -n "$NS" delete pod -l app=gitlab-gitlab-runner --wait=false 2>/dev/null || \
            kubectl -n "$NS" delete pod -l app.kubernetes.io/name=gitlab-gitlab-runner --wait=false 2>/dev/null || true
          kubectl -n "$NS" rollout restart deploy/gitlab-gitlab-runner 2>/dev/null || \
            kubectl -n "$NS" rollout restart deployment -l app=gitlab-gitlab-runner 2>/dev/null || true
          echo "gitlab_runner_register: token installed"
          exit 0
        fi
        echo "gitlab_runner_register: attempt $i/30 got unexpected token output: $TOKEN"
        sleep 20
      done
      echo "gitlab_runner_register: failed" >&2
      exit 1
    EOT
  }

  depends_on = [
    helm_release.gitlab,
    kubernetes_secret.gitlab_runner_token,
    null_resource.gitlab_sso_only,
  ]
}
