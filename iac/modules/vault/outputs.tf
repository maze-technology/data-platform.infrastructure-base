# Outputs for Vault module

output "namespace" {
  description = "Namespace where Vault is installed"
  value       = kubernetes_namespace.vault.metadata[0].name
}

output "vault_service_name" {
  description = "Name of the Vault Kubernetes Service"
  value       = "vault"
}

output "vault_service_namespace" {
  description = "Namespace of the Vault Kubernetes Service"
  value       = kubernetes_namespace.vault.metadata[0].name
}

output "vault_endpoint" {
  description = "Vault endpoint URL"
  value       = "http://vault.${kubernetes_namespace.vault.metadata[0].name}.svc.cluster.local:8200"
}

output "vault_ui_endpoint" {
  description = "Vault UI endpoint (if ingress is enabled)"
  value       = var.ingress_enabled ? "http://${var.ingress_host}" : "http://vault.${kubernetes_namespace.vault.metadata[0].name}.svc.cluster.local:8200/ui"
}

output "helm_release" {
  description = "Helm release resource for dependencies"
  value       = helm_release.vault
}
