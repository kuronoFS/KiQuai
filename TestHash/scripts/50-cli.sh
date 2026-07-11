#!/usr/bin/env bash
# shellcheck shell=bash
# KiQuai module: cli
# kiquai-module-api: 1
# kiquai-release: 3.2.0

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
    printf '\n===== Bounded logs =====\n'
    local log
    for log in migration.log mysql.log mysql-supervisor.log backend.log apache-error.log nginx-error.log nginx-supervisor.log agent.log supervisord.log bootstrap.log loader.log; do
      printf '\n--- %s ---\n' "${log}"
      tail -n 160 "${LOG_DIR}/${log}" 2>&1 || true
    done
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
copied into loader.log or bootstrap.log.
EOF
}

print_credentials_to_console() {
  if [[ "${KIQUAI_CONSOLE_FD:-}" == "3" && -e /proc/self/fd/3 ]]; then
    _print_credentials_body >&3
  else
    warn "The private console descriptor is unavailable; credential output may be captured by the caller."
    _print_credentials_body
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
    [[ -s "${AGENT_DIR}/config.json" ]] \
      || die "AGENT_ENABLED=1 but the local agent has no completed config.json registration."
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
EOF
  print_credentials_to_console
}

require_existing_installation() {
  [[ -f "${ENV_FILE}" && -f "${SUPERVISOR_CONFIG}" ]] \
    || die "No single-container installation exists under ${APP_DIR}; run './run.sh deploy' first."
}

usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Usage:
  ./run.sh                         Deploy or reconcile everything
  ./run.sh deploy                  Same as above
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
  PUBLIC_URL=http://IP:PORT ./run.sh
  APP_DIR=/data/kiquai-hashtopolis ./run.sh
  FORCE_REBUILD=1 ./run.sh
  WIPE_DATA=1 ./run.sh
  REQUIRE_HASHCAT_GPU=0 ./run.sh
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
  local log
  for log in migration.log mysql.log mysql-supervisor.log backend.log apache-error.log nginx-error.log nginx-supervisor.log agent.log supervisord.log bootstrap.log loader.log; do
    printf '\n===== %s =====\n' "${log}"
    tail -n 220 "${LOG_DIR}/${log}" 2>/dev/null || true
  done
}

command_diagnostics() {
  collect_diagnostics
  success "Diagnostic report created: ${LAST_DIAGNOSTIC_FILE}"
}

command_stop() {
  require_existing_installation
  acquire_lock
  stop_managed_services
  success "All KiQuai services stopped. Database and files were preserved."
}

command_agent_start() {
  local voucher="${1-}"
  require_existing_installation
  acquire_lock
  if [[ -n "${voucher}" ]]; then
    AGENT_VOUCHER="${voucher}"
  fi
  if [[ ! -s "${AGENT_DIR}/config.json" && -z "${AGENT_VOUCHER}" ]]; then
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
  download_agent
  reconcile_agent_process
}

command_agent_stop() {
  require_existing_installation
  acquire_lock
  AGENT_ENABLED=0
  write_dotenv
  if supervisor_is_running; then
    supervisor_ctl stop agent >/dev/null 2>&1 || true
    write_supervisor_config
    supervisor_ctl reread
    supervisor_ctl update
  fi
  success "The local agent is stopped and disabled; its registration data was preserved."
}

deploy() {
  acquire_lock
  print_header

  if [[ "${AGENT_ENABLED}" == "1" && -z "${AGENT_VOUCHER}" && ! -s "${AGENT_DIR}/config.json" ]]; then
    die "AGENT_ENABLED=1 requires AGENT_VOUCHER unless an existing agent/config.json is present."
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

main() {
  local command="${1:-deploy}"
  case "${command}" in
    help|-h|--help)
      usage
      return 0
      ;;
    deploy|preflight|status|logs|diagnostics|credentials|stop|restart|agent-start|agent-stop)
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
