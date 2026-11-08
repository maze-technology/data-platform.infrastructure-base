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

variable "etcd_cpu_request" {
  description = "etcd CPU request enforced on static pod manifests by the CP resource guard."
  type        = string
  default     = "100m"
}

variable "etcd_heartbeat_interval_ms" {
  description = "etcd --heartbeat-interval (ms). Above the 100ms default so HDD fsync stalls do not miss heartbeats."
  type        = number
  default     = 500
}

variable "etcd_election_timeout_ms" {
  description = "etcd --election-timeout (ms). ~10x heartbeat; tolerates multi-second fsync stalls without leader churn."
  type        = number
  default     = 5000
}

variable "etcd_io_weight" {
  description = "io.bfq.weight (1-1000) for the etcd pod cgroup; other pods stay at the default 100."
  type        = number
  default     = 1000
}

variable "root_disk_io_scheduler" {
  description = "I/O scheduler for the root disk holding /var/lib/etcd (bfq is required for etcd_io_weight to apply)."
  type        = string
  default     = "bfq"
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
  description = "How often the guard re-checks manifests, kubelet config and etcd I/O weight (lost when the etcd pod is recreated)."
  type        = number
  default     = 60
}
