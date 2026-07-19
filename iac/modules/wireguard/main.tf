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

# linuxserver writes Endpoint with SERVERPORT (container listen port). On kind NodePort,
# clients must dial node_port instead — patch generated peer confs once the deploy is ready.
resource "null_resource" "patch_peer_endpoint_port" {
  count = var.service_type == "NodePort" ? 1 : 0

  triggers = {
    deploy   = kubernetes_deployment.wireguard.id
    peers    = var.peers
    nodeport = tostring(var.node_port)
    listen   = tostring(var.server_port)
    dns      = var.peer_dns
    allowed  = local.allowed_ips
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      WG_NS       = var.namespace
      WG_LISTEN   = tostring(var.server_port)
      WG_NODEPORT = tostring(var.node_port)
      WG_DNS      = var.peer_dns
      WG_ALLOWED  = local.allowed_ips
    }
    command = <<-EOT
      set -euo pipefail
      kubectl -n "$${WG_NS}" rollout status deploy/wireguard --timeout=300s
      for i in $(seq 1 60); do
        if kubectl -n "$${WG_NS}" exec deploy/wireguard -- sh -c 'ls /config/peer_*/*.conf >/dev/null 2>&1'; then
          break
        fi
        sleep 2
      done
      # Expand WG_* locally; pass \$f to the container shell.
      kubectl -n "$${WG_NS}" exec deploy/wireguard -- /bin/sh -c "
        set -e
        for f in /config/peer_*/*.conf; do
          [ -f \"\$f\" ] || continue
          sed -i \"s/^Endpoint = \\(.*\\):$${WG_LISTEN}\$/Endpoint = \\1:$${WG_NODEPORT}/\" \"\$f\"
          if [ -n \"$${WG_DNS}\" ]; then
            sed -i \"s/^DNS = .*/DNS = $${WG_DNS}/\" \"\$f\"
          fi
          sed -i \"s|^AllowedIPs = .*|AllowedIPs = $${WG_ALLOWED}|\" \"\$f\"
          sed -i '/^ListenPort = /d' \"\$f\"
          echo patched \"\$f\"
          grep -E '^(DNS|Endpoint|AllowedIPs)' \"\$f\" || true
        done
      "
    EOT
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
