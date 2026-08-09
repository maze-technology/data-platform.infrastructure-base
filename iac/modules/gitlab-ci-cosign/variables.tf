variable "gitlab_namespace" {
  description = "Kubernetes namespace where GitLab is installed"
  type        = string
  default     = "gitlab"
}

variable "org_group_path" {
  description = "Optional top-level GitLab group to create and share with engineers/admins. Empty skips (no default org group)."
  type        = string
  default     = ""
}

variable "org_group_name" {
  description = "Display name for org_group_path when set"
  type        = string
  default     = ""
}

variable "engineers_gitlab_group" {
  description = "OIDC-synced GitLab group for engineers (ACL roster only)"
  type        = string
  default     = "engineers"
}

variable "admin_gitlab_group" {
  description = "OIDC-synced GitLab group for admins (ACL roster only). Empty skips."
  type        = string
  default     = "admins"
}

variable "delete_group_paths" {
  description = "GitLab group full paths to delete if present (unused default org + obsolete ACL groups)"
  type        = list(string)
  default     = ["maze", "maze/algorithms", "maze/algos", "algotrader-engineers"]
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
