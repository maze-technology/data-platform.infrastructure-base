# infrastructure-base

Versioned OpenTofu **root module** that composes cluster-level components under `iac/modules/*`. Environment entrypoints (providers, backends, tfvars, `make apply`) live in the separate [`infrastructure`](https://github.com/maze-technology/infrastructure) composition repo.

**First release scope:** GitLab CE, Rook-Ceph, WireGuard VPN, observability, Argo CD, Keycloak, Vault, cert-manager, ingress, Kyverno/cosign. Temporal is deferred.

## Usage

Consumers pin a semver tag and pass providers + inputs:

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.23" }
    helm       = { source = "hashicorp/helm", version = "~> 2.11" }
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    vault      = { source = "hashicorp/vault", version = "~> 3.23" }
    # plus external, random, null as needed
  }
}

provider "kubernetes" { /* ... */ }
provider "helm" { /* ... */ }
provider "vault" { /* ... */ }

provider "aws" {
  alias = "rgw"
  # S3-compatible settings pointing at Rook RGW (or a port-forward)
  # ...
}

locals {
  infrastructure_base_ref = "v0.1.0" # bump intentionally when adopting a new release
}

module "infrastructure_base" {
  source = "git::https://github.com/maze-technology/infrastructure-base.git?ref=${local.infrastructure_base_ref}"

  providers = {
    aws.rgw = aws.rgw
  }

  environment    = "local" # or "production"
  cluster_name   = "local"
  cluster_domain = "maze.local"

  # Feature flags / sizing — see variables.tf
  enable_kind_cluster = true
  enable_cluster_dns  = true
  create_maze_ca      = true
  # ...
}
```

This root module declares `required_providers` (including `aws` with `configuration_aliases = [aws.rgw]`) but **does not** configure providers or backends. The composition repo owns kubeconfig, Vault address/token, and the RGW AWS alias.

## What this module deploys

| Layer | Components |
|-------|------------|
| Foundation | Rook-Ceph (RBD + RGW), Vault, RGW credential bootstrap, cosign keys |
| Infrastructure | cert-manager, NGINX ingress, optional CoreDNS hosts, Keycloak, WireGuard |
| Observability | Prometheus, Grafana, Loki, Tempo (+ Promtail) |
| Applications | Argo CD, GitLab CE (+ runner), Kyverno signed-image policy, GitLab CI cosign vars |
| Object storage | `loki-logs-<env>` and `gitlab-storage-<env>` buckets via `aws.rgw` |
| Backup (optional) | Velero + Kopia (PVCs) and rclone crypt mirror of RGW buckets to the composition-chosen backup store |

Optional (local/kind only):

- `enable_kind_cluster` — probes/creates the kind cluster module
- `enable_cluster_dns` — CoreDNS rewrites for `*.cluster_domain` + GitLab Envoy DNS patch
- `create_maze_ca` — internal Maze CA instead of public Let's Encrypt
- Loop-device OSD settings for safe kind storage

## Inputs

See [`variables.tf`](variables.tf) for the full interface. High-level groups:

| Group | Examples |
|-------|----------|
| Core | `environment`, `cluster_name`, `cluster_domain`, `cluster_public_ip` |
| Feature flags | `enable_kind_cluster`, `enable_cluster_dns`, `create_maze_ca`, `restrict_to_vpn` |
| Rook-Ceph | `storage_nodes`, `create_loop_devices`, `mon_count`, `replication_size`, resource requests/limits |
| TLS / ingress | `letsencrypt_email`, `letsencrypt_server`, `ingress_service_type`, NodePorts |
| VPN | `vpn_subnet`, `wireguard_server_url`, `wireguard_peers`, service type / storage |
| Identity | `bootstrap_admin`, `bootstrap_users`, Keycloak admin + DB settings |
| Vault | replica/HA, `vault_storage_backend`, storage class/size |
| Observability | PVC sizes, Loki mode/caches, bucket name overrides |
| GitLab | external PostgreSQL, storage classes (incl. Gitaly), replica profile, bucket name |
| S3 | `s3_force_destroy` |
| Backup | `backup_enabled`, S3 endpoint/bucket/keys, `backup_encryption_password`, schedule/TTL, RGW object-sync cron |

Storage class variables that are empty resolve to Rook RBD (or encrypted RBD for Gitaly).

## Outputs

See [`outputs.tf`](outputs.tf). Useful ones:

- `hosts`, `service_urls`, `etc_hosts`
- `vpn_subnet`, `wireguard_peer_config_command`
- `storage_class_name`, `encrypted_storage_class_name`, `rgw_endpoint`
- `gitlab_url`, `registry_url`, `gitlab_gateway_cluster_ip`
- `keycloak_issuer_url`, `tls_cluster_issuer`
- `cosign_vault_path`, `kyverno_signed_images_label`
- `bootstrap_credentials` (sensitive)
- `backup_schedule` (cron, TTL, bucket) when `backup_enabled`

## Cluster backup (Velero + Kopia + RGW mirror)

Opt-in via `backup_enabled`. The composition repo supplies the object store (local RGW smoke bucket or production OVH Object Storage) and:

- **Encryption** — one password (`backup_encryption_password`, min 16 chars) for both Kopia (`velero-repo-credentials`) and **rclone crypt** (RGW object mirror). Store offline; required to restore.
- **Cluster / PVCs** — Kopia filesystem backup (`uploaderType=kopia`); first full, then incremental. Schedule: `backup_schedule_cron` + `backup_ttl`.
- **RGW objects** — CronJob syncs application buckets (GitLab storage, Loki logs) into the same backup bucket under `rgw-mirror/<name>/`, encrypted with rclone crypt. Schedule: `backup_object_sync_schedule_cron` (default `30 2 * * *`). Source list is built in the root module (not hardcoded in the Job image).
- **Versioning** — enabled on the live GitLab and Loki RGW buckets.
- **Out of scope** — Backups for **external resources** supplied outside this module (for example OVH managed PostgreSQL for GitLab/Keycloak, or any other third-party database/object store) are **not** managed here. The person running the infrastructure is responsible for backing those up.

## Identity and access

Keycloak is the central IdP (SSO for GitLab, Grafana, Argo CD). Groups:

| Group | Purpose |
|-------|---------|
| `vpn-users` | WireGuard peer name = Keycloak username |
| `engineers` | GitLab SSO + shared `maze` group, Grafana Editor, Argo CD readonly |
| `admins` | Full platform admin |

GitLab stays VPN-only via Envoy `SecurityPolicy`. Cosign + Kyverno enforce signed images on namespaces labeled `<cluster_domain>/require-signed-images=true`. Details: [docs/gitlab-container-security.md](docs/gitlab-container-security.md).

## Layout

```
.
├── main.tf          # Root module — wires iac/modules/*
├── variables.tf     # Public inputs
├── outputs.tf       # Public outputs
├── versions.tf      # required_version + required_providers (no provider blocks)
├── iac/modules/     # Child modules (not imported directly by consumers)
├── config/          # Shared kind config reference (ops live in infrastructure/)
└── docs/
```

## Development

```bash
make format          # tofu fmt -recursive
make help
```

CI runs `tofu fmt -check -recursive` on pull requests. Pushes to `main` bump and push the next semver **patch** tag via [`anothrNick/github-tag-action`](https://github.com/anothrNick/github-tag-action) (same pattern as the org publish workflows).

## Related repos

- [`infrastructure`](https://github.com/maze-technology/infrastructure) — env roots that call this module
- [`configuration`](https://github.com/maze-technology/configuration) — GitHub org / repository management
