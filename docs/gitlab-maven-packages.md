# GitLab Maven Package Registry

## Releases (auto-tag on main)

GitHub used to bump a patch tag on every push to `main` (`publish.yaml` /
`tag-release.yaml`).

GitLab equivalent: include `ci/templates/tag-release.gitlab-ci.yml`. On `main` it
creates the next `vX.Y.Z` tag via `GITLAB_TAG_TOKEN` (group access token:
`api` + `write_repository`) and triggers the tag pipeline. On the tag pipeline,
`gitlab_release` (same template) creates a **GitLab Release** with notes from the
changelog API, falling back to commit titles between the previous semver tag and
this one when no `Changelog:` trailers are present.

## Release approval / protecting `main`

GitHub used `.github/workflows/release-approval.yaml` + a `release` environment
reviewed by `release-engineers`. GitLab CE has **no** MR approval-rules API and
**no** protected-environment reviewers (Premium).

CE parity:

1. **Protected branch `main`**: push = No one, merge = Maintainers (already live).
2. **Manual gate**: include `ci/templates/release-approval.gitlab-ci.yml` and enable
   **Settings → Merge requests → Pipelines must succeed**. MRs into `main` stay
   blocked until a Maintainer plays the `release_approval` job.
3. **Roster**: keep people who may merge releases in `engineers/release-engineers`
   (and as project Maintainers).

## Resolve (read)

Group Maven URL (data-platform): `https://scm.maze.trading/api/v4/groups/6/-/packages/maven`

CI/local read: group CI vars `GITLAB_MAVEN_USER` / `GITLAB_MAVEN_PASSWORD` (Deploy Token with `read_package_registry`),
or `GITLAB_TOKEN` with `read_api` + `read_package_registry`.

Templates specs (e.g. `dtos.helloworld`) publish under the **templates** group. Consumers there also need:

- `GITLAB_TEMPLATES_MAVEN_URL` = `https://scm.maze.trading/api/v4/groups/7/-/packages/maven`
- `GITLAB_TEMPLATES_MAVEN_USER` / `GITLAB_TEMPLATES_MAVEN_PASSWORD` (group-7 Deploy Token with `read_package_registry`)

Keep `GITLAB_MAVEN_*` pointed at group 6 for `tech.maze:commons` and other data-platform artifacts.

## Publish (write)

GitLab only accepts Maven **PUT** on the **project** endpoint (group URL returns **415 Unsupported Media Type**):

`https://scm.maze.trading/api/v4/projects/<project_id>/packages/maven`

The reusable publish job sets `GITLAB_MAVEN_URL` to `${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/maven`
and authenticates with `gitlab-ci-token` + `$CI_JOB_TOKEN`.

Override publish URL with `GITLAB_MAVEN_PUBLISH_URL` if needed.

Reusable publish job: `ci/templates/maven-publish.gitlab-ci.yml`.

## Job token allowlists

GitLab CE inbound job-token scope is project-allowlist only (group allowlist is EE).
Prefer the group Deploy Token CI vars for cross-project and templates→data-platform reads.
For `CI_JOB_TOKEN` reads (e.g. git submodule clone), add consumer projects under each publisher's
**Settings → CI/CD → Job token permissions** allowlist.
