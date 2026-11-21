# GitLab container security (CE): Trivy scan

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

## Build → scan → publish

| Job | When | What |
|-----|------|------|
| `container_build` | MR / branch / tag | Build image, `docker save` to a **local** tar, `trivy image --input` (no registry pull; tar is **not** a CI artifact — avoids 413 on ~500Mi Paketo images) |
| `trivy` | after build | No-op marker (scan already done in `container_build`) |
| `container_publish` | **main** + **tags** only | Rebuild + push to GitLab registry (Hub optional) |

Develop / feature / MR pipelines build and scan; they do **not** push images.

Templates:

- [`ci/templates/container-publish.gitlab-ci.yml`](../ci/templates/container-publish.gitlab-ci.yml)
- [`ci/templates/container-secure.gitlab-ci.yml`](../ci/templates/container-secure.gitlab-ci.yml)

Trivy policy (on `container_build`):

- **MR / non-default branches:** hard fail
- **Default branch (`main`):** soft fail (`allow_failure: true`)

Example `.gitlab-ci.yml`:

```yaml
stages: [build, secure, publish]

include:
  - project: 'iac/infrastructure-base'
    file: '/ci/templates/container-publish.gitlab-ci.yml'
    inputs:
      dockerfile: Dockerfile
      context: .
      trivy_severity: HIGH
      trivy_extra_args: '--skip-files "**/cnb/lifecycle/**"'
  - project: 'iac/infrastructure-base'
    file: '/ci/templates/container-secure.gitlab-ci.yml'
```

Image signing / cluster admission (cosign + Kyverno) was removed; keep the bar simple with Trivy in CI.
