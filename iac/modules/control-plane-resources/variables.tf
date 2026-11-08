variable "enabled" {
  description = "Install the static-pod / kubelet reserve guard DaemonSet on control-plane nodes."
  type        = bool
  default     = true
}

variable "apiserver_memory_request" {
  description = "kube-apiserver memory request (Guaranteed when equal to limit)."
  type        = string
  default     = "3Gi"
}

variable "apiserver_memory_limit" {
  description = "kube-apiserver memory limit (should match request for Guaranteed QoS)."
  type        = string
  default     = "3Gi"
}

variable "etcd_memory_request" {
  description = "etcd memory request (Guaranteed when equal to limit)."
  type        = string
  default     = "2Gi"
}

variable "etcd_memory_limit" {
  description = "etcd memory limit (should match request for Guaranteed QoS)."
  type        = string
  default     = "2Gi"
}

variable "kube_reserved_cpu" {
  description = "kubelet kubeReserved.cpu (kubernetes system daemons)."
  type        = string
  default     = "500m"
}

variable "kube_reserved_memory" {
  description = "kubelet kubeReserved.memory — shrinks Node Allocatable so CI cannot schedule into kubelet/runtime RAM."
  type        = string
  default     = "2Gi"
}

variable "system_reserved_cpu" {
  description = "kubelet systemReserved.cpu (OS daemons)."
  type        = string
  default     = "500m"
}

variable "system_reserved_memory" {
  description = "kubelet systemReserved.memory — shrinks Node Allocatable so CI cannot schedule into OS RAM."
  type        = string
  default     = "2Gi"
}

variable "eviction_hard_memory_available" {
  description = "kubelet evictionHard memory.available threshold (e.g. 1Gi)."
  type        = string
  default     = "1Gi"
}

variable "reconcile_seconds" {
  description = "How often the guard re-checks manifests and kubelet config."
  type        = number
  default     = 300
}
