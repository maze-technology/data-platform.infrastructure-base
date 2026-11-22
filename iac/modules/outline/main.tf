resource "kubernetes_namespace_v1" "outline" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/name"    = "outline"
      "app.kubernetes.io/part-of" = "outline"
      environment                 = var.environment
      managed-by                  = "opentofu"
    }
  }
}

locals {
  namespace = var.create_namespace ? kubernetes_namespace_v1.outline[0].metadata[0].name : var.namespace
  hostname  = var.hostname != "" ? var.hostname : "wiki.${var.cluster_domain}"
  url       = var.enable_tls ? "https://${local.hostname}" : "http://${local.hostname}"

  ingress_whitelist = "${var.vpn_cidr},127.0.0.1/32,10.0.0.0/8"

  postgres_cluster_name = "outline-pg"
  postgres_host         = "${local.postgres_cluster_name}-rw.${local.namespace}.svc.cluster.local"

  valkey_release_name = "valkey"
  valkey_host         = "${local.valkey_release_name}.${local.namespace}.svc.cluster.local"

  labels = {
    "app.kubernetes.io/name"    = "outline"
    "app.kubernetes.io/part-of" = "outline"
    environment                 = var.environment
    managed-by                  = "opentofu"
  }
}
