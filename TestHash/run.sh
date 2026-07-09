#!/usr/bin/env bash
set -Eeuo pipefail

# Vast.ai-friendly Hashtopolis + Hashcat bootstrap.
# Key design: run Hashcat directly in the Vast instance, and run Hashtopolis
# server containers using ROOTLESS Docker to avoid CAP_NET_ADMIN/iptables errors.

DOCKER_USER="${DOCKER_USER:-kiquai}"
INTERNAL_PORT="${INTERNAL_PORT:-8080}"
APP_DIR="${APP_DIR:-/home/${DOCKER_USER}/kiquai-hashtopolis}"

MYSQL_DATABASE_DEFAULT="${MYSQL_DATABASE:-hashtopolis}"
MYSQL_USER_DEFAULT="${MYSQL_USER:-hashtopolis}"
HASHTOPOLIS_ADMIN_USER_DEFAULT="${HASHTOPOLIS_ADMIN_USER:-admin}"

PUBLIC_URL_OVERRIDE="${PUBLIC_URL:-}"
PUBLIC_IP="${PUBLIC_IPADDR:-$(curl -fsS https://api.ipify.org || echo 127.0.0.1)}"
PUBLIC_PORT_VAR="VAST_TCP_PORT_${INTERNAL_PORT}"
PUBLIC_PORT_DETECTED="${!PUBLIC_PORT_VAR:-}"
PUBLIC_PORT="${PUBLIC_PORT_DETECTED:-${INTERNAL_PORT}}"
PUBLIC_URL="${PUBLIC_URL:-http://${PUBLIC_IP}:${PUBLIC_PORT}}"

log() { echo "[$(date +'%F %T')] $*"; }
fatal() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fatal "Run this script as root inside the Vast.ai instance."
  fi
}

rand_secret() {
  openssl rand -base64 32 | tr -d '=+/ ' | cut -c1-32
}

upsert_env() {
  local key="$1"
  local value="$2"
  local file="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

require_root

if [ -z "${PUBLIC_PORT_DETECTED}" ] && [ -z "${PUBLIC_URL_OVERRIDE}" ]; then
  echo "WARNING: ${PUBLIC_PORT_VAR} is not set." >&2
  echo "         Vast.ai usually maps internal ports to random external ports." >&2
  echo "         If the printed URL is wrong, find the mapping in Vast.ai IP Port Info" >&2
  echo "         and rerun with PUBLIC_URL=\"http://PUBLIC_IP:EXTERNAL_PORT\"." >&2
fi

log "[1/10] Validating GPU"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  fatal "nvidia-smi is not installed in this image. Use a CUDA/NVIDIA Vast.ai image."
fi
nvidia-smi || fatal "nvidia-smi failed. The Vast.ai instance does not expose GPU correctly."

log "[2/10] Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
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
  hashcat

log "[3/10] Installing Docker Engine + rootless extras"
if ! command -v docker >/dev/null 2>&1 || ! command -v dockerd-rootless.sh >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    docker-ce-rootless-extras \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
fi

log "[4/10] Preparing rootless Docker user"
if ! id "${DOCKER_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${DOCKER_USER}"
fi

DOCKER_UID="$(id -u "${DOCKER_USER}")"
DOCKER_GID="$(id -g "${DOCKER_USER}")"
DOCKER_HOME="$(getent passwd "${DOCKER_USER}" | cut -d: -f6)"
XDG_RUNTIME_DIR="/run/user/${DOCKER_UID}"
ROOTLESS_DOCKER_SOCK="${XDG_RUNTIME_DIR}/docker.sock"
export DOCKER_HOST="unix://${ROOTLESS_DOCKER_SOCK}"

mkdir -p "${XDG_RUNTIME_DIR}"
chown "${DOCKER_UID}:${DOCKER_GID}" "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"

# Rootless Docker requires subordinate UID/GID ranges.
if ! grep -q "^${DOCKER_USER}:" /etc/subuid 2>/dev/null; then
  echo "${DOCKER_USER}:100000:65536" >> /etc/subuid
fi
if ! grep -q "^${DOCKER_USER}:" /etc/subgid 2>/dev/null; then
  echo "${DOCKER_USER}:100000:65536" >> /etc/subgid
fi

# Hard fail early when the provider/template blocks unprivileged user namespaces.
if ! su -s /bin/bash "${DOCKER_USER}" -c "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} unshare -Ur true" >/dev/null 2>&1; then
  cat >&2 <<EOM
ERROR: unprivileged user namespaces are not available in this Vast.ai instance.
Rootless Docker cannot run here.

Fix options:
  1. Use a different Vast.ai offer/template that allows rootless containers/user namespaces.
  2. Use a provider/template that truly supports privileged Docker-in-Docker.
  3. Avoid nested Docker and deploy Hashtopolis on a native VM/bare-metal host.
EOM
  exit 1
fi

log "[5/10] Starting rootless dockerd"
mkdir -p "${DOCKER_HOME}/.local/share/docker" "${DOCKER_HOME}/.config/docker"
chown -R "${DOCKER_UID}:${DOCKER_GID}" "${DOCKER_HOME}/.local" "${DOCKER_HOME}/.config"

# Stop stale rootless daemons owned by the Docker user only.
pkill -u "${DOCKER_UID}" rootlesskit 2>/dev/null || true
pkill -u "${DOCKER_UID}" dockerd 2>/dev/null || true
rm -f "${ROOTLESS_DOCKER_SOCK}"

su -s /bin/bash "${DOCKER_USER}" -c "
  export XDG_RUNTIME_DIR='${XDG_RUNTIME_DIR}'
  export PATH='/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
  nohup dockerd-rootless.sh \
    --host='unix://${ROOTLESS_DOCKER_SOCK}' \
    --storage-driver=fuse-overlayfs \
    --iptables=false \
    > '${DOCKER_HOME}/dockerd-rootless.log' 2>&1 &
"

for _ in $(seq 1 90); do
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

cat > /etc/profile.d/kiquai-rootless-docker.sh <<EOF2
export DOCKER_HOST=unix://${ROOTLESS_DOCKER_SOCK}
EOF2

log "Rootless Docker is ready"
docker info --format 'Docker driver={{.Driver}} rootless={{.SecurityOptions}}'

log "[6/10] Checking hashcat"
hashcat --version || true
hashcat -I || true

log "[7/10] Preparing Hashtopolis app directory"
mkdir -p "${APP_DIR}"
chown -R "${DOCKER_UID}:${DOCKER_GID}" "${APP_DIR}"
cd "${APP_DIR}"

if [ -f .env ]; then
  log "Existing .env found; preserving database/admin secrets"
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
HASHTOPOLIS_BACKEND_URL="${PUBLIC_URL}/api/v2"

cat > .env <<EOF2
INTERNAL_PORT=${INTERNAL_PORT}
MYSQL_ROOT_PASS=${MYSQL_ROOT_PASS}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
HASHTOPOLIS_ADMIN_USER=${HASHTOPOLIS_ADMIN_USER}
HASHTOPOLIS_ADMIN_PASSWORD=${HASHTOPOLIS_ADMIN_PASSWORD}
HASHTOPOLIS_BACKEND_URL=${HASHTOPOLIS_BACKEND_URL}
EOF2
chown "${DOCKER_UID}:${DOCKER_GID}" .env
chmod 600 .env

cat > docker-compose.yml <<'EOF2'
services:
  hashtopolis-db:
    image: mariadb:10.11
    container_name: hashtopolis-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASS}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - hash_db:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -h 127.0.0.1 -uroot -p$${MYSQL_ROOT_PASSWORD} || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 30

  hashtopolis-backend:
    image: hashtopolis/backend:latest
    container_name: hashtopolis-backend
    restart: unless-stopped
    environment:
      HASHTOPOLIS_DB_TYPE: mysql
      HASHTOPOLIS_DB_HOST: hashtopolis-db
      HASHTOPOLIS_DB_USER: ${MYSQL_USER}
      HASHTOPOLIS_DB_PASS: ${MYSQL_PASSWORD}
      HASHTOPOLIS_DB_DATABASE: ${MYSQL_DATABASE}
      HASHTOPOLIS_ADMIN_USER: ${HASHTOPOLIS_ADMIN_USER}
      HASHTOPOLIS_ADMIN_PASSWORD: ${HASHTOPOLIS_ADMIN_PASSWORD}
      HASHTOPOLIS_BACKEND_URL: ${HASHTOPOLIS_BACKEND_URL}
      HASHTOPOLIS_FRONTEND_PORT: 80
      HASHTOPOLIS_APIV2_ENABLE: "1"
    volumes:
      - hash_data:/usr/local/share/hashtopolis
    depends_on:
      hashtopolis-db:
        condition: service_healthy

  hashtopolis-frontend:
    image: hashtopolis/frontend:latest
    container_name: hashtopolis-frontend
    restart: unless-stopped
    environment:
      HASHTOPOLIS_BACKEND_URL: ${HASHTOPOLIS_BACKEND_URL}
    depends_on:
      - hashtopolis-backend

  hashtopolis-proxy:
    image: nginx:alpine
    container_name: hashtopolis-proxy
    restart: unless-stopped
    ports:
      - "${INTERNAL_PORT}:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - hashtopolis-frontend
      - hashtopolis-backend

volumes:
  hash_db:
  hash_data:
EOF2

cat > nginx.conf <<'EOF2'
events {}

http {
  client_max_body_size 20G;

  upstream frontend {
    server hashtopolis-frontend:80;
  }

  upstream backend {
    server hashtopolis-backend:80;
  }

  server {
    listen 80;

    location /api/v2 {
      proxy_pass http://backend/api/v2;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /api/server.php {
      proxy_pass http://backend/api/server.php;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /api/ {
      proxy_pass http://backend/api/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
      proxy_pass http://frontend/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }
  }
}
EOF2
chown "${DOCKER_UID}:${DOCKER_GID}" docker-compose.yml nginx.conf

log "[8/10] Checking internal port ${INTERNAL_PORT}"
if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :${INTERNAL_PORT}" 2>/dev/null | grep -q .; then
  echo "ERROR: port ${INTERNAL_PORT} is already listening inside this Vast.ai instance." >&2
  echo "       Common cause: Jupyter launch mode already uses 8080." >&2
  echo "       Fix: launch in SSH mode, or set INTERNAL_PORT=18080 and expose -p 18080:18080 in Vast.ai." >&2
  ss -ltnp "sport = :${INTERNAL_PORT}" || true
  exit 1
fi

log "[9/10] Pulling and starting Hashtopolis containers"
docker compose pull
docker compose up -d

log "[10/10] Status"
docker compose ps

cat <<EOF2

============================================================
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

Check GPU:
  nvidia-smi
  hashcat -I

Check containers:
  export DOCKER_HOST=${DOCKER_HOST}
  docker compose -f ${APP_DIR}/docker-compose.yml ps

Check Docker mode:
  docker info --format '{{json .SecurityOptions}}'
  docker info --format '{{.Driver}}'

Check HTTP locally:
  curl -I http://127.0.0.1:${INTERNAL_PORT}
  curl -I http://127.0.0.1:${INTERNAL_PORT}/api/v2
============================================================
EOF2
