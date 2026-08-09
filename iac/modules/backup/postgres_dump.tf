# Logical pg_dump of in-cluster Postgres → OVH backup bucket (rclone crypt).
# Complements Velero/Kopia PVC snapshots with application-consistent dumps.

locals {
  postgres_dump_names  = toset([for t in var.postgres_dump_targets : nonsensitive(t.name)])
  postgres_dump_active = var.enabled && var.postgres_dump_enabled && length(local.postgres_dump_names) > 0

  # for_each keys must be non-sensitive; passwords stay in values / secrets.
  postgres_dump_by_name = {
    for t in var.postgres_dump_targets : nonsensitive(t.name) => {
      name     = nonsensitive(t.name)
      host     = nonsensitive(t.host)
      port     = nonsensitive(tostring(t.port))
      user     = nonsensitive(t.user)
      database = nonsensitive(t.database)
      password = t.password
    }
  }

  postgres_dump_rclone_conf = <<-EOT
    [backup]
    type = s3
    provider = Ceph
    env_auth = false
    access_key_id = ${var.s3_access_key}
    secret_access_key = ${var.s3_secret_key}
    endpoint = ${var.s3_endpoint}
    region = ${var.s3_region}
    force_path_style = ${var.s3_force_path_style}
    acl = private
    ${var.s3_insecure_skip_tls_verify ? "no_check_certificate = true" : ""}
  EOT

  postgres_dump_script = <<-EOT
    set -euo pipefail
    echo "postgres dump starting at $$(date -u +%Y-%m-%dT%H:%M:%SZ) target=$${DUMP_NAME}"

    if [ -z "$${ENCRYPTION_PASSWORD:-}" ]; then
      echo "ENCRYPTION_PASSWORD is required" >&2
      exit 1
    fi
    if [ -z "$${PGPASSWORD:-}" ]; then
      echo "PGPASSWORD is required" >&2
      exit 1
    fi

    STAMP="$$(date -u +%Y%m%dT%H%M%SZ)"
    OUT="/tmp/$${DUMP_NAME}-$${STAMP}.dump"
    pg_dump -Fc -h "$${PGHOST}" -p "$${PGPORT}" -U "$${PGUSER}" -d "$${PGDATABASE}" -f "$$OUT"
    ls -la "$$OUT"

    CRYPT_PASS="$$(/shared/rclone obscure "$$ENCRYPTION_PASSWORD")"
    CRYPT_SALT="$$(/shared/rclone obscure "$$ENCRYPTION_PASSWORD")"
    {
      cat /config/rclone.conf
      echo ""
      echo "[backup-crypt]"
      echo "type = crypt"
      echo "remote = backup:$${S3_BUCKET}/$${DEST_PREFIX}"
      echo "password = $$CRYPT_PASS"
      echo "password2 = $$CRYPT_SALT"
      echo "filename_encryption = standard"
      echo "directory_name_encryption = true"
    } > /tmp/rclone.conf
    export RCLONE_CONFIG=/tmp/rclone.conf

    /shared/rclone copy "$$OUT" "backup-crypt:$${DUMP_NAME}/" --log-level INFO
    echo "postgres dump finished at $$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  EOT
}

resource "kubernetes_secret" "postgres_dump" {
  for_each = local.postgres_dump_active ? local.postgres_dump_by_name : {}

  metadata {
    name      = "postgres-dump-${each.key}"
    namespace = kubernetes_namespace.velero[0].metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
      purpose     = "postgres-logical-dump"
      target      = each.key
    }
  }

  data = {
    "rclone.conf"         = local.postgres_dump_rclone_conf
    "encryption-password" = var.encryption_password
    "dump.sh"             = local.postgres_dump_script
    PGPASSWORD            = each.value.password
  }

  lifecycle {
    precondition {
      condition     = length(var.encryption_password) >= 16
      error_message = "backup encryption_password must be at least 16 characters when postgres dumps are enabled."
    }
  }
}

resource "kubernetes_cron_job_v1" "postgres_dump" {
  for_each = local.postgres_dump_active ? local.postgres_dump_by_name : {}

  metadata {
    name      = "postgres-dump-${each.key}"
    namespace = kubernetes_namespace.velero[0].metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
      purpose     = "postgres-logical-dump"
      target      = each.key
    }
  }

  spec {
    schedule                      = var.postgres_dump_schedule_cron
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 600

    job_template {
      metadata {
        labels = {
          app     = "postgres-dump"
          purpose = "postgres-logical-dump"
          target  = each.key
        }
      }

      spec {
        backoff_limit = 2
        template {
          metadata {
            labels = {
              app     = "postgres-dump"
              purpose = "postgres-logical-dump"
              target  = each.key
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

            init_container {
              name    = "fetch-rclone"
              image   = var.object_sync_rclone_image
              command = ["sh", "-c", "cp /usr/local/bin/rclone /shared/rclone && chmod 755 /shared/rclone"]

              volume_mount {
                name       = "shared"
                mount_path = "/shared"
              }

              security_context {
                allow_privilege_escalation = false
                read_only_root_filesystem  = true
                capabilities {
                  drop = ["ALL"]
                }
              }
            }

            container {
              name    = "dump"
              image   = var.postgres_dump_image
              command = ["/bin/sh", "/scripts/dump.sh"]

              env {
                name  = "DUMP_NAME"
                value = each.key
              }
              env {
                name  = "PGHOST"
                value = each.value.host
              }
              env {
                name  = "PGPORT"
                value = tostring(each.value.port)
              }
              env {
                name  = "PGUSER"
                value = each.value.user
              }
              env {
                name  = "PGDATABASE"
                value = each.value.database
              }
              env {
                name  = "S3_BUCKET"
                value = var.s3_bucket
              }
              env {
                name  = "DEST_PREFIX"
                value = var.postgres_dump_prefix
              }
              env {
                name = "PGPASSWORD"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.postgres_dump[each.key].metadata[0].name
                    key  = "PGPASSWORD"
                  }
                }
              }
              env {
                name = "ENCRYPTION_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.postgres_dump[each.key].metadata[0].name
                    key  = "encryption-password"
                  }
                }
              }

              volume_mount {
                name       = "config"
                mount_path = "/config"
                read_only  = true
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
              volume_mount {
                name       = "shared"
                mount_path = "/shared"
                read_only  = true
              }
              volume_mount {
                name       = "tmp"
                mount_path = "/tmp"
              }

              resources {
                requests = {
                  cpu    = "100m"
                  memory = "256Mi"
                }
                limits = {
                  cpu    = "1"
                  memory = "1Gi"
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
              secret {
                secret_name = kubernetes_secret.postgres_dump[each.key].metadata[0].name
                items {
                  key  = "rclone.conf"
                  path = "rclone.conf"
                }
              }
            }

            volume {
              name = "scripts"
              secret {
                secret_name  = kubernetes_secret.postgres_dump[each.key].metadata[0].name
                default_mode = "0755"
                items {
                  key  = "dump.sh"
                  path = "dump.sh"
                }
              }
            }

            volume {
              name = "shared"
              empty_dir {}
            }

            volume {
              name = "tmp"
              empty_dir {}
            }
          }
        }
      }
    }
  }
}
