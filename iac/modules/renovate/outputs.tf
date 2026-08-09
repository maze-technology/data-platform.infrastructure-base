output "cronjob_name" {
  description = "Renovate CronJob name (empty when disabled)"
  value       = try(kubernetes_cron_job_v1.renovate[0].metadata[0].name, "")
}

output "bot_username" {
  description = "GitLab username used by Renovate"
  value       = var.bot_username
}
