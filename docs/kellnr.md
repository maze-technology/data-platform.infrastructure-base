# Kellnr (private Cargo registry)

Deployed when `enable_kellnr = true` (default).

| Item | Value |
|------|--------|
| URL | `https://crates.<cluster_domain>` |
| Namespace | `kellnr` |
| Cargo registry name | `maze` |
| Sparse index | `sparse+https://crates.<cluster_domain>/api/v1/crates/` |
| Auth UI | Keycloak SSO — `admins` → Kellnr admin; `engineers` → normal users |
| Auth Cargo | API tokens (`authRequired = true`) |
| DB | In-cluster CloudNativePG (`kellnr-pg`) |
| Blobs | Rook RGW bucket `kellnr-crates-<env>` |

## Cargo config

```toml
# ~/.cargo/config.toml
[registries.maze]
index = "sparse+https://crates.maze.trading/api/v1/crates/"
```

```toml
# Cargo.toml
[dependencies]
my-dto = { version = "0.1.0", registry = "maze" }
```

CI: store a Kellnr token as GitLab group variable `CARGO_REGISTRIES_MAZE_TOKEN`
(optional `CARGO_REGISTRIES_MAZE_INDEX`). Specs publish crates on **git tags** via
[`ci/templates/cargo-publish.gitlab-ci.yml`](../ci/templates/cargo-publish.gitlab-ci.yml)
(`make rust-crate` → `cargo publish --registry maze`).

Bootstrap admin token is in OpenTofu output `kellnr_admin_token` / secret
`kellnr-secret` key `KELLNR_SETUP__ADMIN_TOKEN` — prefer UI-issued tokens for day-to-day CI.
