# Self-hosted Renovate against maze GitLab (Kubernetes CronJob).
# Creates renovate-bot + PAT via Rails (same bootstrap style as gitlab-ci-cosign),
# then runs renovate/renovate on a schedule with autodiscover limited to product groups.

terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    null = {
      source = "hashicorp/null"
    }
  }
}

locals {
  active = var.enabled

  config_json = jsonencode({
    platform           = "gitlab"
    endpoint           = var.gitlab_endpoint
    autodiscover       = true
    autodiscoverFilter = var.autodiscover_filters
    onboarding         = true
    onboardingConfig = {
      extends = ["config:recommended"]
    }
    gitAuthor       = "${var.bot_name} <${var.bot_email}>"
    persistRepoData = false
  })
}

resource "kubernetes_config_map" "renovate" {
  count = local.active ? 1 : 0

  metadata {
    name      = "renovate-config"
    namespace = var.gitlab_namespace
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
      purpose     = "renovate"
    }
  }

  data = {
    "config.json" = local.config_json
  }
}

resource "kubernetes_secret" "renovate_env" {
  count = local.active ? 1 : 0

  metadata {
    name      = "renovate-env"
    namespace = var.gitlab_namespace
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
      purpose     = "renovate"
    }
  }

  data = merge(
    {
      RENOVATE_PLATFORM     = "gitlab"
      RENOVATE_ENDPOINT     = var.gitlab_endpoint
      RENOVATE_AUTODISCOVER = "true"
      LOG_LEVEL             = var.log_level
      RENOVATE_CONFIG_FILE  = "/opt/renovate/config.json"
      RENOVATE_BASE_DIR     = "/tmp/renovate/"
    },
    var.github_com_token != "" ? {
      RENOVATE_GITHUB_COM_TOKEN = var.github_com_token
    } : {},
    var.custom_ca_pem != "" ? {
      NODE_EXTRA_CA_CERTS = "/etc/ssl/maze/maze-ca.crt"
    } : {},
  )
}

resource "kubernetes_secret" "renovate_ca" {
  count = local.active && var.custom_ca_pem != "" ? 1 : 0

  metadata {
    name      = "renovate-maze-ca"
    namespace = var.gitlab_namespace
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
      purpose     = "renovate"
    }
  }

  data = {
    "maze-ca.crt" = var.custom_ca_pem
  }
}

resource "null_resource" "renovate_bot" {
  count = local.active ? 1 : 0

  triggers = {
    namespace   = var.gitlab_namespace
    bot_user    = var.bot_username
    bot_email   = var.bot_email
    bot_name    = var.bot_name
    groups      = join(",", var.group_paths)
    secret_name = var.api_token_secret_name
    generation  = "2"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      GITLAB_NS        = var.gitlab_namespace
      BOT_USERNAME     = var.bot_username
      BOT_EMAIL        = var.bot_email
      BOT_NAME         = var.bot_name
      GROUP_PATHS      = join(",", var.group_paths)
      API_TOKEN_SECRET = var.api_token_secret_name
    }
    command = <<-EOT
      set -euo pipefail
      NS="$${GITLAB_NS}"
      kubectl -n "$NS" wait --for=condition=available deploy/gitlab-webservice-default --timeout=900s
      kubectl -n "$NS" wait --for=condition=ready pod -l app=toolbox --timeout=300s

      POD=""
      for i in $(seq 1 30); do
        POD="$(kubectl -n "$NS" get pod -l app=toolbox --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        [ -n "$POD" ] && break
        sleep 10
      done
      [ -n "$POD" ] || { echo "renovate: no toolbox pod" >&2; exit 1; }

      # Ensure bot user exists.
      kubectl -n "$NS" exec "$POD" -- gitlab-rails runner "
username = '${var.bot_username}'
email    = '${var.bot_email}'
name     = '${var.bot_name}'
u = User.find_by_username(username)
if u.nil?
  pass = SecureRandom.hex(32)
  attrs = {
    username: username,
    name: name,
    email: email,
    password: pass,
    password_confirmation: pass
  }
  u = User.new(attrs)
  u.skip_confirmation! if u.respond_to?(:skip_confirmation!)
  if u.respond_to?(:assign_personal_namespace)
    org = Organizations::Organization.default_organization rescue nil
    u.assign_personal_namespace(org) if org
  end
  raise u.errors.full_messages.join(', ') unless u.save
  puts 'created'
else
  puts 'exists'
end
"

      PF_LOCAL=18281
      if ss -ltn 2>/dev/null | grep -q ":$${PF_LOCAL} " || netstat -ltn 2>/dev/null | grep -q ":$${PF_LOCAL} "; then
        PF_LOCAL=18282
      fi
      kubectl -n "$NS" port-forward svc/gitlab-webservice-default "$${PF_LOCAL}:8181" >/tmp/gitlab-pf-renovate.log 2>&1 &
      PF_PID=$!
      trap 'kill $PF_PID 2>/dev/null || true' EXIT

      TOKEN=""
      if kubectl -n "$NS" get secret "$${API_TOKEN_SECRET}" >/dev/null 2>&1; then
        TOKEN="$(kubectl -n "$NS" get secret "$${API_TOKEN_SECRET}" -o jsonpath='{.data.token}' | base64 -d || true)"
      fi

      for i in $(seq 1 60); do
        if [ -n "$${TOKEN}" ]; then
          code="$(curl -s -o /tmp/gitlab-renovate-ver.json -w '%%{http_code}' \
            -H "PRIVATE-TOKEN: $${TOKEN}" \
            "http://127.0.0.1:$${PF_LOCAL}/api/v4/version" || true)"
          if [ "$code" = "200" ]; then
            break
          fi
          TOKEN=""
        fi
        TOKEN="$(kubectl -n "$NS" exec "$POD" -- gitlab-rails runner "
u = User.find_by_username('${var.bot_username}')
raise 'renovate-bot missing' if u.nil?
u.personal_access_tokens.where(name: 'renovate').destroy_all
pat = u.personal_access_tokens.create!(
  name: 'renovate',
  scopes: %w[api read_api read_user write_repository],
  expires_at: 1.year.from_now
)
puts pat.token
" 2>/dev/null | tail -n 1 | tr -d '\r')"
        [ "$${#TOKEN}" -ge 16 ] || { echo "renovate: failed to create PAT" >&2; exit 1; }
        kubectl -n "$NS" create secret generic "$${API_TOKEN_SECRET}" \
          --from-literal=token="$TOKEN" \
          --dry-run=client -o yaml | kubectl apply -f -
        kubectl -n "$NS" label secret "$${API_TOKEN_SECRET}" managed-by=opentofu purpose=renovate --overwrite
        sleep 2
      done

      code="$(curl -s -o /tmp/gitlab-renovate-ver.json -w '%%{http_code}' \
        -H "PRIVATE-TOKEN: $${TOKEN}" \
        "http://127.0.0.1:$${PF_LOCAL}/api/v4/version" || true)"
      if [ "$${code:-}" != "200" ]; then
        echo "renovate: API not ready code=$${code:-none}" >&2
        cat /tmp/gitlab-renovate-ver.json 2>/dev/null || true
        exit 1
      fi

      BOT_ID="$(curl -sS -H "PRIVATE-TOKEN: $${TOKEN}" \
        "http://127.0.0.1:$${PF_LOCAL}/api/v4/user" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')"

      IFS=',' read -r -a GROUPS <<< "$${GROUP_PATHS}"
      for gpath in "$${GROUPS[@]}"; do
        [ -n "$gpath" ] || continue
        kubectl -n "$NS" exec "$POD" -- gitlab-rails runner "
g = Group.find_by_full_path('$gpath')
raise 'group $gpath missing' if g.nil?
u = User.find_by_username('${var.bot_username}')
raise 'bot missing' if u.nil?
m = g.members.find_by(user_id: u.id)
if m.nil?
  g.add_member(u, Gitlab::Access::MAINTAINER)
  puts 'added $gpath'
elsif m.access_level < Gitlab::Access::MAINTAINER
  m.update!(access_level: Gitlab::Access::MAINTAINER)
  puts 'upgraded $gpath'
else
  puts 'ok $gpath'
end
"
      done

      echo "renovate: bot ready user=${var.bot_username} id=$${BOT_ID}"
    EOT
  }
}

resource "kubernetes_cron_job_v1" "renovate" {
  count = local.active ? 1 : 0

  metadata {
    name      = "renovate"
    namespace = var.gitlab_namespace
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
      purpose     = "renovate"
    }
  }

  spec {
    schedule                      = var.schedule_cron
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 600

    job_template {
      metadata {
        labels = {
          app     = "renovate"
          purpose = "renovate"
        }
      }

      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 86400

        template {
          metadata {
            labels = {
              app     = "renovate"
              purpose = "renovate"
            }
          }

          spec {
            restart_policy = "Never"

            security_context {
              run_as_non_root = true
              run_as_user     = 12021
              fs_group        = 12021
              seccomp_profile {
                type = "RuntimeDefault"
              }
            }

            container {
              name  = "renovate"
              image = var.image

              env_from {
                secret_ref {
                  name = kubernetes_secret.renovate_env[0].metadata[0].name
                }
              }

              env {
                name = "RENOVATE_TOKEN"
                value_from {
                  secret_key_ref {
                    name = var.api_token_secret_name
                    key  = "token"
                  }
                }
              }

              volume_mount {
                name       = "config"
                mount_path = "/opt/renovate"
                read_only  = true
              }

              volume_mount {
                name       = "tmp"
                mount_path = "/tmp"
              }

              dynamic "volume_mount" {
                for_each = var.custom_ca_pem != "" ? [1] : []
                content {
                  name       = "maze-ca"
                  mount_path = "/etc/ssl/maze"
                  read_only  = true
                }
              }

              resources {
                requests = {
                  cpu    = "200m"
                  memory = "512Mi"
                }
                limits = {
                  cpu    = "2"
                  memory = "2Gi"
                }
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
              name = "config"
              config_map {
                name = kubernetes_config_map.renovate[0].metadata[0].name
              }
            }

            volume {
              name = "tmp"
              empty_dir {}
            }

            dynamic "volume" {
              for_each = var.custom_ca_pem != "" ? [1] : []
              content {
                name = "maze-ca"
                secret {
                  secret_name = kubernetes_secret.renovate_ca[0].metadata[0].name
                }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [null_resource.renovate_bot]
}
