# Patches kubeadm static-pod manifests on each control-plane node so apiserver
# and etcd get Guaranteed memory (request == limit). Without this, kubeadm
# defaults leave apiserver with no memory request and the OOM killer prefers it
# under CI pressure.

locals {
  guard_script = <<-SCRIPT
    set -eu
    MANIFESTS=/host/etc/kubernetes/manifests
    APISERVER_REQ="${var.apiserver_memory_request}"
    APISERVER_LIM="${var.apiserver_memory_limit}"
    ETCD_REQ="${var.etcd_memory_request}"
    ETCD_LIM="${var.etcd_memory_limit}"

    ensure_resources() {
      file="$1"
      mem_req="$2"
      mem_lim="$3"
      cpu_req_default="$4"
      [ -f "$file" ] || return 0

      cur_req=$(yq -r '.spec.containers[0].resources.requests.memory // ""' "$file")
      cur_lim=$(yq -r '.spec.containers[0].resources.limits.memory // ""' "$file")
      if [ "$cur_req" = "$mem_req" ] && [ "$cur_lim" = "$mem_lim" ]; then
        return 0
      fi

      echo "patching $file memory request=$mem_req limit=$mem_lim (was req=$cur_req lim=$cur_lim)"
      cpu_req=$(yq -r ".spec.containers[0].resources.requests.cpu // \"$cpu_req_default\"" "$file")
      yq -i "
        .spec.containers[0].resources.requests.cpu = \"$cpu_req\" |
        .spec.containers[0].resources.requests.memory = \"$mem_req\" |
        .spec.containers[0].resources.limits.cpu = (.spec.containers[0].resources.limits.cpu // \"2000m\") |
        .spec.containers[0].resources.limits.memory = \"$mem_lim\"
      " "$file"
    }

    while true; do
      ensure_resources "$MANIFESTS/kube-apiserver.yaml" "$APISERVER_REQ" "$APISERVER_LIM" "250m"
      ensure_resources "$MANIFESTS/etcd.yaml" "$ETCD_REQ" "$ETCD_LIM" "100m"
      sleep "${var.reconcile_seconds}"
    done
  SCRIPT
}

resource "kubernetes_service_account_v1" "guard" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "maze-cp-resource-guard"
    namespace = "kube-system"
    labels = {
      managed-by = "opentofu"
      purpose    = "control-plane-memory"
    }
  }
}

resource "kubernetes_daemon_set_v1" "guard" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "maze-cp-resource-guard"
    namespace = "kube-system"
    labels = {
      app        = "maze-cp-resource-guard"
      managed-by = "opentofu"
      purpose    = "control-plane-memory"
    }
  }

  spec {
    selector {
      match_labels = {
        app = "maze-cp-resource-guard"
      }
    }

    template {
      metadata {
        labels = {
          app     = "maze-cp-resource-guard"
          purpose = "control-plane-memory"
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.guard[0].metadata[0].name
        host_network         = true
        host_pid             = true
        priority_class_name  = "system-node-critical"

        node_selector = {
          "node-role.kubernetes.io/control-plane" = ""
        }

        toleration {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        toleration {
          key      = "node-role.kubernetes.io/master"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        container {
          name  = "guard"
          image = "mikefarah/yq:4.44.3"

          command = ["/bin/sh", "-ec", local.guard_script]

          security_context {
            privileged                 = true
            run_as_user                = 0
            run_as_group               = 0
            allow_privilege_escalation = true
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }

          volume_mount {
            name       = "host"
            mount_path = "/host"
            read_only  = false
          }
        }

        volume {
          name = "host"
          host_path {
            path = "/"
            type = "Directory"
          }
        }
      }
    }
  }
}
