resource "kubernetes_secret_v1" "s3" {
  metadata {
    name      = "outline-s3"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    access-key-id     = var.object_storage.access_key
    secret-access-key = var.object_storage.secret_key
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.outline]
}
