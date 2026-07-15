output "cluster_domain" {
  description = "Base domain for cluster services"
  value       = local.cluster_domain
}

output "service_urls" {
  description = "Service URLs (VPN + /etc/hosts → ClusterIPs; trust Maze CA or accept browser warning)"
  value = {
    auth_admin   = "${module.keycloak.admin_console_url}/admin"
    auth_realm   = module.keycloak.issuer_url
    scm          = "https://${local.hosts.scm}"
    registry     = "https://${local.hosts.registry}"
    grafana      = "https://${local.hosts.grafana}"
    argocd       = "https://${local.hosts.argocd}"
    vault        = "https://${local.hosts.vault}"
    vpn_endpoint = "${local.hosts.vpn}:31820/udp"
  }
}

output "maze_ca_install_hint" {
  description = "How to export the Maze CA for trusting local HTTPS (optional)"
  value       = "kubectl get secret maze-ca -n cert-manager -o jsonpath='{.data.ca\\.crt}' | base64 -d > maze-ca.crt"
}

output "etc_hosts" {
  description = "Lines to add to /etc/hosts — replace VPS_IP with your server public IP"
  value = var.cluster_public_ip != "" ? join("\n", [
    for host in values(local.hosts) : "${var.cluster_public_ip}  ${host}"
  ]) : <<-EOT
    # Set cluster_public_ip in terraform.tfvars to generate ready-to-paste lines
    # Example (replace VPS_IP):
    ${join("\n", [for host in values(local.hosts) : "# VPS_IP  ${host}"])}
  EOT
}

output "wireguard_peer_config_command" {
  description = "Retrieve WireGuard config for bootstrap admin (run on machine with kubectl access)"
  value       = "kubectl exec -n wireguard deploy/wireguard -- cat /config/peer_${nonsensitive(var.bootstrap_admin.username)}/peer_${nonsensitive(var.bootstrap_admin.username)}.conf"
}

output "bootstrap_credentials" {
  description = "Initial credentials configured via terraform.tfvars"
  sensitive   = true
  value = {
    keycloak_master = {
      username = var.keycloak_admin_username
      url      = "${module.keycloak.admin_console_url}/admin"
    }
    platform_admin = {
      username = var.bootstrap_admin.username
      realm    = module.keycloak.realm
      note     = "Use SSO login on services, or Keycloak admin console to manage users"
    }
  }
}
