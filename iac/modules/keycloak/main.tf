# Keycloak identity provider (quay.io/keycloak + CloudNativePG).

terraform {
  required_providers {
    helm = {
      source = "hashicorp/helm"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    null = {
      source = "hashicorp/null"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

resource "random_password" "gitlab_client_secret" {
  length  = 32
  special = false
}

resource "random_password" "argocd_client_secret" {
  length  = 32
  special = false
}

resource "random_password" "kellnr_client_secret" {
  length  = 32
  special = false
}

resource "random_password" "grafana_client_secret" {
  length  = 32
  special = false
}

resource "random_password" "postgresql_password" {
  count   = var.use_external_database ? 0 : 1
  length  = 32
  special = false
}

resource "kubernetes_namespace" "keycloak" {
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
  protocol       = var.enable_tls ? "https" : "http"
  issuer_url     = "${local.protocol}://${var.keycloak_host}${var.ingress_port_suffix}/realms/${var.realm}"
  admin_base_url = "${local.protocol}://${var.keycloak_host}${var.ingress_port_suffix}"

  ingress_whitelist = "${var.vpn_cidr},127.0.0.1/32,10.0.0.0/8"

  ingress_annotations = merge(
    var.restrict_to_vpn ? {
      "nginx.ingress.kubernetes.io/whitelist-source-range" = local.ingress_whitelist
    } : {},
    var.enable_tls ? {
      "cert-manager.io/cluster-issuer"                 = var.tls_cluster_issuer
      "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"
      "nginx.ingress.kubernetes.io/ssl-redirect"       = "true"
    } : {},
    {
      "nginx.ingress.kubernetes.io/limit-rps"              = "5"
      "nginx.ingress.kubernetes.io/limit-rpm"              = "60"
      "nginx.ingress.kubernetes.io/limit-burst-multiplier" = "3"
      "nginx.ingress.kubernetes.io/limit-connections"      = "20"
      "nginx.ingress.kubernetes.io/limit-whitelist"        = "10.0.0.0/8,127.0.0.1/32"
    },
  )

  vpn_peer_usernames = [
    for user in var.bootstrap_users : user.username
    if contains(user.groups, "vpn-users")
  ]

  realm_users_yaml = join("\n", [
    for user in var.bootstrap_users : <<-USER
  - username: ${user.username}
    email: ${user.email}
    emailVerified: true
    enabled: true
    firstName: ${user.username}
    lastName: User
    credentials:
      - type: password
        value: ${user.password}
        temporary: ${try(user.password_temporary, false)}
    requiredActions:
      - CONFIGURE_TOTP
    groups:
${join("\n", [for g in user.groups : "      - ${g}"])}
    USER
  ])

  realm_config = templatefile("${path.module}/realm.yaml.tpl", {
    realm                 = var.realm
    gitlab_client_secret  = random_password.gitlab_client_secret.result
    argocd_client_secret  = random_password.argocd_client_secret.result
    grafana_client_secret = random_password.grafana_client_secret.result
    kellnr_client_secret  = random_password.kellnr_client_secret.result
    gitlab_redirect_uri   = var.oidc_clients.gitlab_redirect_uri
    argocd_redirect_uri   = var.oidc_clients.argocd_redirect_uri
    grafana_redirect_uri  = var.oidc_clients.grafana_redirect_uri
    kellnr_redirect_uri   = var.oidc_clients.kellnr_redirect_uri
    realm_users_yaml      = local.realm_users_yaml
  })

  event_webhook_enabled = var.event_webhook_uri != "" && var.event_webhook_secret != ""

  db_host     = var.use_external_database ? var.postgresql_host : module.keycloak_postgresql[0].rw_host
  db_port     = var.use_external_database ? var.postgresql_port : module.keycloak_postgresql[0].port
  db_name     = var.use_external_database ? var.postgresql_database : var.postgresql_database
  db_user     = var.use_external_database ? var.postgresql_username : var.postgresql_username
  db_password = var.use_external_database ? var.postgresql_password : random_password.postgresql_password[0].result

  keycloak_service_url = "http://keycloak-http.${var.namespace}.svc.cluster.local:8080"

  events_extra_volumes_body = <<-EOT
    - name: keycloak-providers
      emptyDir: {}
  EOT

  events_extra_volume_mounts_body = <<-EOT
    - name: keycloak-providers
      mountPath: /opt/keycloak/providers
  EOT

  events_extra_init_containers_body = <<-EOT
    - name: keycloak-events-provider
      image: curlimages/curl:8.12.1
      command:
        - /bin/sh
        - -c
        - |
          set -euo pipefail
          curl -fsSL -o /providers/keycloak-events.jar "${var.keycloak_events_jar_url}"
          ls -la /providers/keycloak-events.jar
      volumeMounts:
        - name: keycloak-providers
          mountPath: /providers
  EOT

  events_extra_volumes        = local.event_webhook_enabled ? local.events_extra_volumes_body : ""
  events_extra_volume_mounts   = local.event_webhook_enabled ? local.events_extra_volume_mounts_body : ""
  events_extra_init_containers = local.event_webhook_enabled ? local.events_extra_init_containers_body : ""
}

module "keycloak_postgresql" {
  count  = var.use_external_database ? 0 : 1
  source = "../cnpg-cluster"

  environment    = var.environment
  namespace      = kubernetes_namespace.keycloak.metadata[0].name
  cluster_name   = "keycloak-pg"
  database       = var.postgresql_database
  username       = var.postgresql_username
  password       = random_password.postgresql_password[0].result
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

  depends_on = [kubernetes_namespace.keycloak]
}

resource "kubernetes_secret" "keycloak_db" {
  metadata {
    name      = "keycloak-db-credentials"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    password = local.db_password
  }

  type = "Opaque"
}

resource "helm_release" "keycloak" {
  name       = "keycloak"
  repository = "https://codecentric.github.io/helm-charts"
  chart      = "keycloakx"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.keycloak.metadata[0].name

  timeout = 1800
  wait    = false

  values = [
    yamlencode({
      replicas = var.replica_count

      image = {
        repository = "quay.io/keycloak/keycloak"
        tag        = var.keycloak_image_tag
      }

      http = {
        relativePath = "/"
      }

      proxy = {
        enabled = true
        mode    = "xforwarded"
        http = {
          enabled = true
        }
      }

      dbchecker = {
        enabled = true
      }

      database = {
        vendor            = "postgres"
        hostname          = local.db_host
        port              = local.db_port
        database          = local.db_name
        username          = local.db_user
        existingSecret    = kubernetes_secret.keycloak_db.metadata[0].name
        existingSecretKey = "password"
      }

      ingress = {
        enabled          = true
        ingressClassName = var.ingress_class
        annotations      = local.ingress_annotations
        rules = [{
          host = var.keycloak_host
          paths = [{
            path     = "/"
            pathType = "Prefix"
          }]
        }]
        tls = var.enable_tls ? [{
          hosts      = [var.keycloak_host]
          secretName = var.tls_secret_name
        }] : []
      }

      startupProbe = <<-EOT
        httpGet:
          path: /health
          port: http-internal
          scheme: HTTP
        initialDelaySeconds: 30
        periodSeconds: 10
        timeoutSeconds: 5
        failureThreshold: 60
      EOT

      resources = {
        requests = {
          cpu    = "500m"
          memory = "1Gi"
        }
        limits = {
          cpu    = "2"
          memory = "2Gi"
        }
      }

      extraEnv = join("\n", concat(
        [
          "- name: KEYCLOAK_ADMIN",
          "  value: ${var.admin_username}",
          "- name: KEYCLOAK_ADMIN_PASSWORD",
          "  value: ${var.admin_password}",
        ],
        var.postgresql_ssl ? [
          "- name: KC_DB_URL_PROPERTIES",
          "  value: sslmode=require",
        ] : [],
        local.event_webhook_enabled ? [
          "- name: WEBHOOK_URI",
          "  value: ${var.event_webhook_uri}",
          "- name: WEBHOOK_SECRET",
          "  value: ${var.event_webhook_secret}",
        ] : [],
      ))

      extraVolumes        = local.events_extra_volumes
      extraVolumeMounts   = local.events_extra_volume_mounts
      extraInitContainers = local.events_extra_init_containers
    })
  ]

  depends_on = [
    kubernetes_namespace.keycloak,
    kubernetes_secret.keycloak_db,
    module.keycloak_postgresql,
  ]
}

resource "kubernetes_config_map" "realm_config" {
  metadata {
    name      = "keycloak-realm-config"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    "maze-realm.yaml" = local.realm_config
  }
}

resource "kubernetes_secret" "keycloak_config_cli_admin" {
  metadata {
    name      = "keycloak-config-cli-admin"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    username = var.admin_username
    password = var.admin_password
  }

  type = "Opaque"
}

# Realm import via adorsys/keycloak-config-cli (replaces Bitnami keycloak-config-cli subchart).
resource "null_resource" "keycloak_realm_import" {
  triggers = {
    realm_hash = sha256(local.realm_config)
    release    = helm_release.keycloak.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      NS='${kubernetes_namespace.keycloak.metadata[0].name}'
      JOB="keycloak-config-cli-$${RANDOM}"

      kubectl -n "$NS" delete job -l app=keycloak-config-cli --ignore-not-found=true --wait=true

      cat <<YAML | kubectl -n "$NS" apply -f -
      apiVersion: batch/v1
      kind: Job
      metadata:
        name: $JOB
        labels:
          app: keycloak-config-cli
          managed-by: opentofu
      spec:
        backoffLimit: 20
        template:
          metadata:
            labels:
              app: keycloak-config-cli
          spec:
            restartPolicy: OnFailure
            containers:
              - name: config-cli
                image: ${var.keycloak_config_cli_image}
                env:
                  - name: KEYCLOAK_URL
                    value: "${local.keycloak_service_url}"
                  - name: KEYCLOAK_USER
                    valueFrom:
                      secretKeyRef:
                        name: ${kubernetes_secret.keycloak_config_cli_admin.metadata[0].name}
                        key: username
                  - name: KEYCLOAK_PASSWORD
                    valueFrom:
                      secretKeyRef:
                        name: ${kubernetes_secret.keycloak_config_cli_admin.metadata[0].name}
                        key: password
                  - name: IMPORT_FILES_LOCATIONS
                    value: /config/*
                  - name: IMPORT_VARSUBSTITUTION_ENABLED
                    value: "true"
                  - name: KEYCLOAK_AVAILABILITYCHECK_ENABLED
                    value: "true"
                  - name: KEYCLOAK_AVAILABILITYCHECK_TIMEOUT
                    value: "600s"
                  - name: IMPORT_MANAGED_GROUP
                    value: "NO_DELETE"
                volumeMounts:
                  - name: config
                    mountPath: /config
                    readOnly: true
            volumes:
              - name: config
                configMap:
                  name: ${kubernetes_config_map.realm_config.metadata[0].name}
      YAML

      kubectl -n "$NS" wait --for=condition=complete "job/$JOB" --timeout=900s
    EOT
  }

  depends_on = [
    helm_release.keycloak,
    kubernetes_config_map.realm_config,
    kubernetes_secret.keycloak_config_cli_admin,
  ]
}
