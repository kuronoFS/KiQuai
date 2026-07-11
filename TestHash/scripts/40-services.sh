#!/usr/bin/env bash
# shellcheck shell=bash
# KiQuai module: services
# kiquai-module-api: 1
# kiquai-release: 3.1.1

if [[ "${KIQUAI_MODULE_CONTEXT:-0}" != "1" ]]; then
  printf 'This file is a KiQuai module; run ../run.sh instead.\n' >&2
  return 64 2>/dev/null || exit 64
fi

initialize_mysql_data() {
  if [[ -d "${MYSQL_DATA_DIR}/mysql" ]]; then
    info "Reusing the existing MySQL data directory."
    return 0
  fi
  [[ -z "$(find "${MYSQL_DATA_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || die "MYSQL_DATA_DIR is not empty but is not an initialized MySQL data directory."
  chown -R mysql:mysql "${MYSQL_DATA_DIR}" "${MYSQL_RUN_DIR}"
  /usr/sbin/mysqld --defaults-file="${MYSQL_CONFIG}" --initialize-insecure --user=mysql
  success "Initialized a new local MySQL data directory."
}

start_or_reload_supervisor() {
  if supervisor_is_running; then
    supervisor_ctl reread
    supervisor_ctl update
  else
    rm -f "${SUPERVISOR_SOCKET}" "${SUPERVISOR_PID}"
    supervisord -c "${SUPERVISOR_CONFIG}"
    local deadline=$((SECONDS + 30))
    while [[ ! -S "${SUPERVISOR_SOCKET}" ]] && (( SECONDS < deadline )); do
      sleep 1
    done
    [[ -S "${SUPERVISOR_SOCKET}" ]] || die "The isolated supervisord socket did not become ready."
  fi

  local program
  for program in mysql backend nginx; do
    if ! supervisor_ctl status "${program}" 2>/dev/null | grep -q ' RUNNING '; then
      supervisor_ctl start "${program}" >/dev/null || true
    fi
  done
}

mysql_root_exec() {
  if [[ "${MYSQL_ROOT_AUTH_MODE:-}" == "password" ]]; then
    MYSQL_PWD="${MYSQL_ROOT_PASS}" mysql --protocol=socket \
      --socket="${MYSQL_RUN_DIR}/mysqld.sock" -uroot "$@"
  else
    mysql --protocol=socket --socket="${MYSQL_RUN_DIR}/mysqld.sock" -uroot "$@"
  fi
}

wait_for_mysql() {
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if MYSQL_PWD="${MYSQL_ROOT_PASS}" mysql --protocol=socket \
        --socket="${MYSQL_RUN_DIR}/mysqld.sock" -uroot -Nse 'SELECT 1' >/dev/null 2>&1; then
      MYSQL_ROOT_AUTH_MODE="password"
      return 0
    fi
    if mysql --protocol=socket --socket="${MYSQL_RUN_DIR}/mysqld.sock" \
        -uroot -Nse 'SELECT 1' >/dev/null 2>&1; then
      MYSQL_ROOT_AUTH_MODE="empty"
      return 0
    fi
    sleep 2
  done
  supervisor_ctl status || true
  tail -n 100 "${LOG_DIR}/mysql.log" 2>/dev/null || true
  die "MySQL did not become ready within 180 seconds."
}

provision_database() {
  mysql_root_exec <<SQL
CREATE DATABASE IF NOT EXISTS ${MYSQL_DATABASE} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASSWORD}';
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON ${MYSQL_DATABASE}.* TO '${MYSQL_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON ${MYSQL_DATABASE}.* TO '${MYSQL_USER}'@'localhost';
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL
  MYSQL_ROOT_AUTH_MODE="password"
  MYSQL_PWD="${MYSQL_PASSWORD}" mysql --protocol=tcp -h 127.0.0.1 \
    -P "${DB_PORT}" -u "${MYSQL_USER}" -D "${MYSQL_DATABASE}" \
    -Nse 'SELECT 1' >/dev/null
  success "Local MySQL database and application account are ready."
}

supervisor_program_state() {
  local program="$1"
  local output=""
  output="$(supervisor_ctl status "${program}" 2>/dev/null || true)"
  awk 'NR == 1 { print $2 }' <<< "${output}"
}

wait_for_supervisor_running() {
  local program="$1"
  local timeout="$2"
  local deadline=$((SECONDS + timeout))
  local state=""

  while (( SECONDS < deadline )); do
    state="$(supervisor_program_state "${program}")"
    case "${state}" in
      RUNNING)
        return 0
        ;;
      FATAL)
        return 1
        ;;
    esac
    sleep 1
  done
  return 1
}

restart_or_start_supervisor_program() {
  local program="$1"
  local timeout="$2"
  local state=""
  local output=""
  local deadline

  state="$(supervisor_program_state "${program}")"
  info "Reconciling Supervisor program '${program}' (state=${state:-unknown})."

  case "${state}" in
    RUNNING|STARTING|BACKOFF|STOPPING)
      supervisor_ctl stop "${program}" >/dev/null 2>&1 || true
      deadline=$((SECONDS + 45))
      while (( SECONDS < deadline )); do
        state="$(supervisor_program_state "${program}")"
        case "${state}" in
          STOPPED|EXITED|FATAL|"")
            break
            ;;
        esac
        sleep 1
      done
      ;;
  esac

  state="$(supervisor_program_state "${program}")"
  case "${state}" in
    RUNNING)
      success "Supervisor program '${program}' is running."
      return 0
      ;;
    STARTING|BACKOFF|STOPPING)
      supervisor_ctl status "${program}" || true
      die "Supervisor program '${program}' did not reach a restartable stopped state."
      ;;
  esac

  if ! output="$(supervisor_ctl start "${program}" 2>&1)"; then
    state="$(supervisor_program_state "${program}")"
    if [[ "${state}" != "RUNNING" && "${state}" != "STARTING" ]]; then
      [[ -n "${output}" ]] && printf '%s\n' "${output}" >&2
      supervisor_ctl status "${program}" || true
      die "Supervisor could not start '${program}'."
    fi
  fi

  if ! wait_for_supervisor_running "${program}" "${timeout}"; then
    supervisor_ctl status "${program}" || true
    case "${program}" in
      backend)
        tail -n 160 "${LOG_DIR}/backend.log" 2>/dev/null || true
        tail -n 120 "${LOG_DIR}/apache-error.log" 2>/dev/null || true
        ;;
      nginx)
        tail -n 120 "${LOG_DIR}/nginx-error.log" 2>/dev/null || true
        ;;
    esac
    die "Supervisor program '${program}' did not reach RUNNING within ${timeout} seconds."
  fi
  success "Supervisor program '${program}' is running."
}

restart_web_services() {
  restart_or_start_supervisor_program backend 180
  restart_or_start_supervisor_program nginx 90
}

wait_for_http() {
  local deadline=$((SECONDS + 420))
  local code
  while (( SECONDS < deadline )); do
    if curl -fsS --max-time 8 "http://127.0.0.1:${INTERNAL_PORT}/" >/dev/null 2>&1; then
      code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 \
        "http://127.0.0.1:${INTERNAL_PORT}/api/server.php" 2>/dev/null || true)"
      [[ "${code}" =~ ^[0-9]{3}$ ]] || code=000
      if [[ "${code}" =~ ^[1-4][0-9][0-9]$ ]]; then
        success "Frontend and legacy agent API health checks passed."
        return 0
      fi
    fi
    sleep 3
  done
  supervisor_ctl status || true
  tail -n 120 "${LOG_DIR}/backend.log" 2>/dev/null || true
  tail -n 80 "${LOG_DIR}/apache-error.log" 2>/dev/null || true
  die "Hashtopolis did not become healthy within 420 seconds."
}

download_agent() {
  local target="${AGENT_DIR}/hashtopolis.zip"
  if [[ -s "${target}" ]] && python3 -m zipfile -t "${target}" >/dev/null 2>&1; then
    info "Reusing the installed Hashtopolis Python agent package."
    return 0
  fi

  local url="${AGENT_DOWNLOAD_URL}"
  [[ -n "${url}" ]] || url="http://127.0.0.1:${INTERNAL_PORT}/agents.php?download=1"
  local temp="${target}.tmp.$$"
  retry 4 5 curl -fsSL "${url}" -o "${temp}"
  python3 -m zipfile -t "${temp}" >/dev/null \
    || die "The downloaded Hashtopolis agent is not a valid ZIP application."
  mv -f "${temp}" "${target}"
  chmod 600 "${target}"
  mkdir -p \
    "${AGENT_DIR}/files" "${AGENT_DIR}/crackers" "${AGENT_DIR}/hashlists" \
    "${AGENT_DIR}/preprocessors" "${AGENT_DIR}/zaps"
  success "Installed the Hashtopolis Python agent package."
}

reconcile_agent_process() {
  write_agent_launcher
  write_supervisor_config
  supervisor_ctl reread
  supervisor_ctl update
  if [[ "${AGENT_ENABLED}" == "1" ]]; then
    if supervisor_ctl status agent 2>/dev/null | grep -q ' RUNNING '; then
      supervisor_ctl restart agent >/dev/null
    else
      supervisor_ctl start agent >/dev/null
    fi
    if [[ -n "${AGENT_VOUCHER}" ]]; then
      local deadline=$((SECONDS + 90))
      while [[ ! -s "${AGENT_DIR}/config.json" ]] && (( SECONDS < deadline )); do
        sleep 2
      done
      if [[ -s "${AGENT_DIR}/config.json" ]]; then
        AGENT_VOUCHER=""
        write_dotenv
        success "Agent registration completed; the one-time voucher was removed from saved configuration."
      else
        warn "The agent has not produced config.json yet. Check './run.sh logs'; the voucher remains saved for retry."
      fi
    fi
    success "The local GPU agent is enabled."
  else
    supervisor_ctl stop agent >/dev/null 2>&1 || true
    info "Agent is installed but not registered. Use './run.sh agent-start VOUCHER'."
  fi
}
