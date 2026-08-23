# Mirror application RGW buckets into the backup object store (same bucket as Velero).
# Destination is wrapped with rclone crypt using encryption_password (same as Kopia).

locals {
  object_sync_active = var.enabled && var.object_sync_enabled && length(var.object_sync_sources) > 0

  rclone_s3_dest = "backup"
  rclone_crypt   = "backup-crypt"

  # S3 remotes only — crypt password is obscured at job runtime from ENCRYPTION_PASSWORD.
  rclone_conf = local.object_sync_active ? join("\n", concat(
    [
      for src in var.object_sync_sources : <<-EOT
        [src-${src.name}]
        type = s3
        provider = Ceph
        env_auth = false
        access_key_id = ${src.access_key}
        secret_access_key = ${src.secret_key}
        endpoint = ${src.endpoint}
        region = ${src.region}
        force_path_style = ${src.force_path_style}
        acl = private
        ${src.insecure_skip_tls_verify ? "no_check_certificate = true" : ""}
      EOT
    ],
    [
      <<-EOT
        [${local.rclone_s3_dest}]
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
    ]
  )) : ""

  rclone_sync_script = <<-EOT
    set -euo pipefail
    echo "RGW object mirror starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [ -z "$${ENCRYPTION_PASSWORD:-}" ]; then
      echo "ENCRYPTION_PASSWORD is required for rclone crypt" >&2
      exit 1
    fi

    # Do not use $$ — OpenTofu leaves it literal and bash expands $$ as PID.
    CRYPT_PASS="$(rclone obscure "$${ENCRYPTION_PASSWORD}")"
    CRYPT_SALT="$(rclone obscure "$${ENCRYPTION_PASSWORD}")"

    {
      cat /config/rclone.conf
      echo ""
      echo "[${local.rclone_crypt}]"
      echo "type = crypt"
      echo "remote = ${local.rclone_s3_dest}:${var.s3_bucket}/${var.object_sync_dest_prefix}"
      echo "password = $${CRYPT_PASS}"
      echo "password2 = $${CRYPT_SALT}"
      echo "filename_encryption = standard"
      echo "directory_name_encryption = true"
    } > /tmp/rclone.conf

    export RCLONE_CONFIG=/tmp/rclone.conf

    %{for src in var.object_sync_sources~}
    echo "Syncing ${src.bucket} → crypt:${var.s3_bucket}/${var.object_sync_dest_prefix}/${src.name}/"
    rclone sync "src-${src.name}:${src.bucket}" "${local.rclone_crypt}:${src.name}" \
      --checksum --transfers 8 --checkers 16 --fast-list --log-level INFO
    %{endfor~}

    echo "RGW object mirror finished at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  EOT
}

resource "kubernetes_secret" "rclone_config" {
  count = local.object_sync_active ? 1 : 0

  metadata {
    name      = "rclone-rgw-mirror"
    namespace = kubernetes_namespace.velero[0].metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
      purpose     = "rgw-object-mirror"
    }
  }

  data = {
    "rclone.conf"         = local.rclone_conf
    "encryption-password" = var.encryption_password
    "sync.sh"             = local.rclone_sync_script
  }

  lifecycle {
    precondition {
      condition     = length(var.encryption_password) >= 16
      error_message = "backup encryption_password must be at least 16 characters when RGW object sync is enabled (shared with Kopia + rclone crypt)."
    }
  }
}

resource "kubernetes_cron_job_v1" "rgw_object_mirror" {
  count = local.object_sync_active ? 1 : 0

  metadata {
    name      = "rgw-object-mirror"
    namespace = kubernetes_namespace.velero[0].metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
      purpose     = "rgw-object-mirror"
    }
  }

  spec {
    schedule                      = var.object_sync_schedule_cron
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 600

    job_template {
      metadata {
        labels = {
          app     = "rgw-object-mirror"
          purpose = "rgw-object-mirror"
        }
      }

      spec {
        backoff_limit = 2
        template {
          metadata {
            labels = {
              app     = "rgw-object-mirror"
              purpose = "rgw-object-mirror"
            }
          }

          spec {
            restart_policy = "OnFailure"

            security_context {
              run_as_non_root = true
              run_as_user     = 1000
              fs_group        = 1000
              seccomp_profile {
                type = "RuntimeDefault"
              }
            }

            container {
              name    = "rclone"
              image   = var.object_sync_rclone_image
              # rclone image ENTRYPOINT is `rclone`; must override with command (not args).
              command = ["/bin/sh", "/scripts/sync.sh"]

              env {
                name = "ENCRYPTION_PASSWORD"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.rclone_config[0].metadata[0].name
                    key  = "encryption-password"
                  }
                }
              }

              volume_mount {
                name       = "rclone-config"
                mount_path = "/config"
                read_only  = true
              }

              volume_mount {
                name       = "sync-script"
                mount_path = "/scripts"
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
              name = "rclone-config"
              secret {
                secret_name = kubernetes_secret.rclone_config[0].metadata[0].name
                items {
                  key  = "rclone.conf"
                  path = "rclone.conf"
                }
              }
            }

            volume {
              name = "sync-script"
              secret {
                secret_name  = kubernetes_secret.rclone_config[0].metadata[0].name
                default_mode = "0755"
                items {
                  key  = "sync.sh"
                  path = "sync.sh"
                }
              }
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

  depends_on = [kubernetes_secret.rclone_config]
}
