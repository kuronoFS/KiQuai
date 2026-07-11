#!/usr/bin/env bash
# shellcheck shell=bash
# KiQuai module: config
# kiquai-module-api: 1
# kiquai-release: 3.2.0

if [[ "${KIQUAI_MODULE_CONTEXT:-0}" != "1" ]]; then
  printf 'This file is a KiQuai module; run ../run.sh instead.\n' >&2
  return 64 2>/dev/null || exit 64
fi

write_mysql_config() {
  local temp="${MYSQL_CONFIG}.tmp.$$"
  touch "${LOG_DIR}/mysql.log"
  chown mysql:mysql "${LOG_DIR}/mysql.log"
  chmod 640 "${LOG_DIR}/mysql.log"
  cat > "${temp}" <<EOF
[mysqld]
user=mysql
datadir=${MYSQL_DATA_DIR}
socket=${MYSQL_RUN_DIR}/mysqld.sock
pid-file=${MYSQL_RUN_DIR}/mysqld.pid
port=${DB_PORT}
bind-address=127.0.0.1
mysqlx=0
skip-name-resolve
skip-log-bin
max_allowed_packet=1G
log-error=${LOG_DIR}/mysql.log

[client]
socket=${MYSQL_RUN_DIR}/mysqld.sock
port=${DB_PORT}
host=127.0.0.1
EOF
  chown mysql:mysql "${temp}"
  chmod 600 "${temp}"
  mv -f "${temp}" "${MYSQL_CONFIG}"
}

write_php_config() {
  local directory
  for directory in /etc/php/*/apache2/conf.d; do
    [[ -d "${directory}" ]] || continue
    cat > "${directory}/99-kiquai-hashtopolis.ini" <<'EOF'
memory_limit = 512M
upload_max_filesize = 20G
post_max_size = 20G
max_execution_time = 3600
max_input_time = 3600
display_errors = Off
log_errors = On
expose_php = Off
EOF
  done
}

write_apache_config() {
  cat > /etc/apache2/ports.conf <<EOF
Listen 127.0.0.1:${BACKEND_PORT}
EOF
  cat > /etc/apache2/conf-available/kiquai-servername.conf <<'EOF'
ServerName 127.0.0.1
EOF
  a2enconf kiquai-servername >/dev/null
  a2dissite 000-default.conf >/dev/null 2>&1 || true
  cat > /etc/apache2/sites-available/kiquai-hashtopolis.conf <<EOF
<VirtualHost 127.0.0.1:${BACKEND_PORT}>
    ServerName 127.0.0.1
    DocumentRoot "${SERVER_CURRENT}/src"
    ErrorLog "${LOG_DIR}/apache-error.log"
    CustomLog "${LOG_DIR}/apache-access.log" combined

    <Directory "${SERVER_CURRENT}/src">
        Options FollowSymLinks
        AllowOverride None
        Require all granted
        LimitRequestBody 0
    </Directory>

    <Directory "${SERVER_CURRENT}/src/api/v2">
        AllowOverride All
        Require all granted
    </Directory>

    <Directory "${SERVER_CURRENT}/src/install">
        Require all denied
    </Directory>

    Alias /binaries "${HASHTOPOLIS_DATA_DIR}/binaries"
    <Directory "${HASHTOPOLIS_DATA_DIR}/binaries">
        Options FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    Header always set Referrer-Policy "same-origin"
    Header always set X-Frame-Options "DENY"
    Header always set X-Content-Type-Options "nosniff"
    Header unset X-Powered-By
</VirtualHost>
EOF
  a2ensite kiquai-hashtopolis.conf >/dev/null
  write_php_config
  apache2ctl configtest
}

write_frontend_config() {
  local example="${FRONTEND_CURRENT}/dist/assets/config.json.example"
  local target="${FRONTEND_CURRENT}/dist/assets/config.json"
  local temp="${target}.tmp.$$"
  local themes_target="${FRONTEND_CURRENT}/dist/assets/themes/custom-themes.json"
  local themes_temp="${themes_target}.tmp.$$"
  [[ -f "${example}" ]] || die "Frontend config template is missing: ${example}"
  mkdir -p "${FRONTEND_CURRENT}/dist/assets/themes"
  jq --arg backend_url "${HASHTOPOLIS_BACKEND_URL}" \
    '.hashtopolis_backend_url = $backend_url' "${example}" > "${temp}"
  jq -e '.hashtopolis_backend_url | type == "string" and endswith("/api/v2")' \
    "${temp}" >/dev/null || die "Generated frontend config is invalid."
  printf '%s\n' '[]' > "${themes_temp}"
  chown root:www-data "${temp}" "${themes_temp}"
  chmod 640 "${temp}" "${themes_temp}"
  mv -f "${temp}" "${target}"
  mv -f "${themes_temp}" "${themes_target}"
}

write_nginx_config() {
  local temp="${NGINX_CONFIG}.tmp.$$"
  cat > "${temp}" <<EOF
user www-data;
worker_processes auto;
pid ${RUN_DIR}/nginx.pid;
error_log ${LOG_DIR}/nginx-error.log notice;

events {
    worker_connections 2048;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log ${LOG_DIR}/nginx-access.log;
    server_tokens off;
    sendfile on;

    client_max_body_size 20G;
    client_body_timeout 3600s;
    proxy_connect_timeout 30s;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    server {
        listen 0.0.0.0:${INTERNAL_PORT};
        server_name _;
        root ${FRONTEND_CURRENT}/dist;
        index index.html;

        location = /healthz {
            access_log off;
            add_header Content-Type text/plain;
            return 200 "ok\n";
        }

        location ^~ /api/ {
            proxy_pass http://127.0.0.1:${BACKEND_PORT};
            proxy_request_buffering off;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host \$http_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location ^~ /binaries/ {
            proxy_pass http://127.0.0.1:${BACKEND_PORT};
            proxy_request_buffering off;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host \$http_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location ~ \.php\$ {
            proxy_pass http://127.0.0.1:${BACKEND_PORT};
            proxy_request_buffering off;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host \$http_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF
  chmod 640 "${temp}"
  nginx -t -c "${temp}"
  mv -f "${temp}" "${NGINX_CONFIG}"
}

write_runtime_environment() {
  cat > "${RUNTIME_ENV_FILE}" <<'EOF'
#!/usr/bin/env bash
if [[ "${KIQUAI_RUNTIME_CONFIG_LOADED:-0}" != "1" ]]; then
  set -a
  source "__ENV_FILE__"
  set +a
fi

SERVER_CURRENT="${APP_DIR}/current/server"
HASHTOPOLIS_DATA_DIR="${APP_DIR}/data/hashtopolis"
RUN_DIR="${APP_DIR}/run"
BACKEND_READY_FILE="${RUN_DIR}/backend-ready"
KIQUAI_RUN_ID="$(cat "${RUN_DIR}/current-run-id" 2>/dev/null || printf 'service-restart')"
export PATH="${APP_DIR}/tools/bin:/usr/local/nvidia/bin:${PATH}"
export LD_LIBRARY_PATH="/usr/local/nvidia/lib:/usr/local/nvidia/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export HASHTOPOLIS_DOCUMENT_ROOT="${SERVER_CURRENT}/src"
export HASHTOPOLIS_PATH="${HASHTOPOLIS_DATA_DIR}"
export HASHTOPOLIS_FILES_PATH="${HASHTOPOLIS_DATA_DIR}/files"
export HASHTOPOLIS_IMPORT_PATH="${HASHTOPOLIS_DATA_DIR}/import"
export HASHTOPOLIS_LOG_PATH="${HASHTOPOLIS_DATA_DIR}/log"
export HASHTOPOLIS_CONFIG_PATH="${HASHTOPOLIS_DATA_DIR}/config"
export HASHTOPOLIS_BINARIES_PATH="${HASHTOPOLIS_DATA_DIR}/binaries"
export HASHTOPOLIS_TUS_PATH="${HASHTOPOLIS_DATA_DIR}/tus"
export HASHTOPOLIS_TEMP_UPLOADS_PATH="${HASHTOPOLIS_DATA_DIR}/tus/uploads"
export HASHTOPOLIS_TEMP_META_PATH="${HASHTOPOLIS_DATA_DIR}/tus/meta"
export HASHTOPOLIS_DB_TYPE="mysql"
export HASHTOPOLIS_DB_HOST="127.0.0.1"
export HASHTOPOLIS_DB_PORT="${DB_PORT}"
export HASHTOPOLIS_DB_USER="${MYSQL_USER}"
export HASHTOPOLIS_DB_PASS="${MYSQL_PASSWORD}"
export HASHTOPOLIS_DB_DATABASE="${MYSQL_DATABASE}"
export HASHTOPOLIS_APIV2_ENABLE="1"
export HASHTOPOLIS_ADMIN_USER HASHTOPOLIS_ADMIN_PASSWORD
export HASHTOPOLIS_BACKEND_URL HASHTOPOLIS_FRONTEND_PORT

runtime_log() {
  local level="$1"
  shift
  printf '[%s] %-5s [run=%s] [component=%s] %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S%z')" "${level}" "${KIQUAI_RUN_ID}" \
    "${KIQUAI_COMPONENT:-runtime}" "$*"
}
EOF
  sed -i "s|__ENV_FILE__|${ENV_FILE}|g" "${RUNTIME_ENV_FILE}"
  chmod 700 "${RUNTIME_ENV_FILE}"
}

write_backend_launcher() {
  cat > "${CONFIG_DIR}/start-backend.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source "__RUNTIME_ENV_FILE__"
KIQUAI_COMPONENT="backend"

expected_ready="${HASHTOPOLIS_VERSION}|$(readlink -f "${SERVER_CURRENT}")"
actual_ready="$(cat "${BACKEND_READY_FILE}" 2>/dev/null || true)"
if [[ "${actual_ready}" != "${expected_ready}" ]]; then
  runtime_log ERROR "Backend start refused: the synchronous migration gate is not complete for the active release."
  runtime_log ERROR "Expected marker '${expected_ready}', found '${actual_ready:-missing}'. Run './run.sh deploy'."
  exit 1
fi
if ! runuser -u www-data -- test -w "${SERVER_CURRENT}/src/inc/utils/locks"; then
  runtime_log ERROR "Hashtopolis lock directory is not writable by www-data: ${SERVER_CURRENT}/src/inc/utils/locks"
  exit 1
fi

runtime_log INFO "Starting Apache for Hashtopolis ${HASHTOPOLIS_VERSION}; migrations already completed."
exec /usr/sbin/apache2ctl -DFOREGROUND
EOF
  sed -i "s|__RUNTIME_ENV_FILE__|${RUNTIME_ENV_FILE}|g" "${CONFIG_DIR}/start-backend.sh"
  chmod 700 "${CONFIG_DIR}/start-backend.sh"
}

write_agent_launcher() {
  cat > "${CONFIG_DIR}/start-agent.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source "__RUNTIME_ENV_FILE__"
KIQUAI_COMPONENT="agent"
AGENT_DIR="${APP_DIR}/agent"
cd "${AGENT_DIR}"

for _attempt in $(seq 1 150); do
  [[ -f "${AGENT_DIR}/hashtopolis.zip" ]] && break
  if [[ "${_attempt}" == "150" ]]; then
    runtime_log ERROR "Agent package did not become available."
    exit 1
  fi
  sleep 2
done

args=(
  python3 "${AGENT_DIR}/hashtopolis.zip"
  --url "http://127.0.0.1:${INTERNAL_PORT}/api/server.php"
  --files-path "${AGENT_DIR}/files"
  --crackers-path "${AGENT_DIR}/crackers"
  --hashlists-path "${AGENT_DIR}/hashlists"
  --preprocessors-path "${AGENT_DIR}/preprocessors"
  --zaps-path "${AGENT_DIR}/zaps"
)
if [[ ! -s "${AGENT_DIR}/config.json" ]]; then
  [[ -n "${AGENT_VOUCHER}" ]] || {
    runtime_log ERROR "No agent config or AGENT_VOUCHER is available."
    exit 1
  }
  args+=(--voucher "${AGENT_VOUCHER}")
fi
runtime_log INFO "Starting the Hashtopolis Python agent."
exec "${args[@]}"
EOF
  sed -i "s|__RUNTIME_ENV_FILE__|${RUNTIME_ENV_FILE}|g" "${CONFIG_DIR}/start-agent.sh"
  chmod 700 "${CONFIG_DIR}/start-agent.sh"
}

write_supervisor_config() {
  local temp="${SUPERVISOR_CONFIG}.tmp.$$"
  cat > "${temp}" <<EOF
[unix_http_server]
file=${SUPERVISOR_SOCKET}
chmod=0700

[supervisord]
logfile=${LOG_DIR}/supervisord.log
logfile_maxbytes=20MB
logfile_backups=3
pidfile=${SUPERVISOR_PID}
childlogdir=${LOG_DIR}
nodaemon=false
minfds=4096
user=root

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://${SUPERVISOR_SOCKET}

[program:mysql]
command=/usr/sbin/mysqld --defaults-file=${MYSQL_CONFIG}
user=mysql
priority=10
autostart=true
autorestart=true
startsecs=5
startretries=20
stopasgroup=true
killasgroup=true
stopsignal=TERM
stopwaitsecs=60
redirect_stderr=true
stdout_logfile=${LOG_DIR}/mysql-supervisor.log
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=3

[program:backend]
command=/bin/bash ${CONFIG_DIR}/start-backend.sh
user=root
priority=20
autostart=false
autorestart=true
startsecs=5
startretries=3
stopasgroup=true
killasgroup=true
stopsignal=TERM
stopwaitsecs=30
redirect_stderr=true
stdout_logfile=${LOG_DIR}/backend.log
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=3

[program:nginx]
command=/usr/sbin/nginx -c ${NGINX_CONFIG} -g "daemon off;"
user=root
priority=30
autostart=false
autorestart=true
startsecs=5
startretries=20
stopasgroup=true
killasgroup=true
stopsignal=QUIT
stopwaitsecs=20
redirect_stderr=true
stdout_logfile=${LOG_DIR}/nginx-supervisor.log
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=3

[program:agent]
command=/bin/bash ${CONFIG_DIR}/start-agent.sh
directory=${AGENT_DIR}
user=root
priority=40
autostart=false
autorestart=unexpected
startsecs=10
startretries=3
stopasgroup=true
killasgroup=true
stopsignal=TERM
stopwaitsecs=30
redirect_stderr=true
stdout_logfile=${LOG_DIR}/agent.log
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=3
EOF
  chmod 600 "${temp}"
  mv -f "${temp}" "${SUPERVISOR_CONFIG}"
}

write_runtime_configs() {
  write_mysql_config
  write_apache_config
  write_frontend_config
  write_nginx_config
  write_runtime_environment
  write_backend_launcher
  write_agent_launcher
  write_supervisor_config
}
