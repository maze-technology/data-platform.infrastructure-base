output "cluster_domain" {
  description = "Base domain for cluster services"
  value       = local.cluster_domain
}

output "service_urls" {
  description = "Service URLs (add cluster_domain hosts to /etc/hosts first)"
  value = {
    auth_admin   = "${module.keycloak.admin_console_url}/admin"
    auth_realm   = module.keycloak.issuer_url
    scm          = "http://${local.hosts.scm}${local.gitlab_http_port}"
    registry     = "http://${local.hosts.registry}${local.gitlab_http_port}"
    grafana      = "http://${local.hosts.grafana}${local.ingress_port}"
    argocd       = "http://${local.hosts.argocd}${local.ingress_port}"
    vault        = "http://${local.hosts.vault}${local.ingress_port}"
    vpn_endpoint = "${local.hosts.vpn}:31820/udp"
  }
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
