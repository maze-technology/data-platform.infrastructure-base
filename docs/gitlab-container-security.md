# GitLab container security (CE): scan + cosign

For trading algo images in `registry.scm.*`. Works on **GitLab CE** (no EE features).

## Encryption at rest (Gitaly / Ceph)

**PVC / RBD LUKS** (not whole-OSD): only volumes on `rook-ceph-block-encrypted` are encrypted. Bulk OHLCV stays on plain `rook-ceph-block`.

| What | Where |
|------|--------|
| Master passphrase | Vault `secret/ceph/rbd-luks` |
| Same passphrase for CSI | K8s Secret `storage-encryption-secret` in `gitlab` (and `rook-ceph`) |
| Per-volume DEKs | Wrapped in RBD image metadata (unlocked via that passphrase) |
| Gitaly (production) | `gitaly_storage_class = rook-ceph-block-encrypted` |
| Local kind | Gitaly still on `standard` (local-path) — RBD mounts are unreliable on kind; encryption SC is still created for parity |

**Existing cluster:** enabling encryption does not magically encrypt an already-provisioned Gitaly PVC. Prefer tear down + re-apply (or migrate) so Gitaly is created on the encrypted class from day one.

## Audit events

Skipped on CE (Premium+). Rely on Promtail/Loki container logs for now.

## Scan on build (fail on High+) + cosign — plain English

### What is a GitLab Runner?

A **worker** that executes CI jobs (build, Trivy, cosign). GitLab itself only *schedules* pipelines; without a runner, jobs stay **pending** forever.

We install **one** in-cluster GitLab Runner (`install_gitlab_runner = true`, Kubernetes executor, privileged for Docker builds). Token registration uses the modern `glrt-` auth-token workflow (created via Rails after GitLab is up).

**You still need** COSIGN_* CI variables on the algo project for signing jobs.

### Cosign keys (Vault → GitLab CI variables)

1. Keys are generated into Vault: `secret/cosign/gitlab` (`private_key`, `public_key`, `password`).
2. In GitLab UI (group or project **Settings → CI/CD → Variables**), create:
   - `COSIGN_PRIVATE_KEY` = Vault `private_key` (masked)
   - `COSIGN_PASSWORD` = Vault `password` (masked)
3. Those are **CI/CD variables** (injected into jobs), not something you export on your laptop unless you are debugging.

```bash
export VAULT_ADDR=... VAULT_TOKEN=...
vault kv get -field=private_key secret/cosign/gitlab   # paste into GitLab variable
vault kv get -field=password secret/cosign/gitlab
```

### What “include the template after docker push” means

In the **algo repo’s** `.gitlab-ci.yml` you typically:

1. **build** job: `docker build` + `docker push` to `registry.scm…`
2. **then** run scan/sign jobs that need that image to already exist in the registry

Example:

```yaml
stages: [build, secure]

build:
  stage: build
  script:
    - docker build -t $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA .
    - docker push $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA

include:
  - project: 'platform/ci-templates'   # after you mirror ci/templates/container-secure.gitlab-ci.yml there
    file: '/container-secure.gitlab-ci.yml'
    inputs:
      image: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
      severity: HIGH

variables:
  SECURE_IMAGE: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
```

“Include” = reuse our shared YAML so every algo repo gets the same Trivy (fail on High+) + cosign behavior without copy-pasting.

Template file in this repo: [`ci/templates/container-secure.gitlab-ci.yml`](../ci/templates/container-secure.gitlab-ci.yml)

### Verify before deploy

```bash
cosign verify --key cosign.pub "$IMAGE"
```
