output "namespace" {
  description = "Kyverno namespace"
  value       = kubernetes_namespace.kyverno.metadata[0].name
}

output "policy_name" {
  description = "ClusterPolicy that enforces cosign verify"
  value       = var.policy_name
}

output "namespace_opt_in_label" {
  description = "Label to set on algo namespaces to require signed images"
  value       = "${var.namespace_label_key}=${var.namespace_label_value}"
}

output "cosign_secret_name" {
  description = "Secret containing cosign.pub"
  value       = kubernetes_secret.cosign_public_key.metadata[0].name
}
