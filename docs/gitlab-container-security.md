# GitLab container security (CE): scan + cosign

For trading algo images in `registry.scm.*`. Works on **GitLab CE** (no EE features).

## Encryption at rest (Gitaly / Ceph)

**PVC / RBD LUKS** (not whole-OSD): only volumes on `rook-ceph-block-encrypted` are encrypted. Bulk OHLCV stays on plain `rook-ceph-block`.

| What | Where |
|------|--------|
| Master passphrase | Vault `secret/ceph/rbd-luks` |
| Same passphrase for CSI | K8s Secret `storage-encryption-secret` in `gitlab` (and `rook-ceph`) |
| Per-volume DEKs | Wrapped in RBD image metadata (unlocked via that passphrase) |
| Gitaly (**production**) | `gitaly_storage_class = rook-ceph-block-encrypted` |
| Gitaly (**local kind**) | `standard` (local-path) — kind mounts `/sys` read-only so kernel RBD (`krbd`) map fails; encryption SC is still created for parity |

**Existing cluster:** enabling encryption does not magically encrypt an already-provisioned Gitaly PVC. Prefer tear down + re-apply (or migrate) so Gitaly is created on the encrypted class from day one.

## Audit events

Skipped on CE (Premium+). Rely on Promtail/Loki container logs for now.

## Scan on build (fail on High+) + cosign — plain English

### What is a GitLab Runner?

A **worker** that executes CI jobs (build, Trivy, cosign). GitLab itself only *schedules* pipelines; without a runner, jobs stay **pending** forever.

We install **one** in-cluster GitLab Runner (`install_gitlab_runner = true`, Kubernetes executor, privileged for Docker builds). Token registration uses the modern `glrt-` auth-token workflow (created via Rails after GitLab is up).

### Cosign keys (Vault → GitLab group `maze/algos`)

OpenTofu module `gitlab-ci-cosign` auto-wires group CI/CD variables from Vault `secret/cosign/gitlab`:

| Variable | Content |
|----------|---------|
| `COSIGN_PRIVATE_KEY` | base64(cosign.key), masked + protected |
| `COSIGN_PASSWORD` | key password, masked + protected |
| `COSIGN_PUBLIC_KEY` | base64(cosign.pub), masked + protected |

Put algo repos **under group `maze/algos`** so pipelines inherit these variables. Keys are base64 so GitLab masking works (PEM newlines are rejected).

Manual debug (optional):

```bash
export VAULT_ADDR=... VAULT_TOKEN=...
vault kv get -field=public_key secret/cosign/gitlab
```

### CI template: Trivy + sign + verify

Template: [`ci/templates/container-secure.gitlab-ci.yml`](../ci/templates/container-secure.gitlab-ci.yml)

- `trivy` — fail on High+ (unfixed) and Critical
- `cosign_sign` — default branch, offline (`--tlog-upload=false`)
- `cosign_verify` — default branch, `--insecure-ignore-tlog`

Example algo `.gitlab-ci.yml`:

```yaml
stages: [build, secure]

build:
  stage: build
  script:
    - docker build -t $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA .
    - docker push $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA

include:
  - project: 'platform/ci-templates'   # after you mirror the template there
    file: '/container-secure.gitlab-ci.yml'
    inputs:
      image: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
      severity: HIGH

variables:
  SECURE_IMAGE: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
```

### Cluster admission (Kyverno)

Module `kyverno` installs Kyverno and a `ClusterPolicy` that **enforces** cosign verify for Pods that:

1. Run in a namespace labeled `maze.io/require-signed-images=true`
2. Pull images from `registry.scm.*` (configured registry host)

Platform namespaces (gitlab, keycloak, …) are **not** labeled → unsigned images keep working.

Enable for an algo namespace:

```bash
kubectl label namespace my-algo maze.io/require-signed-images=true
```

Public key is synced to Secret `cosign-public-key` in namespace `kyverno`.
