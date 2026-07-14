resource "random_password" "gitlab_client_secret" {
  length  = 32
  special = false
}

resource "random_password" "argocd_client_secret" {
  length  = 32
  special = false
}

resource "random_password" "grafana_client_secret" {
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

  ingress_annotations = var.restrict_to_vpn ? {
    "nginx.ingress.kubernetes.io/whitelist-source-range" = local.ingress_whitelist
  } : {}

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
    groups:
${join("\n", [for g in user.groups : "      - ${g}"])}
    USER
  ])

  realm_config = templatefile("${path.module}/realm.yaml.tpl", {
    realm                 = var.realm
    gitlab_client_secret  = random_password.gitlab_client_secret.result
    argocd_client_secret  = random_password.argocd_client_secret.result
    grafana_client_secret = random_password.grafana_client_secret.result
    gitlab_redirect_uri   = var.oidc_clients.gitlab_redirect_uri
    argocd_redirect_uri   = var.oidc_clients.argocd_redirect_uri
    grafana_redirect_uri  = var.oidc_clients.grafana_redirect_uri
    realm_users_yaml      = local.realm_users_yaml
  })
}

resource "helm_release" "keycloak" {
  name       = "keycloak"
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "keycloak"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.keycloak.metadata[0].name

  timeout = 1800

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
      }

      postgresql = {
        enabled = !var.use_external_database
        image = {
          registry   = "docker.io"
          repository = "bitnamilegacy/postgresql"
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
        enabled = true
        configuration = {
          "maze-realm.yaml" = local.realm_config
        }
      }

      extraEnvVars = var.use_external_database ? [] : [
        # Bitnami setup script reads KEYCLOAK_DATABASE_HOST (defaults to "postgresql")
        { name = "KEYCLOAK_DATABASE_HOST", value = "keycloak-postgresql" },
        { name = "KEYCLOAK_DATABASE_PORT", value = "5432" },
      ]

      resources = {
        requests = {
          cpu    = "250m"
          memory = "512Mi"
        }
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }
      }, var.use_external_database ? {
      externalDatabase = {
        host     = var.postgresql_host
        port     = var.postgresql_port
        user     = var.postgresql_username
        password = var.postgresql_password
        database = var.postgresql_database
      }
    } : {}))
  ]

  depends_on = [kubernetes_namespace.keycloak]
}
