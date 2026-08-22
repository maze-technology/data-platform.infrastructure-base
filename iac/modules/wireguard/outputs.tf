output "namespace" {
  description = "WireGuard namespace name"
  value       = kubernetes_namespace.wireguard.metadata[0].name
}

output "vpn_subnet" {
  description = "WireGuard VPN subnet CIDR"
  value       = var.vpn_subnet
}

output "server_port" {
  description = "WireGuard UDP port"
  value       = var.server_port
}

output "node_port" {
  description = "NodePort for WireGuard (local/kind access)"
  value       = var.service_type == "NodePort" ? var.node_port : null
}

output "peer_configs_command" {
  description = "kubectl command to retrieve generated peer WireGuard configs"
  value       = "kubectl exec -n ${kubernetes_namespace.wireguard.metadata[0].name} ds/wireguard -c wireguard -- cat /config/peer_<name>/peer_<name>.conf"
}
