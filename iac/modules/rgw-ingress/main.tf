terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

locals {
  ingress_whitelist = "${var.vpn_cidr},127.0.0.1/32,10.0.0.0/8"

  labels = {
    app         = "rook-ceph-rgw"
    environment = var.environment
    managed-by  = "opentofu"
  }

  # S3 via nginx: large bodies, long timeouts, HTTP backend to RGW.
  # Clients must use path-style (bucket in URL path); *.s3.<domain> is not routed.
  ingress_annotations = merge(
    {
      "nginx.ingress.kubernetes.io/proxy-body-size"         = "0"
      "nginx.ingress.kubernetes.io/proxy-read-timeout"      = "600"
      "nginx.ingress.kubernetes.io/proxy-send-timeout"      = "600"
      "nginx.ingress.kubernetes.io/proxy-request-buffering" = "off"
      "nginx.ingress.kubernetes.io/backend-protocol"        = "HTTP"
    },
    var.restrict_to_vpn ? {
      "nginx.ingress.kubernetes.io/whitelist-source-range" = local.ingress_whitelist
    } : {},
    var.enable_tls ? {
      "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"
      "nginx.ingress.kubernetes.io/ssl-redirect"       = "true"
    } : {},
  )
}

resource "kubernetes_manifest" "tls_certificate" {
  count = var.enable_tls ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "rgw-s3-tls"
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      secretName = var.tls_secret_name
      dnsNames   = [var.hostname]
      issuerRef = {
        name  = var.tls_cluster_issuer
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
    }
  }
}

resource "kubernetes_ingress_v1" "rgw_s3" {
  metadata {
    name        = "rgw-s3"
    namespace   = var.namespace
    labels      = local.labels
    annotations = local.ingress_annotations
  }

  spec {
    ingress_class_name = var.ingress_class

    dynamic "tls" {
      for_each = var.enable_tls ? [1] : []
      content {
        hosts       = [var.hostname]
        secret_name = var.tls_secret_name
      }
    }

    rule {
      host = var.hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = var.service_name
              port {
                number = var.service_port
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.tls_certificate]
}
