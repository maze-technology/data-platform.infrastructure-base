output "server_public_ip" {
  description = "Public IP of the GitLab bare metal server"
  value       = module.gitlab.server_public_ip
}

output "ssh_command" {
  description = "SSH command to connect to the server"
  value       = module.gitlab.ssh_command
}

output "gitlab_url" {
  description = "GitLab URL (requires WireGuard VPN connection)"
  value       = module.gitlab.gitlab_url
}

output "gitlab_registry_url" {
  description = "GitLab Container Registry URL (requires WireGuard VPN)"
  value       = module.gitlab.gitlab_registry_url
}

output "wireguard_server_endpoint" {
  description = "WireGuard server endpoint (public_ip:port)"
  value       = module.gitlab.wireguard_server_endpoint
}

output "wireguard_client_configs" {
  description = "Ready-to-use WireGuard client configs for each peer (replace <CLIENT_PRIVATE_KEY>)"
  value       = module.gitlab.wireguard_client_configs
  sensitive   = false # Keys are placeholders — actual private keys stay on client devices
}

output "post_deploy_instructions" {
  description = "Step-by-step guide for completing the setup after tofu apply"
  value       = module.gitlab.post_deploy_instructions
}
