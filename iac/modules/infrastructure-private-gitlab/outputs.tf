output "server_public_ip" {
  description = "Public IPv4 address of the bare metal server"
  value       = data.ovh_dedicated_server.gitlab.ip
}

output "server_service_name" {
  description = "OVH service name of the dedicated server"
  value       = data.ovh_dedicated_server.gitlab.service_name
}

output "ssh_command" {
  description = "SSH command to connect to the server as the admin user"
  value       = "ssh -i ${var.ssh_private_key_path} ${var.ssh_user}@${data.ovh_dedicated_server.gitlab.ip}"
}

output "gitlab_url" {
  description = "GitLab URL (accessible only after connecting to WireGuard VPN)"
  value       = "https://${var.gitlab_domain}"
}

output "gitlab_registry_url" {
  description = "GitLab Container Registry URL (accessible only via VPN)"
  value       = "https://${var.gitlab_registry_domain}"
}

output "wireguard_server_endpoint" {
  description = "WireGuard server endpoint for client configuration"
  value       = "${data.ovh_dedicated_server.gitlab.ip}:${var.wireguard_port}"
}

# Render a ready-to-use WireGuard client config for each defined peer.
# Each peer must supply their own PrivateKey (generated on their device).
# Replace <CLIENT_PRIVATE_KEY> with the actual private key.
output "wireguard_client_configs" {
  description = <<-EOT
    WireGuard client configuration for each defined peer.
    Replace <CLIENT_PRIVATE_KEY> with the peer's private key (generated on the client device).
    Add to /etc/hosts on each client: ${var.wireguard_server_vpn_ip} ${var.gitlab_domain} ${var.gitlab_registry_domain}
  EOT
  value = {
    for peer in var.wireguard_peers :
    peer.name => templatefile("${path.module}/templates/wg0-client.conf.tpl", {
      client_vpn_ip     = peer.vpn_ip
      server_public_key = var.wireguard_server_public_key
      server_endpoint   = "${data.ovh_dedicated_server.gitlab.ip}:${var.wireguard_port}"
      vpn_subnet        = var.wireguard_vpn_subnet
      server_vpn_ip     = var.wireguard_server_vpn_ip
    })
  }
}

output "post_deploy_instructions" {
  description = "Step-by-step instructions after a successful apply"
  value       = <<-EOT
    ════════════════════════════════════════════════════════════
    GitLab Infrastructure — Post-Deploy Steps
    ════════════════════════════════════════════════════════════

    1. CONNECT TO WIREGUARD VPN
       Copy your WireGuard client config from wireguard_client_configs output.
       Save it (e.g., /etc/wireguard/wg-gitlab.conf) and connect:
         sudo wg-quick up wg-gitlab

    2. UPDATE /etc/hosts (on each client machine)
       Add:
         ${var.wireguard_server_vpn_ip}  ${var.gitlab_domain}
         ${var.wireguard_server_vpn_ip}  ${var.gitlab_registry_domain}

    3. TRUST THE SELF-SIGNED CERTIFICATE
       Fetch and trust the CA cert (macOS/Linux):
         ssh -i ${var.ssh_private_key_path} ${var.ssh_user}@${data.ovh_dedicated_server.gitlab.ip} \
           "sudo cat /etc/gitlab/ssl/${var.gitlab_domain}.crt" > gitlab-ca.crt
       Then import it into your OS/browser trust store.

    4. ACCESS GITLAB
       URL: https://${var.gitlab_domain}
       User: root
       Password: (the gitlab_root_password variable value)
       ⚠ Change the root password immediately after first login.

    5. DISABLE ROOT SIGN-IN AFTER SETTING UP YOUR ACCOUNT
       Admin Area → Settings → General → Sign-in restrictions

    6. CONFIGURE BACKUP DECRYPTION
       Store your age private key offline (printed/encrypted drive).
       To restore a backup:
         age -d -i /path/to/age-key.txt backup-TIMESTAMP.tar.gz.age > backup.tar.gz
         gitlab-backup restore BACKUP=TIMESTAMP

    7. SSH SERVER ADMIN ACCESS
       ${join("\n       ", [for peer in var.wireguard_peers : "# ${peer.name}: ssh ${var.ssh_user}@${data.ovh_dedicated_server.gitlab.ip}"])}

    ════════════════════════════════════════════════════════════
  EOT
}
