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
      # Rate-limit VPN clients; exempt in-cluster OIDC (GitLab/Grafana/Argo → Keycloak).
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
}

resource "helm_release" "keycloak" {
  name       = "keycloak"
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "keycloak"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.keycloak.metadata[0].name

  timeout = 1800
  wait    = false

  values = [
    yamlencode(merge({
      auth = {
        adminUser     = var.admin_username
        adminPassword = var.admin_password
      }

      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/keycloak"
        tag        = var.keycloak_image_tag
      }

      production   = var.production_mode
      proxyHeaders = var.production_mode ? "xforwarded" : ""

      replicaCount = var.replica_count

      ingress = {
        enabled          = true
        ingressClassName = var.ingress_class
        hostname         = var.keycloak_host
        tls              = var.enable_tls
        annotations      = local.ingress_annotations
        extraTls = var.enable_tls ? [{
          hosts      = [var.keycloak_host]
          secretName = var.tls_secret_name
        }] : []
      }

      postgresql = {
        enabled = !var.use_external_database
        image = {
          registry   = "docker.io"
          repository = "bitnamilegacy/postgresql"
        }
        auth = var.use_external_database ? null : {
          username = "bn_keycloak"
          password = random_password.postgresql_password[0].result
          database = "bitnami_keycloak"
        }
        primary = {
          persistence = {
            enabled      = true
            storageClass = var.storage_class != "" ? var.storage_class : null
            size         = var.postgresql_storage_size
          }
        }
      }

      keycloakConfigCli = {
        enabled      = true
        backoffLimit = 20
        image = {
          registry   = "docker.io"
          repository = "bitnamilegacy/keycloak-config-cli"
        }
        configuration = {
          "maze-realm.yaml" = local.realm_config
        }
        # First Keycloak boot builds the server image; default 120s wait is too short.
        extraEnvVars = [
          { name = "KEYCLOAK_AVAILABILITYCHECK_ENABLED", value = "true" },
          { name = "KEYCLOAK_AVAILABILITYCHECK_TIMEOUT", value = "600s" },
        ]
      }

      # First start runs Quarkus build; without startupProbe, liveness (120s) kills the pod.
      startupProbe = {
        enabled             = true
        initialDelaySeconds = 30
        periodSeconds       = 10
        timeoutSeconds      = 5
        failureThreshold    = 60
        httpGet = {
          path = "/realms/master"
        }
      }
      livenessProbe = {
        enabled             = true
        initialDelaySeconds = 0
        periodSeconds       = 10
        timeoutSeconds      = 5
        failureThreshold    = 3
      }
      readinessProbe = {
        enabled             = true
        initialDelaySeconds = 0
        periodSeconds       = 10
        timeoutSeconds      = 5
        failureThreshold    = 3
        httpGet = {
          path = "/realms/master"
        }
      }

      extraEnvVars = concat(
        var.use_external_database ? concat(
          [
            # Bitnami wait-for-DB still uses KEYCLOAK_DATABASE_* even when KC_DB_URL is set.
            { name = "KEYCLOAK_DATABASE_HOST", value = var.postgresql_host },
            { name = "KEYCLOAK_DATABASE_PORT", value = tostring(var.postgresql_port) },
            { name = "KEYCLOAK_DATABASE_USER", value = var.postgresql_username },
            { name = "KEYCLOAK_DATABASE_NAME", value = var.postgresql_database },
            { name = "KEYCLOAK_DATABASE_PASSWORD", value = var.postgresql_password },
          ],
          var.postgresql_ssl ? [
            { name = "KC_DB_URL_PROPERTIES", value = "sslmode=require" }
          ] : []
          ) : [
          { name = "KEYCLOAK_DATABASE_HOST", value = "keycloak-postgresql" },
          { name = "KEYCLOAK_DATABASE_PORT", value = "5432" },
          { name = "KEYCLOAK_DATABASE_USER", value = "bn_keycloak" },
          { name = "KEYCLOAK_DATABASE_NAME", value = "bitnami_keycloak" },
          { name = "KEYCLOAK_DATABASE_PASSWORD", value = random_password.postgresql_password[0].result },
          { name = "KC_DB_PASSWORD", value = random_password.postgresql_password[0].result },
        ],
        local.event_webhook_enabled ? [
          { name = "WEBHOOK_URI", value = var.event_webhook_uri },
          { name = "WEBHOOK_SECRET", value = var.event_webhook_secret },
        ] : [],
      )

      initContainers = local.event_webhook_enabled ? [{
        name  = "keycloak-events-provider"
        image = "curlimages/curl:8.12.1"
        command = ["/bin/sh", "-c", <<-EOT
          set -euo pipefail
          mkdir -p /providers
          curl -fsSL -o /providers/keycloak-events.jar "${var.keycloak_events_jar_url}"
        EOT
        ]
        volumeMounts = [{
          name      = "keycloak-providers"
          mountPath = "/providers"
        }]
      }] : []

      extraVolumes = local.event_webhook_enabled ? [{
        name     = "keycloak-providers"
        emptyDir = {}
      }] : []

      extraVolumeMounts = local.event_webhook_enabled ? [{
        name      = "keycloak-providers"
        mountPath = "/opt/bitnami/keycloak/providers"
      }] : []

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
      },
      # jsondecode keeps both ternary branches the same dynamic type for OpenTofu
      jsondecode(var.use_external_database ? jsonencode({
        externalDatabase = {
          host     = var.postgresql_host
          port     = var.postgresql_port
          user     = var.postgresql_username
          password = var.postgresql_password
          database = var.postgresql_database
        }
      }) : "{}")
    ))
  ]

  depends_on = [kubernetes_namespace.keycloak]
}
