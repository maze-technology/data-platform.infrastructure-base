# Coder (in-cluster dev workspaces)

Deployed when `enable_coder = true`.

| Item | Value |
|------|--------|
| URL | `https://coder.<cluster_domain>` |
| Control plane namespace | `coder` |
| Workspace namespace | `coder-workspaces` |
| Auth | Keycloak OIDC — `engineers` and `admins` groups by default |
| DB | In-cluster CloudNativePG (`coder-pg`) |
| Workspace storage | `rook-ceph-block` PVC per workspace (default 50 GiB home disk) |
| Access | VPN-only ingress (same as GitLab/Grafana) |

## First-time setup

1. Apply OpenTofu with `enable_coder = true`.
2. Connect via WireGuard and open `https://coder.<cluster_domain>`.
3. Sign in with SSO (Keycloak). The first `admins` group member should be promoted to **Owner** in Coder (Organization → Members) if not automatic.
4. Push the default workspace template from a machine with the [Coder CLI](https://coder.com/docs/install):

```bash
# After: coder login https://coder.maze.trading
coder templates push maze-dev iac/modules/coder/templates/kubernetes-dev \
  --variable namespace=coder-workspaces \
  --variable storage_class=rook-ceph-block \
  --yes
```

Or run the command from OpenTofu output `coder_push_template_command`.

5. Create a workspace from template **maze-dev** in the UI (or `coder create --template maze-dev my-dev`).

## Developer access

### Browser

Use the Coder dashboard or the **code-server** app on the workspace.

### SSH (full terminal, scp, rsync)

```bash
coder login https://coder.<cluster_domain>
coder config-ssh --no-wildcard
ssh coder.<workspace-name>
```

### Cursor

Install the **Coder Remote** extension, run **Coder: Login**, then **Coder: Open Workspace**.

## Backup

Coder is covered by the platform backup stack in three layers:

| Layer | What | Schedule |
|-------|------|----------|
| **Velero + Kopia** | `coder` and `coder-workspaces` namespaces (Deployments, PVCs, Secrets) | Daily cluster backup (`backup_schedule_cron`) |
| **Postgres logical dump** | `coder-pg` database (workspace metadata, users, templates) | Daily (`backup_postgres_dump_schedule_cron`) |
| **GitLab** | Committed source code (source of truth) | Existing GitLab backup path |

Namespaces are labeled `backup.maze.trading/enabled=true` (production uses `<cluster_domain>/backup-enabled`).

Workspace home PVCs use `lifecycle { ignore_changes = all }` in the template so stop/start and template upgrades do not recreate disks.

### Restore a single workspace home directory

1. Identify the PVC: `kubectl -n coder-workspaces get pvc -l com.coder.workspace.name=<workspace>`.
2. Restore from Velero (example):

```bash
velero restore create coder-ws-restore \
  --from-backup cluster-daily-<timestamp> \
  --include-namespaces coder-workspaces \
  --selector com.coder.workspace.name=<workspace>
```

3. Restart the workspace from the Coder UI.

If the workspace was deleted, recreate it with the same name/owner first, then restore the PVC and restart.

### Restore Coder control plane

1. Restore namespace `coder` from Velero (includes `coder-pg` PVC and secrets).
2. Restore logical dump into Postgres if needed (see `docs/` backup runbooks for CNPG pg_dump restore).
3. Restart Coder deployment: `kubectl -n coder rollout restart deploy/coder`.

After a partial restore, workspace agents may need a restart from the Coder UI (known Coder + Velero edge case).

## Security notes

- Do **not** mount platform break-glass secrets (`vault-init`, tfvars, state passphrase) into workspace templates.
- Workspace pods run as UID 1000, non-root, in an isolated namespace.
- Disable password auth is enabled by default; use Keycloak SSO only.
