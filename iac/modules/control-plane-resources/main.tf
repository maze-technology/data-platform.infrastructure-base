# On shared CP nodes: (1) Guaranteed memory (+ etcd CPU) for kubeadm static pods
# (apiserver/etcd), (2) kubelet kubeReserved/systemReserved + evictionHard so Node
# Allocatable cannot be filled with CI to the point the OS/kubelet/apiserver starve,
# (3) etcd survives slow fsync on the shared root HDD: bfq scheduler with a high
# etcd I/O weight, and raft heartbeat/election timeouts sized for HDD latency.

locals {
  guard_script = <<-SCRIPT
    set -eu
    MANIFESTS=/host/etc/kubernetes/manifests
    KUBELET_CFG=/host/var/lib/kubelet/config.yaml
    HOST_CGROUP=/host-root/sys/fs/cgroup
    APISERVER_REQ="${var.apiserver_memory_request}"
    APISERVER_LIM="${var.apiserver_memory_limit}"
    ETCD_REQ="${var.etcd_memory_request}"
    ETCD_LIM="${var.etcd_memory_limit}"
    ETCD_CPU_REQ="${var.etcd_cpu_request}"
    ETCD_HEARTBEAT_MS="${var.etcd_heartbeat_interval_ms}"
    ETCD_ELECTION_MS="${var.etcd_election_timeout_ms}"
    ETCD_IO_WEIGHT="${var.etcd_io_weight}"
    IO_SCHEDULER="${var.root_disk_io_scheduler}"
    KUBE_RES_CPU="${var.kube_reserved_cpu}"
    KUBE_RES_MEM="${var.kube_reserved_memory}"
    SYS_RES_CPU="${var.system_reserved_cpu}"
    SYS_RES_MEM="${var.system_reserved_memory}"
    EVICT_MEM="${var.eviction_hard_memory_available}"
    FLAG=/host/var/lib/kubelet/.maze-cp-reserve-restart

    ensure_resources() {
      file="$1"
      mem_req="$2"
      mem_lim="$3"
      cpu_req="$4"
      [ -f "$file" ] || return 0

      cur_mem_req=$(yq -r '.spec.containers[0].resources.requests.memory // ""' "$file")
      cur_mem_lim=$(yq -r '.spec.containers[0].resources.limits.memory // ""' "$file")
      cur_cpu_req=$(yq -r '.spec.containers[0].resources.requests.cpu // ""' "$file")
      if [ "$cur_mem_req" = "$mem_req" ] && [ "$cur_mem_lim" = "$mem_lim" ] && [ "$cur_cpu_req" = "$cpu_req" ]; then
        return 0
      fi

      echo "patching $file cpu=$cpu_req memory request=$mem_req limit=$mem_lim (was cpu=$cur_cpu_req mem_req=$cur_mem_req mem_lim=$cur_mem_lim)"
      yq -i "
        .spec.containers[0].resources.requests.cpu = \"$cpu_req\" |
        .spec.containers[0].resources.requests.memory = \"$mem_req\" |
        .spec.containers[0].resources.limits.cpu = (.spec.containers[0].resources.limits.cpu // \"2000m\") |
        .spec.containers[0].resources.limits.memory = \"$mem_lim\"
      " "$file"
    }

    ensure_kubelet_reserved() {
      [ -f "$KUBELET_CFG" ] || return 0
      desired="$KUBE_RES_MEM|$SYS_RES_MEM|$EVICT_MEM"

      cur_kube_mem=$(yq -r '.kubeReserved.memory // ""' "$KUBELET_CFG")
      cur_sys_mem=$(yq -r '.systemReserved.memory // ""' "$KUBELET_CFG")
      cur_evict=$(yq -r '.evictionHard."memory.available" // ""' "$KUBELET_CFG")
      if [ "$cur_kube_mem" != "$KUBE_RES_MEM" ] || [ "$cur_sys_mem" != "$SYS_RES_MEM" ] || [ "$cur_evict" != "$EVICT_MEM" ]; then
        echo "patching kubelet reserved kube=$KUBE_RES_CPU/$KUBE_RES_MEM sys=$SYS_RES_CPU/$SYS_RES_MEM evictionHard.memory.available=$EVICT_MEM"
        yq -i "
          .kubeReserved.cpu = \"$KUBE_RES_CPU\" |
          .kubeReserved.memory = \"$KUBE_RES_MEM\" |
          .systemReserved.cpu = \"$SYS_RES_CPU\" |
          .systemReserved.memory = \"$SYS_RES_MEM\" |
          .evictionHard.\"memory.available\" = \"$EVICT_MEM\"
        " "$KUBELET_CFG"
      fi

      cur_flag=$(cat "$FLAG" 2>/dev/null || true)
      if [ "$cur_flag" = "$desired" ]; then
        return 0
      fi

      echo "restarting kubelet to apply reserved/eviction"
      # yq image cannot exec host ELF binaries directly (missing dynamic linker).
      # chroot into the host rootfs and restart kubelet there.
      if chroot /host-root /bin/systemctl restart kubelet; then
        echo "$desired" > "$FLAG"
      else
        echo "WARN: kubelet restart failed (will retry next loop)" >&2
      fi
    }

    # Changing flags restarts etcd; patching every CP node at once (fresh rollout)
    # briefly drops quorum, so roll new values node by node by hand first.
    ensure_etcd_flags() {
      file="$MANIFESTS/etcd.yaml"
      [ -f "$file" ] || return 0

      cur_hb=$(yq -r '.spec.containers[0].command[] | select(test("^--heartbeat-interval="))' "$file" | cut -d= -f2)
      cur_el=$(yq -r '.spec.containers[0].command[] | select(test("^--election-timeout="))' "$file" | cut -d= -f2)
      if [ "$cur_hb" = "$ETCD_HEARTBEAT_MS" ] && [ "$cur_el" = "$ETCD_ELECTION_MS" ]; then
        return 0
      fi

      echo "patching $file heartbeat-interval=$ETCD_HEARTBEAT_MS election-timeout=$ETCD_ELECTION_MS (was $cur_hb/$cur_el)"
      yq -i "
        .spec.containers[0].command |= (map(select(test(\"^--(heartbeat-interval|election-timeout)=\") | not)) + [\"--heartbeat-interval=$ETCD_HEARTBEAT_MS\", \"--election-timeout=$ETCD_ELECTION_MS\"])
      " "$file"
    }

    # mq-deadline ignores cgroup I/O weights; bfq honours io.bfq.weight, so etcd
    # fsyncs get served ahead of CI build writes on the same root disk.
    ensure_io_priority() {
      dev=$(chroot /host-root lsblk -no PKNAME "$(chroot /host-root findmnt -no SOURCE /)" 2>/dev/null || true)
      [ -n "$dev" ] || return 0

      sched=/sys/block/$dev/queue/scheduler
      if ! grep -q "\[$IO_SCHEDULER\]" "$sched"; then
        chroot /host-root modprobe "$IO_SCHEDULER" 2>/dev/null || true
        echo "setting /dev/$dev scheduler=$IO_SCHEDULER (was: $(cat "$sched"))"
        echo "$IO_SCHEDULER" > "$sched" || { echo "WARN: could not set scheduler on /dev/$dev" >&2; return 0; }
      fi

      pid=$(chroot /host-root pgrep -x etcd | head -1 || true)
      [ -n "$pid" ] || return 0
      scope=$(sed 's/^0:://' "/proc/$pid/cgroup")
      for cg in "$(dirname "$scope")" "$scope"; do
        f="$HOST_CGROUP$cg/io.bfq.weight"
        [ -w "$f" ] || continue
        if ! head -1 "$f" | grep -qx "default $ETCD_IO_WEIGHT"; then
          echo "setting $cg io.bfq.weight=$ETCD_IO_WEIGHT"
          echo "default $ETCD_IO_WEIGHT" > "$f"
        fi
      done
    }

    while true; do
      ensure_resources "$MANIFESTS/kube-apiserver.yaml" "$APISERVER_REQ" "$APISERVER_LIM" "250m"
      ensure_resources "$MANIFESTS/etcd.yaml" "$ETCD_REQ" "$ETCD_LIM" "$ETCD_CPU_REQ"
      ensure_etcd_flags
      ensure_io_priority
      ensure_kubelet_reserved
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
          name = "guard"
          # Debian-based so nsenter/systemctl path works via host nsenter binary;
          # image still provides yq. Use mikefarah/yq but call host nsenter.
          image = "mikefarah/yq:4.44.3"

          command = ["/bin/sh", "-ec", local.guard_script]

          security_context {
            privileged                 = true
            run_as_user                = 0
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
            name       = "kubernetes"
            mount_path = "/host/etc/kubernetes"
            read_only  = false
          }

          volume_mount {
            name       = "kubelet"
            mount_path = "/host/var/lib/kubelet"
            read_only  = false
          }

          volume_mount {
            name       = "host-root"
            mount_path = "/host-root"
            read_only  = true
          }
        }

        volume {
          name = "kubernetes"
          host_path {
            path = "/etc/kubernetes"
            type = "Directory"
          }
        }

        volume {
          name = "kubelet"
          host_path {
            path = "/var/lib/kubelet"
            type = "Directory"
          }
        }

        volume {
          name = "host-root"
          host_path {
            path = "/"
            type = "Directory"
          }
        }
      }
    }
  }
}
