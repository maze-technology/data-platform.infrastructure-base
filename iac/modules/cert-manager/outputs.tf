output "namespace" {
  description = "Namespace where cert-manager is installed"
  value       = var.namespace
}

output "cluster_issuer_name" {
  description = "Default ClusterIssuer name for ingress TLS annotations"
  value = coalesce(
    var.create_maze_ca ? "maze-ca" : null,
    var.letsencrypt_email != "" ? "letsencrypt-prod" : null,
  )
}

output "maze_ca_secret_name" {
  description = "Kubernetes secret containing the Maze CA certificate (install on clients to trust local HTTPS)"
  value       = var.create_maze_ca ? "maze-ca" : null
}

