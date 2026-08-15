# GitLab Maven Package Registry

Group Maven URL (data-platform): `https://scm.maze.trading/api/v4/groups/6/-/packages/maven`

Override with `GITLAB_MAVEN_URL`. Auth:

- CI publish: force `gitlab-ci-token` + `$CI_JOB_TOKEN` (group Deploy Token is read-only)
- CI/local read: group CI vars `GITLAB_MAVEN_USER` / `GITLAB_MAVEN_PASSWORD` (Deploy Token with `read_package_registry`)
- Local/dev: `GITLAB_TOKEN` with `read_api` + `read_package_registry`

Reusable publish job: `ci/templates/maven-publish.gitlab-ci.yml`.

## Job token allowlists

GitLab CE inbound job-token scope is project-allowlist only (group allowlist is EE).
Prefer the group Deploy Token CI vars for cross-project and templates→data-platform reads.
For `CI_JOB_TOKEN` reads, add consumer projects under each publisher's
**Settings → CI/CD → Job token permissions** allowlist.
