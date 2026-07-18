output "ingress_ip" {
  description = "ClusterIP used for in-cluster maze.local DNS"
  value       = local.ingress_ip
}
