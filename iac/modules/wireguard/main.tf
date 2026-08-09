locals {
  # kind defaults: services 10.96.0.0/12, pods 10.244.0.0/16 — avoid full 10.0.0.0/8
  allowed_ips = var.allowed_ips != "" ? var.allowed_ips : "${var.vpn_subnet},10.96.0.0/12,10.244.0.0/16"
  # Client Endpoint must use NodePort when service_type=NodePort (container still listens on server_port).
  peer_endpoint_port = var.service_type == "NodePort" ? var.node_port : var.server_port
}

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
        # Ubuntu 25+/26 ships an AppArmor wg-quick profile that breaks
        # linuxserver's busybox readlink inside the container.
        annotations = {
          "container.apparmor.security.beta.kubernetes.io/wireguard" = "unconfined"
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
            value = var.peer_dns != "" ? var.peer_dns : "auto"
          }
          env {
            name  = "INTERNAL_SUBNET"
            value = var.vpn_subnet
          }
          env {
            name  = "ALLOWEDIPS"
            value = local.allowed_ips
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
            privileged                 = true
            allow_privilege_escalation = true
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

# Patch peer templates + generated confs after deploy:
# - NodePort: Endpoint must use node_port (container listens on server_port)
# - Always: MTU=1280 (avoids TLS blackholes over WG), DNS/AllowedIPs, no ListenPort
# - Server PostUp: TCP MSS clamp for the same MTU path issue
resource "null_resource" "patch_peer_endpoint_port" {
  triggers = {
    deploy       = kubernetes_deployment.wireguard.id
    peers        = var.peers
    nodeport     = tostring(var.node_port)
    listen       = tostring(var.server_port)
    dns          = var.peer_dns
    allowed      = local.allowed_ips
    service_type = var.service_type
    peer_mtu     = "1280"
    patch_script = filesha256("${path.module}/patch-peer-confs.sh")
    peer_tpl     = filesha256("${path.module}/templates/peer.conf")
  }

  provisioner "local-exec" {
    command = "${path.module}/patch-peer-confs.sh"
    environment = {
      WG_NS           = var.namespace
      WG_LISTEN       = tostring(var.server_port)
      WG_NODEPORT     = tostring(var.node_port)
      WG_DNS          = var.peer_dns
      WG_ALLOWED      = local.allowed_ips
      WG_SERVICE_TYPE = var.service_type
      WG_PEER_MTU     = "1280"
    }
  }

  depends_on = [kubernetes_deployment.wireguard, kubernetes_service.wireguard]
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
