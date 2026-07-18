variable "gitlab_namespace" {
  description = "Kubernetes namespace where GitLab is installed"
  type        = string
  default     = "gitlab"
}

variable "org_group_path" {
  description = "Top-level GitLab group shared with all engineers (e.g. maze)"
  type        = string
  default     = "maze"
}

variable "org_group_name" {
  description = "Display name for the org group"
  type        = string
  default     = "maze"
}

variable "engineers_gitlab_group" {
  description = "OIDC-synced GitLab group for engineers (Maintainer on org group)"
  type        = string
  default     = "engineers"
}

variable "admin_gitlab_group" {
  description = "OIDC-synced GitLab group for admins (Owner on org group). Empty skips."
  type        = string
  default     = "admins"
}

variable "delete_group_paths" {
  description = "GitLab group full paths to delete if present (obsolete algo ACL groups)"
  type        = list(string)
  default     = ["maze/algorithms", "maze/algos", "algotrader-engineers"]
}

variable "vault_kv_mount" {
  description = "Vault KV mount"
  type        = string
  default     = "secret"
}

variable "vault_secret_path" {
  description = "Vault path under mount for cosign material"
  type        = string
  default     = "cosign/gitlab"
}

variable "api_token_secret_name" {
  description = "Kubernetes Secret storing the OpenTofu GitLab API PAT"
  type        = string
  default     = "opentofu-gitlab-api-token"
}
