# Kind / bare clusters only put maze.local names in client /etc/hosts.
# Pods (GitLab/Grafana/Argo OIDC) still need to resolve those names to the
# ingress ClusterIP so server-side token exchange can reach Keycloak.

data "kubernetes_service" "ingress" {
  metadata {
    name      = var.ingress_service_name
    namespace = var.ingress_namespace
  }
}

locals {
  ingress_ip = data.kubernetes_service.ingress.spec[0].cluster_ip
  corefile = <<-EOT
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    hosts {
${join("\n", [for h in var.hosts : "        ${local.ingress_ip} ${h}"])}
       fallthrough
    }
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30 {
       disable success cluster.local
       disable denial cluster.local
    }
    loop
    reload
    loadbalance
}
EOT
}

resource "kubernetes_config_map_v1_data" "coredns_hosts" {
  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }
  data = {
    Corefile = local.corefile
  }
  force = true
}

resource "null_resource" "restart_coredns" {
  triggers = {
    corefile = local.corefile
  }

  provisioner "local-exec" {
    command = "kubectl -n kube-system rollout restart deploy/coredns && kubectl -n kube-system rollout status deploy/coredns --timeout=120s"
  }

  depends_on = [kubernetes_config_map_v1_data.coredns_hosts]
}
