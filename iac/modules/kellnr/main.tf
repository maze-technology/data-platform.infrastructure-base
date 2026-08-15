terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    helm = {
      source = "hashicorp/helm"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

locals {
  ingress_whitelist = "${var.vpn_cidr},127.0.0.1/32,10.0.0.0/8"

  # Sparse index URL for Cargo (registry = "maze")
  sparse_index = "sparse+https://${var.hostname}/api/v1/crates/"

  postgresql_host = "kellnr-postgresql.${kubernetes_namespace.kellnr.metadata[0].name}.svc.cluster.local"
}

resource "kubernetes_namespace" "kellnr" {
  metadata {
    name = var.namespace
    labels = {
      name        = var.namespace
      environment = var.environment
      managed-by  = "opentofu"
    }
  }
}

resource "random_password" "postgresql" {
  length  = 32
  special = false
}

resource "random_password" "admin_pwd" {
  length  = 24
  special = false
}

resource "random_password" "admin_token" {
  length  = 32
  special = false
}

# Shared across replicas so UI sessions survive pod moves.
resource "random_password" "cookie_signing_key" {
  length  = 64
  special = false
}

resource "kubernetes_secret" "postgresql" {
  metadata {
    name      = "kellnr-postgresql-password"
    namespace = kubernetes_namespace.kellnr.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    password = random_password.postgresql.result
  }

  type = "Opaque"
}

resource "helm_release" "postgresql" {
  name       = "kellnr-postgresql"
  repository = "oci://registry-1.docker.io/bitnamicharts"
  chart      = "postgresql"
  namespace  = kubernetes_namespace.kellnr.metadata[0].name

  values = [
    yamlencode({
      auth = {
        username = var.postgresql_username
        password = random_password.postgresql.result
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
            cpu    = "100m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/postgresql"
      }
    })
  ]

  depends_on = [kubernetes_namespace.kellnr]
}

resource "helm_release" "kellnr" {
  name       = "kellnr"
  repository = "https://kellnr.github.io/helm"
  chart      = "kellnr"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.kellnr.metadata[0].name

  timeout = 600

  values = [
    yamlencode({
      replicaCount = var.replica_count

      resources = var.resources

      ingress = {
        enabled   = true
        className = var.ingress_class
        pathType  = "Prefix"
        path      = "/"
        annotations = merge(
          var.restrict_to_vpn ? {
            "nginx.ingress.kubernetes.io/whitelist-source-range" = local.ingress_whitelist
          } : {},
          var.enable_tls ? {
            "cert-manager.io/cluster-issuer"                 = var.tls_cluster_issuer
            "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"
            "nginx.ingress.kubernetes.io/ssl-redirect"       = "true"
          } : {},
        )
        tls = {
          secretName = "kellnr-tls"
        }
      }

      certificate = {
        enabled    = var.enable_tls
        secretName = "kellnr-tls"
        issuerRef = {
          name = var.tls_cluster_issuer
          kind = "ClusterIssuer"
        }
      }

      pvc = {
        enabled          = false # crate blobs live in S3
        storageClassName = var.storage_class != "" ? var.storage_class : "manual"
      }

      kellnr = {
        setup = {
          adminPwd   = random_password.admin_pwd.result
          adminToken = random_password.admin_token.result
        }
        registry = {
          authRequired = var.auth_required
          dataDir      = "/var/lib/kellnr"
        }
        cookieSigningKey = random_password.cookie_signing_key.result
        origin = {
          hostname = var.hostname
          protocol = var.enable_tls ? "https" : "http"
          port     = var.enable_tls ? 443 : 80
        }
        postgres = {
          enabled = true
          address = local.postgresql_host
          port    = 5432
          db      = var.postgresql_database
          user    = var.postgresql_username
          pwd     = random_password.postgresql.result
        }
        s3 = {
          enabled       = true
          accessKey     = var.object_storage.access_key
          secretKey     = var.object_storage.secret_key
          region        = var.object_storage.region
          endpoint      = var.object_storage.endpoint
          allowHttp     = startswith(var.object_storage.endpoint, "http://")
          crates_bucket = var.object_storage.crates_bucket
        }
        oauth2 = var.oidc != null ? {
          enabled            = true
          issuerUrl          = var.oidc.issuer_url
          clientId           = var.oidc.client_id
          clientSecret       = var.oidc.client_secret
          scopes             = "openid,profile,email"
          autoProvisionUsers = true
          adminGroupClaim    = "groups"
          adminGroupValue    = "admins"
          buttonText         = "Login with SSO"
          } : {
          enabled = false
        }
        proxy = {
          enabled = false
        }
        docs = {
          enabled = false
        }
      }
    })
  ]

  depends_on = [
    helm_release.postgresql,
    kubernetes_secret.postgresql,
  ]
}
