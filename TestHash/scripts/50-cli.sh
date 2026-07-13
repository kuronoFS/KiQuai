#!/usr/bin/env bash
# shellcheck shell=bash
# KiQuai module: cli
# kiquai-module-api: 1
# kiquai-release: 3.2.2

if [[ "${KIQUAI_MODULE_CONTEXT:-0}" != "1" ]]; then
  printf 'This file is a KiQuai module; run ../run.sh instead.\n' >&2
  return 64 2>/dev/null || exit 64
fi

redacted_environment() {
  [[ -r "${ENV_FILE}" ]] || return 0
  awk -F= '
    BEGIN { IGNORECASE=1 }
    {
      key=$1
      if (key ~ /(PASS|PASSWORD|VOUCHER|TOKEN|SECRET)/) {
        print key "='\''<redacted>'\''"
      } else {
        gsub(/:\/\/[^\/@:]+:[^\/@]+@/, "://<redacted>@")
        print
      }
    }
  ' "${ENV_FILE}"
}

collect_diagnostics() {
  local diagnostics_dir="${LOG_DIR}/diagnostics"
  mkdir -p "${diagnostics_dir}"
  chmod 700 "${diagnostics_dir}"
  LAST_DIAGNOSTIC_FILE="${diagnostics_dir}/diagnostic-$(date '+%Y%m%d-%H%M%S')-$$.log"
  {
    printf 'KiQuai diagnostic report\n'
    printf 'generated=%s\nrun_id=%s\ncommand_name=%s\nscript_version=%s\nstage=%s\nmodule=%s\nsource=%s\nline=%s\nfunction=%s\ncaller_source=%s\ncaller_line=%s\ncaller_function=%s\ncommand=%s\n\n' \
      "$(timestamp)" "${RUN_ID}" "${CURRENT_COMMAND}" "${SCRIPT_VERSION}" "${CURRENT_STAGE}" \
      "${LAST_ERROR_MODULE:-}" "${LAST_ERROR_SOURCE:-}" "${LAST_ERROR_LINE:-}" \
      "${LAST_ERROR_FUNCTION:-}" "${LAST_ERROR_CALLER_SOURCE:-}" \
      "${LAST_ERROR_CALLER_LINE:-}" "${LAST_ERROR_CALLER_FUNCTION:-}" \
      "${LAST_ERROR_COMMAND:-}"
    printf '===== OS =====\n'
    uname -a
    [[ -r /etc/os-release ]] && sed -n '1,40p' /etc/os-release
    printf '\n===== Outer container lifecycle =====\n'
    printf 'script_pid=%s\nscript_ppid=%s\n' "$$" "${PPID}"
    printf 'pid1_name='
    cat /proc/1/comm 2>/dev/null || printf 'unknown\n'
    printf 'pid1_start_ticks='
    awk '{print $22}' /proc/1/stat 2>/dev/null || printf 'unknown\n'
    printf 'intentional_stop_marker=%s\n' "$([[ -f "${SERVE_STOP_MARKER}" ]] && printf present || printf absent)"
    [[ ! -r "${SUPERVISOR_PID}" ]] || printf 'supervisor_pid=%s\n' "$(<"${SUPERVISOR_PID}")"
    printf '\n===== Disk and memory =====\n'
    df -h "$(dirname "${APP_DIR}")" 2>&1 || true
    free -h 2>&1 || true
    printf '\n===== Redacted configuration =====\n'
    redacted_environment
    printf '\n===== Processes =====\n'
    if [[ -f "${SUPERVISOR_CONFIG}" ]] && supervisor_is_running; then
      supervisor_ctl status 2>&1 || true
    else
      printf 'KiQuai supervisord is not running.\n'
    fi
    printf '\n===== Listening TCP ports =====\n'
    ss -ltnp 2>&1 || true
    printf '\n===== Versions =====\n'
    php -v 2>&1 || true
    composer --version 2>&1 || true
    mysql --version 2>&1 || true
    nginx -v 2>&1 || true
    apache2ctl -v 2>&1 || true
    printf '\n===== SQLx binaries =====\n'
    ls -l "${TOOLS_DIR}/bin/sqlx" /usr/bin/sqlx 2>&1 || true
    "${TOOLS_DIR}/bin/sqlx" --version 2>&1 || true
    /usr/bin/sqlx --version 2>&1 || true
    printf '\n===== SQLx migration state =====\n'
    if MYSQL_PWD="${MYSQL_PASSWORD}" mysql --protocol=tcp -h 127.0.0.1 \
        -P "${DB_PORT}" -u "${MYSQL_USER}" -D "${MYSQL_DATABASE}" \
        -Nse 'SELECT 1' >/dev/null 2>&1; then
      failed_migration_rows 2>&1 || true
      mysql_app_exec -e \
        'SELECT version, description, installed_on, success, execution_time FROM _sqlx_migrations ORDER BY version DESC LIMIT 20;' \
        2>&1 || true
    else
      printf 'Application database is not reachable with saved credentials.\n'
    fi
    printf '\n===== PHP modules =====\n'
    php -m 2>&1 || true
    printf '\n===== NVIDIA =====\n'
    nvidia-smi 2>&1 || true
    printf '\n===== Hashcat =====\n'
    hashcat -I 2>&1 | sed -n '1,180p' || true
    printf '\n===== HTTP =====\n'
    curl -sS -D - -o /dev/null --max-time 8 \
      "http://127.0.0.1:${INTERNAL_PORT}/" 2>&1 || true
    printf '\n===== Agent lock and dispatch state =====\n'
    print_agent_lock_diagnostics
    mysql_app_exec -e \
      "SELECT item, value FROM \`Config\` WHERE item = 'priority0Start';" 2>&1 || true
    mysql_app_exec -e \
      "SELECT agentId, agentName, isActive, cpuOnly, lastAct, lastTime FROM \`Agent\` ORDER BY agentId;" \
      2>&1 || true
    mysql_app_exec -e \
      "SELECT assignmentId, taskId, agentId FROM \`Assignment\` ORDER BY assignmentId;" \
      2>&1 || true
    mysql_app_exec -e \
      "SELECT accessGroupAgentId, accessGroupId, agentId FROM \`AccessGroupAgent\` ORDER BY accessGroupAgentId;" \
      2>&1 || true
    mysql_app_exec -e \
      "SELECT taskWrapperId, priority, maxAgents, taskType, hashlistId, accessGroupId, isArchived FROM \`TaskWrapper\` ORDER BY taskWrapperId DESC LIMIT 30;" \
      2>&1 || true
    mysql_app_exec -e \
      "SELECT hashlistId, hashlistName, hashTypeId, hashCount, cracked, isSecret, accessGroupId, isArchived FROM \`Hashlist\` ORDER BY hashlistId DESC LIMIT 30;" \
      2>&1 || true
    mysql_app_exec -e \
      "SELECT ft.taskId, f.fileId, f.filename, f.isSecret, f.accessGroupId FROM \`FileTask\` ft JOIN \`File\` f ON f.fileId = ft.fileId ORDER BY ft.taskId DESC LIMIT 60;" \
      2>&1 || true
    mysql_app_exec -e \
      "SELECT taskId, taskName, priority, isCpuTask, isArchived, crackerBinaryId FROM \`Task\` ORDER BY taskId DESC LIMIT 30;" \
      2>&1 || true
    printf '\n===== Bounded logs =====\n'
    local log
    for log in migration.log mysql.log mysql-supervisor.log backend.log apache-error.log nginx-error.log nginx-supervisor.log supervisord.log bootstrap.log loader.log; do
      printf '\n--- %s ---\n' "${log}"
      tail -n 160 "${LOG_DIR}/${log}" 2>&1 || true
    done
    tail_agent_file agent.log "${LOG_DIR}/agent.log" 180
    tail_agent_file agent/client.log "${AGENT_DIR}/client.log" 220
  } > "${LAST_DIAGNOSTIC_FILE}" 2>&1
  chmod 600 "${LAST_DIAGNOSTIC_FILE}"
}

print_runtime_summary() {
  cat <<EOF
Configuration summary (secrets redacted):
  APP_DIR             ${APP_DIR}
  INTERNAL_PORT       ${INTERNAL_PORT}
  BACKEND_PORT        ${BACKEND_PORT} (loopback only)
  DB_PORT             ${DB_PORT} (loopback only)
  PUBLIC_URL          ${PUBLIC_URL}
  BACKEND_VERSION     ${HASHTOPOLIS_VERSION}
  FRONTEND_VERSION    ${HASHTOPOLIS_FRONTEND_VERSION}
  AGENT_ENABLED       ${AGENT_ENABLED}
  AUTO_ASSIGN_TASKS   ${HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO} (priority 0)
  MAIN_LOG            ${MAIN_LOG}
EOF
}

_print_credentials_body() {
  cat <<EOF

======================================================================
HASHTOPOLIS CREDENTIALS
======================================================================
URL            : ${PUBLIC_URL}
Admin username : ${HASHTOPOLIS_ADMIN_USER}
Admin password : ${HASHTOPOLIS_ADMIN_PASSWORD}
Stored in      : ${ENV_FILE} (mode 600)

This credential block is written directly to the operator console and is not
copied into loader.log or bootstrap.log. Your terminal or platform may still
retain console output; close the session after use and never attach it to a log.
EOF
}

print_credentials_to_console() {
  if [[ "${KIQUAI_CONSOLE_FD:-}" == "3" && -e /proc/self/fd/3 && -t 3 ]]; then
    _print_credentials_body >&3
  elif [[ -t 1 ]]; then
    _print_credentials_body
  else
    die "Refusing to print the admin password to non-interactive output. Run './run.sh credentials' from an interactive SSH/terminal session, or inspect ${ENV_FILE} locally."
  fi
}

print_success() {
  local program
  local state
  for program in mysql backend nginx; do
    state="$(supervisor_program_state "${program}")"
    [[ "${state}" == "RUNNING" ]] \
      || die "Required Supervisor program '${program}' is ${state:-unknown}, not RUNNING."
  done
  if [[ "${AGENT_ENABLED}" == "1" ]]; then
    state="$(supervisor_program_state agent)"
    [[ "${state}" == "RUNNING" ]] \
      || die "AGENT_ENABLED=1 but Supervisor program 'agent' is ${state:-unknown}, not RUNNING."
    agent_registration_is_complete \
      || die "AGENT_ENABLED=1 but the local agent has no completed registration token."
  fi
  supervisor_ctl status || true
  printf '\n%s' "${C_GREEN}"
  print_rule
  printf '%sDEPLOYMENT COMPLETE%s\n' "${C_BOLD}" "${C_RESET}${C_GREEN}"
  print_rule
  printf '%s' "${C_RESET}"
  cat <<EOF
Hashtopolis URL : ${PUBLIC_URL}
API v2          : ${PUBLIC_URL}/api/v2
Legacy agent API: ${PUBLIC_URL}/api/server.php

Application dir : ${APP_DIR}
Credentials     : ${ENV_FILE} (mode 600)
Bootstrap log   : ${MAIN_LOG}

Useful commands:
  $(realpath "$0") status
  $(realpath "$0") logs
  $(realpath "$0") diagnostics
  $(realpath "$0") credentials
  $(realpath "$0") agent-start YOUR_VOUCHER

Security notice: traffic is plain HTTP unless PUBLIC_URL is provided through a
trusted HTTPS reverse proxy or tunnel. Use Hashtopolis only for authorized work.

The admin password is not printed during deploy/serve. Retrieve it explicitly
from an interactive terminal with: $(realpath "$0") credentials
EOF
}

require_existing_installation() {
  [[ -f "${ENV_FILE}" && -f "${SUPERVISOR_CONFIG}" ]] \
    || die "No single-container installation exists under ${APP_DIR}; run './run.sh deploy' first."
}

usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Usage:
  ./run.sh                         TTY: deploy once; non-TTY startup: serve
  ./run.sh deploy                  Deploy or reconcile, then return
  ./run.sh serve                   Deploy, then keep the outer container alive
  ./run.sh verify-modules          Download and validate every module only
  ./run.sh preflight               Check root, disk, and NVIDIA visibility
  ./run.sh status                  Show service, HTTP, database, and GPU status
  ./run.sh logs                    Print bounded service logs
  ./run.sh diagnostics             Create a diagnostic report
  ./run.sh credentials             Print saved admin credentials to console only
  ./run.sh stop                    Stop all managed processes; preserve data
  ./run.sh restart                 Reconcile and restart the managed services
  ./run.sh agent-start VOUCHER     Register/start the local GPU agent
  ./run.sh agent-stop              Stop and persistently disable the local agent
  ./run.sh help                    Show this help

Common overrides:
  PUBLIC_URL=http://IP:PORT ./run.sh deploy
  APP_DIR=/data/kiquai-hashtopolis ./run.sh deploy
  FORCE_REBUILD=1 ./run.sh deploy
  WIPE_DATA=1 ./run.sh deploy
  REQUIRE_HASHCAT_GPU=0 ./run.sh deploy
  HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO=0 ./run.sh deploy
EOF
}

command_preflight() {
  print_header
  validate_outer_runtime
}

command_status() {
  require_existing_installation
  local failed=0
  local failed_rows=""
  local program=""
  local state=""
  local priority_zero_policy=""
  if supervisor_is_running; then
    supervisor_ctl status || true
    for program in mysql backend nginx; do
      state="$(supervisor_program_state "${program}")"
      if [[ "${state}" != "RUNNING" ]]; then
        error "Required Supervisor program '${program}' is ${state:-unknown}."
        failed=1
      fi
    done
    if [[ "${AGENT_ENABLED}" == "1" ]]; then
      state="$(supervisor_program_state agent)"
      if [[ "${state}" != "RUNNING" ]]; then
        error "AGENT_ENABLED=1 but the agent is ${state:-unknown}."
        failed=1
      fi
      if ! agent_registration_is_complete; then
        error "AGENT_ENABLED=1 but config.json has no completed registration token."
        failed=1
      fi
    fi
  else
    error "KiQuai supervisord is not running."
    failed=1
  fi
  if check_http_contract; then
    success "HTTP contract passed (frontend=${HEALTH_FRONTEND_CODE}, agent_api=${HEALTH_API_CODE})."
  else
    error "HTTP contract failed (frontend=${HEALTH_FRONTEND_CODE}, agent_api=${HEALTH_API_CODE})."
    failed=1
  fi
  if MYSQL_PWD="${MYSQL_PASSWORD}" mysql --protocol=tcp -h 127.0.0.1 \
      -P "${DB_PORT}" -u "${MYSQL_USER}" -Nse 'SELECT 1' >/dev/null 2>&1; then
    success "Database login passed."
    priority_zero_policy="$(mysql_app_exec -Nse \
      "SELECT \`value\` FROM \`Config\` WHERE \`item\` = 'priority0Start' LIMIT 1;" \
      2>/dev/null || true)"
    if [[ "${priority_zero_policy}" == "1" ]]; then
      success "Automatic assignment is enabled for priority-0 tasks."
    else
      warn "Automatic assignment is not enabled for priority-0 tasks (value=${priority_zero_policy:-missing})."
    fi
    if ! failed_rows="$(failed_migration_rows 2>/dev/null)"; then
      error "Database login passed but SQLx migration state could not be inspected."
      failed=1
    elif [[ -n "${failed_rows}" ]]; then
      error "Database contains at least one partially applied SQLx migration."
      failed=1
    fi
  else
    error "Database login failed."
    failed=1
  fi
  if ! nvidia-smi --query-gpu=index,name,driver_version,memory.total,utilization.gpu \
      --format=csv,noheader 2>/dev/null; then
    if [[ "${REQUIRE_HASHCAT_GPU}" == "1" ]]; then
      error "NVIDIA GPU status is unavailable."
      failed=1
    else
      warn "NVIDIA GPU status is unavailable in server-only mode."
    fi
  fi
  if ! hashcat -I 2>/dev/null | sed -n '1,100p'; then
    if [[ "${REQUIRE_HASHCAT_GPU}" == "1" ]]; then
      error "Hashcat backend status is unavailable."
      failed=1
    else
      warn "Hashcat backend status is unavailable in server-only mode."
    fi
  fi
  return "${failed}"
}

command_credentials() {
  local saved_user=""
  local saved_password=""
  local saved_url=""
  [[ -r "${ENV_FILE}" ]] \
    || die "No saved credentials exist at ${ENV_FILE}; run './run.sh deploy' first."
  saved_user="$(dotenv_get HASHTOPOLIS_ADMIN_USER "${ENV_FILE}" 2>/dev/null || true)"
  saved_password="$(dotenv_get HASHTOPOLIS_ADMIN_PASSWORD "${ENV_FILE}" 2>/dev/null || true)"
  saved_url="$(dotenv_get PUBLIC_URL "${ENV_FILE}" 2>/dev/null || true)"
  [[ -n "${saved_user}" && -n "${saved_password}" ]] \
    || die "Saved admin credentials are incomplete in ${ENV_FILE}."
  HASHTOPOLIS_ADMIN_USER="${saved_user}"
  HASHTOPOLIS_ADMIN_PASSWORD="${saved_password}"
  [[ -z "${saved_url}" ]] || PUBLIC_URL="${saved_url}"
  print_credentials_to_console
}

command_logs() {
  require_existing_installation
  supervisor_is_running && supervisor_ctl status || true
  print_agent_lock_diagnostics
  local log
  for log in migration.log mysql.log mysql-supervisor.log backend.log apache-error.log nginx-error.log nginx-supervisor.log supervisord.log bootstrap.log loader.log; do
    printf '\n===== %s =====\n' "${log}"
    tail -n 220 "${LOG_DIR}/${log}" 2>/dev/null || true
  done
  tail_agent_file agent.log "${LOG_DIR}/agent.log" 220
  tail_agent_file agent/client.log "${AGENT_DIR}/client.log" 260
}

command_diagnostics() {
  collect_diagnostics
  success "Diagnostic report created: ${LAST_DIAGNOSTIC_FILE}"
}

command_stop() {
  require_existing_installation
  acquire_lock
  printf 'run=%s requested=%s\n' "${RUN_ID}" "$(timestamp)" \
    > "${SERVE_STOP_MARKER}.tmp.$$"
  chmod 600 "${SERVE_STOP_MARKER}.tmp.$$"
  mv -f "${SERVE_STOP_MARKER}.tmp.$$" "${SERVE_STOP_MARKER}"
  stop_managed_services
  success "All KiQuai services stopped intentionally. The foreground keeper, if active, remains available; database and files were preserved."
}

acquire_serve_lock() {
  mkdir -p "$(dirname "${LOCK_FILE}")"
  exec 7>"${LOCK_FILE}.serve"
  if ! flock -n 7; then
    exec 7>&-
    die "Another KiQuai serve process is already monitoring this installation."
  fi
}

serve_request_shutdown() {
  local signal="$1"
  if [[ "${SERVE_SHUTDOWN_REQUESTED:-0}" == "1" ]]; then
    return 0
  fi
  SERVE_SHUTDOWN_REQUESTED=1
  SERVE_SHUTDOWN_DEADLINE=$((SECONDS + 90))
  warn "Foreground service mode received ${signal}; requesting a clean Supervisor shutdown."
  if supervisor_is_running && ! supervisor_ctl shutdown >/dev/null 2>&1; then
    warn "Supervisor did not accept the shutdown request; waiting for the outer runtime to stop it."
  fi
}

serve_ignore_hup() {
  warn "Foreground service mode ignored HUP; use TERM or INT for a clean shutdown."
}

monitor_supervisor_foreground() {
  local supervisor_pid=""
  local pid1_name="unknown"
  local pid1_start_ticks="unknown"
  local intentional_stop_logged=0

  supervisor_is_running \
    || die "Cannot enter foreground service mode because KiQuai supervisord is not running."
  supervisor_pid="$(<"${SUPERVISOR_PID}")"
  [[ ! -r /proc/1/comm ]] || pid1_name="$(</proc/1/comm)"
  [[ ! -r /proc/1/stat ]] \
    || pid1_start_ticks="$(awk '{print $22}' /proc/1/stat 2>/dev/null || printf 'unknown')"

  CURRENT_STAGE="serve:foreground-monitor"
  DEPLOYMENT_COMPLETE=0
  SERVE_SHUTDOWN_REQUESTED=0
  SERVE_SHUTDOWN_DEADLINE=0
  trap 'serve_request_shutdown INT' INT
  trap 'serve_request_shutdown TERM' TERM
  trap 'serve_ignore_hup' HUP

  success "Foreground service mode is active (keeper_pid=$$, supervisor_pid=${supervisor_pid}, pid1=${pid1_name}, pid1_start_ticks=${pid1_start_ticks})."
  info "The operation lock was released; status/logs/diagnostics remain available from another terminal."

  while :; do
    if supervisor_is_running; then
      if [[ "${SERVE_SHUTDOWN_REQUESTED}" == "1" ]] \
          && (( SECONDS >= SERVE_SHUTDOWN_DEADLINE )); then
        die "KiQuai supervisord did not stop within 90 seconds after the shutdown signal."
      fi
      intentional_stop_logged=0
    elif [[ "${SERVE_SHUTDOWN_REQUESTED}" == "1" ]]; then
      success "KiQuai Supervisor and all managed processes stopped cleanly."
      return 0
    elif [[ -f "${SERVE_STOP_MARKER}" ]]; then
      if [[ "${intentional_stop_logged}" == "0" ]]; then
        warn "Managed services were stopped intentionally; foreground keeper remains active. Run './run.sh restart' to reconcile them or stop the Vast instance to end the container."
        intentional_stop_logged=1
      fi
    else
      die "KiQuai supervisord exited unexpectedly while foreground service mode was active."
    fi
    sleep 2 || true
  done
}

command_serve() {
  acquire_serve_lock
  deploy
  release_lock
  monitor_supervisor_foreground
}

command_agent_start() {
  local voucher="${1-}"
  require_existing_installation
  acquire_lock
  if [[ -n "${voucher}" ]]; then
    if agent_registration_is_complete; then
      warn "An existing agent registration is present; the supplied voucher is ignored. Remove config.json only when intentionally re-registering this agent."
      AGENT_VOUCHER=""
    else
      AGENT_VOUCHER="${voucher}"
    fi
  fi
  if ! agent_registration_is_complete && [[ -z "${AGENT_VOUCHER}" ]]; then
    die "Provide a voucher: ./run.sh agent-start YOUR_VOUCHER"
  fi
  AGENT_ENABLED=1
  validate_config
  write_dotenv
  printf '%s\n' "${RUN_ID}" > "${RUN_DIR}/current-run-id"
  chmod 600 "${RUN_DIR}/current-run-id"
  if ! supervisor_is_running || ! check_http_contract; then
    warn "The web stack is not healthy; reconciling it before starting the agent."
    quiesce_application_services
    start_or_reload_supervisor
    restart_or_start_supervisor_program mysql 180
    wait_for_mysql
    provision_database
    run_backend_setup
    start_web_services_after_migration
  fi
  wait_for_http
  configure_task_dispatch_policy
  download_agent
  reconcile_agent_process
}

command_agent_stop() {
  local output=""
  require_existing_installation
  acquire_lock
  AGENT_ENABLED=0
  write_dotenv
  stop_supervisor_program_if_active agent
  if supervisor_is_running; then
    write_supervisor_config
    if ! output="$(supervisor_ctl reread 2>&1)"; then
      [[ -n "${output}" ]] && printf '%s\n' "${output}" >&2
      die "Supervisor could not reread the disabled agent configuration."
    fi
    if ! output="$(supervisor_ctl update 2>&1)"; then
      [[ -n "${output}" ]] && printf '%s\n' "${output}" >&2
      die "Supervisor could not apply the disabled agent configuration."
    fi
  fi
  success "The local agent is stopped and disabled; its registration data was preserved."
}

deploy() {
  acquire_lock
  print_header

  if [[ "${AGENT_ENABLED}" == "1" && -z "${AGENT_VOUCHER}" ]] \
      && ! agent_registration_is_complete; then
    die "AGENT_ENABLED=1 requires AGENT_VOUCHER unless config.json contains a completed registration token."
  fi

  begin_step "Preflight: root, disk, and NVIDIA GPU"
  validate_outer_runtime
  end_step

  begin_step "Install native service and build dependencies"
  install_packages
  end_step

  begin_step "Prepare persistent single-container layout"
  wipe_data_if_requested
  prepare_layout
  rm -f "${SERVE_STOP_MARKER}"
  stop_legacy_dind_runtime
  archive_legacy_dind_config
  validate_service_ports
  write_dotenv
  print_runtime_summary
  end_step

  begin_step "Validate Hashcat GPU backend"
  configure_nvidia_runtime
  validate_hashcat
  end_step

  begin_step "Install Hashtopolis migration tooling"
  install_sqlx
  end_step

  begin_step "Build matching backend and frontend releases"
  build_server_release
  build_frontend_release
  end_step

  begin_step "Quiesce, activate releases, and generate validated configuration"
  quiesce_application_services
  activate_releases
  printf '%s\n' "${RUN_ID}" > "${RUN_DIR}/current-run-id"
  chmod 600 "${RUN_DIR}/current-run-id"
  write_runtime_configs
  initialize_mysql_data
  end_step

  begin_step "Provision MySQL, run migrations once, then start web services"
  start_or_reload_supervisor
  restart_or_start_supervisor_program mysql 180
  wait_for_mysql
  provision_database
  run_backend_setup
  configure_task_dispatch_policy
  start_web_services_after_migration
  end_step

  begin_step "Verify HTTP routes and install the Python agent"
  wait_for_http
  download_agent
  reconcile_agent_process
  end_step

  begin_step "Final status"
  print_success
  end_step
  DEPLOYMENT_COMPLETE=1
}

resolve_cli_command() {
  local requested="${1-}"
  if [[ -n "${requested}" ]]; then
    printf '%s\n' "${requested}"
    return 0
  fi
  if [[ -t 0 ]] && {
      [[ "${KIQUAI_CONSOLE_FD:-}" == "3" && -t 3 ]] || [[ -t 1 ]];
    }; then
    printf 'deploy\n'
  else
    printf 'serve\n'
  fi
}

main() {
  local command=""
  command="$(resolve_cli_command "${1-}")"
  case "${command}" in
    help|-h|--help)
      usage
      return 0
      ;;
    deploy|serve|preflight|status|logs|diagnostics|credentials|stop|restart|agent-start|agent-stop)
      ;;
    *)
      usage >&2
      printf '\nUnknown command: %s\n' "${command}" >&2
      return 2
      ;;
  esac

  CURRENT_COMMAND="${command}"
  CURRENT_STAGE="command:${command}"
  CURRENT_MODULE="50-cli.sh"
  RUN_ID="${KIQUAI_RUN_ID:-$(date '+%Y%m%dT%H%M%S%z')-$$}"
  require_root
  load_saved_config
  apply_defaults
  resolve_public_url
  resolve_credentials
  validate_config
  mkdir -p "${LOG_DIR}"
  init_logging
  install_traps
  info "Starting command '${command}' with KiQuai ${SCRIPT_VERSION}."

  case "${command}" in
    deploy) deploy ;;
    serve) command_serve ;;
    preflight) command_preflight ;;
    status) command_status ;;
    logs) command_logs ;;
    diagnostics) command_diagnostics ;;
    credentials) command_credentials ;;
    stop) command_stop ;;
    restart)
      deploy
      ;;
    agent-start) command_agent_start "${2-}" ;;
    agent-stop) command_agent_stop ;;
  esac
}
