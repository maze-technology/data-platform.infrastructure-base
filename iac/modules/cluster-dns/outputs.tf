output "ingress_ip" {
  description = "ClusterIP used for in-cluster maze.local DNS"
  value       = local.ingress_ip
}

output "corefile" {
  description = "Rendered CoreDNS Corefile (for dependent patches that must re-run after DNS rewrite)"
  value       = local.corefile
}
