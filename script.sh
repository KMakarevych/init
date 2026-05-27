#!/usr/bin/env bash
#
# Deploy GitLab Runner as docker compose stack.
# Creates a runner via /user/runners (new auth-token workflow) and writes
# ~/docker/gitlab-runner/compose.yml with the obtained authentication token.
#
# Required env (or interactive prompt if missing):
#   GITLAB_PAT          — fine-grained PAT with Runner:Create (User boundary)
#
# Optional env:
#   GITLAB_URL          — default: https://gitlab.com
#   RUNNER_TYPE         — instance_type | group_type | project_type (default: group_type)
#   GROUP_ID            — required if RUNNER_TYPE=group_type
#   PROJECT_ID          — required if RUNNER_TYPE=project_type
#   RUNNER_DESCRIPTION  — default: $(hostname)-runner
#   RUNNER_TAGS         — comma-separated, default: docker
#   RUNNER_LOCKED       — true|false (default: false)
#   RUNNER_RUN_UNTAGGED — true|false (default: true)

set -euo pipefail

readonly COMPOSE_DIR="${HOME}/docker/gitlab-runner"
readonly COMPOSE_FILE="${COMPOSE_DIR}/compose.yml"

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[-]\033[0m %s\n' "$*" >&2; exit 1; }

detect_distro() {
  [ -f /etc/os-release ] || err "/etc/os-release not found, cannot detect distro"
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO="${ID:-unknown}"
  DISTRO_LIKE="${ID_LIKE:-}"
  log "Detected distro: ${DISTRO} (${PRETTY_NAME:-unknown})"
}

install_base_packages() {
  log "Installing base packages: jq, curl"
  local pkgs=(jq curl)

  case "$DISTRO" in
    ubuntu|debian|linuxmint|pop)
      $SUDO apt-get update -qq
      $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
      ;;
    fedora|rhel|centos|rocky|almalinux|ol)
      $SUDO dnf install -y -q "${pkgs[@]}"
      ;;
    arch|manjaro|cachyos|endeavouros)
      $SUDO pacman -Sy --noconfirm --needed "${pkgs[@]}"
      ;;
    opensuse*|sles)
      $SUDO zypper --non-interactive install "${pkgs[@]}"
      ;;
    alpine)
      $SUDO apk add --no-cache "${pkgs[@]}"
      ;;
    *)
      # fallback for derivatives via ID_LIKE
      case "$DISTRO_LIKE" in
        *debian*)  $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "${pkgs[@]}" ;;
        *rhel*|*fedora*) $SUDO dnf install -y -q "${pkgs[@]}" ;;
        *arch*)    $SUDO pacman -Sy --noconfirm --needed "${pkgs[@]}" ;;
        *suse*)    $SUDO zypper --non-interactive install "${pkgs[@]}" ;;
        *)         err "Unsupported distro: $DISTRO ($DISTRO_LIKE)" ;;
      esac
      ;;
  esac
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version)"
  else
    case "$DISTRO" in
      arch|manjaro|cachyos|endeavouros)
        log "Installing docker + compose plugin via pacman"
        $SUDO pacman -S --noconfirm --needed docker docker-compose
        ;;
      *)
        log "Installing Docker via https://get.docker.com"
        curl -fsSL https://get.docker.com | $SUDO sh
        ;;
    esac
  fi

  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable --now docker
  fi

  # quick sanity check
  docker compose version >/dev/null 2>&1 \
    || warn "docker compose plugin not found; install docker-compose-plugin manually"
}

prompt_pat() {
  if [ -n "${GITLAB_PAT:-}" ]; then
    log "Using GITLAB_PAT from environment"
    return
  fi
  # When piped (curl|bash) stdin is the pipe, not the terminal.
  # Read from /dev/tty directly to bypass it.
  if [ ! -e /dev/tty ]; then
    err "GITLAB_PAT not set and no TTY available. Run via: curl ... | GITLAB_PAT=xxx bash"
  fi
  read -r -s -p "Enter GitLab PAT (Runner:Create scope): " GITLAB_PAT < /dev/tty
  echo
  [ -n "$GITLAB_PAT" ] || err "PAT is empty"
  export GITLAB_PAT
}

resolve_params() {
  GITLAB_URL="${GITLAB_URL:-https://gitlab.com}"
  RUNNER_TYPE="${RUNNER_TYPE:-group_type}"
  RUNNER_DESCRIPTION="${RUNNER_DESCRIPTION:-$(hostname)-runner}"
  RUNNER_TAGS="${RUNNER_TAGS:-docker}"
  RUNNER_LOCKED="${RUNNER_LOCKED:-false}"
  RUNNER_RUN_UNTAGGED="${RUNNER_RUN_UNTAGGED:-true}"

  case "$RUNNER_TYPE" in
    group_type)
      if [ -z "${GROUP_ID:-}" ]; then
        [ -e /dev/tty ] || err "GROUP_ID not set and no TTY available. Run via: curl ... | GROUP_ID=123 bash"
        read -r -p "Group ID: " GROUP_ID < /dev/tty
        [ -n "$GROUP_ID" ] || err "GROUP_ID is required for group_type"
      fi
      ;;
    project_type)
      if [ -z "${PROJECT_ID:-}" ]; then
        [ -e /dev/tty ] || err "PROJECT_ID not set and no TTY available. Run via: curl ... | PROJECT_ID=123 bash"
        read -r -p "Project ID: " PROJECT_ID < /dev/tty
        [ -n "$PROJECT_ID" ] || err "PROJECT_ID is required for project_type"
      fi
      ;;
    instance_type) ;;
    *) err "Invalid RUNNER_TYPE: $RUNNER_TYPE" ;;
  esac
}

create_runner() {
  log "Creating $RUNNER_TYPE runner on $GITLAB_URL"

  local args=(
    -F "runner_type=${RUNNER_TYPE}"
    -F "description=${RUNNER_DESCRIPTION}"
    -F "tag_list=${RUNNER_TAGS}"
    -F "locked=${RUNNER_LOCKED}"
    -F "run_untagged=${RUNNER_RUN_UNTAGGED}"
  )
  case "$RUNNER_TYPE" in
    group_type)   args+=(-F "group_id=${GROUP_ID}") ;;
    project_type) args+=(-F "project_id=${PROJECT_ID}") ;;
  esac

  local response
  response=$(curl -sS --fail-with-body -X POST \
    -H "PRIVATE-TOKEN: ${GITLAB_PAT}" \
    "${args[@]}" \
    "${GITLAB_URL}/api/v4/user/runners") \
    || err "API call failed: $response"

  RUNNER_TOKEN=$(echo "$response" | jq -r '.token // empty')
  [ -n "$RUNNER_TOKEN" ] || err "Could not extract .token from response: $response"

  local runner_id
  runner_id=$(echo "$response" | jq -r '.id // empty')
  log "Runner created (id=${runner_id})"
}

write_compose() {
  log "Writing $COMPOSE_FILE"
  mkdir -p "$COMPOSE_DIR"

  if [ -f "$COMPOSE_FILE" ]; then
    local backup="${COMPOSE_FILE}.$(date +%Y%m%d-%H%M%S).bak"
    warn "Existing compose.yml found, backing up to $backup"
    cp "$COMPOSE_FILE" "$backup"
  fi

  cat > "$COMPOSE_FILE" <<EOF
configs:
  config.toml:
    content: |
      concurrent = 10
      [[runners]]
        name = "${RUNNER_DESCRIPTION}"
        url = "${GITLAB_URL}"
        token = "${RUNNER_TOKEN}"
        executor = "docker"
        request_concurrency = 10
        [runners.docker]
          image = "alpine"
          network_mode = "host"


services:
  gitlab-runner:
    image: gitlab/gitlab-runner:latest
    container_name: gitlab-runner
    restart: always
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    configs:
      - source: config.toml
        target: /etc/gitlab-runner/config.toml
EOF

  chmod 600 "$COMPOSE_FILE"
}

start_stack() {
  log "Starting docker compose stack"
  ( cd "$COMPOSE_DIR" && $SUDO docker compose up -d )
  log "Done. Tail logs: sudo docker logs -f gitlab-runner"
}

main() {
  detect_distro
  install_base_packages
  install_docker
  prompt_pat
  resolve_params
  create_runner
  write_compose
  start_stack
}

main "$@"