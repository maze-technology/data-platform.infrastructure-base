# Cosign signing keys for GitLab Container Registry images.
# Generates a key pair once and stores it in Vault KV (idempotent).
# Requires VAULT_ADDR + VAULT_TOKEN in the apply environment (same as other Vault modules).

terraform {
  required_providers {
    random = {
      source = "hashicorp/random"
    }
  }
}

variable "vault_kv_mount" {
  description = "Vault KV v2 mount path"
  type        = string
  default     = "secret"
}

variable "vault_secret_path" {
  description = "Path under the KV mount for cosign material"
  type        = string
  default     = "cosign/gitlab"
}

variable "cosign_password" {
  description = "Password protecting the cosign private key. Empty generates a random one stored only in Vault."
  type        = string
  sensitive   = true
  default     = ""
}

variable "cosign_image" {
  description = "Container image used to run cosign generate-key-pair"
  type        = string
  default     = "gcr.io/projectsigstore/cosign:v2.4.3"
}

resource "random_password" "cosign" {
  count   = var.cosign_password == "" ? 1 : 0
  length  = 32
  special = false
}

locals {
  cosign_password = var.cosign_password != "" ? var.cosign_password : random_password.cosign[0].result
}

resource "null_resource" "cosign_keys" {
  triggers = {
    mount      = var.vault_kv_mount
    path       = var.vault_secret_path
    generation = "1"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      COSIGN_PASSWORD   = local.cosign_password
      VAULT_KV_MOUNT    = var.vault_kv_mount
      VAULT_SECRET_PATH = var.vault_secret_path
      COSIGN_IMAGE      = var.cosign_image
    }
    command = <<-EOT
      set -euo pipefail
      if [ -z "$${VAULT_ADDR:-}" ] || [ -z "$${VAULT_TOKEN:-}" ]; then
        echo "VAULT_ADDR and VAULT_TOKEN must be set in the apply environment" >&2
        exit 1
      fi
      if vault kv get -mount="$${VAULT_KV_MOUNT}" "$${VAULT_SECRET_PATH}" >/dev/null 2>&1; then
        echo "cosign keys already present at $${VAULT_KV_MOUNT}/$${VAULT_SECRET_PATH}"
        exit 0
      fi
      TMP="$(mktemp -d)"
      trap 'rm -rf "$TMP"' EXIT
      chmod 777 "$TMP"
      docker pull "$${COSIGN_IMAGE}"
      docker run --rm \
        -e COSIGN_PASSWORD \
        -v "$TMP:/work" -w /work \
        --user "$(id -u):$(id -g)" \
        --entrypoint cosign \
        "$${COSIGN_IMAGE}" \
        generate-key-pair
      test -f "$TMP/cosign.key" && test -f "$TMP/cosign.pub"
      vault kv put -mount="$${VAULT_KV_MOUNT}" "$${VAULT_SECRET_PATH}" \
        private_key="$(cat "$TMP/cosign.key")" \
        public_key="$(cat "$TMP/cosign.pub")" \
        password="$${COSIGN_PASSWORD}"
      echo "Stored cosign keys at $${VAULT_KV_MOUNT}/$${VAULT_SECRET_PATH}"
    EOT
  }
}

output "vault_path" {
  description = "Vault path of cosign key material (kv get secret/cosign/gitlab)"
  value       = "${var.vault_kv_mount}/${var.vault_secret_path}"
}
