# GitLab Runner — Docker Compose bootstrap

`script.sh` registers a new GitLab Runner via the [auth-token API](https://docs.gitlab.com/ee/api/users.html#create-a-runner) and writes a ready-to-run Docker Compose stack to `~/docker/gitlab-runner/compose.yml`.

## What it does

1. Detects the Linux distro and installs `jq` + `curl` if missing.
2. Installs Docker (via `get.docker.com`) if not already present and enables the daemon.
3. Calls `POST /api/v4/user/runners` with your PAT to create the runner and obtain an auth token.
4. Writes `~/docker/gitlab-runner/compose.yml` (mode `600`) with the token embedded in an inline `config.toml`.
5. Runs `docker compose up -d` to start the stack.

## Requirements

- Linux (Debian/Ubuntu, Fedora/RHEL/Rocky, Arch, openSUSE, or Alpine)
- A GitLab PAT with the **`Runner:Create`** scope (`/user/runners` endpoint)

## Quick start

**One-liner from the internet (curl):**
```bash
curl -fsSL https://raw.githubusercontent.com/KMakarevych/init/refs/heads/main/script.sh | GITLAB_PAT=glpat-xxxx bash
```

**One-liner from the internet (wget):**
```bash
wget -qO- https://raw.githubusercontent.com/KMakarevych/init/refs/heads/main/script.sh | GITLAB_PAT=glpat-xxxx bash
```

**Local run:**
```bash
GITLAB_PAT=glpat-xxxx bash script.sh
```

The script will prompt for any missing required values (PAT, Group ID, etc.).

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `GITLAB_PAT` | **yes** | *(prompted)* | Fine-grained PAT with `Runner:Create` scope |
| `GITLAB_URL` | no | `https://gitlab.com` | GitLab instance base URL |
| `RUNNER_TYPE` | no | `group_type` | `instance_type` \| `group_type` \| `project_type` |
| `GROUP_ID` | if `group_type` | *(prompted)* | GitLab group numeric ID |
| `PROJECT_ID` | if `project_type` | *(prompted)* | GitLab project numeric ID |
| `RUNNER_DESCRIPTION` | no | `<hostname>-runner` | Runner display name |
| `RUNNER_TAGS` | no | `docker` | Comma-separated job tags |
| `RUNNER_LOCKED` | no | `false` | Lock runner to current project |
| `RUNNER_RUN_UNTAGGED` | no | `true` | Pick up untagged jobs |

## Examples

**Group runner:**
```bash
GITLAB_PAT=glpat-xxxx GROUP_ID=42 bash script.sh
```

**Project runner with custom tags:**
```bash
GITLAB_PAT=glpat-xxxx \
  RUNNER_TYPE=project_type \
  PROJECT_ID=123 \
  RUNNER_TAGS=docker,linux \
  bash script.sh
```

**Self-hosted GitLab instance runner:**
```bash
GITLAB_PAT=glpat-xxxx \
  GITLAB_URL=https://gitlab.example.com \
  GROUP_ID=42 \
  bash script.sh
```

## Generated compose file

The stack is written to `~/docker/gitlab-runner/compose.yml` (permissions `600`).
If a file already exists it is backed up as `compose.yml.<timestamp>.bak` before being overwritten.

The runner is configured with:
- `concurrent = 10` / `request_concurrency = 10`
- `executor = docker`, base image `alpine`
- `network_mode = host`
- Docker socket mounted from the host

## Notes

- Run as a non-root user — `sudo` is prepended automatically where needed.
- The PAT is used **only** to create the runner; it is not stored anywhere by the script.
