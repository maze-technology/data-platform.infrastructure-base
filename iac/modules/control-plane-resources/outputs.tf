output "daemonset_name" {
  description = "Name of the control-plane static-pod memory guard DaemonSet."
  value       = try(kubernetes_daemon_set_v1.guard[0].metadata[0].name, null)
}
