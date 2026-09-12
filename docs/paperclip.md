# Paperclip (AI agent orchestration)

Deployed when `enable_paperclip = true`.

| Item | Value |
|------|--------|
| URL | `https://paperclip.<cluster_domain>` |
| Control plane namespace | `paperclip` |
| Agent run namespaces | `paperclip-<companySlug>` (created on first dispatch) |
| Auth | Better Auth email/password (VPN-only). Keycloak OIDC is **not** supported in current Paperclip OSS. |
| DB | In-cluster CloudNativePG (`paperclip-pg`) |
| Attachments | Rook RGW bucket `paperclip-storage-<env>` |
| Sandboxes | `@paperclipai/plugin-kubernetes` with `backend: sandbox-cr` + [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) |
| Access | VPN-only ingress (same whitelist pattern as Coder) |

## First-time setup

1. Apply OpenTofu with `enable_paperclip = true` (production pins a tagged `infrastructure-base` release).
2. Connect via WireGuard and open **https://paperclip.`<cluster_domain>`**.
3. Complete onboarding: create the first email/password user and claim the board / organization.
4. Confirm the Kubernetes plugin auto-installed:

```bash
kubectl -n paperclip logs deploy/paperclip | grep -i kubernetes
```

Look for `paperclip.kubernetes-sandbox-provider` ready / installed. The init container stages `@paperclipai/plugin-kubernetes` into `PAPERCLIP_BUNDLED_PLUGIN_ROOT`; self-hosted auto-install loads it at boot.

5. In the UI, create a **sandbox** environment with roughly:

```json
{
  "provider": "kubernetes",
  "inCluster": true,
  "backend": "sandbox-cr",
  "adapterType": "claude_local",
  "egressMode": "standard",
  "namespacePrefix": "paperclip-",
  "imageAllowList": ["ghcr.io/paperclipai/agent-runtime-*:v*"]
}
```

Use `cursor_local` (or another supported adapter) if that matches your agent runtime image allow-list.

6. Add company secrets for model API keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …) and GitLab access (`GITLAB_TOKEN` / git remotes against `https://scm.<cluster_domain>`).
7. After bootstrap, disable further sign-ups in Instance settings (`auth.disableSignUp`) if you want invite-only access.

## agent-sandbox controller

OpenTofu applies `https://github.com/kubernetes-sigs/agent-sandbox/releases/download/<version>/sandbox.yaml` (default `v1.0.1`) into `agent-sandbox-system`. The Paperclip ServiceAccount has a ClusterRole so the plugin can create tenant namespaces, NetworkPolicies, Jobs/Sandboxes, and `pods/exec`.

```bash
kubectl -n agent-sandbox-system get deploy,pods
kubectl get crd sandboxes.agents.x-k8s.io
```

## Backup

| What | How |
|------|-----|
| Postgres logical dump | `paperclip-pg` via `backup_postgres_dump_targets` (add in the composition env) |
| Attachments | RGW bucket mirrored when `backup_object_sync_enabled` (source `paperclip-storage`) |
| Home PVC | Included when the `paperclip` namespace carries the platform backup label |

## Ops notes

- Single replica + `Recreate` strategy so the RWO home PVC is not multi-attached.
- Seeded `config.json` is written only on first boot; later storage/URL changes need a manual edit or PVC wipe.
- Image / plugin pins: `paperclip_image`, `paperclip_plugin_version`, `paperclip_agent_sandbox_version`.
- The bundled `@paperclipai/plugin-kubernetes` still hard-codes Sandbox CRD `v1alpha1`; agent-sandbox **v1.0+** only serves **`v1beta1`**. The `install-k8s-plugin` init rewrites that API version after `npm pack` so lease create does not 404.
