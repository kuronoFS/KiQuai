#!/usr/bin/env bash
set -Eeuo pipefail

# KiQuai Hashtopolis + Hashcat bootstrap for Vast.ai
# Target image: nvidia/cuda:12.9.1-devel-ubuntu24.04
# Target Vast Docker options: --privileged -p 8080:8080 -e OPEN_BUTTON_PORT=8080 --shm-size=8g
#
# Design goals:
#   - Run Hashcat directly in the Vast.ai instance for GPU access.
#   - Run Hashtopolis server containers through rootless Docker to avoid
#     CAP_NET_ADMIN / iptables / NAT-chain failures in nested container setups.
#   - Use one public port through Nginx reverse proxy.
#   - Fail loudly with diagnostics instead of hiding container crash loops.
#
# Security/legal notice:
#   Use only for authorized password recovery, internal security audit, or lab work.

#######################################
# User-configurable variables
#######################################
DOCKER_USER="${DOCKER_USER:-kiquai}"
INTERNAL_PORT="${INTERNAL_PORT:-${OPEN_BUTTON_PORT:-8080}}"
APP_DIR="${APP_DIR:-/home/${DOCKER_USER}/kiquai-hashtopolis}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-kiquai_hashtopolis}"

# Hashtopolis image defaults.
# These can be overridden at runtime if upstream tags change:
#   HASHTOPOLIS_BACKEND_IMAGE=hashtopolis/backend:latest HASHTOPOLIS_FRONTEND_IMAGE=hashtopolis/frontend:master bash run.sh
HASHTOPOLIS_BACKEND_IMAGE="${HASHTOPOLIS_BACKEND_IMAGE:-hashtopolis/backend:v1.0.0-rc1}"
HASHTOPOLIS_FRONTEND_IMAGE="${HASHTOPOLIS_FRONTEND_IMAGE:-hashtopolis/frontend:master}"
DB_IMAGE="${DB_IMAGE:-mysql:9.7}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:alpine}"

MYSQL_DATABASE_DEFAULT="${MYSQL_DATABASE:-hashtopolis}"
MYSQL_USER_DEFAULT="${MYSQL_USER:-hashtopolis}"
HASHTOPOLIS_ADMIN_USER_DEFAULT="${HASHTOPOLIS_ADMIN_USER:-admin}"

STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-420}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-5}"
RESTART_ROOTLESS_DOCKER="${RESTART_ROOTLESS_DOCKER:-auto}"
FORCE_RECREATE="${FORCE_RECREATE:-1}"
WIPE_DATA="${WIPE_DATA:-0}"
SKIP_GPU_CHECK="${SKIP_GPU_CHECK:-0}"
SKIP_HASHCAT_CHECK="${SKIP_HASHCAT_CHECK:-0}"
DEBUG="${DEBUG:-0}"

PUBLIC_URL_OVERRIDE="${PUBLIC_URL:-}"
PUBLIC_IP="${PUBLIC_IPADDR:-$(curl -fsS --connect-timeout 4 https://api.ipify.org 2>/dev/null || echo 127.0.0.1)}"
PUBLIC_PORT_VAR="VAST_TCP_PORT_${INTERNAL_PORT}"
PUBLIC_PORT_DETECTED="${!PUBLIC_PORT_VAR:-}"
PUBLIC_PORT="${PUBLIC_PORT_DETECTED:-${INTERNAL_PORT}}"
PUBLIC_URL="${PUBLIC_URL:-http://${PUBLIC_IP}:${PUBLIC_PORT}}"
HASHTOPOLIS_BACKEND_URL="${HASHTOPOLIS_BACKEND_URL:-${PUBLIC_URL}/api/v2}"
HASHTOPOLIS_FRONTEND_PORT="${HASHTOPOLIS_FRONTEND_PORT:-${PUBLIC_PORT}}"

#######################################
# Generic helpers
#######################################
log() { echo "[$(date +'%F %T')] $*"; }
warn() { echo "WARNING: $*" >&2; }
fatal() { echo "ERROR: $*" >&2; exit 1; }

if [ "${DEBUG}" = "1" ]; then
  set -x
fi

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  echo >&2
  echo "ERROR: run.sh failed at line ${line_no}, exit code ${exit_code}." >&2
  echo "Collecting diagnostics..." >&2
  diagnose || true
  exit "${exit_code}"
}
trap 'on_error $LINENO' ERR

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fatal "Run this script as root inside the Vast.ai instance."
  fi
}

rand_secret() {
  # Keep the charset Compose/.env-safe to avoid interpolation surprises.
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32
}

apt_retry() {
  local attempt
  for attempt in 1 2 3; do
    if apt-get "$@"; then
      return 0
    fi
    warn "apt-get $* failed on attempt ${attempt}/3; retrying..."
    sleep $((attempt * 4))
  done
  return 1
}

safe_env_value() {
  local name="$1"
  local value="$2"
  if [[ "${value}" =~ [[:space:]] || "${value}" == *\"* || "${value}" == *"'"* || "${value}" == *'$'* || "${value}" == *\\* ]]; then
    fatal "${name} contains unsupported characters for this one-line .env deployment. Use only letters, numbers, dot, dash, underscore, colon, slash, at-sign, percent."
  fi
}

write_env_kv() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "${key}" "${value}"
}

as_docker_user() {
  su -s /bin/bash "${DOCKER_USER}" -c "$*"
}

compose() {
  COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}" docker compose -f "${APP_DIR}/docker-compose.yml" "$@"
}

service_container_names() {
  printf '%s\n' hashtopolis-db hashtopolis-backend hashtopolis-frontend hashtopolis-proxy
}

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

container_field() {
  local name="$1"
  local format="$2"
  docker inspect -f "${format}" "${name}" 2>/dev/null || true
}

container_health() {
  local name="$1"
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "${name}" 2>/dev/null || true
}

container_status() {
  local name="$1"
  docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || true
}

http_code() {
  curl -sS --max-time "${HTTP_TIMEOUT}" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo "000"
}

http_okish() {
  local code="$1"
  case "${code}" in
    2*|3*|4*) return 0 ;;
    *) return 1 ;;
  esac
}

#######################################
# Diagnostics
#######################################
diagnose() {
  echo "==================== BASIC ====================" >&2
  echo "User: $(id || true)" >&2
  echo "Kernel: $(uname -a || true)" >&2
  echo "APP_DIR=${APP_DIR}" >&2
  echo "DOCKER_HOST=${DOCKER_HOST:-unset}" >&2
  echo "PUBLIC_URL=${PUBLIC_URL}" >&2
  echo "INTERNAL_PORT=${INTERNAL_PORT}" >&2

  echo "==================== GPU ======================" >&2
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi >&2 || true
  else
    echo "nvidia-smi not found" >&2
  fi

  echo "==================== DOCKER ===================" >&2
  docker version >&2 || true
  docker info >&2 || true

  if [ -d "${APP_DIR}" ]; then
    echo "==================== COMPOSE CONFIG ===========" >&2
    (cd "${APP_DIR}" && COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}" docker compose config) >&2 || true

    echo "==================== COMPOSE PS ===============" >&2
    compose ps -a >&2 || true
  fi

  echo "==================== PORTS ====================" >&2
  ss -ltnp >&2 || true

  echo "==================== CONTAINER LOGS ===========" >&2
  for c in $(service_container_names); do
    if container_exists "${c}"; then
      echo "----- ${c}: inspect state -----" >&2
      docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}} restart={{.RestartCount}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}} oom={{.State.OOMKilled}} error={{.State.Error}}' "${c}" >&2 || true
      echo "----- ${c}: logs last 160 lines -----" >&2
      docker logs --tail 160 "${c}" >&2 || true
    fi
  done

  local uid home log_file
  if id "${DOCKER_USER}" >/dev/null 2>&1; then
    uid="$(id -u "${DOCKER_USER}")"
    home="$(getent passwd "${DOCKER_USER}" | cut -d: -f6)"
    log_file="${home}/dockerd-rootless.log"
    if [ -f "${log_file}" ]; then
      echo "==================== ROOTLESS DOCKERD LOG =====" >&2
      tail -n 240 "${log_file}" >&2 || true
    fi
    if [ -d "/run/user/${uid}" ]; then
      echo "Runtime dir: /run/user/${uid}" >&2
      ls -la "/run/user/${uid}" >&2 || true
    fi
  fi
}

#######################################
# Host and GPU preparation
#######################################
install_system_packages() {
  log "[1/9] Installing system packages"

  export DEBIAN_FRONTEND=noninteractive
  apt_retry update
  apt_retry install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    gnupg \
    lsb-release \
    iptables \
    kmod \
    procps \
    iproute2 \
    uidmap \
    dbus-user-session \
    fuse-overlayfs \
    slirp4netns \
    bash \
    git \
    jq \
    openssl \
    python3 \
    python3-pip \
    python3-venv \
    python3-requests \
    python3-psutil \
    p7zip-full \
    unzip \
    clinfo \
    ocl-icd-libopencl1 \
    hashcat \
    netcat-openbsd
}

validate_gpu_and_hashcat() {
  log "[2/9] Validating GPU and Hashcat"

  if [ "${SKIP_GPU_CHECK}" != "1" ]; then
    command -v nvidia-smi >/dev/null 2>&1 || fatal "nvidia-smi is not installed. Use an NVIDIA/CUDA Vast.ai image."
    nvidia-smi || fatal "nvidia-smi failed. The Vast.ai instance is not exposing the GPU correctly."
  else
    warn "SKIP_GPU_CHECK=1 is set; GPU validation skipped."
  fi

  if [ "${SKIP_HASHCAT_CHECK}" != "1" ]; then
    command -v hashcat >/dev/null 2>&1 || fatal "hashcat is not installed."
    hashcat --version || true
    # hashcat -I may return non-zero on some OpenCL/runtime edge cases; show it but do not fail deployment.
    hashcat -I || warn "hashcat -I did not complete successfully. The server can still deploy, but the agent/GPU runtime may need attention."
  else
    warn "SKIP_HASHCAT_CHECK=1 is set; Hashcat validation skipped."
  fi
}

install_docker_engine() {
  log "[3/9] Installing Docker Engine and rootless extras"

  if command -v docker >/dev/null 2>&1 && command -v dockerd-rootless.sh >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker CLI, Compose plugin, and rootless extras are already installed."
    return 0
  fi

  . /etc/os-release
  local codename="${VERSION_CODENAME:-}"
  if [ -z "${codename}" ]; then
    fatal "Cannot detect Ubuntu/Debian VERSION_CODENAME from /etc/os-release."
  fi

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt_retry update
  apt_retry install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    docker-ce-rootless-extras \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
}

#######################################
# Rootless Docker
#######################################
prepare_rootless_user() {
  log "[4/9] Preparing rootless Docker user"

  if ! id "${DOCKER_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${DOCKER_USER}"
  fi

  DOCKER_UID="$(id -u "${DOCKER_USER}")"
  DOCKER_GID="$(id -g "${DOCKER_USER}")"
  DOCKER_HOME="$(getent passwd "${DOCKER_USER}" | cut -d: -f6)"
  XDG_RUNTIME_DIR="/run/user/${DOCKER_UID}"
  ROOTLESS_DOCKER_SOCK="${XDG_RUNTIME_DIR}/docker.sock"
  export XDG_RUNTIME_DIR
  export DOCKER_HOST="unix://${ROOTLESS_DOCKER_SOCK}"

  mkdir -p "${XDG_RUNTIME_DIR}"
  chown "${DOCKER_UID}:${DOCKER_GID}" "${XDG_RUNTIME_DIR}"
  chmod 700 "${XDG_RUNTIME_DIR}"

  mkdir -p "${DOCKER_HOME}/.local/share/docker" "${DOCKER_HOME}/.config/docker"
  chown -R "${DOCKER_UID}:${DOCKER_GID}" "${DOCKER_HOME}/.local" "${DOCKER_HOME}/.config"

  # Rootless Docker requires subordinate UID/GID ranges.
  if ! grep -q "^${DOCKER_USER}:" /etc/subuid 2>/dev/null; then
    echo "${DOCKER_USER}:100000:65536" >> /etc/subuid
  fi
  if ! grep -q "^${DOCKER_USER}:" /etc/subgid 2>/dev/null; then
    echo "${DOCKER_USER}:100000:65536" >> /etc/subgid
  fi

  command -v newuidmap >/dev/null 2>&1 || fatal "newuidmap is missing; uidmap package is required for rootless Docker."
  command -v newgidmap >/dev/null 2>&1 || fatal "newgidmap is missing; uidmap package is required for rootless Docker."
  command -v slirp4netns >/dev/null 2>&1 || fatal "slirp4netns is missing; required for rootless Docker networking."
  command -v fuse-overlayfs >/dev/null 2>&1 || fatal "fuse-overlayfs is missing; required for reliable rootless Docker storage."

  # Best effort. Some container templates block sysctl writes; the unshare test below is authoritative.
  sysctl -w kernel.unprivileged_userns_clone=1 >/dev/null 2>&1 || true

  if ! as_docker_user "XDG_RUNTIME_DIR='${XDG_RUNTIME_DIR}' unshare -Ur true" >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: unprivileged user namespaces are not available in this Vast.ai instance.
Rootless Docker cannot run here.

Fix options:
  1. Confirm the Vast.ai template Docker options include: --privileged -p ${INTERNAL_PORT}:${INTERNAL_PORT} -e OPEN_BUTTON_PORT=${INTERNAL_PORT} --shm-size=8g
  2. Try a different Vast.ai offer/provider where user namespaces are not blocked.
  3. Avoid nested Docker and deploy Hashtopolis on a native VM/bare-metal host.
EOF
    exit 1
  fi
}

start_rootless_docker() {
  log "[5/9] Starting rootless Docker daemon"

  export DOCKER_HOST="unix://${ROOTLESS_DOCKER_SOCK}"

  if docker info >/dev/null 2>&1; then
    if [ "${RESTART_ROOTLESS_DOCKER}" = "1" ]; then
      log "Rootless Docker is already running but RESTART_ROOTLESS_DOCKER=1; restarting it."
    else
      log "Rootless Docker is already running."
      docker info --format 'Docker driver={{.Driver}} security={{json .SecurityOptions}}' || true
      return 0
    fi
  fi

  pkill -u "${DOCKER_UID}" -f rootlesskit 2>/dev/null || true
  pkill -u "${DOCKER_UID}" -f dockerd 2>/dev/null || true
  rm -f "${ROOTLESS_DOCKER_SOCK}"

  as_docker_user "
    export XDG_RUNTIME_DIR='${XDG_RUNTIME_DIR}'
    export PATH='/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
    export DOCKERD_ROOTLESS_ROOTLESSKIT_NET='slirp4netns'
    export DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER='builtin'
    nohup dockerd-rootless.sh \
      --host='unix://${ROOTLESS_DOCKER_SOCK}' \
      --storage-driver='fuse-overlayfs' \
      --iptables=false \
      > '${DOCKER_HOME}/dockerd-rootless.log' 2>&1 &
  "

  local i
  for i in $(seq 1 120); do
    if docker info >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: rootless dockerd failed to start." >&2
    echo "==== ${DOCKER_HOME}/dockerd-rootless.log ====" >&2
    cat "${DOCKER_HOME}/dockerd-rootless.log" >&2 || true
    exit 1
  fi

  cat > /etc/profile.d/kiquai-rootless-docker.sh <<EOF
export DOCKER_HOST=unix://${ROOTLESS_DOCKER_SOCK}
export COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
EOF

  log "Rootless Docker is ready."
  docker info --format 'Docker driver={{.Driver}} security={{json .SecurityOptions}}' || true
}

#######################################
# Hashtopolis stack
#######################################
prepare_app_dir_and_env() {
  log "[6/9] Preparing Hashtopolis app directory and environment"

  mkdir -p "${APP_DIR}"
  chown -R "${DOCKER_UID}:${DOCKER_GID}" "${APP_DIR}"
  cd "${APP_DIR}"

  if [ -f .env ]; then
    log "Existing .env found; preserving existing database/admin secrets where present."
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
  fi

  MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-$(rand_secret)}"
  MYSQL_DATABASE="${MYSQL_DATABASE:-${MYSQL_DATABASE_DEFAULT}}"
  MYSQL_USER="${MYSQL_USER:-${MYSQL_USER_DEFAULT}}"
  MYSQL_PASSWORD="${MYSQL_PASSWORD:-$(rand_secret)}"
  HASHTOPOLIS_ADMIN_USER="${HASHTOPOLIS_ADMIN_USER:-${HASHTOPOLIS_ADMIN_USER_DEFAULT}}"
  HASHTOPOLIS_ADMIN_PASSWORD="${HASHTOPOLIS_ADMIN_PASSWORD:-$(rand_secret)}"
  HASHTOPOLIS_DB_HOST="${HASHTOPOLIS_DB_HOST:-db}"

  safe_env_value MYSQL_ROOT_PASS "${MYSQL_ROOT_PASS}"
  safe_env_value MYSQL_DATABASE "${MYSQL_DATABASE}"
  safe_env_value MYSQL_USER "${MYSQL_USER}"
  safe_env_value MYSQL_PASSWORD "${MYSQL_PASSWORD}"
  safe_env_value HASHTOPOLIS_ADMIN_USER "${HASHTOPOLIS_ADMIN_USER}"
  safe_env_value HASHTOPOLIS_ADMIN_PASSWORD "${HASHTOPOLIS_ADMIN_PASSWORD}"
  safe_env_value HASHTOPOLIS_BACKEND_URL "${HASHTOPOLIS_BACKEND_URL}"
  safe_env_value PUBLIC_URL "${PUBLIC_URL}"

  {
    write_env_kv COMPOSE_PROJECT_NAME "${COMPOSE_PROJECT_NAME}"
    write_env_kv INTERNAL_PORT "${INTERNAL_PORT}"
    write_env_kv PUBLIC_URL "${PUBLIC_URL}"
    write_env_kv PUBLIC_IP "${PUBLIC_IP}"
    write_env_kv PUBLIC_PORT "${PUBLIC_PORT}"
    write_env_kv DB_IMAGE "${DB_IMAGE}"
    write_env_kv HASHTOPOLIS_BACKEND_IMAGE "${HASHTOPOLIS_BACKEND_IMAGE}"
    write_env_kv HASHTOPOLIS_FRONTEND_IMAGE "${HASHTOPOLIS_FRONTEND_IMAGE}"
    write_env_kv NGINX_IMAGE "${NGINX_IMAGE}"
    write_env_kv MYSQL_ROOT_PASS "${MYSQL_ROOT_PASS}"
    write_env_kv MYSQL_DATABASE "${MYSQL_DATABASE}"
    write_env_kv MYSQL_USER "${MYSQL_USER}"
    write_env_kv MYSQL_PASSWORD "${MYSQL_PASSWORD}"
    write_env_kv HASHTOPOLIS_DB_HOST "${HASHTOPOLIS_DB_HOST}"
    write_env_kv HASHTOPOLIS_ADMIN_USER "${HASHTOPOLIS_ADMIN_USER}"
    write_env_kv HASHTOPOLIS_ADMIN_PASSWORD "${HASHTOPOLIS_ADMIN_PASSWORD}"
    write_env_kv HASHTOPOLIS_BACKEND_URL "${HASHTOPOLIS_BACKEND_URL}"
    write_env_kv HASHTOPOLIS_FRONTEND_PORT "${HASHTOPOLIS_FRONTEND_PORT}"
  } > .env

  chown "${DOCKER_UID}:${DOCKER_GID}" .env
  chmod 600 .env

  if [ -z "${PUBLIC_PORT_DETECTED}" ] && [ -z "${PUBLIC_URL_OVERRIDE}" ]; then
    warn "${PUBLIC_PORT_VAR} is not set. Vast.ai may map internal ports to random external ports. If the printed URL is wrong, rerun with PUBLIC_URL=http://PUBLIC_IP:EXTERNAL_PORT."
  fi
}

write_compose_and_nginx() {
  log "[7/9] Writing docker-compose.yml, nginx.conf, and helper scripts"

  cd "${APP_DIR}"

  cat > docker-compose.yml <<'EOF'
name: ${COMPOSE_PROJECT_NAME}

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
  db:
    image: ${DB_IMAGE}
    container_name: hashtopolis-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASS}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --max_allowed_packet=1073741824
    volumes:
      - db:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p$${MYSQL_ROOT_PASSWORD} --silent || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 60
      start_period: 45s
    logging: *default-logging

  hashtopolis-backend:
    image: ${HASHTOPOLIS_BACKEND_IMAGE}
    container_name: hashtopolis-backend
    restart: unless-stopped
    environment:
      HASHTOPOLIS_DB_TYPE: mysql
      HASHTOPOLIS_DB_USER: ${MYSQL_USER}
      HASHTOPOLIS_DB_PASS: ${MYSQL_PASSWORD}
      HASHTOPOLIS_DB_HOST: ${HASHTOPOLIS_DB_HOST}
      HASHTOPOLIS_DB_DATABASE: ${MYSQL_DATABASE}
      HASHTOPOLIS_ADMIN_USER: ${HASHTOPOLIS_ADMIN_USER}
      HASHTOPOLIS_ADMIN_PASSWORD: ${HASHTOPOLIS_ADMIN_PASSWORD}
      HASHTOPOLIS_BACKEND_URL: ${HASHTOPOLIS_BACKEND_URL}
      HASHTOPOLIS_FRONTEND_PORT: ${HASHTOPOLIS_FRONTEND_PORT}
    volumes:
      - hashtopolis:/usr/local/share/hashtopolis
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "php -r 'exit(@fsockopen(\"127.0.0.1\", 80) ? 0 : 1);'"]
      interval: 10s
      timeout: 5s
      retries: 60
      start_period: 60s
    logging: *default-logging

  hashtopolis-frontend:
    image: ${HASHTOPOLIS_FRONTEND_IMAGE}
    container_name: hashtopolis-frontend
    restart: unless-stopped
    environment:
      HASHTOPOLIS_BACKEND_URL: ${HASHTOPOLIS_BACKEND_URL}
    depends_on:
      hashtopolis-backend:
        condition: service_healthy
    logging: *default-logging

  hashtopolis-proxy:
    image: ${NGINX_IMAGE}
    container_name: hashtopolis-proxy
    restart: unless-stopped
    ports:
      - "${INTERNAL_PORT}:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      hashtopolis-backend:
        condition: service_healthy
      hashtopolis-frontend:
        condition: service_started
    healthcheck:
      test: ["CMD-SHELL", "wget --spider -q http://127.0.0.1/ || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 20s
    logging: *default-logging

volumes:
  db:
  hashtopolis:
EOF

  cat > nginx.conf <<'EOF'
events {
  worker_connections 1024;
}

http {
  client_max_body_size 20G;
  proxy_connect_timeout 60s;
  proxy_send_timeout 3600s;
  proxy_read_timeout 3600s;
  send_timeout 3600s;

  upstream hashtopolis_frontend {
    server hashtopolis-frontend:80;
  }

  upstream hashtopolis_backend {
    server hashtopolis-backend:80;
  }

  server {
    listen 80;
    server_name _;

    # Lightweight local readiness endpoint for the proxy container.
    location = /__kiquai_health {
      access_log off;
      return 200 "ok\n";
      add_header Content-Type text/plain;
    }

    # Hashtopolis API v2. Keep the path unchanged.
    location = /api/v2 {
      proxy_pass http://hashtopolis_backend/api/v2;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host $host;
    }

    location /api/v2/ {
      proxy_pass http://hashtopolis_backend/api/v2/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host $host;
    }

    # Legacy agent API.
    location = /api/server.php {
      proxy_pass http://hashtopolis_backend/api/server.php;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host $host;
    }

    location /api/ {
      proxy_pass http://hashtopolis_backend/api/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host $host;
    }

    # Files and binaries are served by the backend.
    location /files/ {
      proxy_pass http://hashtopolis_backend/files/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host $host;
    }

    location /binaries/ {
      proxy_pass http://hashtopolis_backend/binaries/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host $host;
    }

    # Angular frontend.
    location / {
      proxy_pass http://hashtopolis_frontend/;
      proxy_http_version 1.1;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host $host;
    }
  }
}
EOF

  cat > kiquai-status.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi
export DOCKER_HOST="${DOCKER_HOST:-$(grep -h '^export DOCKER_HOST=' /etc/profile.d/kiquai-rootless-docker.sh 2>/dev/null | cut -d= -f2- || true)}"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-kiquai_hashtopolis}"
docker compose ps -a
printf '\nLocal UI: %s\n' "http://127.0.0.1:${INTERNAL_PORT:-8080}"
printf 'Public UI: %s\n' "${PUBLIC_URL:-unknown}"
EOF

  cat > kiquai-logs.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi
export DOCKER_HOST="${DOCKER_HOST:-$(grep -h '^export DOCKER_HOST=' /etc/profile.d/kiquai-rootless-docker.sh 2>/dev/null | cut -d= -f2- || true)}"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-kiquai_hashtopolis}"
docker compose logs --tail 250 "$@"
EOF

  chmod +x kiquai-status.sh kiquai-logs.sh
  chown "${DOCKER_UID}:${DOCKER_GID}" docker-compose.yml nginx.conf kiquai-status.sh kiquai-logs.sh
}

preflight_compose() {
  log "[8/9] Validating Compose config and port availability"

  cd "${APP_DIR}"
  compose config >/dev/null

  if [ "${WIPE_DATA}" = "1" ]; then
    warn "WIPE_DATA=1: removing containers and volumes for a clean deployment."
    compose down --volumes --remove-orphans || true
  elif [ "${FORCE_RECREATE}" = "1" ]; then
    log "Stopping previous KiQuai Hashtopolis containers, preserving volumes."
    compose down --remove-orphans || true
  fi

  if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :${INTERNAL_PORT}" 2>/dev/null | grep -q .; then
    echo "ERROR: port ${INTERNAL_PORT} is already listening inside this Vast.ai instance." >&2
    echo "Common causes:" >&2
    echo "  - Jupyter/template service already uses 8080." >&2
    echo "  - Another application is already bound to this port." >&2
    echo "Fix:" >&2
    echo "  - Use SSH mode, or rerun with INTERNAL_PORT=18080 and expose -p 18080:18080." >&2
    ss -ltnp "sport = :${INTERNAL_PORT}" >&2 || true
    exit 1
  fi
}

pull_and_start_stack() {
  log "[9/9] Pulling images and starting Hashtopolis stack"

  cd "${APP_DIR}"

  log "Pulling images: ${DB_IMAGE}, ${HASHTOPOLIS_BACKEND_IMAGE}, ${HASHTOPOLIS_FRONTEND_IMAGE}, ${NGINX_IMAGE}"
  compose pull
  compose up -d --remove-orphans
}

wait_for_stack() {
  log "Waiting for containers to become healthy. Timeout: ${STARTUP_TIMEOUT}s"

  local start now elapsed c status health restart_count exit_code oom error code all_ok
  start="$(date +%s)"

  while true; do
    all_ok=1

    for c in $(service_container_names); do
      if ! container_exists "${c}"; then
        all_ok=0
        continue
      fi

      status="$(container_status "${c}")"
      health="$(container_health "${c}")"
      restart_count="$(container_field "${c}" '{{.RestartCount}}')"
      exit_code="$(container_field "${c}" '{{.State.ExitCode}}')"
      oom="$(container_field "${c}" '{{.State.OOMKilled}}')"
      error="$(container_field "${c}" '{{.State.Error}}')"

      if [ "${status}" = "exited" ] || [ "${status}" = "dead" ] || [ "${status}" = "removing" ]; then
        echo "ERROR: ${c} is ${status}. exit=${exit_code} restart=${restart_count} oom=${oom} error=${error}" >&2
        diagnose || true
        exit 1
      fi

      if [ "${status}" != "running" ]; then
        all_ok=0
      fi

      if [ "${health}" = "starting" ] || [ "${health}" = "unhealthy" ]; then
        all_ok=0
      fi
    done

    code="$(http_code "http://127.0.0.1:${INTERNAL_PORT}/__kiquai_health")"
    if ! http_okish "${code}"; then
      all_ok=0
    fi

    if [ "${all_ok}" = "1" ]; then
      log "All containers are running and the local proxy responded with HTTP ${code}."
      return 0
    fi

    now="$(date +%s)"
    elapsed=$((now - start))
    if [ "${elapsed}" -ge "${STARTUP_TIMEOUT}" ]; then
      echo "ERROR: stack did not become healthy within ${STARTUP_TIMEOUT}s." >&2
      diagnose || true
      exit 1
    fi

    if [ $((elapsed % 20)) -eq 0 ]; then
      log "Still waiting... elapsed=${elapsed}s"
      compose ps -a || true
    fi

    sleep 2
  done
}

print_success() {
  cd "${APP_DIR}"

  local root_code api_code legacy_code
  root_code="$(http_code "http://127.0.0.1:${INTERNAL_PORT}/")"
  api_code="$(http_code "http://127.0.0.1:${INTERNAL_PORT}/api/v2")"
  legacy_code="$(http_code "http://127.0.0.1:${INTERNAL_PORT}/api/server.php")"

  cat <<EOF

============================================================
KiQuai Hashtopolis deployment completed.

Hashtopolis URL:
  ${PUBLIC_URL}

Admin username:
  ${HASHTOPOLIS_ADMIN_USER}

Admin password:
  ${HASHTOPOLIS_ADMIN_PASSWORD}

Backend API v2:
  ${PUBLIC_URL}/api/v2

Legacy agent API:
  ${PUBLIC_URL}/api/server.php

Rootless Docker socket:
  ${DOCKER_HOST}

Images:
  DB:       ${DB_IMAGE}
  Backend:  ${HASHTOPOLIS_BACKEND_IMAGE}
  Frontend: ${HASHTOPOLIS_FRONTEND_IMAGE}
  Proxy:    ${NGINX_IMAGE}

Local HTTP probes:
  /                 -> HTTP ${root_code}
  /api/v2           -> HTTP ${api_code}
  /api/server.php   -> HTTP ${legacy_code}

Operational commands:
  export DOCKER_HOST=${DOCKER_HOST}
  cd ${APP_DIR}
  docker compose ps -a
  docker compose logs --tail 200 hashtopolis-backend
  ./kiquai-status.sh
  ./kiquai-logs.sh

GPU checks:
  nvidia-smi
  hashcat -I

Data reset, if you intentionally want a clean reinstall:
  WIPE_DATA=1 bash run.sh

If the URL is wrong because Vast.ai used another external port:
  PUBLIC_URL="http://PUBLIC_IP:EXTERNAL_PORT" bash run.sh
============================================================
EOF
}

main() {
  require_root

  log "KiQuai Hashtopolis + Hashcat bootstrap started."
  log "Target public URL: ${PUBLIC_URL}"
  log "Target internal port: ${INTERNAL_PORT}"

  install_system_packages
  validate_gpu_and_hashcat
  install_docker_engine
  prepare_rootless_user
  start_rootless_docker
  prepare_app_dir_and_env
  write_compose_and_nginx
  preflight_compose
  pull_and_start_stack
  wait_for_stack
  print_success
}

main "$@"
