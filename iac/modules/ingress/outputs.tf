output "ingress_class" {
  description = "Ingress class name"
  value       = var.ingress_class
}

output "namespace" {
  description = "Namespace where ingress controller is installed"
  value       = var.namespace
}

output "service_name" {
  description = "Name of the ingress controller service"
  value       = "${var.namespace}-controller"
}

output "service_type" {
  description = "Service type of the ingress controller"
  value       = var.service_type
}

