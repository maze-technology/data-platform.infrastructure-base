resource "kubernetes_namespace" "wireguard" {
  metadata {
    name = var.namespace
    labels = {
      name        = var.namespace
      environment = var.environment
      managed-by  = "opentofu"
    }
  }
}

resource "kubernetes_persistent_volume_claim" "wireguard_config" {
  metadata {
    name      = "wireguard-config"
    namespace = kubernetes_namespace.wireguard.metadata[0].name
    labels = {
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = var.storage_size
      }
    }
    storage_class_name = var.storage_class != "" ? var.storage_class : null
  }

  wait_until_bound = false
}

resource "kubernetes_deployment" "wireguard" {
  metadata {
    name      = "wireguard"
    namespace = kubernetes_namespace.wireguard.metadata[0].name
    labels = {
      app         = "wireguard"
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "wireguard"
      }
    }

    template {
      metadata {
        labels = {
          app = "wireguard"
        }
      }

      spec {
        container {
          name  = "wireguard"
          image = "lscr.io/linuxserver/wireguard:latest"

          env {
            name  = "PUID"
            value = "1000"
          }
          env {
            name  = "PGID"
            value = "1000"
          }
          env {
            name  = "TZ"
            value = "UTC"
          }
          env {
            name  = "SERVERURL"
            value = var.server_url
          }
          env {
            name  = "SERVERPORT"
            value = tostring(var.server_port)
          }
          env {
            name  = "PEERS"
            value = var.peers
          }
          env {
            name  = "PEERDNS"
            value = "auto"
          }
          env {
            name  = "INTERNAL_SUBNET"
            value = var.vpn_subnet
          }
          env {
            name  = "ALLOWEDIPS"
            value = var.vpn_subnet
          }
          env {
            name  = "LOG_CONFS"
            value = "true"
          }

          port {
            container_port = var.server_port
            protocol       = "UDP"
          }

          security_context {
            capabilities {
              add = ["NET_ADMIN", "SYS_MODULE"]
            }
            privileged = true
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "lib-modules"
            mount_path = "/lib/modules"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.wireguard_config.metadata[0].name
          }
        }

        volume {
          name = "lib-modules"
          host_path {
            path = "/lib/modules"
            type = "Directory"
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.wireguard]
}

resource "kubernetes_service" "wireguard" {
  metadata {
    name      = "wireguard"
    namespace = kubernetes_namespace.wireguard.metadata[0].name
    labels = {
      app         = "wireguard"
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  spec {
    type = var.service_type

    selector = {
      app = "wireguard"
    }

    port {
      name        = "wireguard"
      port        = var.server_port
      target_port = var.server_port
      protocol    = "UDP"
      node_port   = var.service_type == "NodePort" ? var.node_port : null
    }
  }

  depends_on = [kubernetes_deployment.wireguard]
}
