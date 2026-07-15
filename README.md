# Infrastructure Global

OpenTofu-managed global infrastructure for the trading data platform. This repository bootstraps Kubernetes clusters and deploys cluster-level components shared across environments.

**First release scope:** GitLab CE in-cluster, Rook-Ceph object/block storage, WireGuard VPN, observability stack, Argo CD. Temporal is deferred.

## Overview

This repository manages:

- **Kubernetes clusters** — local (`kind`) now; OVH bare metal (3 servers) in production
- **Storage (Rook-Ceph)** — block storage (RBD) and S3-compatible object storage (RGW) we operate ourselves
- **GitLab CE** — source control and CI/CD, deployed inside the cluster
- **WireGuard VPN** — web services reachable only over VPN (trading data cluster, max security)
- **Observability** — Prometheus, Grafana, Loki, Tempo, OpenTelemetry Collector, Promtail
- **Ingress** — NGINX Ingress Controller
- **GitOps** — Argo CD
- **Secrets** — HashiCorp Vault (local dev mode)
- **Identity (Keycloak)** — central user directory, groups, and SSO for all services

### Delegated to OVH managed services (production)

We do **not** self-host these in production:

- **PostgreSQL** — OVH Cloud Databases (RDS) for GitLab and Keycloak
- Other stateful services as needed

Redis/Valkey for GitLab and Argo CD runs **in-cluster** (Helm subcharts) — ephemeral cache and job queues, backed by Rook-Ceph PVCs where persistence is enabled.

Locally, GitLab uses bundled PostgreSQL and in-cluster Redis. Production uses OVH PostgreSQL with in-cluster Redis.

## Identity and access (Keycloak)

We use **Keycloak** as the central identity provider — not OpenLDAP alone. Keycloak gives you:

- **Single user directory** — users, passwords, groups in one place
- **SSO (OpenID Connect)** — one login for GitLab, Grafana, Argo CD
- **Group-based access** — membership drives permissions across services

### Why Keycloak over OpenLDAP?

| | Keycloak | OpenLDAP alone |
|---|----------|----------------|
| SSO (OIDC) | Built-in | Needs another component |
| User/group UI | Yes | LDAP tools only |
| GitLab CE integration | OIDC native | LDAP bind (no SSO button) |
| WireGuard | Group → peer mapping | No native integration |

OpenLDAP can be added **later** as a backend user store federated into Keycloak if you need raw LDAP for legacy apps. For first release, Keycloak's built-in directory is enough.

### Groups

| Group | Purpose |
|-------|---------|
| `vpn-users` | Allowed to connect via WireGuard VPN (peer name = Keycloak username) |
| `developers` | GitLab, Grafana (Editor), Argo CD (readonly) |
| `admins` | Full platform admin on all services |

### How services connect

```
auth.maze.local (Keycloak — identity & SSO)
    ├── scm.maze.local   → OIDC "Sign in with Keycloak"
    ├── grafana          → Generic OAuth
    ├── argocd           → OIDC + group → RBAC mapping
    └── vpn.maze.local   → vpn-users group → WireGuard peer configs
```

**VPN access flow:** A user must be in the `vpn-users` group in Keycloak. Their Keycloak **username** becomes their WireGuard peer name. Adding a user to `vpn-users` and re-applying updates WireGuard peer configs.

**Note:** WireGuard does not support OIDC login natively — identity is enforced by (1) VPN membership in Keycloak and (2) SSO on services behind the VPN.

### Default bootstrap users (local)

Configure in `iac/envs/local/terraform.tfvars` **before first deploy**:

```hcl
cluster_domain    = "maze.local"
cluster_public_ip = "YOUR_VPS_IP"

keycloak_admin_username = "admin"
keycloak_admin_password = "YourKeycloakMasterPassword123!"

bootstrap_admin = {
  username = "admin"
  password = "YourPlatformAdminPassword123!"
  email    = "admin@maze.tech"
}
```

| Credential | Purpose | Where to use |
|------------|---------|--------------|
| `keycloak_admin_*` | Keycloak master admin | `http://auth.maze.local:30080/admin` — manage users/groups |
| `bootstrap_admin` | Platform root user | SSO login on SCM/Grafana + WireGuard peer name `admin` |

### Cluster domain (`maze.local`)

Hostnames describe **what the service does**, not the technology behind it:

| Host | Service |
|------|---------|
| `vpn.maze.local` | WireGuard endpoint (UDP 31820) |
| `auth.maze.local` | Identity, SSO, user/group admin |
| `scm.maze.local` | Source control (GitLab) |
| `registry.scm.maze.local` | Container registry |
| `grafana.maze.local` | Observability dashboards |
| `argocd.maze.local` | GitOps |
| `vault.maze.local` | Secrets |

Generate `/etc/hosts` lines after deploy:

```bash
cd iac/envs/local && tofu output etc_hosts
```

### Bootstrap access (no chicken-and-egg)

**You do NOT need Keycloak to get VPN access.** Bootstrap order:

1. Deploy: `make apply`
2. Get WireGuard config (needs kubectl only, not VPN):
   ```bash
   tofu output wireguard_peer_config_command
   # → kubectl exec -n wireguard deploy/wireguard -- cat /config/peer_admin/peer_admin.conf
   ```
3. Add `/etc/hosts` (VPS IP → all `*.maze.local` hosts)
4. Connect WireGuard using the config (endpoint: `vpn.maze.local:31820`)
5. Access all services via VPN — including `http://auth.maze.local:30080/admin`

Local and production use the same model: **auth is VPN-restricted**. Bootstrap only requires kubectl access to retrieve the WireGuard peer config; you never need to reach Keycloak before VPN is up.

### Production databases

Keycloak uses OVH managed PostgreSQL in production (same pattern as GitLab). GitLab and Keycloak each have their own database instance.

### What this repository does NOT do

- Deploy business microservices (data or trading services)
- Manage application-level configurations
- Run Temporal (commented out for first release)

## Architecture (first release)

```
┌─────────────────────────────────────────────────────────────┐
│  VPN clients (WireGuard)                                     │
│       │                                                      │
│       ▼                                                      │
│  WireGuard (in-cluster) ──► NGINX Ingress (VPN whitelist)   │
│       │                         │                            │
│       │              ┌──────────┼──────────┐                 │
│       │              ▼          ▼          ▼                 │
│       │           GitLab    Grafana    Argo CD               │
│       │              │                                       │
│       │    ┌─────────┴─────────┐                             │
│       │    ▼                   ▼                             │
│       │  Gitaly (RBD)    Object storage (RGW S3)            │
│       │                                                      │
│  Observability: Prometheus / Loki(S3) / Tempo / Promtail   │
└─────────────────────────────────────────────────────────────┘

Production PostgreSQL: OVH managed (external to cluster)
GitLab/Argo CD Redis: in-cluster Helm subcharts (Rook-Ceph PVCs)
Local PostgreSQL/Redis: GitLab Helm bundled subcharts
```

## Quick Start (local)

### Prerequisites

- OpenTofu >= 1.5.0
- kubectl, kind, docker
- **vault** CLI and **jq** (used by `make apply` to read RGW credentials from Vault)
- helm provider dependencies resolved via `tofu init`
- ~16 GB RAM recommended (GitLab is resource-heavy)

### 1. Create the kind cluster

```bash
make local-setup
```

This creates a 4-node cluster (1 control-plane + 3 workers) with:

- Ingress NodePorts: `30080` (HTTP), `30443` (HTTPS)
- GitLab (Envoy Gateway) NodePort: `32458` (HTTP) — mapped in `config/kind-config.yaml`
- WireGuard NodePort: `31820` (UDP)
- Host mount `/var/lib/rook` for Rook-Ceph loop-device images and data
- Raised **inotify limits** on every node (required for Promtail log shipping on kind)

### 2. Deploy infrastructure (no manual steps)

From the **repository root**:

```bash
make init ENV=local    # once, or: cd iac/envs/local && make init
make apply ENV=local
```

The Makefile runs a **two-stage apply** automatically:

1. **Foundation** (~15–25 min) — Rook-Ceph (OSDs, RGW), Vault, RGW credential bootstrap into Vault
2. **Services** (~5–15 min) — S3 buckets, ingress, observability, WireGuard, Keycloak, GitLab, Argo CD

`make apply-services` fetches RGW credentials from Vault via port-forward — you do **not** need to export `AWS_ACCESS_KEY_ID` manually.

**Do not** run `make apply-services` alone after a failed apply unless foundation is already healthy; prefer `make apply ENV=local` for a clean end-to-end run.

After deploy, print service URLs:

```bash
cd iac/envs/local && tofu output service_urls
```

Alternatively, deploy incrementally by commenting/uncommenting modules in `iac/envs/local/main.tf`.

### 3. Connect via VPN and access services

```bash
# Retrieve a WireGuard peer config (replace 'admin' with your peer name)
kubectl exec -n wireguard deploy/wireguard -- cat /config/peer_admin/peer_admin.conf

# Connect (save config to a file first)
sudo wg-quick up ./wg-admin.conf

# Add to /etc/hosts (see: cd iac/envs/local && tofu output etc_hosts)
# VPS_IP  vpn.maze.local auth.maze.local scm.maze.local ...

# Or generate lines automatically:
tofu output wireguard_peer_config_command

# Connect VPN, then access services (auth is VPN-restricted — same as production)
open http://auth.maze.local:30080/admin
open http://scm.maze.local:32458
```

**Default credentials:** GitLab root password is set by the Helm chart on first install (check `gitlab-gitlab-initial-root-password` secret).

### 4. Access observability

| Service   | URL (via VPN + `/etc/hosts`)   | Notes |
|-----------|--------------------------------|-------|
| Grafana   | http://grafana.maze.local:30080 | Loki datasource pre-configured |
| Argo CD   | http://argocd.maze.local:30080 | |
| Vault     | http://vault.maze.local:30080  | Dev mode, root token `root` |
| GitLab    | http://scm.maze.local:32458    | Envoy Gateway NodePort (not `:30080`) |

Grafana default login: `admin` / `admin` (override in production).

**Logs (production parity):** Promtail ships container logs to Loki via `loki-gateway`. In Grafana → Explore → Loki, query e.g. `{namespace="gitlab"}`. Do not rely on `kubectl logs` for parity testing.

**Traces/metrics:** Tempo and Prometheus are wired; OpenTelemetry Collector receives OTLP (metrics + traces). Application log shipping via OTLP is not configured — use Promtail for container logs.

### Teardown and recreate

```bash
make local-teardown ENV=local   # tofu destroy + detach host loop/DM devices + delete kind cluster
make local-setup ENV=local
make apply ENV=local
```

`local-teardown` destroys Terraform-managed resources **while the cluster is still up** (with Vault/RGW port-forwards), then removes stale Ceph loop/DM state on the host so the next `apply` does not hit ghost OSD devices. If destroy cannot finish (e.g. RGW already broken), local OpenTofu state is cleared so the next apply is a clean create.

**Host-only steps (not part of the cluster):** add `/etc/hosts` entries and connect WireGuard — same as production bootstrap.

## Rook-Ceph storage safety

**Previous issue:** Rook could auto-discover and format the first available disk partition, destroying the host OS disk on a VPS.

**Current fix:**

| Setting | Value | Effect |
|---------|-------|--------|
| `useAllDevices` | **always `false`** | No automatic disk discovery |
| `deviceFilter` | **always `""`** | No regex-based device matching |
| Local (`kind`) | Per-worker **loop image + LVM** (`dm-*`) | Sparse 10 GB images under `/var/lib/rook/*-osd.img`; `ROOK_CEPH_ALLOW_LOOP_DEVICES=true` |
| Production | Explicit `storage_nodes` per bare-metal server | Only dedicated disks (e.g. `/dev/sdb`) — **never the OS disk** |

Local loop device config in `iac/envs/local/main.tf`:

```hcl
use_all_nodes       = false
create_loop_devices = true
allow_loop_devices  = true
storage_nodes = [
  { name = "local-worker",  devices = ["dm-1"], loop_device = "loop10" },
  { name = "local-worker2", devices = ["dm-2"], loop_device = "loop11" },
  { name = "local-worker3", devices = ["dm-0"], loop_device = "loop12" },
]
replication_size = 1   # local dev only
```

Loop images and LVM state live on the **host** under `/var/lib/rook` (bind-mounted into kind nodes). `make local-teardown` detaches loops, removes Ceph DM devices, and deletes `*-osd.img` so the next bootstrap starts clean.

After a **host reboot** (cluster still running), re-attach loop devices:

```bash
make setup-loop-devices ENV=local
```

## Modules

| Module | Purpose |
|--------|---------|
| `rook-ceph` | CephCluster, RBD block storage, RGW S3 object storage |
| `wireguard` | WireGuard VPN server (linuxserver/wireguard) |
| `keycloak` | Identity module (served at `auth.<domain>`) — users, groups, OIDC SSO |
| `gitlab` | SCM module (served at `scm.<domain>`) — GitLab CE, VPN-only ingress |
| `observability` | Prometheus, Grafana, Loki, Tempo, OTel, Promtail |
| `ingress` | NGINX Ingress Controller |
| `cert-manager` | TLS certificate management |
| `argocd` | GitOps engine |
| `vault` | Secret management (dev mode locally) |
| `rgw-bootstrap` | RGW credentials → Vault |
| `cluster` | Kind cluster validation |
| `temporal` | Workflow orchestration (**disabled for first release**) |

## Environments — there are only two

| Environment | Directory | Where it runs | What you do |
|-------------|-----------|---------------|-------------|
| **local** | `iac/envs/local/` | Your VPS via **kind** (simulated K8s cluster) | `make local-setup && make apply ENV=local` |
| **production** | `iac/envs/production/` | **OVH bare metal** (3 servers with real Kubernetes) | Bootstrap K8s on bare metal first, then `cd iac/envs/production && tofu apply` |

Both environments deploy the **same stack** inside Kubernetes: Rook-Ceph, WireGuard, GitLab, observability, Argo CD. The only differences are sizing, TLS, and where GitLab's database lives:

| | local | production |
|---|-------|------------|
| Kubernetes | kind on 1 VPS | Real K8s on 3 OVH bare metal servers |
| GitLab database | Bundled in Helm chart | OVH managed PostgreSQL |
| GitLab Redis | In-cluster (Helm subchart) | In-cluster (Helm subchart, Rook PVC) |
| Argo CD Redis | In-cluster (Helm subchart) | In-cluster redis-ha (Helm subchart) |
| Observability PVCs | Prometheus, Grafana, Tempo on Rook-Ceph | Same |
| Rook-Ceph disks | Safe loop image files | Dedicated `/dev/sdb` per server |
| VPN | NodePort on localhost | LoadBalancer on public IP |

You do **not** uncomment modules in `production/main.tf`. Everything is already wired. You only fill in `terraform.tfvars` (copy from `terraform.tfvars.example`).

### Production setup

```bash
# 1. Bootstrap Kubernetes on your 3 OVH bare metal servers (outside this repo)
# 2. Configure access
cd iac/envs/production
cp terraform.tfvars.example terraform.tfvars
# Edit: kubeconfig_context, storage_nodes, wireguard_server_url, OVH DB endpoints

make init
make apply   # or: make apply-foundation && make apply-services
```

Required values in `terraform.tfvars`:

- `kubeconfig_context` — your kubectl context name
- `storage_nodes` — node hostnames + dedicated disk paths (must match `kubectl get nodes`)
- `wireguard_server_url` — public IP for VPN
- `gitlab_postgresql_host` — OVH managed PostgreSQL endpoint for GitLab
- Passwords via env vars: `export TF_VAR_gitlab_postgresql_password=...`

### What was removed: `iac/envs/gitlab/`

There used to be a third directory called `gitlab/` that installed GitLab **directly on a bare metal server** (not in Kubernetes) using OVH API + SSH scripts. That approach has been **removed**. GitLab now runs **inside the Kubernetes cluster** in both local and production environments, using the `iac/modules/gitlab/` module.

## Makefile commands

```bash
make help                 # All targets
make local-setup          # Create kind cluster (from repo root)
make apply ENV=local      # Full two-stage deploy (foundation + services)
make apply-foundation     # Rook-Ceph + Vault + RGW bootstrap only
make apply-services       # Everything else (auto-fetches Vault/RGW creds)
make local-teardown       # tofu destroy + loop cleanup + delete kind cluster
make setup-loop-devices   # Re-attach Rook loop devices after host reboot
make prepull-ceph-image   # Pre-pull Ceph image (large download)
make validate             # tofu validate (ENV=local|production)
```

All `make apply*` targets accept `ENV=local` (default) or `ENV=production`.

## Configuration

### Secrets

Never commit secrets. Provide via:

- Environment variables: `export TF_VAR_gitlab_postgresql_password="..."`
- CI/CD pipeline variables
- `terraform.tfvars` (gitignored)

### Incremental debugging

Comment/uncomment module blocks in `iac/envs/local/main.tf`:

1. Foundation: `rook_ceph`, `vault`, `rgw_bootstrap`
2. Infrastructure: `wireguard`, `cert_manager`, `ingress`
3. Observability: `observability`
4. Applications: `gitlab`, `argocd`

- UTF-8, 2-space indent, LF line endings
- Small composable modules with clear inputs/outputs
- Environment differences via variables and `*.tfvars`, not copy-pasted resources
- Production-ready defaults (resource requests/limits, labels, annotations)

## License

[Add your license here]
