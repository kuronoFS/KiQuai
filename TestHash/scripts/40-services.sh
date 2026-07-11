#!/usr/bin/env bash
# shellcheck shell=bash
# KiQuai module: services
# kiquai-module-api: 1
# kiquai-release: 3.2.0

if [[ "${KIQUAI_MODULE_CONTEXT:-0}" != "1" ]]; then
  printf 'This file is a KiQuai module; run ../run.sh instead.\n' >&2
  return 64 2>/dev/null || exit 64
fi

HEALTH_FRONTEND_CODE=000
HEALTH_API_CODE=000
HEALTH_API_BODY=""

initialize_mysql_data() {
  local marker="${MYSQL_DATA_DIR}/.kiquai-initialized"
  local existing_entry=""
  if [[ -d "${MYSQL_DATA_DIR}/mysql" ]]; then
    if [[ ! -f "${marker}" ]]; then
      [[ -f "${MYSQL_DATA_DIR}/auto.cnf" && -f "${MYSQL_DATA_DIR}/mysql.ibd" ]] \
        || die "MySQL data directory looks partially initialized (required auto.cnf/mysql.ibd metadata is missing). Restore a backup or use WIPE_DATA=1 only if the data is disposable."
      touch "${marker}"
      chown mysql:mysql "${marker}"
      chmod 600 "${marker}"
      warn "Adopted a pre-3.2.0 MySQL data directory after structural validation."
    fi
    info "Reusing the existing MySQL data directory."
    return 0
  fi
  existing_entry="$(find "${MYSQL_DATA_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" \
    || die "Unable to inspect MYSQL_DATA_DIR before initialization."
  [[ -z "${existing_entry}" ]] \
    || die "MYSQL_DATA_DIR is not empty but is not an initialized MySQL data directory."
  chown -R mysql:mysql "${MYSQL_DATA_DIR}" "${MYSQL_RUN_DIR}"
  /usr/sbin/mysqld --defaults-file="${MYSQL_CONFIG}" --initialize-insecure --user=mysql
  [[ -d "${MYSQL_DATA_DIR}/mysql" && -f "${MYSQL_DATA_DIR}/auto.cnf" && -f "${MYSQL_DATA_DIR}/mysql.ibd" ]] \
    || die "MySQL initialization returned without producing a complete base layout."
  touch "${marker}"
  chown mysql:mysql "${marker}"
  chmod 600 "${marker}"
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
}

mysql_root_exec() {
  if [[ "${MYSQL_ROOT_AUTH_MODE:-}" == "password" ]]; then
    MYSQL_PWD="${MYSQL_ROOT_PASS}" mysql --protocol=socket \
      --socket="${MYSQL_RUN_DIR}/mysqld.sock" -uroot
  else
    mysql --protocol=socket --socket="${MYSQL_RUN_DIR}/mysqld.sock" -uroot
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

mysql_app_exec() {
  MYSQL_PWD="${MYSQL_PASSWORD}" mysql --protocol=tcp \
    -h 127.0.0.1 -P "${DB_PORT}" -u "${MYSQL_USER}" \
    -D "${MYSQL_DATABASE}" "$@"
}

failed_migration_rows() {
  local table_exists=""
  if ! table_exists="$(mysql_app_exec -Nse \
      "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '_sqlx_migrations';")"; then
    return 1
  fi
  [[ "${table_exists}" == "1" ]] || return 0
  mysql_app_exec -Nse \
    "SELECT CONCAT(version, CHAR(9), description, CHAR(9), installed_on) FROM _sqlx_migrations WHERE success = 0 ORDER BY version;" \
    || return 1
}

assert_no_failed_migrations() {
  local failed=""
  failed="$(failed_migration_rows)" \
    || die "Unable to inspect SQLx migration state before changing the database."
  [[ -z "${failed}" ]] && return 0

  printf '\nFailed SQLx migrations (version, description, installed_on):\n%s\n\n' "${failed}" >&2
  die "Database contains a partially applied SQLx migration. Automatic row deletion or schema mutation is disabled because MySQL DDL may already be committed. Back up the database and inspect/repair it, or run WIPE_DATA=1 only when every existing Hashtopolis datum is disposable."
}

run_backend_setup() {
  local setup_script="${SERVER_CURRENT}/src/inc/startup/setup.php"
  local setup_rc=0
  local formatter_rc=0
  local tee_rc=0
  local -a pipeline_status=()
  local marker_temp="${BACKEND_READY_FILE}.tmp.$$"
  local ready_value=""

  [[ -f "${setup_script}" ]] || die "Hashtopolis setup script is missing: ${setup_script}."
  sqlx_version_matches /usr/bin/sqlx \
    || die "Migration requires /usr/bin/sqlx to be sqlx-cli ${SQLX_CLI_VERSION}."
  [[ -r "${RUNTIME_ENV_FILE}" ]] || die "Runtime environment is missing: ${RUNTIME_ENV_FILE}."
  export KIQUAI_RUNTIME_CONFIG_LOADED=1
  # shellcheck disable=SC1090
  source "${RUNTIME_ENV_FILE}"
  export KIQUAI_COMPONENT="migration"
  runuser -u www-data -- test -w "${SERVER_CURRENT}/src/inc/utils/locks" \
    || die "Hashtopolis lock directory is not writable by www-data."

  rm -f "${BACKEND_READY_FILE}" "${marker_temp}"
  assert_no_failed_migrations
  touch "${MIGRATION_LOG}"
  chmod 600 "${MIGRATION_LOG}"
  printf '\n[%s] ===== migration start: run=%s release=%s =====\n' \
    "$(timestamp)" "${RUN_ID}" "${HASHTOPOLIS_VERSION}" | tee -a "${MIGRATION_LOG}"

  set +e
  runuser -u www-data --preserve-environment -- \
    php -f "${setup_script}" 2>&1 \
    | while IFS= read -r line || [[ -n "${line}" ]]; do
        printf '[%s] %-5s [run=%s] [component=migration] %s\n' \
          "$(date '+%Y-%m-%d %H:%M:%S%z')" INFO "${RUN_ID}" "${line}"
      done \
    | tee -a "${MIGRATION_LOG}"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  setup_rc=${pipeline_status[0]:-1}
  formatter_rc=${pipeline_status[1]:-1}
  tee_rc=${pipeline_status[2]:-1}

  if (( setup_rc != 0 )); then
    error "Hashtopolis setup.php failed (exit=${setup_rc})."
    assert_no_failed_migrations
    die "Hashtopolis setup.php failed with exit ${setup_rc}; backend and Nginx remain stopped. See ${MIGRATION_LOG}."
  fi
  if (( formatter_rc != 0 || tee_rc != 0 )); then
    die "Migration completed but its logging pipeline failed (formatter=${formatter_rc}, tee=${tee_rc}); the backend gate remains closed to preserve an auditable startup."
  fi
  assert_no_failed_migrations

  ready_value="${HASHTOPOLIS_VERSION}|$(readlink -f "${SERVER_CURRENT}")"
  printf '%s\n' "${ready_value}" > "${marker_temp}"
  chmod 600 "${marker_temp}"
  mv -f "${marker_temp}" "${BACKEND_READY_FILE}"
  success "Hashtopolis migration/setup completed synchronously; backend start gate opened."
}

supervisor_program_state() {
  local program="$1"
  local output=""
  output="$(supervisor_ctl status "${program}" 2>/dev/null || true)"
  awk 'NR == 1 { print $2 }' <<< "${output}"
}

backend_migration_is_active() {
  local process_line=""
  local process_output=""
  local pgrep_rc=0
  have_cmd pgrep \
    || die "Cannot safely inspect a legacy backend migration because required command 'pgrep' is missing."
  set +e
  process_output="$(pgrep -af 'setup[.]php|sqlx migrate run' 2>/dev/null)"
  pgrep_rc=$?
  set -e
  if (( pgrep_rc > 1 )); then
    die "pgrep failed with exit ${pgrep_rc}; refusing to stop a backend whose migration state cannot be inspected."
  fi
  while IFS= read -r process_line; do
    [[ "${process_line}" == *"${APP_DIR}"* ]] && return 0
  done <<< "${process_output}"
  return 1
}

wait_for_legacy_backend_migration() {
  local deadline=$((SECONDS + 900))
  local next_notice=$SECONDS
  backend_migration_is_active || return 0
  warn "A legacy backend migration is active; waiting instead of sending SIGTERM."
  while backend_migration_is_active && (( SECONDS < deadline )); do
    if (( SECONDS >= next_notice )); then
      info "Legacy setup.php/sqlx is still active; cutover remains paused."
      next_notice=$((SECONDS + 30))
    fi
    sleep 3
  done
  backend_migration_is_active \
    && die "A legacy backend migration remained active for 900 seconds. It was not interrupted; inspect the process and migration log before retrying."
  success "Legacy migration process finished; application cutover can proceed safely."
}

stop_supervisor_program_if_active() {
  local program="$1"
  local state=""
  local deadline
  local safe_deadline
  supervisor_is_running || return 0
  state="$(supervisor_program_state "${program}")"
  case "${state}" in
    STOPPED|EXITED|FATAL|"")
      return 0
      ;;
  esac

  if [[ "${program}" == "backend" ]]; then
    safe_deadline=$((SECONDS + 900))
    while :; do
      wait_for_legacy_backend_migration
      state="$(supervisor_program_state "${program}")"
      [[ "${state}" != "STARTING" ]] && break
      (( SECONDS < safe_deadline )) \
        || die "Legacy backend remained STARTING for 900 seconds; it was not interrupted."
      sleep 2
    done
    case "${state}" in
      STOPPED|EXITED|FATAL|"")
        return 0
        ;;
    esac
  fi

  info "Stopping Supervisor program '${program}' before the deployment cutover (state=${state})."
  supervisor_ctl stop "${program}" >/dev/null 2>&1 || true
  deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    state="$(supervisor_program_state "${program}")"
    case "${state}" in
      STOPPED|EXITED|FATAL|"")
        return 0
        ;;
    esac
    sleep 1
  done
  print_supervisor_program_diagnostics "${program}"
  die "Supervisor program '${program}' did not stop; release and database state were left untouched."
}

quiesce_application_services() {
  supervisor_is_running || return 0
  stop_supervisor_program_if_active agent
  stop_supervisor_program_if_active nginx
  stop_supervisor_program_if_active backend
  rm -f "${BACKEND_READY_FILE}"
  success "Application processes are stopped; MySQL remains isolated for the migration cutover."
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

print_supervisor_program_diagnostics() {
  local program="$1"
  supervisor_ctl status "${program}" || true
  tail -n 120 "${LOG_DIR}/supervisord.log" 2>/dev/null || true
  case "${program}" in
    backend)
      printf '\n===== migration.log =====\n' >&2
      tail -n 180 "${MIGRATION_LOG}" 2>/dev/null || true
      printf '\n===== backend.log =====\n' >&2
      tail -n 120 "${LOG_DIR}/backend.log" 2>/dev/null || true
      printf '\n===== apache-error.log =====\n' >&2
      tail -n 160 "${LOG_DIR}/apache-error.log" 2>/dev/null || true
      ;;
    nginx)
      printf '\n===== nginx-error.log =====\n' >&2
      tail -n 160 "${LOG_DIR}/nginx-error.log" 2>/dev/null || true
      ;;
  esac
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
      deadline=$((SECONDS + 75))
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
    STOPPED|EXITED|FATAL|"")
      ;;
    *)
      print_supervisor_program_diagnostics "${program}"
      die "Supervisor program '${program}' did not stop cleanly; refusing to report a successful restart."
      ;;
  esac

  if ! output="$(supervisor_ctl start "${program}" 2>&1)"; then
    state="$(supervisor_program_state "${program}")"
    if [[ "${state}" != "RUNNING" && "${state}" != "STARTING" ]]; then
      [[ -n "${output}" ]] && printf '%s\n' "${output}" >&2
      print_supervisor_program_diagnostics "${program}"
      die "Supervisor could not start '${program}'."
    fi
  fi

  if ! wait_for_supervisor_running "${program}" "${timeout}"; then
    print_supervisor_program_diagnostics "${program}"
    die "Supervisor program '${program}' did not reach RUNNING within ${timeout} seconds."
  fi
  success "Supervisor program '${program}' is running."
}

start_web_services_after_migration() {
  [[ -s "${BACKEND_READY_FILE}" ]] \
    || die "Refusing to start web services before the migration gate is complete."
  restart_or_start_supervisor_program backend 180
  restart_or_start_supervisor_program nginx 90
}

check_http_contract() {
  local api_response=""
  HEALTH_FRONTEND_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 \
      "http://127.0.0.1:${INTERNAL_PORT}/" 2>/dev/null || true)"
  [[ "${HEALTH_FRONTEND_CODE}" =~ ^[0-9]{3}$ ]] || HEALTH_FRONTEND_CODE=000

  api_response="$(curl -sS --max-time 8 \
    -H 'Content-Type: application/json' \
    --data '{"action":"testConnection"}' \
    -w $'\n%{http_code}' \
    "http://127.0.0.1:${INTERNAL_PORT}/api/server.php" 2>/dev/null || true)"
  HEALTH_API_CODE="${api_response##*$'\n'}"
  HEALTH_API_BODY="${api_response%$'\n'*}"
  [[ "${HEALTH_API_CODE}" =~ ^[0-9]{3}$ ]] || HEALTH_API_CODE=000

  [[ "${HEALTH_FRONTEND_CODE}" =~ ^[23][0-9][0-9]$ && "${HEALTH_API_CODE}" == "200" ]] \
    && jq -e '.action == "testConnection" and .response == "SUCCESS"' \
      <<< "${HEALTH_API_BODY}" >/dev/null 2>&1
}

wait_for_http() {
  local deadline=$((SECONDS + 420))
  while (( SECONDS < deadline )); do
    if check_http_contract; then
      success "Frontend and legacy agent API contract health checks passed."
      return 0
    fi
    sleep 3
  done
  supervisor_ctl status || true
  tail -n 120 "${LOG_DIR}/backend.log" 2>/dev/null || true
  tail -n 80 "${LOG_DIR}/apache-error.log" 2>/dev/null || true
  die "Hashtopolis did not become healthy within 420 seconds (frontend_http=${HEALTH_FRONTEND_CODE}, agent_api_http=${HEALTH_API_CODE})."
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
      supervisor_ctl restart agent >/dev/null \
        || die "Supervisor could not restart the local GPU agent."
    else
      supervisor_ctl start agent >/dev/null \
        || die "Supervisor could not start the local GPU agent."
    fi
    if ! wait_for_supervisor_running agent 90; then
      print_supervisor_program_diagnostics agent
      tail -n 160 "${LOG_DIR}/agent.log" 2>/dev/null || true
      die "The local GPU agent did not reach RUNNING within 90 seconds."
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
        tail -n 160 "${LOG_DIR}/agent.log" 2>/dev/null || true
        die "The agent stayed running but did not produce config.json within 90 seconds; the voucher remains saved for a deliberate retry."
      fi
    fi
    success "The local GPU agent is enabled."
  else
    supervisor_ctl stop agent >/dev/null 2>&1 || true
    info "Agent is installed but not registered. Use './run.sh agent-start VOUCHER'."
  fi
}
