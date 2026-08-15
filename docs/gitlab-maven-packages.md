# GitLab Maven Package Registry

## Resolve (read)

Group Maven URL (data-platform): `https://scm.maze.trading/api/v4/groups/6/-/packages/maven`

CI/local read: group CI vars `GITLAB_MAVEN_USER` / `GITLAB_MAVEN_PASSWORD` (Deploy Token with `read_package_registry`),
or `GITLAB_TOKEN` with `read_api` + `read_package_registry`.

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
