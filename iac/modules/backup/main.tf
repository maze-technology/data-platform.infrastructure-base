# Velero with Kopia filesystem backups → S3-compatible object storage.
# Client-side encryption via velero-repo-credentials (repository-password).
# Object store endpoint/bucket/credentials are inputs — composition chooses RGW vs OVH/etc.

locals {
  cloud_credentials = <<-EOT
    [default]
    aws_access_key_id=${var.s3_access_key}
    aws_secret_access_key=${var.s3_secret_key}
  EOT

  bsl_config = merge(
    {
      region                = var.s3_region
      s3ForcePathStyle      = tostring(var.s3_force_path_style)
      s3Url                 = var.s3_endpoint
      insecureSkipTLSVerify = tostring(var.s3_insecure_skip_tls_verify)
    },
    # Empty s3Url is invalid for non-AWS; composition must set endpoint for RGW/OVH.
  )

  schedule_template = merge(
    {
      ttl                      = var.backup_ttl
      storageLocation          = "default"
      snapshotVolumes          = var.snapshots_enabled
      defaultVolumesToFsBackup = var.default_volumes_to_fs_backup
      excludedNamespaces       = var.excluded_namespaces
    },
    length(var.included_namespaces) > 0 ? { includedNamespaces = var.included_namespaces } : {},
  )
}

resource "kubernetes_namespace" "velero" {
  count = var.enabled ? 1 : 0

  metadata {
    name = var.namespace
    labels = {
      name        = var.namespace
      environment = var.environment
      managed-by  = "opentofu"
    }
  }
}

# Kopia repository password — must exist before the first filesystem backup.
resource "kubernetes_secret" "velero_repo_credentials" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "velero-repo-credentials"
    namespace = kubernetes_namespace.velero[0].metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    "repository-password" = var.encryption_password
  }

  lifecycle {
    precondition {
      condition     = length(var.encryption_password) >= 16
      error_message = "backup encryption_password must be at least 16 characters when Velero is enabled."
    }
  }
}

resource "helm_release" "velero" {
  count = var.enabled ? 1 : 0

  name       = "velero"
  repository = "https://vmware-tanzu.github.io/helm-charts"
  chart      = "velero"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.velero[0].metadata[0].name

  values = [
    yamlencode({
      image = {
        repository = "velero/velero"
        pullPolicy = "IfNotPresent"
      }

      initContainers = [
        {
          name            = "velero-plugin-for-aws"
          image           = "velero/velero-plugin-for-aws:${var.aws_plugin_image_tag}"
          imagePullPolicy = "IfNotPresent"
          volumeMounts = [{
            mountPath = "/target"
            name      = "plugins"
          }]
        }
      ]

      configuration = {
        uploaderType             = "kopia"
        defaultVolumesToFsBackup = var.default_volumes_to_fs_backup
        defaultBackupTTL         = var.backup_ttl
        backupStorageLocation = [{
          name     = "default"
          provider = "aws"
          bucket   = var.s3_bucket
          prefix   = var.s3_prefix
          default  = true
          config   = local.bsl_config
        }]
        volumeSnapshotLocation = var.snapshots_enabled ? [{
          name     = "default"
          provider = "aws"
          config = {
            region = var.s3_region
          }
        }] : []
      }

      credentials = {
        useSecret = true
        secretContents = {
          cloud = local.cloud_credentials
        }
      }

      backupsEnabled   = true
      snapshotsEnabled = var.snapshots_enabled
      deployNodeAgent  = true

      schedules = {
        (var.schedule_name) = {
          disabled = false
          schedule = var.schedule_cron
          template = local.schedule_template
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.velero,
    kubernetes_secret.velero_repo_credentials,
  ]

  lifecycle {
    precondition {
      condition     = var.s3_bucket != "" && var.s3_endpoint != "" && var.s3_access_key != "" && var.s3_secret_key != ""
      error_message = "When backup is enabled, s3_bucket, s3_endpoint, s3_access_key, and s3_secret_key are required (composition supplies the object store)."
    }
  }
}
