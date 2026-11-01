#!/usr/bin/env bash
#
# Task 2 helper: publish the AI Learning Assistant image to Alibaba Cloud
# Container Registry (ACR) and run it on an Aliyun ECS instance on port 14242.
#
# The script can run on your own computer (it will SSH into the ECS) or directly
# on the ECS instance. It never writes secrets into the repository; configuration
# is read from environment variables or from an untracked env file.
#
# Quick start (recommended):
#   1. Copy scripts/deploy-ecs.env.example to .env.ecs and fill in the values.
#   2. Run:  bash scripts/deploy-ecs.sh all --env-file .env.ecs
#
# Modes:
#   all          build + push to ACR, then deploy on ECS over SSH, then collect
#                ecs-docker-check.txt back into the project folder (default)
#   build-push   build a linux/amd64 image and push it to ACR (run locally)
#   server       pull the image on this machine and run it on port 14242
#                (run on the ECS instance)
#   check        verify the running container and write ecs-docker-check.txt
#                (run on the ECS instance)
#
# Common options:
#   --env-file FILE   Load configuration from FILE (default: .env.ecs if present)
#   --mode MODE       Same as passing MODE as the first argument
#   -y, --yes         Do not ask for confirmation before changing the ECS host
#   -h, --help        Show this help

set -euo pipefail
umask 077

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename "${BASH_SOURCE[0]}")"
  ROOT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
else
  SCRIPT_PATH=""
  ROOT_DIR="${AILA_PROJECT_ROOT:-${PWD}}"
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
log() { printf '[deploy] %s\n' "$*"; }
warn() { printf '[deploy] WARNING: %s\n' "$*" >&2; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: bash scripts/deploy-ecs.sh [MODE] [options]

Modes:
  all          build + push to ACR, deploy on the ECS over SSH, collect evidence
  build-push   build a linux/amd64 image and push it to ACR (local machine)
  server       pull the image and run it on port 14242 (on the ECS instance)
  check        verify the running container and write ecs-docker-check.txt

Options:
  --env-file FILE   Load configuration from FILE (default: .env.ecs if present)
  --mode MODE       Same as passing MODE as the first argument
  -y, --yes         Do not ask for confirmation before changing the ECS host
  -h, --help        Show this help

Required configuration (environment or env file):
  ACR_NAMESPACE, ACR_USERNAME, ACR_PASSWORD
  ECS_HOST (mode all only), plus optional ECS_USER, ECS_PORT, ECS_SSH_KEY,
  ECS_APP_DIR, ECS_PUBLIC_IP, IMAGE_TAG, MODEL_API_KEY.
  BUILD_MODE=auto|buildx|docker selects the image builder (default: auto).

See scripts/deploy-ecs.env.example for a template.
USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE="all"
ENV_FILE=""
ASSUME_YES=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    all|build-push|server|check) MODE="$1" ;;
    --mode) MODE="${2:-}"; shift ;;
    --mode=*) MODE="${1#*=}" ;;
    --env-file) ENV_FILE="${2:-}"; shift ;;
    --env-file=*) ENV_FILE="${1#*=}" ;;
    -y|--yes) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

case "${MODE}" in
  all|build-push|server|check) ;;
  *) die "unknown mode: ${MODE} (expected all, build-push, server, or check)" ;;
esac

load_env_file() {
  local file="$1"
  [ -n "${file}" ] || return 0
  [ -f "${file}" ] || die "environment file not found: ${file}"
  log "Loading configuration from ${file}"
  set -a
  # shellcheck disable=SC1090
  . "${file}"
  set +a
}

if [ -z "${ENV_FILE}" ]; then
  if [ -f "${ROOT_DIR}/.env.ecs" ]; then
    ENV_FILE="${ROOT_DIR}/.env.ecs"
  elif [ -f "${ROOT_DIR}/scripts/deploy-ecs.env" ]; then
    ENV_FILE="${ROOT_DIR}/scripts/deploy-ecs.env"
  fi
fi
load_env_file "${ENV_FILE}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ACR_REGISTRY="${ACR_REGISTRY:-registry.cn-hangzhou.aliyuncs.com}"
ACR_NAMESPACE="${ACR_NAMESPACE:-}"
ACR_REPO="${ACR_REPO:-ai-learning-assistant}"
ACR_USERNAME="${ACR_USERNAME:-}"
ACR_PASSWORD="${ACR_PASSWORD:-}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE="${AILA_IMAGE:-${ACR_REGISTRY}/${ACR_NAMESPACE}/${ACR_REPO}:${IMAGE_TAG}}"
PLATFORM="${PLATFORM:-linux/amd64}"

ECS_HOST="${ECS_HOST:-}"
ECS_USER="${ECS_USER:-root}"
ECS_PORT="${ECS_PORT:-22}"
ECS_SSH_KEY="${ECS_SSH_KEY:-}"
ECS_APP_DIR="${ECS_APP_DIR:-/opt/ai-learning-assistant}"
ECS_PUBLIC_IP="${ECS_PUBLIC_IP:-}"
BACKEND_PORT="${AILA_BACKEND_PORT:-14242}"
COMPOSE_PROJECT="${AILA_COMPOSE_PROJECT:-ai-learning-assistant}"

MODEL_PROVIDER="${MODEL_PROVIDER:-openai_compatible}"
MODEL_BASE_URL="${MODEL_BASE_URL:-https://dashscope.aliyuncs.com/compatible-mode/v1}"
MODEL_NAME="${MODEL_NAME:-qwen3.6-flash}"
MODEL_API_KEY="${MODEL_API_KEY:-}"
MODEL_CONTEXT_WINDOW="${MODEL_CONTEXT_WINDOW:-1000000}"
MODEL_SUPPORTS_STREAMING="${MODEL_SUPPORTS_STREAMING:-true}"

require_var() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    die "missing required configuration: ${name} (set it in the environment or env file)"
  fi
}

require_path_without_spaces() {
  local name="$1" value="$2"
  case "${value}" in
    *[[:space:]]*) die "${name} must not contain spaces: ${value}" ;;
  esac
}

require_acr() {
  require_var ACR_NAMESPACE
  require_var ACR_USERNAME
  require_var ACR_PASSWORD
  require_var ACR_REGISTRY
}

detect_docker() {
  command -v docker >/dev/null 2>&1 || die \
    "docker is not installed on $(hostname); install Docker Engine and the Compose plugin first (https://get.docker.com)."
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
    warn "using 'sudo -n docker' because the current user cannot access the Docker daemon."
  else
    die "cannot access the Docker daemon (add the user to the docker group or run as root)."
  fi
  "${DOCKER[@]}" compose version >/dev/null 2>&1 \
    || die "the Docker Compose plugin is not available on $(hostname)."
}

# Run a command with sudo only when Docker itself needed sudo.
as_root() {
  if [ "${DOCKER[0]:-}" = "sudo" ]; then
    sudo -n "$@"
  else
    "$@"
  fi
}

# Write a file (content on stdin) with correct ownership and mode.
write_protected_file() {
  local target="$1" mode="$2"
  if [ "${DOCKER[0]:-}" = "sudo" ]; then
    sudo -n tee "${target}" >/dev/null
    sudo -n chmod "${mode}" "${target}"
  else
    cat > "${target}"
    chmod "${mode}" "${target}"
  fi
}

acr_login() {
  log "Logging in to ${ACR_REGISTRY} as ${ACR_USERNAME}..."
  printf '%s' "${ACR_PASSWORD}" | "${DOCKER[@]}" login "${ACR_REGISTRY}" \
    --username "${ACR_USERNAME}" --password-stdin >/dev/null
}

# ---------------------------------------------------------------------------
# build-push
# ---------------------------------------------------------------------------
build_push() {
  require_acr
  detect_docker

  log "Image: ${IMAGE}"
  log "Platform: ${PLATFORM}"
  acr_login

  local build_mode="${BUILD_MODE:-auto}"
  if [ "${build_mode}" = "auto" ]; then
    if "${DOCKER[@]}" buildx version >/dev/null 2>&1; then
      build_mode="buildx"
    else
      build_mode="docker"
    fi
  fi

  if [ "${build_mode}" = "buildx" ]; then
    log "Building with buildx (attestations disabled for ACR compatibility)..."
    # --provenance=false/--sbom=false keep the pushed image a plain single
    # manifest. Alibaba Cloud ACR rejects the extra "empty" attestation manifest
    # with: unknown manifest class for application/vnd.oci.empty.v1+json
    "${DOCKER[@]}" buildx build \
      --platform "${PLATFORM}" \
      --provenance=false \
      --sbom=false \
      -f "${ROOT_DIR}/Dockerfile" \
      -t "${IMAGE}" \
      --load \
      "${ROOT_DIR}"
  else
    log "Building with plain docker build (BUILD_MODE=${build_mode})..."
    "${DOCKER[@]}" build \
      --platform "${PLATFORM}" \
      -f "${ROOT_DIR}/Dockerfile" \
      -t "${IMAGE}" \
      "${ROOT_DIR}"
  fi

  log "Pushing ${IMAGE} to ACR..."
  "${DOCKER[@]}" push "${IMAGE}"
  log "Push complete."
}

# ---------------------------------------------------------------------------
# server (runs on the ECS instance)
# ---------------------------------------------------------------------------
write_env_file() {
  local target="$1"
  write_protected_file "${target}" 600 <<ENVFILE
AILA_IMAGE=${IMAGE}
AILA_BACKEND_PORT=${BACKEND_PORT}
MODEL_PROVIDER=${MODEL_PROVIDER}
MODEL_BASE_URL=${MODEL_BASE_URL}
MODEL_NAME=${MODEL_NAME}
MODEL_API_KEY=${MODEL_API_KEY}
MODEL_KEY_ENCRYPTION_KEY=
MODEL_KEY_ENCRYPTION_FILE=/app/data/model-key-encryption.key
MODEL_SECRET_FILE=/app/data/model-secrets.env
MODEL_CONTEXT_WINDOW=${MODEL_CONTEXT_WINDOW}
MODEL_SUPPORTS_STREAMING=${MODEL_SUPPORTS_STREAMING}
ENVFILE
}

write_compose_file() {
  local target="$1"
  write_protected_file "${target}" 644 <<'YAML'
services:
  backend:
    image: ${AILA_IMAGE}
    env_file:
      - .env
    ports:
      - "${AILA_BACKEND_PORT:-14242}:14242"
    environment:
      APP_SQLITE_PATH: /app/data/app.sqlite
      WORKSPACE_ROOT: /app/workspace
    volumes:
      - ./data:/app/data
      - ./workspace:/app/workspace
    restart: unless-stopped
    healthcheck:
      test:
        - CMD
        - python
        - -c
        - "import urllib.request; urllib.request.urlopen('http://127.0.0.1:14242/health', timeout=2).read()"
      interval: 10s
      timeout: 3s
      retries: 12
      start_period: 10s
YAML
}

compose_server() {
  "${DOCKER[@]}" compose -p "${COMPOSE_PROJECT}" -f "${ECS_APP_DIR}/compose.yml" "$@"
}

wait_for_health() {
  local url="http://127.0.0.1:${BACKEND_PORT}/health"
  local attempt status
  log "Waiting for the backend health check ..."
  for attempt in $(seq 1 60); do
    if command -v curl >/dev/null 2>&1; then
      if curl -fsS --noproxy '*' --connect-timeout 3 --max-time 5 "${url}" >/dev/null 2>&1; then
        log "Health check passed."
        return 0
      fi
    else
      status="$("${DOCKER[@]}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$(compose_server ps -q backend 2>/dev/null)" 2>/dev/null || true)"
      if [ "${status}" = "healthy" ] || [ "${status}" = "running" ]; then
        log "Container state is '${status}' (curl is unavailable; state check used)."
        return 0
      fi
    fi
    sleep 2
  done
  compose_server logs --tail=100 backend || true
  die "the container did not become healthy within 120 seconds."
}

server_mode() {
  require_acr
  require_path_without_spaces ECS_APP_DIR "${ECS_APP_DIR}"
  detect_docker

  log "Preparing application directory ${ECS_APP_DIR} on $(hostname)..."
  as_root mkdir -p "${ECS_APP_DIR}/data" "${ECS_APP_DIR}/workspace"
  write_env_file "${ECS_APP_DIR}/.env"
  write_compose_file "${ECS_APP_DIR}/compose.yml"

  acr_login

  log "Pulling ${IMAGE}..."
  compose_server pull

  log "Starting the container on 0.0.0.0:${BACKEND_PORT}..."
  compose_server up -d

  wait_for_health
  compose_server ps

  log "Running container:"
  "${DOCKER[@]}" ps --filter "publish=${BACKEND_PORT}" \
    --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

  warn "Open TCP ${BACKEND_PORT} in the ECS security group for your own public IP only."
}

# ---------------------------------------------------------------------------
# check (runs on the ECS instance; writes ecs-docker-check.txt)
# ---------------------------------------------------------------------------
resolve_public_ip() {
  if [ -n "${ECS_PUBLIC_IP}" ]; then
    printf '%s' "${ECS_PUBLIC_IP}"
    return 0
  fi
  local detected=""
  detected="$(curl --noproxy '*' -4 -sS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  if [ -z "${detected}" ]; then
    detected="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "${detected}" ]; then
    die "cannot determine the ECS public IPv4 address; set ECS_PUBLIC_IP."
  fi
  printf '%s' "${detected}"
}

check_mode() {
  detect_docker
  command -v curl >/dev/null 2>&1 \
    || die "curl is required for the website check; install it with 'sudo apt install curl'."

  local public_ip output_file writer report
  public_ip="$(resolve_public_ip)"

  if [ -n "${AILA_CHECK_OUTPUT:-}" ]; then
    output_file="${AILA_CHECK_OUTPUT}"
  elif [ -d "${ECS_APP_DIR}" ]; then
    output_file="${ECS_APP_DIR}/ecs-docker-check.txt"
  else
    output_file="${ROOT_DIR}/ecs-docker-check.txt"
  fi

  if [ -w "${output_file}" ] || [ -w "$(dirname "${output_file}")" ]; then
    writer=(tee "${output_file}")
  elif [ "${DOCKER[0]:-}" = "sudo" ]; then
    writer=(sudo -n tee "${output_file}")
  else
    die "cannot write ${output_file}; set AILA_CHECK_OUTPUT to a writable path."
  fi

  report="$(
    {
      printf 'AI Learning Assistant ECS Web Interface Check\n'
      date '+Time (local): %Y-%m-%dT%H:%M:%S%z'
      date -u '+Time (UTC): %Y-%m-%dT%H:%M:%SZ'
      printf 'Machine: %s\n' "$(hostname)"
      printf 'Operating system: %s\n' "$(uname -sr)"
      printf 'CPU architecture: %s\n' "$(uname -m)"
      printf 'ECS login user: %s\n' "$(whoami)"
      printf 'Website URL: http://%s:%s/ui/\n' "${public_ip}" "${BACKEND_PORT}"
      "${DOCKER[@]}" --version
      printf '\nDocker application container:\n'
      "${DOCKER[@]}" ps -a --filter "publish=${BACKEND_PORT}" \
        --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
      printf '\nWebsite URL check from ECS:\n'
      UI_HTTP_STATUS=$(curl --noproxy '*' -sS --connect-timeout 5 --max-time 15 \
        -o /dev/null -w '%{http_code}' "http://${public_ip}:${BACKEND_PORT}/ui/")
      CURL_EXIT_CODE=$?
      printf 'HTTP status: %s\n' "${UI_HTTP_STATUS}"
      if [ "${CURL_EXIT_CODE}" -eq 0 ] && [ "${UI_HTTP_STATUS}" = '200' ]; then
        printf 'Website URL check: PASS\n'
      else
        printf 'Website URL check: FAIL (curl exit code: %s)\n' "${CURL_EXIT_CODE}"
      fi
    } 2>&1 | "${writer[@]}"
  )"
  printf '%s\n' "${report}"

  if [ "${DOCKER[0]:-}" = "sudo" ]; then
    sudo -n chmod 644 "${output_file}" 2>/dev/null || true
  fi

  log "Wrote ${output_file}"

  case "${report}" in
    *"Website URL check: PASS"*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# all (runs on the local computer and drives the ECS over SSH)
# ---------------------------------------------------------------------------
remote_ssh() {
  local args=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -p "${ECS_PORT}")
  if [ -n "${ECS_SSH_KEY}" ]; then
    args+=(-i "${ECS_SSH_KEY}")
  fi
  ssh "${args[@]}" "${ECS_USER}@${ECS_HOST}" "$@"
}

remote_scp() {
  local args=(-q -o BatchMode=yes -o StrictHostKeyChecking=accept-new -P "${ECS_PORT}")
  if [ -n "${ECS_SSH_KEY}" ]; then
    args+=(-i "${ECS_SSH_KEY}")
  fi
  scp "${args[@]}" "$@"
}

run_remote_script() {
  local remote_args="$1"
  # The deployment script is piped to the remote bash, so nothing has to be
  # installed on the ECS instance beyond Docker.
  remote_ssh "bash -s -- ${remote_args}" < "${SCRIPT_PATH}"
}

all_mode() {
  require_acr
  require_var ECS_HOST
  require_path_without_spaces ECS_HOST "${ECS_HOST}"
  require_path_without_spaces ECS_APP_DIR "${ECS_APP_DIR}"
  [ -n "${SCRIPT_PATH}" ] || die "run 'all' from the script file, not from a pipe."

  build_push

  local remote_env="/tmp/aila-deploy-$$.env"
  local tmp_env
  tmp_env="$(mktemp "${TMPDIR:-/tmp}/aila-deploy-env.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp_env}'" EXIT

  {
    printf 'ACR_REGISTRY=%q\n' "${ACR_REGISTRY}"
    printf 'ACR_NAMESPACE=%q\n' "${ACR_NAMESPACE}"
    printf 'ACR_REPO=%q\n' "${ACR_REPO}"
    printf 'ACR_USERNAME=%q\n' "${ACR_USERNAME}"
    printf 'ACR_PASSWORD=%q\n' "${ACR_PASSWORD}"
    printf 'AILA_IMAGE=%q\n' "${IMAGE}"
    printf 'AILA_BACKEND_PORT=%q\n' "${BACKEND_PORT}"
    printf 'AILA_COMPOSE_PROJECT=%q\n' "${COMPOSE_PROJECT}"
    printf 'ECS_APP_DIR=%q\n' "${ECS_APP_DIR}"
    printf 'ECS_PUBLIC_IP=%q\n' "${ECS_PUBLIC_IP}"
    printf 'MODEL_PROVIDER=%q\n' "${MODEL_PROVIDER}"
    printf 'MODEL_BASE_URL=%q\n' "${MODEL_BASE_URL}"
    printf 'MODEL_NAME=%q\n' "${MODEL_NAME}"
    printf 'MODEL_API_KEY=%q\n' "${MODEL_API_KEY}"
    printf 'MODEL_CONTEXT_WINDOW=%q\n' "${MODEL_CONTEXT_WINDOW}"
    printf 'MODEL_SUPPORTS_STREAMING=%q\n' "${MODEL_SUPPORTS_STREAMING}"
  } > "${tmp_env}"

  if [ "${ASSUME_YES}" = false ]; then
    printf '[deploy] About to deploy %s on %s@%s:%s. Continue? [y/N] ' \
      "${IMAGE}" "${ECS_USER}" "${ECS_HOST}" "${ECS_PORT}"
    read -r reply
    case "${reply}" in
      y|Y|yes|YES) ;;
      *) die "aborted by user." ;;
    esac
  fi

  log "Copying configuration to ${ECS_HOST}..."
  remote_scp "${tmp_env}" "${ECS_USER}@${ECS_HOST}:${remote_env}"
  remote_ssh "chmod 600 '${remote_env}'"

  log "Deploying on ${ECS_HOST}..."
  run_remote_script "server --env-file ${remote_env}"

  log "Verifying the public URL from the ECS instance..."
  local check_failed=0
  run_remote_script "check --env-file ${remote_env}" || check_failed=1

  log "Copying ecs-docker-check.txt back to ${ROOT_DIR}..."
  remote_scp \
    "${ECS_USER}@${ECS_HOST}:${ECS_APP_DIR}/ecs-docker-check.txt" \
    "${ROOT_DIR}/ecs-docker-check.txt"

  remote_ssh "rm -f '${remote_env}'" || warn "could not remove ${remote_env} on the ECS instance."

  if [ "${check_failed}" -ne 0 ]; then
    warn "the ECS website check reported FAIL; inspect the copied ecs-docker-check.txt."
    warn "Common causes: port ${BACKEND_PORT} is not open in the security group for your IP,"
    warn "or ECS_PUBLIC_IP is not the instance's public IPv4 address."
    exit 1
  fi

  log "Done. Evidence file: ${ROOT_DIR}/ecs-docker-check.txt"
  log "Open http://${ECS_PUBLIC_IP:-<public-ip>}:${BACKEND_PORT}/ui/ from your own computer."
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${MODE}" in
  build-push) build_push ;;
  server) server_mode ;;
  check) check_mode ;;
  all) all_mode ;;
esac
