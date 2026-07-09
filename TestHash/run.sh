#!/usr/bin/env bash
set -Eeuo pipefail

# KiQuai Hashtopolis + Hashcat bootstrap for Vast.ai
# Mode: ROOTFUL Docker-in-Docker safe mode.
# Use this when rootless Docker fails with:
#   "unprivileged user namespaces are not available"
#
# Design goals:
# - Do NOT require rootless Docker/user namespaces.
# - Avoid Docker iptables/NAT manipulation by not publishing container ports.
# - Expose Hashtopolis through a host-level socat TCP proxy to a static proxy-container IP.
# - Fail fast and dump actionable logs instead of silent restart loops.
# - Keep Hashcat installed directly in the Vast.ai instance, not inside Hashtopolis containers.

############################
# User-configurable values #
############################

APP_DIR="${APP_DIR:-/opt/kiquai-hashtopolis}"
INTERNAL_PORT="${INTERNAL_PORT:-8080}"
OPEN_BUTTON_PORT="${OPEN_BUTTON_PORT:-${INTERNAL_PORT}}"

# Public URL detection for Vast.ai.
PUBLIC_URL_OVERRIDE="${PUBLIC_URL:-}"
PUBLIC_IP="${PUBLIC_IPADDR:-$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || echo 127.0.0.1)}"
PUBLIC_PORT_VAR="VAST_TCP_PORT_${INTERNAL_PORT}"
PUBLIC_PORT_DETECTED="${!PUBLIC_PORT_VAR:-}"
PUBLIC_PORT="${PUBLIC_PORT_DETECTED:-${INTERNAL_PORT}}"
PUBLIC_URL="${PUBLIC_URL:-http://${PUBLIC_IP}:${PUBLIC_PORT}}"

# Images. Override if upstream tags change.
HASHTOPOLIS_BACKEND_IMAGE="${HASHTOPOLIS_BACKEND_IMAGE:-hashtopolis/backend:v1.0.0-rc1}"
HASHTOPOLIS_FRONTEND_IMAGE="${HASHTOPOLIS_FRONTEND_IMAGE:-hashtopolis/frontend:master}"
DB_IMAGE="${DB_IMAGE:-mysql:8.4}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"

# Database / admin defaults.
MYSQL_DATABASE_DEFAULT="${MYSQL_DATABASE:-hashtopolis}"
MYSQL_USER_DEFAULT="${MYSQL_USER:-hashtopolis}"
HASHTOPOLIS_ADMIN_USER_DEFAULT="${HASHTOPOLIS_ADMIN_USER:-admin}"

# Docker-in-Docker daemon paths.
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/kiquai-docker.sock}"
DOCKER_PID="${DOCKER_PID:-/var/run/kiquai-dockerd.pid}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/var/lib/kiquai-docker}"
DOCKER_EXEC_ROOT="${DOCKER_EXEC_ROOT:-/var/run/kiquai-docker}"
DOCKER_LOG="${DOCKER_LOG:-/var/log/kiquai-dockerd.log}"
CONTAINERD_LOG="${CONTAINERD_LOG:-/var/log/kiquai-containerd.log}"

# Use overlay2 first. If it fails, the script retries vfs.
DOCKER_STORAGE_DRIVER="${DOCKER_STORAGE_DRIVER:-overlay2}"
ALLOW_VFS_FALLBACK="${ALLOW_VFS_FALLBACK:-1}"

# Static network for the proxy container. Change if it conflicts with your environment.
COMPOSE_SUBNET="${COMPOSE_SUBNET:-172.30.44.0/24}"
PROXY_STATIC_IP="${PROXY_STATIC_IP:-172.30.44.10}"
SOCAT_PID="${SOCAT_PID:-/var/run/kiquai-hashtopolis-socat.pid}"
SOCAT_LOG="${SOCAT_LOG:-/var/log/kiquai-hashtopolis-socat.log}"

# Runtime controls.
WIPE_DATA="${WIPE_DATA:-0}"
FORCE_RECREATE="${FORCE_RECREATE:-0}"
PULL_IMAGES="${PULL_IMAGES:-1}"
SKIP_APT="${SKIP_APT:-0}"

export DEBIAN_FRONTEND=noninteractive
export DOCKER_HOST="unix://${DOCKER_SOCK}"

#############
# Utilities #
#############

log() { echo "[$(date +'%F %T')] $*"; }
warn() { echo "WARNING: $*" >&2; }
fatal() { echo "ERROR: $*" >&2; exit 1; }

rand_secret() {
  openssl rand -base64 48 | tr -d '=+/[:space:]' | cut -c1-32
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fatal "Run this script as root inside the Vast.ai instance."
  fi
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

print_header() {
  cat <<'EOM'
============================================================
KiQuai Hashtopolis + Hashcat bootstrap for Vast.ai
Mode: rootful Docker-in-Docker safe mode
============================================================
EOM
}

show_environment_summary() {
  cat <<EOF2
Runtime summary:
  APP_DIR=${APP_DIR}
  INTERNAL_PORT=${INTERNAL_PORT}
  PUBLIC_URL=${PUBLIC_URL}
  DOCKER_HOST=${DOCKER_HOST}
  DOCKER_DATA_ROOT=${DOCKER_DATA_ROOT}
  DOCKER_STORAGE_DRIVER=${DOCKER_STORAGE_DRIVER}
  COMPOSE_SUBNET=${COMPOSE_SUBNET}
  PROXY_STATIC_IP=${PROXY_STATIC_IP}
  Backend image=${HASHTOPOLIS_BACKEND_IMAGE}
  Frontend image=${HASHTOPOLIS_FRONTEND_IMAGE}
  DB image=${DB_IMAGE}
EOF2
}

on_error() {
  local exit_code=$?
  echo >&2
  echo "============================================================" >&2
  echo "Deployment failed with exit code ${exit_code}" >&2
  echo "============================================================" >&2
  dump_diagnostics || true
  exit "${exit_code}"
}
trap on_error ERR

################
# Diagnostics  #
################

dump_file_tail() {
  local file="$1"
  local lines="${2:-160}"
  if [ -f "$file" ]; then
    echo >&2
    echo "==== tail -n ${lines} ${file} ====" >&2
    tail -n "$lines" "$file" >&2 || true
  fi
}

dump_diagnostics() {
  echo >&2
  echo "==== basic system info ====" >&2
  uname -a >&2 || true
  id >&2 || true
  cat /etc/os-release >&2 || true

  echo >&2
  echo "==== capability / namespace probes ====" >&2
  grep -E 'Cap(Eff|Prm|Bnd)' /proc/self/status >&2 || true
  sysctl kernel.unprivileged_userns_clone 2>/dev/null >&2 || true
  unshare -Ur true >/dev/null 2>&1 && echo "userns probe: OK" >&2 || echo "userns probe: blocked" >&2

  echo >&2
  echo "==== listening ports ====" >&2
  ss -ltnp >&2 || true

  echo >&2
  echo "==== docker info ====" >&2
  docker info >&2 || true

  if [ -d "${APP_DIR}" ]; then
    echo >&2
    echo "==== docker compose ps ====" >&2
    (cd "${APP_DIR}" && docker compose ps -a) >&2 || true

    for svc in hashtopolis-db hashtopolis-backend hashtopolis-frontend hashtopolis-proxy; do
      echo >&2
      echo "==== logs: ${svc} ====" >&2
      docker logs --tail 180 "${svc}" >&2 || true
      echo >&2
      echo "==== inspect: ${svc} ====" >&2
      docker inspect --format='name={{.Name}} state={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}} oom={{.State.OOMKilled}} started={{.State.StartedAt}} finished={{.State.FinishedAt}} ip={{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${svc}" >&2 || true
    done
  fi

  dump_file_tail "${DOCKER_LOG}" 220
  dump_file_tail "${CONTAINERD_LOG}" 120
  dump_file_tail "${SOCAT_LOG}" 120
}

########################
# Preflight and APT    #
########################

validate_vast_options() {
  if [ -z "${PUBLIC_PORT_DETECTED}" ] && [ -z "${PUBLIC_URL_OVERRIDE}" ]; then
    warn "${PUBLIC_PORT_VAR} is not set. Vast.ai may have mapped ${INTERNAL_PORT} to a random external port."
    warn "If the final URL is wrong, rerun with PUBLIC_URL='http://PUBLIC_IP:EXTERNAL_PORT'."
  fi

  if ss -ltnH "sport = :${INTERNAL_PORT}" 2>/dev/null | grep -q .; then
    warn "Port ${INTERNAL_PORT} is already listening before deployment."
    ss -ltnp "sport = :${INTERNAL_PORT}" || true
    fatal "Choose a different INTERNAL_PORT or stop the process occupying this port."
  fi
}

validate_gpu() {
  log "[1/12] Validating GPU"
  if ! have_cmd nvidia-smi; then
    fatal "nvidia-smi is not installed. Use a CUDA/NVIDIA Vast.ai image, e.g. nvidia/cuda:12.9.1-devel-ubuntu24.04."
  fi
  nvidia-smi || fatal "nvidia-smi failed. The Vast.ai instance does not expose GPU correctly."
}

install_packages() {
  log "[2/12] Installing system packages"
  if [ "${SKIP_APT}" = "1" ]; then
    log "SKIP_APT=1; skipping apt installation."
    return 0
  fi

  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    gnupg \
    lsb-release \
    iptables \
    iproute2 \
    kmod \
    procps \
    psmisc \
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
    socat \
    clinfo \
    ocl-icd-libopencl1 \
    hashcat
}

install_docker_engine() {
  log "[3/12] Installing Docker Engine"
  if have_cmd docker && have_cmd dockerd && docker compose version >/dev/null 2>&1; then
    log "Docker Engine and Compose plugin already installed."
    return 0
  fi

  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
}

############################
# Rootful dockerd startup   #
############################

stop_old_runtime_processes() {
  log "[4/12] Cleaning stale local Docker/socat processes"

  if [ -f "${SOCAT_PID}" ]; then
    kill "$(cat "${SOCAT_PID}")" 2>/dev/null || true
    rm -f "${SOCAT_PID}"
  fi

  if [ -f "${DOCKER_PID}" ]; then
    kill "$(cat "${DOCKER_PID}")" 2>/dev/null || true
    sleep 2 || true
    rm -f "${DOCKER_PID}"
  fi

  # Only kill daemons using our custom socket/path/log when possible.
  pkill -f "dockerd.*${DOCKER_SOCK}" 2>/dev/null || true
  pkill -f "socat.*${PROXY_STATIC_IP}:80" 2>/dev/null || true
  rm -f "${DOCKER_SOCK}"
}

start_containerd_if_needed() {
  if pgrep -x containerd >/dev/null 2>&1; then
    log "containerd is already running."
    return 0
  fi

  log "Starting containerd"
  nohup containerd > "${CONTAINERD_LOG}" 2>&1 &
  for _ in $(seq 1 30); do
    if pgrep -x containerd >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  fatal "containerd failed to start."
}

mount_cgroup_best_effort() {
  # Docker may need cgroup information in nested container environments.
  # In many Vast.ai templates this is already mounted. If it is read-only or blocked,
  # this best-effort step is allowed to fail; the later docker smoke test is decisive.
  if [ -d /sys/fs/cgroup ] && mountpoint -q /sys/fs/cgroup; then
    log "cgroup filesystem is already mounted."
    return 0
  fi

  mkdir -p /sys/fs/cgroup || true
  mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true
}

start_dockerd_with_driver() {
  local driver="$1"

  mkdir -p "${DOCKER_DATA_ROOT}" "${DOCKER_EXEC_ROOT}" "$(dirname "${DOCKER_SOCK}")"
  rm -f "${DOCKER_SOCK}" "${DOCKER_PID}"

  log "Starting dockerd with storage-driver=${driver}"
  cat > /etc/profile.d/kiquai-rootful-docker.sh <<EOF2
export DOCKER_HOST=unix://${DOCKER_SOCK}
EOF2

  # Key flags:
  # --iptables=false / --ip-masq=false: avoid NAT chain DOCKER failures in nested containers.
  # --bridge=none: avoid default docker0 setup; Compose creates a user-defined bridge later.
  # No port publishing is used. A host-level socat proxy exposes ${INTERNAL_PORT}.
  nohup dockerd \
    --host="unix://${DOCKER_SOCK}" \
    --pidfile="${DOCKER_PID}" \
    --data-root="${DOCKER_DATA_ROOT}" \
    --exec-root="${DOCKER_EXEC_ROOT}" \
    --storage-driver="${driver}" \
    --iptables=false \
    --ip6tables=false \
    --ip-masq=false \
    --bridge=none \
    --userland-proxy=false \
    --debug \
    > "${DOCKER_LOG}" 2>&1 &

  for _ in $(seq 1 90); do
    if docker info >/dev/null 2>&1; then
      DOCKER_STORAGE_DRIVER="${driver}"
      return 0
    fi
    sleep 1
  done

  return 1
}

start_dockerd() {
  log "[5/12] Starting rootful Docker daemon safe mode"
  mount_cgroup_best_effort
  start_containerd_if_needed

  if start_dockerd_with_driver "${DOCKER_STORAGE_DRIVER}"; then
    log "dockerd is ready with ${DOCKER_STORAGE_DRIVER}."
  else
    warn "dockerd failed with storage-driver=${DOCKER_STORAGE_DRIVER}."
    dump_file_tail "${DOCKER_LOG}" 120

    if [ "${ALLOW_VFS_FALLBACK}" = "1" ] && [ "${DOCKER_STORAGE_DRIVER}" != "vfs" ]; then
      warn "Retrying dockerd with storage-driver=vfs. This is slower but often works in restricted nested environments."
      pkill -f "dockerd.*${DOCKER_SOCK}" 2>/dev/null || true
      sleep 3
      if ! start_dockerd_with_driver "vfs"; then
        fatal "dockerd failed with both ${DOCKER_STORAGE_DRIVER} and vfs. This Vast.ai offer/template does not support nested Docker enough."
      fi
    else
      fatal "dockerd failed to start."
    fi
  fi

  docker info --format 'Docker ready: server={{.ServerVersion}} driver={{.Driver}} cgroup={{.CgroupDriver}} root={{.DockerRootDir}}'
}

smoke_test_docker_network() {
  log "[6/12] Running Docker smoke tests"
  docker version

  # Pulling proves the daemon can reach registries from the host namespace.
  docker pull hello-world:latest >/dev/null

  # Running proves runc/cgroups/mounts work.
  docker run --rm --network none hello-world:latest >/dev/null

  # User-defined bridge proves Compose service networking can work without Docker iptables NAT.
  docker network rm kiquai-smoke-net >/dev/null 2>&1 || true
  docker network create --driver bridge --subnet 172.30.45.0/24 kiquai-smoke-net >/dev/null
  docker run -d --rm --name kiquai-smoke-nginx --network kiquai-smoke-net --ip 172.30.45.10 nginx:1.27-alpine >/dev/null
  for _ in $(seq 1 30); do
    if curl -fsS --max-time 2 http://172.30.45.10 >/dev/null 2>&1; then
      docker rm -f kiquai-smoke-nginx >/dev/null 2>&1 || true
      docker network rm kiquai-smoke-net >/dev/null 2>&1 || true
      log "Docker network smoke test passed."
      return 0
    fi
    sleep 1
  done

  docker logs kiquai-smoke-nginx || true
  docker rm -f kiquai-smoke-nginx >/dev/null 2>&1 || true
  docker network rm kiquai-smoke-net >/dev/null 2>&1 || true
  fatal "Docker user-defined bridge is not reachable from host. Provider likely blocks nested network namespace/bridge even with --privileged."
}

############################
# Hashtopolis stack files  #
############################

prepare_app_dir() {
  log "[7/12] Preparing Hashtopolis app directory"

  if [ "${WIPE_DATA}" = "1" ]; then
    warn "WIPE_DATA=1: removing ${APP_DIR} and Docker volumes for this stack."
    if [ -d "${APP_DIR}" ]; then
      (cd "${APP_DIR}" && docker compose down -v --remove-orphans) || true
    fi
    rm -rf "${APP_DIR}"
  fi

  mkdir -p "${APP_DIR}"
  cd "${APP_DIR}"

  if [ -f .env ]; then
    log "Existing .env found; preserving credentials unless environment overrides them."
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
  HASHTOPOLIS_APIV2_ENABLE="${HASHTOPOLIS_APIV2_ENABLE:-1}"
  HASHTOPOLIS_BACKEND_URL="${HASHTOPOLIS_BACKEND_URL:-${PUBLIC_URL}/api/v2}"

  cat > .env <<EOF2
INTERNAL_PORT=${INTERNAL_PORT}
PUBLIC_URL=${PUBLIC_URL}
PUBLIC_PORT=${PUBLIC_PORT}
COMPOSE_SUBNET=${COMPOSE_SUBNET}
PROXY_STATIC_IP=${PROXY_STATIC_IP}
HASHTOPOLIS_BACKEND_IMAGE=${HASHTOPOLIS_BACKEND_IMAGE}
HASHTOPOLIS_FRONTEND_IMAGE=${HASHTOPOLIS_FRONTEND_IMAGE}
DB_IMAGE=${DB_IMAGE}
NGINX_IMAGE=${NGINX_IMAGE}
MYSQL_ROOT_PASS=${MYSQL_ROOT_PASS}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
HASHTOPOLIS_ADMIN_USER=${HASHTOPOLIS_ADMIN_USER}
HASHTOPOLIS_ADMIN_PASSWORD=${HASHTOPOLIS_ADMIN_PASSWORD}
HASHTOPOLIS_APIV2_ENABLE=${HASHTOPOLIS_APIV2_ENABLE}
HASHTOPOLIS_BACKEND_URL=${HASHTOPOLIS_BACKEND_URL}
EOF2
  chmod 600 .env
}

write_compose() {
  log "[8/12] Writing docker-compose.yml and nginx.conf"
  cd "${APP_DIR}"

  cat > docker-compose.yml <<'EOF2'
services:
  hashtopolis-db:
    image: ${DB_IMAGE}
    container_name: hashtopolis-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASS}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    command:
      - --max_allowed_packet=1G
    volumes:
      - hash_db:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p$${MYSQL_ROOT_PASSWORD} --silent"]
      interval: 10s
      timeout: 5s
      retries: 60
      start_period: 30s
    networks:
      hashtopolis-net:

  hashtopolis-backend:
    image: ${HASHTOPOLIS_BACKEND_IMAGE}
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
      HASHTOPOLIS_FRONTEND_PORT: ${PUBLIC_PORT}
      HASHTOPOLIS_APIV2_ENABLE: ${HASHTOPOLIS_APIV2_ENABLE}
    volumes:
      - hash_data:/usr/local/share/hashtopolis
    depends_on:
      hashtopolis-db:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1/api/v2 >/dev/null || curl -fsS http://127.0.0.1/api/server.php >/dev/null || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 60
      start_period: 45s
    networks:
      hashtopolis-net:

  hashtopolis-frontend:
    image: ${HASHTOPOLIS_FRONTEND_IMAGE}
    container_name: hashtopolis-frontend
    restart: unless-stopped
    environment:
      HASHTOPOLIS_BACKEND_URL: ${HASHTOPOLIS_BACKEND_URL}
    depends_on:
      hashtopolis-backend:
        condition: service_started
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1/ || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 60
      start_period: 20s
    networks:
      hashtopolis-net:

  hashtopolis-proxy:
    image: ${NGINX_IMAGE}
    container_name: hashtopolis-proxy
    restart: unless-stopped
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      hashtopolis-frontend:
        condition: service_started
      hashtopolis-backend:
        condition: service_started
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1/ || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 60
      start_period: 10s
    networks:
      hashtopolis-net:
        ipv4_address: ${PROXY_STATIC_IP}

volumes:
  hash_db:
  hash_data:

networks:
  hashtopolis-net:
    driver: bridge
    ipam:
      config:
        - subnet: ${COMPOSE_SUBNET}
EOF2

  cat > nginx.conf <<'EOF2'
events {}

http {
  client_max_body_size 20G;
  proxy_read_timeout 3600s;
  proxy_send_timeout 3600s;
  proxy_connect_timeout 120s;

  upstream frontend {
    server hashtopolis-frontend:80;
  }

  upstream backend {
    server hashtopolis-backend:80;
  }

  server {
    listen 80;

    location = /healthz {
      return 200 "ok\n";
      add_header Content-Type text/plain;
    }

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

  cat > kiquai-logs.sh <<EOF2
#!/usr/bin/env bash
set -u
export DOCKER_HOST="unix://${DOCKER_SOCK}"
cd "${APP_DIR}" || exit 1
printf '\n==== docker compose ps -a ====\n'
docker compose ps -a || true
for svc in hashtopolis-db hashtopolis-backend hashtopolis-frontend hashtopolis-proxy; do
  printf '\n==== logs: %s ====\n' "\$svc"
  docker logs --tail 220 "\$svc" || true
  printf '\n==== inspect: %s ====\n' "\$svc"
  docker inspect --format='name={{.Name}} state={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} ip={{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "\$svc" || true
done
printf '\n==== dockerd log ====\n'
tail -n 220 "${DOCKER_LOG}" || true
printf '\n==== socat log ====\n'
tail -n 120 "${SOCAT_LOG}" || true
EOF2
  chmod +x kiquai-logs.sh
}

############################
# Deploy and expose        #
############################

pull_images() {
  log "[9/12] Pulling images"
  cd "${APP_DIR}"
  if [ "${PULL_IMAGES}" = "1" ]; then
    docker compose pull
  else
    log "PULL_IMAGES=0; skipping docker compose pull."
  fi
}

start_stack() {
  log "[10/12] Starting Hashtopolis stack"
  cd "${APP_DIR}"
  docker compose config >/dev/null

  if [ "${FORCE_RECREATE}" = "1" ]; then
    docker compose up -d --force-recreate --remove-orphans
  else
    docker compose up -d --remove-orphans
  fi
}

wait_for_container() {
  local name="$1"
  local max_seconds="${2:-180}"
  local elapsed=0

  while [ "${elapsed}" -lt "${max_seconds}" ]; do
    local status health exit_code
    status="$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || echo missing)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${name}" 2>/dev/null || echo missing)"
    exit_code="$(docker inspect -f '{{.State.ExitCode}}' "${name}" 2>/dev/null || echo 999)"

    if [ "${status}" = "running" ] && { [ "${health}" = "healthy" ] || [ "${health}" = "none" ]; }; then
      log "${name}: status=${status}, health=${health}"
      return 0
    fi

    if [ "${status}" = "exited" ] || [ "${status}" = "dead" ]; then
      warn "${name} is ${status} with exit_code=${exit_code}."
      docker logs --tail 160 "${name}" || true
      return 1
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  warn "Timed out waiting for ${name}."
  docker inspect "${name}" || true
  docker logs --tail 160 "${name}" || true
  return 1
}

wait_for_stack() {
  log "[11/12] Waiting for service health"
  wait_for_container hashtopolis-db 300
  wait_for_container hashtopolis-backend 300
  wait_for_container hashtopolis-frontend 240
  wait_for_container hashtopolis-proxy 240
}

start_socat_proxy() {
  log "[12/12] Exposing Hashtopolis on host port ${INTERNAL_PORT} via socat"

  if [ -f "${SOCAT_PID}" ]; then
    kill "$(cat "${SOCAT_PID}")" 2>/dev/null || true
    rm -f "${SOCAT_PID}"
  fi
  pkill -f "socat.*TCP-LISTEN:${INTERNAL_PORT}.*${PROXY_STATIC_IP}:80" 2>/dev/null || true

  # Verify static container IP before starting the proxy.
  local actual_ip
  actual_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' hashtopolis-proxy)"
  if [ "${actual_ip}" != "${PROXY_STATIC_IP}" ]; then
    fatal "hashtopolis-proxy IP is ${actual_ip}, expected ${PROXY_STATIC_IP}. Check COMPOSE_SUBNET/PROXY_STATIC_IP conflict."
  fi

  nohup socat \
    TCP-LISTEN:"${INTERNAL_PORT}",fork,reuseaddr,bind=0.0.0.0 \
    TCP:"${PROXY_STATIC_IP}":80 \
    > "${SOCAT_LOG}" 2>&1 &
  echo $! > "${SOCAT_PID}"

  for _ in $(seq 1 60); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${INTERNAL_PORT}/healthz" >/dev/null 2>&1; then
      log "Host-level HTTP proxy is ready."
      return 0
    fi
    sleep 1
  done

  fatal "socat proxy did not become reachable on 127.0.0.1:${INTERNAL_PORT}."
}

check_hashcat() {
  log "Checking Hashcat/OpenCL"
  hashcat --version || true
  hashcat -I || true
}

print_success() {
  cd "${APP_DIR}"
  docker compose ps -a

  cat <<EOF2

============================================================
DEPLOYMENT COMPLETE
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

Important shell setup:
  source /etc/profile.d/kiquai-rootful-docker.sh

Check containers:
  cd ${APP_DIR}
  docker compose ps -a

Check logs:
  ${APP_DIR}/kiquai-logs.sh

Check local HTTP:
  curl -I http://127.0.0.1:${INTERNAL_PORT}
  curl -I http://127.0.0.1:${INTERNAL_PORT}/api/v2
  curl -I http://127.0.0.1:${INTERNAL_PORT}/api/server.php

Check GPU and Hashcat:
  nvidia-smi
  hashcat -I

Rootful Docker socket:
  ${DOCKER_HOST}

Docker daemon log:
  ${DOCKER_LOG}

Socat proxy log:
  ${SOCAT_LOG}
============================================================
EOF2
}

main() {
  print_header
  require_root
  show_environment_summary
  validate_vast_options
  validate_gpu
  install_packages
  install_docker_engine
  stop_old_runtime_processes
  start_dockerd
  smoke_test_docker_network
  prepare_app_dir
  write_compose
  pull_images
  start_stack
  wait_for_stack
  start_socat_proxy
  check_hashcat
  print_success
}

main "$@"
