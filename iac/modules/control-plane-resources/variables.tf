variable "enabled" {
  description = "Install the static-pod memory guard DaemonSet on control-plane nodes."
  type        = bool
  default     = true
}

variable "apiserver_memory_request" {
  description = "kube-apiserver memory request (Guaranteed when equal to limit)."
  type        = string
  default     = "1500Mi"
}

variable "apiserver_memory_limit" {
  description = "kube-apiserver memory limit (should match request for Guaranteed QoS)."
  type        = string
  default     = "1500Mi"
}

variable "etcd_memory_request" {
  description = "etcd memory request (Guaranteed when equal to limit)."
  type        = string
  default     = "1Gi"
}

variable "etcd_memory_limit" {
  description = "etcd memory limit (should match request for Guaranteed QoS)."
  type        = string
  default     = "1Gi"
}

variable "reconcile_seconds" {
  description = "How often the guard re-checks /etc/kubernetes/manifests."
  type        = number
  default     = 300
}
