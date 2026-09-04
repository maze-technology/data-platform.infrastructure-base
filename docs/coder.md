# Coder (in-cluster dev workspaces)

Deployed when `enable_coder = true`.

| Item | Value |
|------|--------|
| URL | `https://coder.<cluster_domain>` |
| Control plane namespace | `coder` |
| Workspace namespace | `coder-workspaces` |
| Auth | Keycloak OIDC — `engineers` and `admins` groups by default |
| Roles | `admins` → site **Owner**; `engineers` → ordinary **Member** |
| DB | In-cluster CloudNativePG (`coder-pg`) |
| Workspace storage | `rook-ceph-block` PVC per workspace (default 50 GiB home disk) |
| Access | VPN-only ingress (same as GitLab/Grafana) |

## Roles: admin vs user

| Keycloak group | Coder role | What you can do |
|----------------|------------|-----------------|
| `admins` | **Owner** | Manage users, templates, all workspaces |
| `engineers` | **Member** | Create/use your own workspaces |

How to check your role after SSO:

1. Open **https://coder.`<cluster_domain>`** → avatar / account menu — Owners see **Admin settings**.
2. Or: `coder users show <you>` (roles).
3. Or: Deployment → Users — your row should list **Owner** if you are in Keycloak `admins`.

### How role sync works

Automatic `CODER_OIDC_USER_ROLE_*` mapping is **Coder Premium** (not licensed here).

Instead, Deployment `coder-keycloak-owner-sync` (same pattern as `kellnr-keycloak-sync`):

1. Calls the **Keycloak Admin API** and lists live members of group `admins`.
2. For each matching Coder user (by username or email): set site **Owner** + org-admin.
3. If an OIDC user loses `admins` membership: demote to ordinary **Member**.
4. Reconciles on startup, then every 5 minutes; also exposes `/webhook` for Keycloak events (fan-out not wired yet — Keycloak currently has a single webhook URI pointed at Kellnr).

Adding someone to Keycloak `admins` in the UI is enough; they do **not** need to be in OpenTofu `bootstrap_users`. They must SSO into Coder at least once before promotion can apply.

`coder-bootstrap` / `prebuilds` are never demoted.

## First-time setup

Coder requires **at least one user** in its database before `/login` shows SSO; until then every URL redirects to `/setup` (email/password wizard). OpenTofu bootstraps a break-glass owner automatically; **use SSO for day-to-day access**.

### Why `coder-bootstrap@<domain>` (infra fix)

If the first user is created with your real Keycloak email (e.g. `vincent@maze.trading`) as a **password** account, SSO fails with:

> Incorrect login type — attempting "oidc", but the user has login type "password"

OpenTofu therefore creates owner `coder-bootstrap` / `coder-bootstrap@<cluster_domain>` — an email that never exists in Keycloak — so your SSO account is created cleanly as `login_type=oidc` on first login. Fresh installs keep this behavior so the conflict does not recur.

1. Apply OpenTofu with `enable_coder = true`.
2. Connect via WireGuard and open **https://coder.`<cluster_domain>`/login**
3. Click **Sign in with SSO** (Keycloak). Use your normal Keycloak account (`admins` / `engineers`).
4. If you are in Keycloak `admins`, wait for `coder-keycloak-owner-sync` (startup + every ~5 min), then refresh.
5. Break-glass credentials (emergency DB/bootstrap only — UI password login is disabled while `CODER_DISABLE_PASSWORD_AUTH=true`):

```bash
kubectl -n coder get secret coder-bootstrap-owner -o jsonpath='{.data.password}' | base64 -d
```

If `/login` still redirects to `/setup`, the bootstrap job failed — check `kubectl -n coder logs deploy/coder` or create the owner manually with `coder server create-admin-user` using the **system** email above (never your Keycloak email).

```bash
# After: coder login https://coder.maze.trading
coder templates push maze-dev iac/modules/coder/templates/kubernetes-dev \
  --variable namespace=coder-workspaces \
  --variable storage_class=rook-ceph-block \
  --yes
```

Or run the command from OpenTofu output `coder_push_template_command`.

6. Create a workspace from template **maze-dev** in the UI (or `coder create --template maze-dev my-dev`).

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
- Never bootstrap Coder with a Keycloak user’s email — always use `coder-bootstrap@<cluster_domain>`.
