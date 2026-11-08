output "hostname" {
  description = "S3 API hostname (VPN / CoreDNS)"
  value       = var.hostname
}

output "endpoint" {
  description = "S3 API URL reachable over VPN via ingress"
  value       = var.enable_tls ? "https://${var.hostname}" : "http://${var.hostname}"
}

output "ingress_name" {
  description = "Ingress resource name"
  value       = kubernetes_ingress_v1.rgw_s3.metadata[0].name
}
