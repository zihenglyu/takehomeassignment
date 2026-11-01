#!/usr/bin/env bash
#
# Task 3 helper: publish the AI Learning Assistant through a domain name with
# Nginx, a Let's Encrypt certificate (Certbot), and HTTP Basic Authentication.
#
# This script runs ON the ECS instance (as root). It can also be launched from
# your own computer, in which case it copies itself to the ECS over SSH and runs
# there.
#
# Quick start (from your own computer):
#   1. Add DOMAIN / CERTBOT_EMAIL / BASIC_AUTH_USER to .env.ecs
#      (see scripts/setup-https.env.example).
#   2. bash scripts/setup-https.sh all --env-file .env.ecs
#
# On the ECS instance itself:
#   sudo bash scripts/setup-https.sh server --env-file .env.ecs
#
# What it does:
#   1. verifies the DNS A record points at the ECS public IP
#   2. installs nginx, certbot, python3-certbot-nginx and apache2-utils
#   3. writes /etc/nginx/sites-available/ai-agent (HTTP reverse proxy)
#   4. creates the Basic Auth file /etc/nginx/.htpasswd
#   5. enables the site, tests and reloads nginx
#   6. obtains a certificate with Certbot and enables HTTP -> HTTPS redirect
#   7. verifies 401 without credentials and 200 with credentials
#   8. writes https-domain-check.txt (copied back to your project folder)
#
# Options:
#   --env-file FILE   Load configuration from FILE (default: .env.ecs if present)
#   --domain NAME     Domain or subdomain (overrides DOMAIN)
#   --email ADDR      Certbot account e-mail (overrides CERTBOT_EMAIL)
#   --user NAME       Basic Auth user name (overrides BASIC_AUTH_USER)
#   --password VALUE  Basic Auth password (overrides BASIC_AUTH_PASSWORD)
#   --skip-dns-check  Do not fail when the A record does not match ECS_PUBLIC_IP
#   -y, --yes         Do not ask for confirmation before changing the host
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

log() { printf '[https] %s\n' "$*"; }
warn() { printf '[https] WARNING: %s\n' "$*" >&2; }
die() { printf '[https] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: bash scripts/setup-https.sh [MODE] [options]

Modes:
  all      drive the ECS instance over SSH from this computer (default)
  server   run directly on the ECS instance (must be root)

Options:
  --env-file FILE   Load configuration from FILE (default: .env.ecs if present)
  --domain NAME     Domain or subdomain (overrides DOMAIN)
  --email ADDR      Certbot account e-mail (overrides CERTBOT_EMAIL)
  --user NAME       Basic Auth user name (overrides BASIC_AUTH_USER)
  --password VALUE  Basic Auth password (overrides BASIC_AUTH_PASSWORD)
  --skip-dns-check  Do not fail when the A record does not match ECS_PUBLIC_IP
  -y, --yes         Do not ask for confirmation before changing the host
  -h, --help        Show this help

Required configuration:
  DOMAIN, CERTBOT_EMAIL, and ECS_HOST for mode all.
  Optional: ECS_USER (default root), ECS_PORT, ECS_SSH_KEY, ECS_PUBLIC_IP,
  AILA_BACKEND_PORT (default 14242), BASIC_AUTH_USER, BASIC_AUTH_PASSWORD.
  If BASIC_AUTH_PASSWORD is empty, a random password is generated and printed.

Before running: create a DNS A record DOMAIN -> ECS public IPv4, and allow
inbound TCP 80 and 443 in the ECS security group.
USAGE
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
MODE="all"
ENV_FILE=""
ASSUME_YES=false
SKIP_DNS_CHECK="${SKIP_DNS_CHECK:-0}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    all|server) MODE="$1" ;;
    --mode) MODE="${2:-}"; shift ;;
    --mode=*) MODE="${1#*=}" ;;
    --env-file) ENV_FILE="${2:-}"; shift ;;
    --env-file=*) ENV_FILE="${1#*=}" ;;
    --domain) DOMAIN="${2:-}"; shift ;;
    --domain=*) DOMAIN="${1#*=}" ;;
    --email) CERTBOT_EMAIL="${2:-}"; shift ;;
    --email=*) CERTBOT_EMAIL="${1#*=}" ;;
    --user) BASIC_AUTH_USER="${2:-}"; shift ;;
    --user=*) BASIC_AUTH_USER="${1#*=}" ;;
    --password) BASIC_AUTH_PASSWORD="${2:-}"; shift ;;
    --password=*) BASIC_AUTH_PASSWORD="${1#*=}" ;;
    --skip-dns-check) SKIP_DNS_CHECK=1 ;;
    -y|--yes) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

case "${MODE}" in
  all|server) ;;
  *) die "unknown mode: ${MODE} (expected all or server)" ;;
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
  elif [ -f "${ROOT_DIR}/scripts/setup-https.env" ]; then
    ENV_FILE="${ROOT_DIR}/scripts/setup-https.env"
  fi
fi
load_env_file "${ENV_FILE}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DOMAIN="${DOMAIN:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-student}"
BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-}"
ECS_HOST="${ECS_HOST:-}"
ECS_USER="${ECS_USER:-root}"
ECS_PORT="${ECS_PORT:-22}"
ECS_SSH_KEY="${ECS_SSH_KEY:-}"
ECS_PUBLIC_IP="${ECS_PUBLIC_IP:-}"
BACKEND_PORT="${AILA_BACKEND_PORT:-14242}"
EVIDENCE_FILE="${AILA_HTTPS_EVIDENCE:-/root/https-domain-check.txt}"

SITE_NAME="ai-agent"
SITE_FILE="/etc/nginx/sites-available/${SITE_NAME}"
SITE_LINK="/etc/nginx/sites-enabled/${SITE_NAME}"
HTPASSWD_FILE="/etc/nginx/.htpasswd"
ACME_ROOT="/var/www/html"

require_var() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    die "missing required configuration: ${name} (set it in the environment or env file)"
  fi
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "this mode must run as root; use: sudo bash scripts/setup-https.sh ${MODE}"
  fi
}

install_packages() {
  command -v apt-get >/dev/null 2>&1 \
    || die "this script expects an apt-based system (Ubuntu/Debian)."
  log "Installing nginx, certbot and apache2-utils..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq nginx certbot python3-certbot-nginx apache2-utils curl openssl
}

resolve_domain_ip() {
  getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk '{print $1; exit}'
}

detect_public_ip() {
  if [ -n "${ECS_PUBLIC_IP}" ]; then
    printf '%s' "${ECS_PUBLIC_IP}"
    return 0
  fi
  local detected
  detected="$(curl --noproxy '*' -4 -sS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  if [ -z "${detected}" ]; then
    detected="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "${detected}"
}

check_dns() {
  local resolved public_ip
  resolved="$(resolve_domain_ip)"
  if [ -z "${resolved}" ]; then
    if [ "${SKIP_DNS_CHECK}" = "1" ]; then
      warn "${DOMAIN} does not resolve; continuing because --skip-dns-check was used."
      return 0
    fi
    die "${DOMAIN} does not resolve. Create an A record pointing to the ECS public IPv4 first."
  fi
  log "${DOMAIN} resolves to ${resolved}"
  public_ip="$(detect_public_ip)"
  if [ -z "${public_ip}" ]; then
    warn "cannot determine the ECS public IPv4; skipping the A-record comparison."
    return 0
  fi
  if [ "${resolved}" != "${public_ip}" ]; then
    if [ "${SKIP_DNS_CHECK}" = "1" ]; then
      warn "${DOMAIN} points at ${resolved}, but this host is ${public_ip}; continuing anyway."
      return 0
    fi
    die "${DOMAIN} points at ${resolved}, but this host is ${public_ip}. Fix the A record (or use --skip-dns-check)."
  fi
  log "A record matches this host (${public_ip})."
}

check_backend() {
  local url="http://127.0.0.1:${BACKEND_PORT}/health"
  if curl -fsS --noproxy '*' --connect-timeout 3 --max-time 5 "${url}" >/dev/null 2>&1; then
    log "Backend is healthy at ${url}."
    return 0
  fi
  warn "the backend at ${url} is not responding; Nginx will return 502 until it is running."
  warn "start it first with: bash scripts/deploy-ecs.sh server --env-file .env.ecs"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    log "Allowing 80/tcp and 443/tcp in ufw..."
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
  else
    log "ufw is not active; open TCP 80 and 443 in the Alibaba Cloud security group."
  fi
}

write_site_config() {
  log "Writing ${SITE_FILE} ..."
  mkdir -p "${ACME_ROOT}" /var/www/html
  cat > "${SITE_FILE}" <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;

    client_max_body_size 64m;

    # Let's Encrypt HTTP-01 challenge must stay reachable without auth.
    location ^~ /.well-known/acme-challenge/ {
        auth_basic off;
        root /var/www/html;
        default_type "text/plain";
        try_files $uri =404;
    }

    location / {
        auth_basic "AI Learning Assistant";
        auth_basic_user_file /etc/nginx/.htpasswd;

        proxy_pass http://127.0.0.1:14242;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "";

        proxy_read_timeout 360s;
        proxy_send_timeout 360s;
        proxy_buffering off;
    }
}
NGINX
  sed -i "s/__DOMAIN__/${DOMAIN}/g" "${SITE_FILE}"
  sed -i "s|proxy_pass http://127.0.0.1:14242;|proxy_pass http://127.0.0.1:${BACKEND_PORT};|" "${SITE_FILE}"
  ln -sfn "${SITE_FILE}" "${SITE_LINK}"
}

configure_basic_auth() {
  require_var BASIC_AUTH_USER
  if [ -z "${BASIC_AUTH_PASSWORD}" ]; then
    BASIC_AUTH_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)"
    warn "generated Basic Auth password for user '${BASIC_AUTH_USER}': ${BASIC_AUTH_PASSWORD}"
    warn "store it safely; it is not written to the report or the repository."
  fi
  log "Creating Basic Auth file ${HTPASSWD_FILE} for user '${BASIC_AUTH_USER}' ..."
  if printf '%s\n' "${BASIC_AUTH_PASSWORD}" | htpasswd -ci "${HTPASSWD_FILE}" "${BASIC_AUTH_USER}" 2>/dev/null; then
    :
  else
    htpasswd -bc "${HTPASSWD_FILE}" "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASSWORD}" >/dev/null
  fi
  chmod 640 "${HTPASSWD_FILE}"
  chown root:www-data "${HTPASSWD_FILE}" 2>/dev/null || true
}

reload_nginx() {
  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
  log "Nginx configuration tested and reloaded."
}

http_status() {
  local url="$1"; shift
  curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 20 "$@" "${url}" || true
}

enable_https() {
  require_var CERTBOT_EMAIL
  log "Requesting a Let's Encrypt certificate for ${DOMAIN} ..."
  if certbot --nginx -d "${DOMAIN}" \
      --non-interactive --agree-tos --email "${CERTBOT_EMAIL}" --redirect \
      --keep-until-expiring; then
    log "Certificate installed; HTTP now redirects to HTTPS."
  else
    die "certbot failed. Check that ports 80/443 are open in the security group and that the A record is correct."
  fi
  systemctl reload nginx 2>/dev/null || true
}

write_evidence() {
  local redirect_status https_noauth https_auth certificate resolved
  resolved="$(resolve_domain_ip)"
  redirect_status="$(http_status "http://${DOMAIN}/ui/")"
  https_noauth="$(http_status "https://${DOMAIN}/ui/")"
  https_auth="$(http_status "https://${DOMAIN}/ui/" -u "${BASIC_AUTH_USER}:${BASIC_AUTH_PASSWORD}")"
  certificate="$(echo | openssl s_client -servername "${DOMAIN}" -connect "${DOMAIN}:443" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates 2>/dev/null || true)"

  {
    printf 'AI Learning Assistant HTTPS Domain Check\n'
    date '+Time (local): %Y-%m-%dT%H:%M:%S%z'
    date -u '+Time (UTC): %Y-%m-%dT%H:%M:%SZ'
    printf 'Machine: %s\n' "$(hostname)"
    printf 'Domain: %s\n' "${DOMAIN}"
    printf 'Resolved IPv4: %s\n' "${resolved:-unknown}"
    printf 'Backend: http://127.0.0.1:%s\n' "${BACKEND_PORT}"
    printf 'Nginx site: %s\n' "${SITE_FILE}"
    printf 'Access control: HTTP Basic Auth (user: %s)\n' "${BASIC_AUTH_USER}"
    printf '\nHTTP check (expect 301 redirect to HTTPS):\n'
    printf 'http://%s/ui/ -> HTTP %s\n' "${DOMAIN}" "${redirect_status}"
    printf '\nHTTPS check without credentials (expect 401):\n'
    printf 'https://%s/ui/ -> HTTP %s\n' "${DOMAIN}" "${https_noauth}"
    printf '\nHTTPS check with Basic Auth credentials (expect 200):\n'
    printf 'https://%s/ui/ -> HTTP %s\n' "${DOMAIN}" "${https_auth}"
    printf '\nCertificate:\n'
    printf '%s\n' "${certificate:-unavailable}"
    printf '\nResult: '
    if [ "${https_auth}" = "200" ] && [ "${https_noauth}" = "401" ]; then
      printf 'PASS\n'
    else
      printf 'FAIL\n'
    fi
  } 2>&1 | tee "${EVIDENCE_FILE}"

  log "Wrote ${EVIDENCE_FILE}"
  case "$(cat "${EVIDENCE_FILE}")" in
    *"Result: PASS"*) return 0 ;;
  esac
  return 1
}

server_mode() {
  require_root
  require_var DOMAIN
  require_var CERTBOT_EMAIL

  log "Domain: ${DOMAIN}"
  log "Backend port: ${BACKEND_PORT}"

  install_packages
  check_dns
  check_backend
  open_firewall
  write_site_config
  configure_basic_auth
  reload_nginx
  enable_https

  local evidence_failed=0
  write_evidence || evidence_failed=1

  warn "Now remove the public inbound rule for TCP ${BACKEND_PORT} in the ECS security group;"
  warn "only 80/443 should remain reachable from the internet."
  warn "Take a screenshot of https://${DOMAIN}/ui/ after the Basic Auth prompt, with the address bar visible."

  if [ "${evidence_failed}" -ne 0 ]; then
    warn "the HTTPS check reported FAIL; inspect ${EVIDENCE_FILE}."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# all (drive the ECS over SSH)
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

all_mode() {
  require_var DOMAIN
  require_var CERTBOT_EMAIL
  require_var ECS_HOST
  [ -n "${SCRIPT_PATH}" ] || die "run 'all' from the script file, not from a pipe."

  if [ "${ASSUME_YES}" = false ]; then
    printf '[https] Configure %s on %s@%s (Nginx + Certbot + Basic Auth). Continue? [y/N] ' \
      "${DOMAIN}" "${ECS_USER}" "${ECS_HOST}"
    read -r reply
    case "${reply}" in
      y|Y|yes|YES) ;;
      *) die "aborted by user." ;;
    esac
  fi

  local remote_env="/tmp/aila-https-$$.env"
  local tmp_env
  tmp_env="$(mktemp "${TMPDIR:-/tmp}/aila-https-env.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp_env}'" EXIT

  {
    printf 'DOMAIN=%q\n' "${DOMAIN}"
    printf 'CERTBOT_EMAIL=%q\n' "${CERTBOT_EMAIL}"
    printf 'BASIC_AUTH_USER=%q\n' "${BASIC_AUTH_USER}"
    printf 'BASIC_AUTH_PASSWORD=%q\n' "${BASIC_AUTH_PASSWORD}"
    printf 'ECS_PUBLIC_IP=%q\n' "${ECS_PUBLIC_IP}"
    printf 'AILA_BACKEND_PORT=%q\n' "${BACKEND_PORT}"
    printf 'AILA_HTTPS_EVIDENCE=%q\n' "${EVIDENCE_FILE}"
    printf 'SKIP_DNS_CHECK=%q\n' "${SKIP_DNS_CHECK}"
  } > "${tmp_env}"

  log "Copying configuration to ${ECS_HOST} ..."
  remote_scp "${tmp_env}" "${ECS_USER}@${ECS_HOST}:${remote_env}"
  remote_ssh "chmod 600 '${remote_env}'"

  log "Configuring HTTPS on ${ECS_HOST} ..."
  remote_ssh "bash -s -- server --env-file ${remote_env}" < "${SCRIPT_PATH}"

  log "Copying the evidence file back to ${ROOT_DIR} ..."
  remote_scp "${ECS_USER}@${ECS_HOST}:${EVIDENCE_FILE}" "${ROOT_DIR}/https-domain-check.txt"

  remote_ssh "rm -f '${remote_env}'" || warn "could not remove ${remote_env} on the ECS instance."

  log "Done. Evidence file: ${ROOT_DIR}/https-domain-check.txt"
  log "Open https://${DOMAIN}/ui/ and take a screenshot with the address bar visible."
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${MODE}" in
  server) server_mode ;;
  all) all_mode ;;
esac
