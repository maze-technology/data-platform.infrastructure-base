variable "enabled" {
  description = "Deploy the self-hosted Renovate CronJob for GitLab"
  type        = bool
  default     = true
}

variable "environment" {
  description = "Environment name (local, production)"
  type        = string
}

variable "gitlab_namespace" {
  description = "Kubernetes namespace where GitLab runs"
  type        = string
}

variable "gitlab_endpoint" {
  description = "GitLab API v4 base URL reachable from the CronJob pod (prefer in-cluster HTTP)"
  type        = string
}

variable "schedule_cron" {
  description = "Cron schedule for Renovate runs"
  type        = string
  default     = "0 */2 * * *"
}

variable "image" {
  description = "Renovate container image (pin a SemVer tag)"
  type        = string
  default     = "renovate/renovate:43.239.0"
}

variable "bot_username" {
  description = "GitLab username for the Renovate bot"
  type        = string
  default     = "renovate-bot"
}

variable "bot_email" {
  description = "GitLab email / git author email for the Renovate bot"
  type        = string
  default     = "renovate@maze.trading"
}

variable "bot_name" {
  description = "Display name for the Renovate bot"
  type        = string
  default     = "Renovate Bot"
}

variable "autodiscover_filters" {
  description = "Renovate autodiscoverFilter globs (limit which GitLab projects are scanned)"
  type        = list(string)
  default     = ["data-platform/**", "templates/**"]
}

variable "group_paths" {
  description = "GitLab groups the bot is added to as Maintainer (required for MR creation)"
  type        = list(string)
  default     = ["data-platform", "templates"]
}

variable "github_com_token" {
  description = "Optional github.com PAT for changelogs / release notes (avoids strict unauthenticated rate limits)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "custom_ca_pem" {
  description = "Optional PEM CA bundle for trusting GitLab TLS (local maze-ca). Empty in production (public LE)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "log_level" {
  description = "Renovate LOG_LEVEL"
  type        = string
  default     = "info"
}

variable "api_token_secret_name" {
  description = "Kubernetes Secret name storing the Renovate GitLab PAT"
  type        = string
  default     = "renovate-gitlab-token"
}
