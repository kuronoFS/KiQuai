#!/usr/bin/env bash
# shellcheck shell=bash
# KiQuai module: services
# kiquai-module-api: 1
# kiquai-release: 3.2.4

if [[ "${KIQUAI_MODULE_CONTEXT:-0}" != "1" ]]; then
  printf 'This file is a KiQuai module; run ../run.sh instead.\n' >&2
  return 64 2>/dev/null || exit 64
fi

HEALTH_FRONTEND_CODE=000
HEALTH_API_CODE=000
HEALTH_API_BODY=""

# These globals are populated by agent_registration_query() and
# agent_server_metadata_query().  Keeping the result separate from stdout lets
# callers inspect registration state without ever printing the agent token.
AGENT_REGISTRATION_STATE="unchecked"
AGENT_ID=""
AGENT_NAME=""
AGENT_ACTIVE=""
AGENT_TRUSTED=""
AGENT_CPU_ONLY=""
AGENT_LAST_ACT=""
AGENT_LAST_TIME=""
AGENT_ASSIGNMENT_ID=""
AGENT_ASSIGNMENT_COUNT=""
AGENT_TASK_ID=""
AGENT_TIMEOUT=""
AGENT_LAST_ERROR_ID=""
AGENT_LAST_ERROR_TIME=""
AGENT_LAST_ERROR_TASK_ID=""
AGENT_LAST_ERROR_CHUNK_ID=""
AGENT_LAST_ERROR_MESSAGE=""
AGENT_IDENTITY_RESET_PREPARED=0

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

configure_task_dispatch_policy() {
  local row_count=""
  local current_value=""

  row_count="$(mysql_app_exec -Nse \
    "SELECT COUNT(*) FROM \`Config\` WHERE \`item\` = 'priority0Start';")" \
    || die "Unable to inspect the Hashtopolis priority-0 task assignment policy."
  [[ "${row_count}" == "1" ]] \
    || die "Expected exactly one Hashtopolis Config row for priority0Start, found ${row_count:-none}."
  current_value="$(mysql_app_exec -Nse \
    "SELECT \`value\` FROM \`Config\` WHERE \`item\` = 'priority0Start' LIMIT 1;")" \
    || die "Unable to read the Hashtopolis priority-0 task assignment policy."

  if [[ "${current_value}" != "${HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO}" ]]; then
    mysql_app_exec -e \
      "UPDATE \`Config\` SET \`value\` = '${HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO}' WHERE \`item\` = 'priority0Start';" \
      >/dev/null \
      || die "Unable to update the Hashtopolis priority-0 task assignment policy."
  fi
  current_value="$(mysql_app_exec -Nse \
    "SELECT \`value\` FROM \`Config\` WHERE \`item\` = 'priority0Start' LIMIT 1;")" \
    || die "Unable to verify the Hashtopolis priority-0 task assignment policy."
  [[ "${current_value}" == "${HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO}" ]] \
    || die "Hashtopolis priority-0 task assignment policy verification failed."

  if [[ "${current_value}" == "1" ]]; then
    success "Automatic assignment is enabled for the WebUI's default priority-0 tasks."
  else
    warn "Automatic assignment of priority-0 tasks is disabled by configuration."
  fi
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

managed_agent_cracker_groups() {
  local own_pgid=""
  local proc_dir=""
  local process_cwd=""
  local process_arg=""
  local process_pgid=""
  local has_hashcat=0
  declare -A seen_groups=()

  own_pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]')"
  for proc_dir in /proc/[0-9]*; do
    [[ -d "${proc_dir}" ]] || continue
    process_cwd="$(readlink -f "${proc_dir}/cwd" 2>/dev/null || true)"
    case "${process_cwd}" in
      "${AGENT_DIR}/crackers"|"${AGENT_DIR}/crackers/"*) ;;
      *) continue ;;
    esac
    [[ -r "${proc_dir}/cmdline" ]] || continue
    has_hashcat=0
    while IFS= read -r -d '' process_arg; do
      [[ "${process_arg}" == *hashcat* ]] && has_hashcat=1
    done < "${proc_dir}/cmdline"
    [[ "${has_hashcat}" == "1" ]] || continue
    process_pgid="$(ps -o pgid= -p "${proc_dir##*/}" 2>/dev/null | tr -d '[:space:]')"
    [[ "${process_pgid}" =~ ^[1-9][0-9]*$ && "${process_pgid}" != "${own_pgid}" ]] \
      || continue
    if [[ -z "${seen_groups[${process_pgid}]:-}" ]]; then
      seen_groups["${process_pgid}"]=1
      printf '%s\n' "${process_pgid}"
    fi
  done
}

cleanup_managed_agent_cracker_processes() {
  local deadline=0
  local process_pgid=""
  local -a groups=()

  mapfile -t groups < <(managed_agent_cracker_groups)
  (( ${#groups[@]} > 0 )) || return 0
  warn "Found ${#groups[@]} detached Hashcat process group(s) after stopping the agent; requesting TERM."
  for process_pgid in "${groups[@]}"; do
    kill -TERM -- "-${process_pgid}" 2>/dev/null || true
  done
  deadline=$((SECONDS + 15))
  while (( SECONDS < deadline )); do
    mapfile -t groups < <(managed_agent_cracker_groups)
    (( ${#groups[@]} == 0 )) && {
      success "Detached managed Hashcat processes stopped cleanly."
      return 0
    }
    sleep 1
  done
  mapfile -t groups < <(managed_agent_cracker_groups)
  for process_pgid in "${groups[@]}"; do
    warn "Hashcat process group ${process_pgid} ignored TERM; sending KILL."
    kill -KILL -- "-${process_pgid}" 2>/dev/null || true
  done
  sleep 1
  mapfile -t groups < <(managed_agent_cracker_groups)
  (( ${#groups[@]} == 0 ))
}

stop_supervisor_program_if_active() {
  local program="$1"
  local state=""
  local deadline
  local safe_deadline
  if ! supervisor_is_running; then
    if [[ "${program}" == "agent" ]]; then
      cleanup_managed_agent_cracker_processes \
        || die "Detached managed Hashcat processes remained while Supervisor was offline."
    fi
    return 0
  fi
  state="$(supervisor_program_state "${program}")"
  case "${state}" in
    STOPPED|EXITED|FATAL|"")
      if [[ "${program}" == "agent" ]]; then
        cleanup_managed_agent_cracker_processes \
          || die "Detached managed Hashcat processes remained after the agent stopped."
      fi
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
        if [[ "${program}" == "agent" ]]; then
          cleanup_managed_agent_cracker_processes \
            || die "Detached managed Hashcat processes remained after the agent stopped."
        fi
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
        if [[ "${program}" == "agent" ]]; then
          cleanup_managed_agent_cracker_processes \
            || die "Detached managed Hashcat processes remained after the agent stopped."
        fi
        return 0
        ;;
    esac
    sleep 1
  done
  print_supervisor_program_diagnostics "${program}"
  die "Supervisor program '${program}' did not stop; release and database state were left untouched."
}

quiesce_application_services() {
  stop_supervisor_program_if_active agent
  supervisor_is_running || return 0
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

redact_agent_log_stream() {
  local agent_token=""
  local agent_voucher="${AGENT_VOUCHER:-}"
  local line=""

  if [[ -r "${AGENT_DIR}/config.json" ]]; then
    agent_token="$(jq -r '.token // empty | strings' \
      "${AGENT_DIR}/config.json" 2>/dev/null || true)"
    if [[ -z "${agent_voucher}" ]]; then
      agent_voucher="$(jq -r '.voucher // empty | strings' \
        "${AGENT_DIR}/config.json" 2>/dev/null || true)"
    fi
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${agent_token}" ]] || line="${line//"${agent_token}"/<redacted-token>}"
    [[ -z "${agent_voucher}" ]] || line="${line//"${agent_voucher}"/<redacted-voucher>}"
    printf '%s\n' "${line}"
  done
}

tail_agent_file() {
  local label="$1"
  local path="$2"
  local lines="${3:-160}"
  printf '\n===== %s =====\n' "${label}" >&2
  if [[ ! -r "${path}" ]]; then
    printf 'Log is not readable or does not exist: %s\n' "${path}" >&2
    return 0
  fi
  tail -n "${lines}" "${path}" 2>&1 | redact_agent_log_stream
}

print_agent_lock_diagnostics() {
  local lock_file="${AGENT_DIR}/lock.pid"
  local lock_pid=""
  local process_cwd=""
  local process_arg=""
  local has_agent_archive=0
  local cracker_group=""
  local cracker_group_count=0

  printf '\n===== agent lock state =====\n' >&2
  printf 'runtime_lock=%s\n' "${RUN_DIR}/agent-runtime.lock" >&2
  while IFS= read -r cracker_group; do
    [[ -n "${cracker_group}" ]] || continue
    printf 'managed_hashcat_group=%s\n' "${cracker_group}" >&2
    cracker_group_count=$((cracker_group_count + 1))
  done < <(managed_agent_cracker_groups)
  printf 'managed_hashcat_group_count=%s\n' "${cracker_group_count}" >&2
  if [[ ! -e "${lock_file}" ]]; then
    printf 'upstream_lock=absent\n' >&2
    return 0
  fi
  if [[ ! -f "${lock_file}" || ! -r "${lock_file}" ]]; then
    printf 'upstream_lock=unreadable-or-not-regular\n' >&2
    return 0
  fi
  lock_pid="$(tr -d '\r\n' < "${lock_file}")"
  printf 'upstream_lock_pid=%s\n' "${lock_pid:-empty}" >&2
  if [[ ! "${lock_pid}" =~ ^[1-9][0-9]*$ ]] \
      || [[ ! -d "/proc/${lock_pid}" ]] \
      || ! kill -0 "${lock_pid}" 2>/dev/null; then
    printf 'upstream_lock_pid_live=no\n' >&2
    return 0
  fi
  printf 'upstream_lock_pid_live=yes\n' >&2
  printf 'upstream_lock_pid_comm=' >&2
  tr -d '\r\n' < "/proc/${lock_pid}/comm" 2>/dev/null >&2 || printf 'unavailable' >&2
  printf '\n' >&2
  process_cwd="$(readlink -f "/proc/${lock_pid}/cwd" 2>/dev/null || true)"
  printf 'upstream_lock_pid_cwd=%s\n' "${process_cwd:-unavailable}" >&2
  if [[ -r "/proc/${lock_pid}/cmdline" ]]; then
    while IFS= read -r -d '' process_arg; do
      case "${process_arg}" in
        hashtopolis.zip|"${AGENT_DIR}/hashtopolis.zip")
          has_agent_archive=1
          ;;
      esac
    done < "/proc/${lock_pid}/cmdline"
  fi
  printf 'upstream_lock_pid_has_agent_archive=%s\n' "${has_agent_archive}" >&2
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
    agent)
      print_agent_lock_diagnostics
      tail_agent_file agent.log "${LOG_DIR}/agent.log" 180
      tail_agent_file agent/client.log "${AGENT_DIR}/client.log" 220
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
  local expected_hash="7f6f00a9f1983e3d0f2db5f76f3bd8f0ffb20327ed77bb11659bb7740bff4da2"
  local actual_hash=""
  local url=""
  local temp=""

  if [[ -s "${target}" ]]; then
    actual_hash="$(sha256sum "${target}" 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [[ "${actual_hash}" == "${expected_hash}" ]] \
      && /usr/bin/python3 -m zipfile -t "${target}" >/dev/null 2>&1; then
    info "Reusing the installed Hashtopolis Python agent package."
    return 0
  fi
  if [[ -e "${target}" ]]; then
    warn "The installed agent archive is not the pinned RC2 0.7.4 payload; it will be replaced only after a verified download."
  fi

  url="${AGENT_DOWNLOAD_URL}"
  [[ -n "${url}" ]] || url="http://127.0.0.1:${INTERNAL_PORT}/agents.php?download=1"
  temp="${target}.tmp.$$"
  if ! retry 4 5 curl -fsSL "${url}" -o "${temp}"; then
    rm -f -- "${temp}"
    die "The pinned Hashtopolis agent archive could not be downloaded."
  fi
  if ! /usr/bin/python3 -m zipfile -t "${temp}" >/dev/null 2>&1; then
    rm -f -- "${temp}"
    die "The downloaded Hashtopolis agent is not a valid ZIP application."
  fi
  actual_hash="$(sha256sum "${temp}" | awk '{print $1}')"
  if [[ "${actual_hash}" != "${expected_hash}" ]]; then
    rm -f -- "${temp}"
    die "Unsupported Hashtopolis agent archive (expected pinned RC2 0.7.4 sha256=${expected_hash}, got sha256=${actual_hash:-unavailable})."
  fi
  mv -f "${temp}" "${target}"
  chmod 600 "${target}"
  mkdir -p \
    "${AGENT_DIR}/files" "${AGENT_DIR}/crackers" "${AGENT_DIR}/hashlists" \
    "${AGENT_DIR}/preprocessors" "${AGENT_DIR}/zaps"
  success "Installed the Hashtopolis Python agent package."
}

_clear_agent_metadata() {
  AGENT_ID=""
  AGENT_NAME=""
  AGENT_ACTIVE=""
  AGENT_TRUSTED=""
  AGENT_CPU_ONLY=""
  AGENT_LAST_ACT=""
  AGENT_LAST_TIME=""
  AGENT_ASSIGNMENT_ID=""
  AGENT_ASSIGNMENT_COUNT=""
  AGENT_TASK_ID=""
  AGENT_TIMEOUT=""
  AGENT_LAST_ERROR_ID=""
  AGENT_LAST_ERROR_TIME=""
  AGENT_LAST_ERROR_TASK_ID=""
  AGENT_LAST_ERROR_CHUNK_ID=""
  AGENT_LAST_ERROR_MESSAGE=""
}

agent_config_has_registration_token() {
  local config="${1:-${AGENT_DIR}/config.json}"
  [[ -f "${config}" && ! -L "${config}" && -s "${config}" ]] \
    && jq -e \
      'type == "object" and (.token? | type == "string" and length > 0)' \
      "${config}" >/dev/null 2>&1
}

agent_database_is_ready() {
  local result=""
  result="$(printf 'SELECT 1;\n' \
    | mysql_app_exec --batch --skip-column-names 2>/dev/null)" \
    || return 1
  [[ "${result}" == "1" ]]
}

_agent_config_token_hex() {
  local config="${AGENT_DIR}/config.json"
  agent_config_has_registration_token "${config}" || return 1
  jq -j '.token' "${config}" 2>/dev/null \
    | od -An -v -tx1 \
    | tr -d '[:space:]'
}

# Run SQL after defining @kiquai_agent_token from the config token.  The token
# (and its hexadecimal transport representation) are written only to mysql's
# stdin: neither is placed in process arguments or emitted to a log.
_agent_mysql_with_config_token() {
  local query="$1"
  local token_hex=""
  local xtrace_was_enabled=0
  local mysql_rc=0

  [[ "$-" == *x* ]] && xtrace_was_enabled=1
  set +x
  if ! token_hex="$(_agent_config_token_hex)"; then
    (( xtrace_was_enabled == 0 )) || set -x
    return 1
  fi
  if [[ -z "${token_hex}" || ! "${token_hex}" =~ ^[0-9a-f]+$ ]]; then
    (( xtrace_was_enabled == 0 )) || set -x
    return 1
  fi
  if {
      printf "SET @kiquai_agent_token = UNHEX('%s');\n" "${token_hex}"
      printf '%s\n' "${query}"
    } | mysql_app_exec --batch --skip-column-names; then
    mysql_rc=0
  else
    mysql_rc=$?
  fi
  (( xtrace_was_enabled == 0 )) || set -x
  return "${mysql_rc}"
}

# Return codes: 0=valid unique DB identity, 1=missing/malformed/stale,
# 2=database unavailable or schema/query failure, 3=duplicate token rows.
# AGENT_REGISTRATION_STATE further distinguishes every result.
agent_registration_query() {
  local config="${AGENT_DIR}/config.json"
  local result=""
  local count=""
  local agent_id=""
  local -a rows=()

  _clear_agent_metadata
  AGENT_REGISTRATION_STATE="unchecked"
  if [[ ! -e "${config}" || ! -s "${config}" ]]; then
    AGENT_REGISTRATION_STATE="missing"
    return 1
  fi
  if [[ ! -f "${config}" || -L "${config}" ]] \
      || ! jq -e 'type == "object"' "${config}" >/dev/null 2>&1; then
    AGENT_REGISTRATION_STATE="malformed"
    return 1
  fi
  if ! jq -e '(.token? == null) or (.token? | type == "string")' \
      "${config}" >/dev/null 2>&1; then
    AGENT_REGISTRATION_STATE="malformed"
    return 1
  fi
  if ! agent_config_has_registration_token "${config}"; then
    AGENT_REGISTRATION_STATE="missing"
    return 1
  fi

  if ! result="$(_agent_mysql_with_config_token \
      'SELECT COUNT(*), COALESCE(MIN(`agentId`), 0) FROM `Agent` WHERE BINARY `token` = BINARY @kiquai_agent_token;' \
      2>/dev/null)"; then
    AGENT_REGISTRATION_STATE="database-unavailable"
    return 2
  fi
  mapfile -t rows <<< "${result}"
  if (( ${#rows[@]} != 1 )); then
    AGENT_REGISTRATION_STATE="database-unavailable"
    return 2
  fi
  IFS=$'\t' read -r count agent_id <<< "${rows[0]}"
  if [[ ! "${count}" =~ ^[0-9]+$ || ! "${agent_id}" =~ ^[0-9]+$ ]]; then
    AGENT_REGISTRATION_STATE="database-unavailable"
    return 2
  fi
  if [[ "${count}" == "0" ]]; then
    AGENT_REGISTRATION_STATE="stale"
    return 1
  fi
  if [[ "${count}" != "1" || ! "${agent_id}" =~ ^[1-9][0-9]*$ ]]; then
    AGENT_REGISTRATION_STATE="duplicate"
    return 3
  fi

  AGENT_ID="${agent_id}"
  AGENT_REGISTRATION_STATE="valid"
  return 0
}

agent_registration_is_complete() {
  agent_registration_query
}

normalize_agent_config_url() {
  local config="${AGENT_DIR}/config.json"
  local expected_url="http://127.0.0.1:${INTERNAL_PORT}/api/server.php"
  local temp="${config}.tmp.$$"
  local current_url=""

  [[ -f "${config}" && ! -L "${config}" ]] || return 1
  jq -e 'type == "object"' "${config}" >/dev/null 2>&1 || return 1
  current_url="$(jq -r '.url // empty | strings' "${config}" 2>/dev/null)" \
    || return 1
  if [[ "${current_url}" == "${expected_url}" ]]; then
    chmod 600 "${config}"
    return 0
  fi
  if ! jq --arg url "${expected_url}" '.url = $url' \
      "${config}" > "${temp}"; then
    rm -f -- "${temp}"
    return 1
  fi
  chmod 600 "${temp}"
  mv -f -- "${temp}" "${config}"
  success "Normalized the managed agent API URL to the loopback endpoint."
}

# Back up the raw config, then atomically remove only registration identity.
# An absent config is initialized without manufacturing a backup.  A malformed
# config is preserved byte-for-byte before a fresh identity-free object is
# written.  The caller must have already established that recovery is allowed.
backup_and_reset_agent_identity() {
  local config="${AGENT_DIR}/config.json"
  local backup_dir="${AGENT_DIR}/identity-backups"
  local backup=""
  local expected_url="http://127.0.0.1:${INTERNAL_PORT}/api/server.php"
  local temp="${config}.reset.$$"
  local state=""

  if supervisor_is_running; then
    state="$(supervisor_program_state agent)"
    case "${state}" in
      RUNNING|STARTING|BACKOFF|STOPPING)
        error "Refusing to reset agent identity while Supervisor state is ${state}."
        return 1
        ;;
    esac
  fi
  if [[ -e "${config}" && ( ! -f "${config}" || -L "${config}" ) ]]; then
    error "Refusing to back up a non-regular or symlinked agent config."
    return 1
  fi

  mkdir -p "${backup_dir}"
  chmod 700 "${backup_dir}"
  if [[ -f "${config}" ]]; then
    backup="${backup_dir}/config.json.$(date '+%Y%m%dT%H%M%S%z').$$.bak"
    install -m 600 -- "${config}" "${backup}" || return 1
  fi

  if [[ -f "${config}" ]] \
      && jq -e 'type == "object"' "${config}" >/dev/null 2>&1; then
    if ! jq --arg url "${expected_url}" \
        'del(.token, .uuid, .voucher) | .url = $url' \
        "${config}" > "${temp}"; then
      rm -f -- "${temp}"
      return 1
    fi
  else
    if ! jq -n --arg url "${expected_url}" '{url: $url}' > "${temp}"; then
      rm -f -- "${temp}"
      return 1
    fi
  fi
  chmod 600 "${temp}"
  mv -f -- "${temp}" "${config}"
  AGENT_REGISTRATION_STATE="missing"
  _clear_agent_metadata
  if [[ -n "${backup}" ]]; then
    success "Backed up the previous agent config and reset its stale registration identity (${backup})."
  else
    info "Initialized a fresh identity-free agent config for registration."
  fi
}

_agent_decode_hex() {
  local hex="$1"
  local decoded=""
  local byte=""
  local char=""
  [[ "${hex}" =~ ^([0-9A-Fa-f][0-9A-Fa-f])*$ ]] || return 1
  while [[ -n "${hex}" ]]; do
    byte="${hex:0:2}"
    hex="${hex:2}"
    printf -v char '%b' "\\x${byte}"
    decoded+="${char}"
  done
  printf '%s' "${decoded}"
}

# Populate non-secret server state for status/diagnostics.  Return 0 on a
# complete row, 1 when registration is not valid, and 2 on a DB/schema error.
agent_server_metadata_query() {
  local result=""
  local name_hex=""
  local last_act_hex=""
  local error_hex=""
  local config_count=""
  local -a rows=()

  if [[ "${AGENT_REGISTRATION_STATE}" != "valid" \
      || ! "${AGENT_ID}" =~ ^[1-9][0-9]*$ ]]; then
    agent_registration_query || return $?
  fi
  if ! result="$(_agent_mysql_with_config_token \
    "SELECT a.\`agentId\`, CONCAT('x', HEX(REPLACE(REPLACE(REPLACE(a.\`agentName\`, CHAR(9), ' '), CHAR(10), ' '), CHAR(13), ' '))), a.\`isActive\`, a.\`isTrusted\`, a.\`cpuOnly\`, CONCAT('x', HEX(REPLACE(REPLACE(REPLACE(a.\`lastAct\`, CHAR(9), ' '), CHAR(10), ' '), CHAR(13), ' '))), a.\`lastTime\`, COALESCE((SELECT MIN(x.\`assignmentId\`) FROM \`Assignment\` x WHERE x.\`agentId\` = a.\`agentId\`), 0), (SELECT COUNT(*) FROM \`Assignment\` x WHERE x.\`agentId\` = a.\`agentId\`), COALESCE((SELECT x.\`taskId\` FROM \`Assignment\` x WHERE x.\`agentId\` = a.\`agentId\` ORDER BY x.\`assignmentId\` LIMIT 1), 0), (SELECT COUNT(*) FROM \`Config\` c WHERE c.\`item\` = 'agenttimeout'), COALESCE((SELECT c.\`value\` FROM \`Config\` c WHERE c.\`item\` = 'agenttimeout' ORDER BY c.\`configId\` LIMIT 1), 0), COALESCE((SELECT e.\`agentErrorId\` FROM \`AgentError\` e WHERE e.\`agentId\` = a.\`agentId\` ORDER BY e.\`time\` DESC, e.\`agentErrorId\` DESC LIMIT 1), 0), COALESCE((SELECT e.\`time\` FROM \`AgentError\` e WHERE e.\`agentId\` = a.\`agentId\` ORDER BY e.\`time\` DESC, e.\`agentErrorId\` DESC LIMIT 1), 0), COALESCE((SELECT e.\`taskId\` FROM \`AgentError\` e WHERE e.\`agentId\` = a.\`agentId\` ORDER BY e.\`time\` DESC, e.\`agentErrorId\` DESC LIMIT 1), 0), COALESCE((SELECT e.\`chunkId\` FROM \`AgentError\` e WHERE e.\`agentId\` = a.\`agentId\` ORDER BY e.\`time\` DESC, e.\`agentErrorId\` DESC LIMIT 1), 0), CONCAT('x', COALESCE((SELECT HEX(REPLACE(REPLACE(REPLACE(e.\`error\`, CHAR(9), ' '), CHAR(10), ' '), CHAR(13), ' ')) FROM \`AgentError\` e WHERE e.\`agentId\` = a.\`agentId\` ORDER BY e.\`time\` DESC, e.\`agentErrorId\` DESC LIMIT 1), '')) FROM \`Agent\` a WHERE a.\`agentId\` = ${AGENT_ID} AND BINARY a.\`token\` = BINARY @kiquai_agent_token;" \
    2>/dev/null)"; then
    return 2
  fi
  mapfile -t rows <<< "${result}"
  (( ${#rows[@]} == 1 )) || return 2
  IFS=$'\t' read -r \
    AGENT_ID name_hex AGENT_ACTIVE AGENT_TRUSTED AGENT_CPU_ONLY \
    last_act_hex AGENT_LAST_TIME AGENT_ASSIGNMENT_ID \
    AGENT_ASSIGNMENT_COUNT AGENT_TASK_ID config_count AGENT_TIMEOUT \
    AGENT_LAST_ERROR_ID AGENT_LAST_ERROR_TIME AGENT_LAST_ERROR_TASK_ID \
    AGENT_LAST_ERROR_CHUNK_ID error_hex <<< "${rows[0]}"

  [[ "${AGENT_ID}" =~ ^[1-9][0-9]*$ \
      && "${AGENT_ACTIVE}" =~ ^[01]$ \
      && "${AGENT_TRUSTED}" =~ ^[01]$ \
      && "${AGENT_CPU_ONLY}" =~ ^[01]$ \
      && "${AGENT_LAST_TIME}" =~ ^[0-9]+$ \
      && "${AGENT_ASSIGNMENT_ID}" =~ ^[0-9]+$ \
      && "${AGENT_ASSIGNMENT_COUNT}" =~ ^[0-9]+$ \
      && "${AGENT_TASK_ID}" =~ ^[0-9]+$ \
      && "${config_count}" == "1" \
      && "${AGENT_TIMEOUT}" =~ ^[0-9]+$ \
      && "${AGENT_LAST_ERROR_ID}" =~ ^[0-9]+$ \
      && "${AGENT_LAST_ERROR_TIME}" =~ ^[0-9]+$ \
      && "${AGENT_LAST_ERROR_TASK_ID}" =~ ^[0-9]+$ \
      && "${AGENT_LAST_ERROR_CHUNK_ID}" =~ ^[0-9]+$ ]] || return 2
  [[ "${name_hex}" == x* && "${last_act_hex}" == x* && "${error_hex}" == x* ]] \
    || return 2
  # These metadata globals are consumed by the subsequently sourced CLI module.
  # shellcheck disable=SC2034
  AGENT_NAME="$(_agent_decode_hex "${name_hex#x}")" || return 2
  # shellcheck disable=SC2034
  AGENT_LAST_ACT="$(_agent_decode_hex "${last_act_hex#x}")" || return 2
  if [[ "${AGENT_ASSIGNMENT_ID}" == "0" ]]; then
    AGENT_ASSIGNMENT_ID=""
    AGENT_TASK_ID=""
  fi
  if [[ "${AGENT_LAST_ERROR_ID}" == "0" ]]; then
    AGENT_LAST_ERROR_ID=""
    AGENT_LAST_ERROR_TIME=""
    AGENT_LAST_ERROR_TASK_ID=""
    AGENT_LAST_ERROR_CHUNK_ID=""
    AGENT_LAST_ERROR_MESSAGE=""
  else
    # shellcheck disable=SC2034
    AGENT_LAST_ERROR_MESSAGE="$(_agent_decode_hex "${error_hex#x}")" || return 2
  fi
  return 0
}

agent_heartbeat_age_seconds() {
  local now=""
  [[ "${AGENT_LAST_TIME}" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  [[ "${now}" =~ ^[0-9]+$ ]] || return 1
  if (( now < AGENT_LAST_TIME )); then
    printf '0\n'
  else
    printf '%s\n' "$((now - AGENT_LAST_TIME))"
  fi
}

agent_gpu_preflight_is_confirmed() {
  [[ "${REQUIRE_HASHCAT_GPU}" == "1" ]] || return 1
  have_cmd nvidia-smi && nvidia-smi -L >/dev/null 2>&1 || return 1
  [[ -r "${HASHCAT_LOG}" ]] || return 1
  grep -Eq '(Backend Device ID|Device #[[:space:]]*[0-9]+)' "${HASHCAT_LOG}" \
    && grep -Eiq '(NVIDIA|CUDA)' "${HASHCAT_LOG}"
}

# Reconcile only cpuOnly for a DB-recognized managed identity.  All activation,
# trust, access-group and assignment fields are deliberately left untouched.
reconcile_managed_agent_cpu_mode() {
  local result=""
  local count=""
  local cpu_only=""
  local -a rows=()

  [[ "${REQUIRE_HASHCAT_GPU}" == "1" ]] || return 0
  if ! agent_gpu_preflight_is_confirmed; then
    warn "GPU preflight is not currently confirmed; leaving the agent cpuOnly flag unchanged."
    return 0
  fi
  agent_registration_query || return $?
  if ! result="$(_agent_mysql_with_config_token \
      "UPDATE \`Agent\` SET \`cpuOnly\` = 0 WHERE \`agentId\` = ${AGENT_ID} AND BINARY \`token\` = BINARY @kiquai_agent_token; SELECT COUNT(*), COALESCE(MAX(\`cpuOnly\`), -1) FROM \`Agent\` WHERE \`agentId\` = ${AGENT_ID} AND BINARY \`token\` = BINARY @kiquai_agent_token;" \
      2>/dev/null)"; then
    return 2
  fi
  mapfile -t rows <<< "${result}"
  (( ${#rows[@]} == 1 )) || return 2
  IFS=$'\t' read -r count cpu_only <<< "${rows[0]}"
  [[ "${count}" == "1" && "${cpu_only}" == "0" ]] || return 2
  AGENT_CPU_ONLY=0
  return 0
}

reconcile_agent_process() {
  local state=""
  local output=""
  local registration_required=0
  local registration_rc=0
  local deadline=0

  if [[ "${AGENT_ENABLED}" == "1" ]]; then
    if agent_registration_query; then
      if [[ -n "${AGENT_VOUCHER}" ]]; then
        warn "The existing token is recognized by the server; ignoring the supplied voucher and preserving agentId=${AGENT_ID}."
        AGENT_VOUCHER=""
        write_dotenv
      fi
      normalize_agent_config_url \
        || die "Unable to atomically normalize the registered agent config URL."
      reconcile_managed_agent_cpu_mode \
        || die "Unable to reconcile the registered GPU agent cpuOnly flag."
    else
      registration_rc=$?
      case "${AGENT_REGISTRATION_STATE}" in
        stale|malformed|missing)
          [[ -n "${AGENT_VOUCHER}" ]] \
            || die "Agent registration is ${AGENT_REGISTRATION_STATE}; provide a voucher for an explicit recovery."
          agent_database_is_ready \
            || die "Database readiness could not be proven; refusing to reset agent identity."
          if [[ "${AGENT_IDENTITY_RESET_PREPARED}" != "1" ]]; then
            stop_supervisor_program_if_active agent
            backup_and_reset_agent_identity \
              || die "Unable to back up and reset the stale agent identity."
            normalize_agent_config_url \
              || die "Unable to normalize the identity-free agent config URL."
            AGENT_IDENTITY_RESET_PREPARED=1
          fi
          registration_required=1
          ;;
        database-unavailable)
          die "Agent registration could not be validated because the database is unavailable; no identity state was changed."
          ;;
        duplicate)
          die "The saved agent token matches multiple Agent rows; refusing automated recovery."
          ;;
        *)
          die "Unsupported agent registration state '${AGENT_REGISTRATION_STATE}' (exit=${registration_rc})."
          ;;
      esac
    fi
  fi

  if [[ "${AGENT_ENABLED}" == "1" ]] && supervisor_is_running; then
    state="$(supervisor_program_state agent)"
    if [[ "${state}" == "RUNNING" && "${registration_required}" == "0" ]]; then
      info "The local GPU agent is already RUNNING; preserving its current task and deferring launcher changes until a deliberate service reconcile."
      success "The local GPU agent is enabled."
      return 0
    fi
  fi

  write_agent_launcher
  write_supervisor_config
  if ! output="$(supervisor_ctl reread 2>&1)"; then
    [[ -n "${output}" ]] && printf '%s\n' "${output}" >&2
    print_supervisor_program_diagnostics agent
    die "Supervisor could not reread the local agent configuration."
  fi
  if ! output="$(supervisor_ctl update 2>&1)"; then
    [[ -n "${output}" ]] && printf '%s\n' "${output}" >&2
    print_supervisor_program_diagnostics agent
    die "Supervisor could not apply the local agent configuration."
  fi
  if [[ "${AGENT_ENABLED}" == "1" ]]; then
    state="$(supervisor_program_state agent)"
    case "${state}" in
      RUNNING)
        info "The local GPU agent is already RUNNING; preserving its current task."
        ;;
      STARTING)
        info "The local GPU agent is already STARTING; waiting for stabilization."
        ;;
      BACKOFF|STOPPING)
        warn "The local GPU agent is ${state}; reconciling it before a clean start."
        stop_supervisor_program_if_active agent
        state="$(supervisor_program_state agent)"
        ;;
      STOPPED|EXITED|FATAL)
        ;;
      "")
        print_supervisor_program_diagnostics agent
        die "Supervisor returned no state for the configured local GPU agent."
        ;;
      *)
        print_supervisor_program_diagnostics agent
        die "Supervisor returned unsupported agent state '${state}'."
        ;;
    esac

    if [[ "${state}" != "RUNNING" && "${state}" != "STARTING" ]]; then
      if ! output="$(supervisor_ctl start agent 2>&1)"; then
        [[ -n "${output}" ]] && printf '%s\n' "${output}" >&2
        print_supervisor_program_diagnostics agent
        die "Supervisor could not start the local GPU agent."
      fi
    fi
    if ! wait_for_supervisor_running agent 90; then
      stop_supervisor_program_if_active agent
      print_supervisor_program_diagnostics agent
      die "The local GPU agent did not reach RUNNING within 90 seconds; it was stopped."
    fi
    if [[ "${registration_required}" == "1" ]]; then
      deadline=$((SECONDS + 90))
      while (( SECONDS < deadline )); do
        if agent_registration_query; then
          break
        fi
        [[ "${AGENT_REGISTRATION_STATE}" != "duplicate" ]] \
          || break
        sleep 2
      done
      if [[ "${AGENT_REGISTRATION_STATE}" == "valid" ]]; then
        AGENT_IDENTITY_RESET_PREPARED=0
        AGENT_VOUCHER=""
        write_dotenv
        normalize_agent_config_url \
          || die "Registration succeeded but the agent config URL could not be normalized."
        reconcile_managed_agent_cpu_mode \
          || die "Registration succeeded but the GPU agent cpuOnly flag could not be reconciled."
        success "Agent registration is recognized by MySQL; the one-time voucher was removed from saved configuration."
      else
        stop_supervisor_program_if_active agent
        print_supervisor_program_diagnostics agent
        die "Agent registration was not recognized by MySQL within 90 seconds (state=${AGENT_REGISTRATION_STATE}); the process was stopped and the voucher remains saved."
      fi
    fi
    success "The local GPU agent is enabled."
  else
    stop_supervisor_program_if_active agent
    info "Agent is installed but not registered. Use './run.sh agent-start VOUCHER'."
  fi
}
