#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${APP_DIR:-/opt/kiquai-hashtopolis}"
INTERNAL_PORT="${INTERNAL_PORT:-8080}"

MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-$(openssl rand -base64 24 | tr -d '=+/ ' | cut -c1-24)}"
MYSQL_DATABASE="${MYSQL_DATABASE:-hashtopolis}"
MYSQL_USER="${MYSQL_USER:-hashtopolis}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-$(openssl rand -base64 24 | tr -d '=+/ ' | cut -c1-24)}"

HASHTOPOLIS_ADMIN_USER="${HASHTOPOLIS_ADMIN_USER:-admin}"
HASHTOPOLIS_ADMIN_PASSWORD="${HASHTOPOLIS_ADMIN_PASSWORD:-$(openssl rand -base64 24 | tr -d '=+/ ' | cut -c1-24)}"

PUBLIC_IP="${PUBLIC_IPADDR:-$(curl -fsS https://api.ipify.org || echo 127.0.0.1)}"
PUBLIC_PORT_VAR="VAST_TCP_PORT_${INTERNAL_PORT}"
PUBLIC_PORT="${!PUBLIC_PORT_VAR:-${INTERNAL_PORT}}"
PUBLIC_URL="${PUBLIC_URL:-http://${PUBLIC_IP}:${PUBLIC_PORT}}"

echo "[1/9] Validating GPU..."
nvidia-smi || {
  echo "ERROR: nvidia-smi failed. Make sure the Vast.ai instance has GPU access."
  exit 1
}

echo "[2/9] Installing system packages..."
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

echo "[3/9] Installing Docker Engine inside Vast instance..."
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc

  chmod a+r /etc/apt/keyrings/docker.asc

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
fi

echo "[4/9] Starting dockerd..."
mkdir -p /var/run /var/lib/docker

if ! pgrep dockerd >/dev/null 2>&1; then
  dockerd \
    --host=unix:///var/run/docker.sock \
    --storage-driver=overlay2 \
    > /var/log/dockerd.log 2>&1 &
fi

for i in $(seq 1 90); do
  if docker info >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: dockerd failed to start."
  cat /var/log/dockerd.log || true
  exit 1
fi

echo "[5/9] Checking hashcat..."
hashcat --version || true
hashcat -I || true

echo "[6/9] Creating Hashtopolis stack..."
mkdir -p "${APP_DIR}"
cd "${APP_DIR}"

cat > .env <<EOF
MYSQL_ROOT_PASS=${MYSQL_ROOT_PASS}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
HASHTOPOLIS_ADMIN_USER=${HASHTOPOLIS_ADMIN_USER}
HASHTOPOLIS_ADMIN_PASSWORD=${HASHTOPOLIS_ADMIN_PASSWORD}
HASHTOPOLIS_BACKEND_URL=${PUBLIC_URL}/api/v2
EOF

cat > docker-compose.yml <<'EOF'
services:
  hashtopolis-db:
    image: mariadb:10.11
    container_name: hashtopolis-db
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASS}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - ./hash_db:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -h 127.0.0.1 -uroot -p$${MYSQL_ROOT_PASSWORD} || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 30

  hashtopolis-backend:
    image: hashtopolis/backend:latest
    container_name: hashtopolis-backend
    restart: always
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
      - ./hash_data:/usr/local/share/hashtopolis:Z
    depends_on:
      hashtopolis-db:
        condition: service_healthy

  hashtopolis-frontend:
    image: hashtopolis/frontend:latest
    container_name: hashtopolis-frontend
    restart: always
    environment:
      HASHTOPOLIS_BACKEND_URL: ${HASHTOPOLIS_BACKEND_URL}
    depends_on:
      - hashtopolis-backend

  hashtopolis-proxy:
    image: nginx:alpine
    container_name: hashtopolis-proxy
    restart: always
    ports:
      - "8080:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - hashtopolis-frontend
      - hashtopolis-backend
EOF

cat > nginx.conf <<'EOF'
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
EOF

echo "[7/9] Pulling and starting Hashtopolis containers..."
docker compose pull
docker compose up -d

echo "[8/9] Status..."
docker compose ps

echo "[9/9] Done."
echo
echo "============================================================"
echo "Hashtopolis URL:"
echo "  ${PUBLIC_URL}"
echo
echo "Admin username:"
echo "  ${HASHTOPOLIS_ADMIN_USER}"
echo
echo "Admin password:"
echo "  ${HASHTOPOLIS_ADMIN_PASSWORD}"
echo
echo "Backend API v2:"
echo "  ${PUBLIC_URL}/api/v2"
echo
echo "Legacy agent API:"
echo "  ${PUBLIC_URL}/api/server.php"
echo
echo "Check GPU:"
echo "  nvidia-smi"
echo "  hashcat -I"
echo
echo "Check containers:"
echo "  docker compose -f ${APP_DIR}/docker-compose.yml ps"
echo "============================================================"
