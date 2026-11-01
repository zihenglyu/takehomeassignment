#!/usr/bin/env bash
#
# Task 1 helper: build and start the AI Learning Assistant locally with Docker
# Compose, wait until the backend is healthy, then run the Task 1 evidence
# script (scripts/check-local-ui.sh) which writes local-ui-check.txt.
#
# Usage:
#   bash scripts/run-local.sh            # build, start, verify
#   bash scripts/run-local.sh --no-open  # skip opening the browser
#   bash scripts/run-local.sh --down     # stop the Compose project instead
#
# Requires: Docker Desktop (or Docker Engine with the Compose plugin) running.

set -euo pipefail
umask 077

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"

PROJECT_NAME="${AILA_COMPOSE_PROJECT:-ai-learning-assistant}"
BACKEND_PORT="${AILA_BACKEND_PORT:-14242}"
HEALTH_URL="http://127.0.0.1:${BACKEND_PORT}/health"
UI_URL="http://127.0.0.1:${BACKEND_PORT}/ui/"
HEALTH_TIMEOUT_SECONDS="${AILA_HEALTH_TIMEOUT:-180}"

OPEN_BROWSER=true
DO_DOWN=false

usage() {
  cat <<'USAGE'
Usage: bash scripts/run-local.sh [--no-open] [--down]

  --no-open   Verify the UI but do not request the browser to open it.
  --down      Stop and remove the local Compose project, then exit.
  --help      Show this help text.

Environment overrides:
  AILA_BACKEND_PORT      Host port for the UI and API (default: 14242)
  AILA_COMPOSE_PROJECT   Compose project name (default: ai-learning-assistant)
  AILA_HEALTH_TIMEOUT    Seconds to wait for /health (default: 180)
USAGE
}

log() { printf '[local] %s\n' "$*"; }
warn() { printf '[local] WARNING: %s\n' "$*" >&2; }
die() { printf '[local] ERROR: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-open) OPEN_BROWSER=false ;;
    --down) DO_DOWN=true ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH."
command -v curl >/dev/null 2>&1 || die "curl is required to check the health endpoint."

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
  DOCKER=(sudo -n docker)
  warn "the current user cannot access /var/run/docker.sock; using 'sudo -n docker'."
  warn "files created under data/ and workspace/ will be owned by root."
else
  die "cannot access the Docker daemon at /var/run/docker.sock.
       Either the daemon is not running, or this user is not in the 'docker' group.
       Start it:        sudo systemctl enable --now docker
       Fix permissions: sudo usermod -aG docker \$USER   (then reopen the terminal)"
fi

"${DOCKER[@]}" compose version >/dev/null 2>&1 || die "the Docker Compose plugin is not available."

compose() {
  "${DOCKER[@]}" compose -p "${PROJECT_NAME}" -f "${ROOT_DIR}/compose.yml" "$@"
}

if [ "${DO_DOWN}" = true ]; then
  log "Stopping Compose project ${PROJECT_NAME}..."
  compose down
  log "Stopped."
  exit 0
fi

log "Building and starting ${PROJECT_NAME} (this can take a few minutes)..."
compose up --build -d

log "Waiting for ${HEALTH_URL} (timeout: ${HEALTH_TIMEOUT_SECONDS}s)..."
deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  if curl -fsS --noproxy '*' --max-time 3 "${HEALTH_URL}" >/dev/null 2>&1; then
    log "Backend is healthy."
    break
  fi
  sleep 2
done

if ! curl -fsS --noproxy '*' --max-time 5 "${HEALTH_URL}" >/dev/null 2>&1; then
  compose logs --tail=100 backend || true
  die "backend did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s."
fi

if [ "${OPEN_BROWSER}" = true ]; then
  log "Running local UI check and requesting the browser..."
  bash "${ROOT_DIR}/scripts/check-local-ui.sh" --open
else
  log "Running local UI check without opening the browser..."
  bash "${ROOT_DIR}/scripts/check-local-ui.sh"
fi

log "UI URL: ${UI_URL}"
log "Evidence file: ${ROOT_DIR}/local-ui-check.txt"
