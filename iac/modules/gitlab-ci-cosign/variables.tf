variable "gitlab_namespace" {
  description = "Kubernetes namespace where GitLab is installed"
  type        = string
  default     = "gitlab"
}

variable "group_full_path" {
  description = "Full path of the GitLab group that receives COSIGN_* CI variables (e.g. maze/algos)"
  type        = string
  default     = "maze/algos"
}

variable "group_name" {
  description = "Display name for the leaf group"
  type        = string
  default     = "algos"
}

variable "parent_group_name" {
  description = "Display name for the parent group (first path segment)"
  type        = string
  default     = "maze"
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
