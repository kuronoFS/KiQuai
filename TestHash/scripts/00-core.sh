#!/usr/bin/env bash
# shellcheck shell=bash
# KiQuai module: core
# kiquai-module-api: 1
# kiquai-release: 3.2.4

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

if [[ "${KIQUAI_MODULE_CONTEXT:-0}" != "1" ]]; then
  printf 'This file is a KiQuai module; run ../run.sh instead.\n' >&2
  return 64 2>/dev/null || exit 64
fi


# KiQuai Hashtopolis + Hashcat bootstrap for a single Vast.ai container.
#
# Architecture:
#   Vast.ai CUDA container
#     - MySQL bound to 127.0.0.1
#     - Apache/PHP Hashtopolis backend bound to 127.0.0.1
#     - Nginx serving the frontend and proxying backend routes on 0.0.0.0
#     - Optional Hashtopolis Python agent using the same container and GPU
#
# This script intentionally does not install or start Docker, dockerd, Compose,
# containerd, a nested network namespace, or a socat port forwarder.

readonly SCRIPT_VERSION="3.2.4"
readonly SCRIPT_NAME="KiQuai Hashtopolis modular single-container bootstrap"
readonly TOTAL_STEPS=10
readonly SQLX_CLI_VERSION="0.9.0"
readonly RUST_TOOLCHAIN_VERSION="1.94.0"

umask 077
export DEBIAN_FRONTEND=noninteractive

declare -A CALLER_SET=()
for _name in \
  INTERNAL_PORT BACKEND_PORT DB_PORT PUBLIC_URL \
  HASHTOPOLIS_VERSION HASHTOPOLIS_FRONTEND_VERSION \
  HASHTOPOLIS_SERVER_REPOSITORY HASHTOPOLIS_FRONTEND_REPOSITORY \
  MYSQL_ROOT_PASS MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD \
  HASHTOPOLIS_ADMIN_USER HASHTOPOLIS_ADMIN_PASSWORD \
  HASHTOPOLIS_BACKEND_URL HASHTOPOLIS_FRONTEND_PORT \
  AGENT_ENABLED AGENT_VOUCHER AGENT_DOWNLOAD_URL \
  HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO REQUIRE_HASHCAT_GPU; do
  if [[ -v ${_name} ]]; then
    CALLER_SET["${_name}"]=1
  else
    CALLER_SET["${_name}"]=0
  fi
done
unset _name

APP_DIR="${APP_DIR:-/opt/kiquai-hashtopolis}"
LOG_DIR="${LOG_DIR:-/var/log/kiquai-hashtopolis}"
LOCK_FILE="${LOCK_FILE:-/var/lock/kiquai-hashtopolis.lock}"

INTERNAL_PORT="${INTERNAL_PORT-}"
BACKEND_PORT="${BACKEND_PORT-}"
DB_PORT="${DB_PORT-}"
PUBLIC_URL="${PUBLIC_URL-}"
PUBLIC_IP=""
PUBLIC_PORT=""

HASHTOPOLIS_VERSION="${HASHTOPOLIS_VERSION-}"
HASHTOPOLIS_FRONTEND_VERSION="${HASHTOPOLIS_FRONTEND_VERSION-}"
HASHTOPOLIS_SERVER_REPOSITORY="${HASHTOPOLIS_SERVER_REPOSITORY-}"
HASHTOPOLIS_FRONTEND_REPOSITORY="${HASHTOPOLIS_FRONTEND_REPOSITORY-}"

MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS-}"
MYSQL_DATABASE="${MYSQL_DATABASE-}"
MYSQL_USER="${MYSQL_USER-}"
MYSQL_PASSWORD="${MYSQL_PASSWORD-}"
HASHTOPOLIS_ADMIN_USER="${HASHTOPOLIS_ADMIN_USER-}"
HASHTOPOLIS_ADMIN_PASSWORD="${HASHTOPOLIS_ADMIN_PASSWORD-}"
HASHTOPOLIS_BACKEND_URL="${HASHTOPOLIS_BACKEND_URL-}"
HASHTOPOLIS_FRONTEND_PORT="${HASHTOPOLIS_FRONTEND_PORT-}"

AGENT_ENABLED="${AGENT_ENABLED-}"
AGENT_VOUCHER="${AGENT_VOUCHER-}"
AGENT_DOWNLOAD_URL="${AGENT_DOWNLOAD_URL-}"
HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO="${HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO-}"

WIPE_DATA="${WIPE_DATA:-0}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
SKIP_APT="${SKIP_APT:-0}"
REQUIRE_HASHCAT_GPU="${REQUIRE_HASHCAT_GPU:-1}"
KEEP_BUILD_TOOLCHAINS="${KEEP_BUILD_TOOLCHAINS:-0}"
DIAGNOSTICS_ON_FAILURE="${DIAGNOSTICS_ON_FAILURE:-1}"
FORCE_COLOR="${FORCE_COLOR:-0}"
MIN_FREE_GB="${MIN_FREE_GB:-10}"

MAIN_LOG="${MAIN_LOG:-${LOG_DIR}/bootstrap.log}"
HASHCAT_LOG="${HASHCAT_LOG:-${LOG_DIR}/hashcat-devices.log}"

ENV_FILE=""
CONFIG_DIR=""
DATA_DIR=""
RELEASES_DIR=""
CURRENT_DIR=""
TOOLS_DIR=""
RUN_DIR=""
AGENT_DIR=""
MYSQL_DATA_DIR=""
MYSQL_RUN_DIR=""
HASHTOPOLIS_DATA_DIR=""
SUPERVISOR_CONFIG=""
SUPERVISOR_SOCKET=""
SUPERVISOR_PID=""
SERVER_CURRENT=""
FRONTEND_CURRENT=""
MYSQL_CONFIG=""
NGINX_CONFIG=""
RUNTIME_ENV_FILE=""
BACKEND_READY_FILE=""
MIGRATION_LOG=""
SERVE_STOP_MARKER=""
SERVER_RELEASE_TARGET=""
FRONTEND_RELEASE_TARGET=""

CURRENT_STEP=0
CURRENT_STAGE="initialization"
CURRENT_COMMAND=""
STAGE_STARTED_AT=0
SCRIPT_STARTED_AT=$SECONDS
RUN_ID=""
DEPLOYMENT_COMPLETE=0
LAST_ERROR_MODULE=""
LAST_ERROR_SOURCE=""
LAST_ERROR_LINE=""
LAST_ERROR_FUNCTION=""
LAST_ERROR_CALLER_SOURCE=""
LAST_ERROR_CALLER_LINE=""
LAST_ERROR_CALLER_FUNCTION=""
LAST_ERROR_COMMAND=""
LAST_ERROR_MESSAGE=""
LAST_DIAGNOSTIC_FILE=""
POLICY_RC_CREATED=0
OPERATION_LOCK_HELD=0
CURRENT_MODULE="00-core.sh"

if [[ -t 1 || "${FORCE_COLOR}" == "1" ]] && [[ -z "${NO_COLOR-}" ]]; then
  USE_COLOR=1
else
  USE_COLOR=0
fi

if [[ "${USE_COLOR}" == "1" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_BLUE=$'\033[1;34m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'
  C_GRAY=$'\033[0;37m'
else
  C_RESET=""
  C_BOLD=""
  C_BLUE=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_GRAY=""
fi

timestamp() {
  date '+%Y-%m-%d %H:%M:%S%z'
}

_log() {
  local level="$1"
  local color="$2"
  local source="${BASH_SOURCE[1]:-unknown}"
  local module="${source##*/}"
  local candidate
  for candidate in "${BASH_SOURCE[@]:1}"; do
    module="${candidate##*/}"
    if [[ "${module}" != "00-core.sh" && "${module}" != "run.sh" ]]; then
      source="${candidate}"
      break
    fi
  done
  module="${source##*/}"
  shift 2
  printf '%s[%s] %-5s%s [run=%s] [module=%s] %s\n' \
    "${color}" "$(timestamp)" "${level}" "${C_RESET}" \
    "${RUN_ID:-not-started}" "${module}" "$*"
}

info()    { _log INFO  "${C_BLUE}" "$@"; }
success() { _log OK    "${C_GREEN}" "$@"; }
warn()    { _log WARN  "${C_YELLOW}" "$@" >&2; }
error()   { _log ERROR "${C_RED}" "$@" >&2; }
debug() {
  if [[ "${DEBUG:-0}" == "1" ]]; then
    _log DEBUG "${C_GRAY}" "$@"
  fi
}

print_rule() {
  printf '%s%s%s\n' "${C_BLUE}" '======================================================================' "${C_RESET}"
}

begin_step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  CURRENT_STAGE="$1"
  CURRENT_MODULE="${BASH_SOURCE[1]##*/}"
  STAGE_STARTED_AT=$SECONDS
  printf '\n'
  print_rule
  printf '%s[%02d/%02d] [%s] %s%s\n' \
    "${C_BOLD}" "${CURRENT_STEP}" "${TOTAL_STEPS}" \
    "${CURRENT_MODULE}" "${CURRENT_STAGE}" "${C_RESET}"
  print_rule
}

end_step() {
  success "Completed '${CURRENT_STAGE}' in $((SECONDS - STAGE_STARTED_AT))s"
}

die() {
  LAST_ERROR_MESSAGE="$*"
  LAST_ERROR_SOURCE="${BASH_SOURCE[1]:-unknown}"
  LAST_ERROR_MODULE="${LAST_ERROR_SOURCE##*/}"
  LAST_ERROR_LINE="${BASH_LINENO[0]:-unknown}"
  LAST_ERROR_FUNCTION="${FUNCNAME[1]:-unknown}"
  LAST_ERROR_CALLER_SOURCE=""
  LAST_ERROR_CALLER_LINE=""
  LAST_ERROR_CALLER_FUNCTION=""
  LAST_ERROR_COMMAND="die: $*"
  error "$*"
  exit 1
}

record_error() {
  local code="$1"
  local line="$2"
  local command="$3"
  local source="$4"
  local function_name="$5"
  local caller_source="$6"
  local caller_line="$7"
  local caller_function="$8"
  LAST_ERROR_SOURCE="${source}"
  LAST_ERROR_MODULE="${source##*/}"
  LAST_ERROR_LINE="${line}"
  LAST_ERROR_FUNCTION="${function_name}"
  LAST_ERROR_CALLER_SOURCE="${caller_source}"
  LAST_ERROR_CALLER_LINE="${caller_line}"
  LAST_ERROR_CALLER_FUNCTION="${caller_function}"
  LAST_ERROR_COMMAND="${command}"
  return 0
}

remove_temporary_policy() {
  if [[ "${POLICY_RC_CREATED}" == "1" ]]; then
    rm -f /usr/sbin/policy-rc.d 2>/dev/null || true
    POLICY_RC_CREATED=0
  fi
}

on_signal() {
  local signal="$1"
  LAST_ERROR_MESSAGE="Interrupted by ${signal}"
  LAST_ERROR_SOURCE="${BASH_SOURCE[1]:-unknown}"
  LAST_ERROR_MODULE="${LAST_ERROR_SOURCE##*/}"
  LAST_ERROR_LINE="${BASH_LINENO[0]:-unknown}"
  LAST_ERROR_FUNCTION="${FUNCNAME[1]:-unknown}"
  LAST_ERROR_COMMAND="signal ${signal}"
  error "Interrupted by ${signal}."
  exit 130
}

on_exit() {
  local code="$1"
  trap - ERR EXIT INT TERM HUP
  set +e
  remove_temporary_policy

  if (( code != 0 )); then
    printf '\n%s' "${C_RED}" >&2
    printf '%s\n' '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' >&2
    if [[ "${CURRENT_COMMAND}" == "deploy" || "${CURRENT_COMMAND}" == "restart" \
        || "${CURRENT_COMMAND}" == "serve" ]]; then
      printf 'DEPLOYMENT FAILED (exit=%s, stage=%s)\n' "${code}" "${CURRENT_STAGE}" >&2
    else
      printf 'COMMAND FAILED (command=%s, exit=%s, stage=%s)\n' \
        "${CURRENT_COMMAND:-unknown}" "${code}" "${CURRENT_STAGE}" >&2
    fi
    printf '%s\n' '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' >&2
    printf '%s' "${C_RESET}" >&2
    [[ -n "${LAST_ERROR_MESSAGE}" ]] && printf 'Reason : %s\n' "${LAST_ERROR_MESSAGE}" >&2
    [[ -n "${LAST_ERROR_MODULE}" ]] && printf 'Module : %s\n' "${LAST_ERROR_MODULE}" >&2
    [[ -n "${LAST_ERROR_SOURCE}" ]] && printf 'Source : %s\n' "${LAST_ERROR_SOURCE}" >&2
    [[ -n "${LAST_ERROR_LINE}" ]] && printf 'Line   : %s\n' "${LAST_ERROR_LINE}" >&2
    [[ -n "${LAST_ERROR_FUNCTION}" ]] && printf 'Function: %s\n' "${LAST_ERROR_FUNCTION}" >&2
    if [[ -n "${LAST_ERROR_CALLER_SOURCE}" && "${LAST_ERROR_CALLER_SOURCE}" != "${LAST_ERROR_SOURCE}" ]]; then
      printf 'Caller  : %s:%s (%s)\n' \
        "${LAST_ERROR_CALLER_SOURCE}" "${LAST_ERROR_CALLER_LINE:-unknown}" \
        "${LAST_ERROR_CALLER_FUNCTION:-unknown}" >&2
    fi
    [[ -n "${LAST_ERROR_COMMAND}" ]] && printf 'Command: %s\n' "${LAST_ERROR_COMMAND}" >&2
    [[ -n "${RUN_ID}" ]] && printf 'Run ID : %s\n' "${RUN_ID}" >&2
    printf 'Log    : %s\n' "${MAIN_LOG}" >&2
    printf 'Loader : %s\n' "${KIQUAI_LOADER_LOG:-not configured}" >&2
    if [[ "${DIAGNOSTICS_ON_FAILURE}" == "1" ]] && [[ -n "${APP_DIR}" ]]; then
      collect_diagnostics || true
      [[ -n "${LAST_DIAGNOSTIC_FILE}" ]] && printf 'Report : %s\n' "${LAST_DIAGNOSTIC_FILE}" >&2
    fi
  elif [[ "${DEPLOYMENT_COMPLETE}" == "1" ]]; then
    success "All deployment stages completed in $((SECONDS - SCRIPT_STARTED_AT))s"
  fi
  exit "${code}"
}

init_logging() {
  local pid1_name="unknown"
  local pid1_start_ticks="unknown"
  mkdir -p "${LOG_DIR}"
  # Service log files have their own restrictive modes. The directory needs
  # execute-only traversal for the mysql user.
  chmod 711 "${LOG_DIR}" 2>/dev/null || true
  if [[ -f "${MAIN_LOG}" ]] && [[ $(stat -c '%s' "${MAIN_LOG}" 2>/dev/null || echo 0) -gt 10485760 ]]; then
    mv -f "${MAIN_LOG}" "${MAIN_LOG}.1"
  fi
  touch "${MAIN_LOG}"
  chmod 600 "${MAIN_LOG}"
  exec > >(tee -a "${MAIN_LOG}") 2>&1
  [[ ! -r /proc/1/comm ]] || pid1_name="$(</proc/1/comm)"
  [[ ! -r /proc/1/stat ]] \
    || pid1_start_ticks="$(awk '{print $22}' /proc/1/stat 2>/dev/null || printf 'unknown')"
  printf '\n[%s] ===== KiQuai run start: run=%s command=%s version=%s pid=%s ppid=%s pid1=%s pid1_start_ticks=%s =====\n' \
    "$(timestamp)" "${RUN_ID}" "${CURRENT_COMMAND}" "${SCRIPT_VERSION}" \
    "$$" "${PPID}" "${pid1_name}" "${pid1_start_ticks}"
}

install_traps() {
  trap 'record_error "$?" "$LINENO" "$BASH_COMMAND" "${BASH_SOURCE[0]:-unknown}" "${FUNCNAME[0]:-main}" "${BASH_SOURCE[1]:-}" "${BASH_LINENO[0]:-}" "${FUNCNAME[1]:-}"' ERR
  trap 'on_exit "$?"' EXIT
  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM
  trap 'on_signal HUP' HUP
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  [[ "$(id -u)" == "0" ]] || die "Run this script as root inside the Vast.ai container."
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

validate_bool() {
  local name="$1" value="$2"
  [[ "${value}" == "0" || "${value}" == "1" ]] \
    || die "${name} must be 0 or 1; received '${value}'."
}

validate_port() {
  local name="$1" value="$2"
  is_uint "${value}" || die "${name} must be an integer from 1 to 65535."
  local numeric=$((10#${value}))
  (( numeric >= 1 && numeric <= 65535 )) || die "${name} must be from 1 to 65535."
  printf -v "${name}" '%d' "${numeric}"
}

validate_safe_absolute_path() {
  local name="$1" value="$2" canonical
  [[ "${value}" == /* ]] || die "${name} must be an absolute path."
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] \
    || die "${name} cannot contain newline characters."
  [[ "${value}" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || die "${name} contains unsupported characters."
  canonical="$(realpath -m -- "${value}")"
  case "${canonical}" in
    /|/bin|/boot|/data|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/var/lib|/var/lock|/var/log|/var/run)
      die "Refusing unsafe ${name}='${value}'. Choose a dedicated subdirectory."
      ;;
  esac
  printf -v "${name}" '%s' "${canonical}"
}

retry() {
  local attempts="$1" delay="$2"
  shift 2
  local attempt rc
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if "$@"; then
      return 0
    else
      rc=$?
    fi
    if (( attempt == attempts )); then
      return "${rc}"
    fi
    warn "Command failed (attempt ${attempt}/${attempts}, exit ${rc}); retrying in ${delay}s."
    sleep "${delay}"
  done
}

rand_secret() {
  if have_cmd openssl; then
    openssl rand -hex 24
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

dotenv_get() {
  local key="$1" file="${2:-${APP_DIR}/.env}" value=""
  [[ -r "${file}" ]] || return 1
  value="$(awk -v key="${key}" '
    index($0, key "=") == 1 {
      sub(/^[^=]*=/, "", $0)
      print
      exit
    }
  ' "${file}")"
  [[ -n "${value}" ]] || return 1

  if [[ "${value}" == \'*\' && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
    value="${value//\\\'/\'}"
    value="${value//\\\\/\\}"
  elif [[ "${value}" == \"*\" && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "${value}"
}

dotenv_quote() {
  local value="$1"
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] \
    || die "Environment values cannot contain newline characters."
  [[ "${value}" != *"'"* && "${value}" != *"\\"* ]] \
    || die "Persisted environment values cannot contain a single quote or backslash."
  printf "'%s'" "${value}"
}

write_env_line() {
  local key="$1" value="$2" file="$3"
  printf '%s=%s\n' "${key}" "$(dotenv_quote "${value}")" >> "${file}"
}

load_saved_config() {
  [[ "${WIPE_DATA}" == "0" ]] || return 0
  local name saved
  for name in \
    INTERNAL_PORT BACKEND_PORT DB_PORT PUBLIC_URL \
    HASHTOPOLIS_VERSION HASHTOPOLIS_FRONTEND_VERSION \
    HASHTOPOLIS_SERVER_REPOSITORY HASHTOPOLIS_FRONTEND_REPOSITORY \
    MYSQL_ROOT_PASS MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD \
    HASHTOPOLIS_ADMIN_USER HASHTOPOLIS_ADMIN_PASSWORD \
    HASHTOPOLIS_BACKEND_URL HASHTOPOLIS_FRONTEND_PORT \
    AGENT_ENABLED AGENT_VOUCHER AGENT_DOWNLOAD_URL \
    HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO REQUIRE_HASHCAT_GPU; do
    if [[ "${CALLER_SET[${name}]:-0}" == "0" ]]; then
      saved="$(dotenv_get "${name}" "${APP_DIR}/.env" 2>/dev/null || true)"
      if [[ -n "${saved}" ]]; then
        printf -v "${name}" '%s' "${saved}"
      fi
    fi
  done
}

apply_defaults() {
  INTERNAL_PORT="${INTERNAL_PORT:-8080}"
  BACKEND_PORT="${BACKEND_PORT:-18080}"
  DB_PORT="${DB_PORT:-13306}"
  HASHTOPOLIS_VERSION="${HASHTOPOLIS_VERSION:-v1.0.0-rc2}"
  HASHTOPOLIS_FRONTEND_VERSION="${HASHTOPOLIS_FRONTEND_VERSION:-${HASHTOPOLIS_VERSION}}"
  HASHTOPOLIS_SERVER_REPOSITORY="${HASHTOPOLIS_SERVER_REPOSITORY:-https://github.com/hashtopolis/server.git}"
  HASHTOPOLIS_FRONTEND_REPOSITORY="${HASHTOPOLIS_FRONTEND_REPOSITORY:-https://github.com/hashtopolis/web-ui.git}"

  MYSQL_DATABASE="${MYSQL_DATABASE:-hashtopolis}"
  MYSQL_USER="${MYSQL_USER:-hashtopolis}"
  HASHTOPOLIS_ADMIN_USER="${HASHTOPOLIS_ADMIN_USER:-admin}"
  AGENT_ENABLED="${AGENT_ENABLED:-0}"
  AGENT_DOWNLOAD_URL="${AGENT_DOWNLOAD_URL-}"
  HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO="${HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO:-1}"

  ENV_FILE="${APP_DIR}/.env"
  CONFIG_DIR="${APP_DIR}/config"
  DATA_DIR="${APP_DIR}/data"
  RELEASES_DIR="${APP_DIR}/releases"
  CURRENT_DIR="${APP_DIR}/current"
  TOOLS_DIR="${APP_DIR}/tools"
  RUN_DIR="${APP_DIR}/run"
  AGENT_DIR="${APP_DIR}/agent"
  MYSQL_DATA_DIR="${DATA_DIR}/mysql"
  MYSQL_RUN_DIR="${RUN_DIR}/mysql"
  HASHTOPOLIS_DATA_DIR="${DATA_DIR}/hashtopolis"
  SUPERVISOR_CONFIG="${CONFIG_DIR}/supervisord.conf"
  SUPERVISOR_SOCKET="${RUN_DIR}/supervisor.sock"
  SUPERVISOR_PID="${RUN_DIR}/supervisord.pid"
  SERVER_CURRENT="${CURRENT_DIR}/server"
  FRONTEND_CURRENT="${CURRENT_DIR}/frontend"
  MYSQL_CONFIG="${CONFIG_DIR}/mysql.cnf"
  NGINX_CONFIG="${CONFIG_DIR}/nginx.conf"
  RUNTIME_ENV_FILE="${CONFIG_DIR}/runtime-env.sh"
  BACKEND_READY_FILE="${RUN_DIR}/backend-ready"
  MIGRATION_LOG="${LOG_DIR}/migration.log"
  SERVE_STOP_MARKER="${RUN_DIR}/serve-services-stopped"
}

resolve_public_url() {
  local port_var detected_port scheme authority effective_port
  port_var="VAST_TCP_PORT_${INTERNAL_PORT}"
  detected_port="${!port_var-}"
  PUBLIC_IP="${PUBLIC_IPADDR-}"
  PUBLIC_PORT="${detected_port:-${INTERNAL_PORT}}"

  if [[ -z "${PUBLIC_URL}" ]]; then
    if [[ -z "${PUBLIC_IP}" ]] && have_cmd curl; then
      PUBLIC_IP="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    fi
    if [[ -z "${PUBLIC_IP}" ]]; then
      PUBLIC_IP="127.0.0.1"
      warn "PUBLIC_IPADDR is unavailable. Set PUBLIC_URL if this is a public deployment."
    fi
    PUBLIC_URL="http://${PUBLIC_IP}:${PUBLIC_PORT}"
    if [[ -z "${detected_port}" ]]; then
      warn "${port_var} is not set; verify the public URL shown after deployment."
    fi
  fi
  PUBLIC_URL="${PUBLIC_URL%/}"

  scheme="${PUBLIC_URL%%://*}"
  authority="${PUBLIC_URL#*://}"
  authority="${authority%%/*}"
  if [[ "${authority}" =~ \]:([0-9]+)$ ]]; then
    effective_port="${BASH_REMATCH[1]}"
  elif [[ "${authority}" =~ :([0-9]+)$ ]]; then
    effective_port="${BASH_REMATCH[1]}"
  elif [[ "${scheme}" == "https" ]]; then
    effective_port=443
  else
    effective_port=80
  fi
  PUBLIC_PORT="${effective_port}"
}

resolve_credentials() {
  [[ -n "${MYSQL_ROOT_PASS}" ]] || MYSQL_ROOT_PASS="$(rand_secret)"
  [[ -n "${MYSQL_PASSWORD}" ]] || MYSQL_PASSWORD="$(rand_secret)"
  [[ -n "${HASHTOPOLIS_ADMIN_PASSWORD}" ]] || HASHTOPOLIS_ADMIN_PASSWORD="$(rand_secret)"
  if [[ "${CALLER_SET[PUBLIC_URL]:-0}" == "1" && "${CALLER_SET[HASHTOPOLIS_BACKEND_URL]:-0}" == "0" ]]; then
    HASHTOPOLIS_BACKEND_URL="${PUBLIC_URL}/api/v2"
  elif [[ -z "${HASHTOPOLIS_BACKEND_URL}" ]]; then
    HASHTOPOLIS_BACKEND_URL="${PUBLIC_URL}/api/v2"
  fi
  if [[ "${CALLER_SET[PUBLIC_URL]:-0}" == "1" && "${CALLER_SET[HASHTOPOLIS_FRONTEND_PORT]:-0}" == "0" ]]; then
    HASHTOPOLIS_FRONTEND_PORT="${PUBLIC_PORT}"
  elif [[ -z "${HASHTOPOLIS_FRONTEND_PORT}" ]]; then
    HASHTOPOLIS_FRONTEND_PORT="${PUBLIC_PORT}"
  fi
  if [[ -n "${AGENT_VOUCHER}" ]]; then
    AGENT_ENABLED=1
  fi
}

validate_config() {
  validate_safe_absolute_path APP_DIR "${APP_DIR}"
  validate_safe_absolute_path LOG_DIR "${LOG_DIR}"
  case "${LOG_DIR}" in
    "${APP_DIR}"|"${APP_DIR}/"*)
      die "LOG_DIR must be outside APP_DIR so WIPE_DATA cannot unlink active logs."
      ;;
  esac
  validate_port INTERNAL_PORT "${INTERNAL_PORT}"
  validate_port BACKEND_PORT "${BACKEND_PORT}"
  validate_port DB_PORT "${DB_PORT}"
  validate_port HASHTOPOLIS_FRONTEND_PORT "${HASHTOPOLIS_FRONTEND_PORT}"
  [[ "${INTERNAL_PORT}" != "${BACKEND_PORT}" && "${INTERNAL_PORT}" != "${DB_PORT}" && "${BACKEND_PORT}" != "${DB_PORT}" ]] \
    || die "INTERNAL_PORT, BACKEND_PORT, and DB_PORT must be different."

  validate_bool WIPE_DATA "${WIPE_DATA}"
  validate_bool FORCE_REBUILD "${FORCE_REBUILD}"
  validate_bool SKIP_APT "${SKIP_APT}"
  validate_bool REQUIRE_HASHCAT_GPU "${REQUIRE_HASHCAT_GPU}"
  validate_bool KEEP_BUILD_TOOLCHAINS "${KEEP_BUILD_TOOLCHAINS}"
  validate_bool DIAGNOSTICS_ON_FAILURE "${DIAGNOSTICS_ON_FAILURE}"
  validate_bool AGENT_ENABLED "${AGENT_ENABLED}"
  validate_bool HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO "${HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO}"

  is_uint "${MIN_FREE_GB}" || die "MIN_FREE_GB must be a non-negative integer."
  [[ "${HASHTOPOLIS_VERSION}" =~ ^v[A-Za-z0-9._-]+$ ]] \
    || die "HASHTOPOLIS_VERSION is not a safe Git tag."
  [[ "${HASHTOPOLIS_FRONTEND_VERSION}" =~ ^v[A-Za-z0-9._-]+$ ]] \
    || die "HASHTOPOLIS_FRONTEND_VERSION is not a safe Git tag."
  [[ "${MYSQL_DATABASE}" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] \
    || die "MYSQL_DATABASE must start with a letter and contain only letters, numbers, or underscore."
  [[ "${MYSQL_USER}" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] \
    || die "MYSQL_USER must start with a letter and contain only letters, numbers, or underscore."
  [[ "${MYSQL_ROOT_PASS}" =~ ^[A-Za-z0-9_.:@%+=,-]+$ ]] \
    || die "MYSQL_ROOT_PASS contains unsupported characters."
  [[ "${MYSQL_PASSWORD}" =~ ^[A-Za-z0-9_.:@%+=,-]+$ ]] \
    || die "MYSQL_PASSWORD contains unsupported characters."
  [[ -n "${HASHTOPOLIS_ADMIN_USER}" && "${HASHTOPOLIS_ADMIN_USER}" != *$'\n'* ]] \
    || die "HASHTOPOLIS_ADMIN_USER is invalid."
  [[ -n "${HASHTOPOLIS_ADMIN_PASSWORD}" && "${HASHTOPOLIS_ADMIN_PASSWORD}" != *$'\n'* ]] \
    || die "HASHTOPOLIS_ADMIN_PASSWORD is invalid."
  [[ "${PUBLIC_URL}" =~ ^https?://[^/[:space:]]+$ ]] \
    || die "PUBLIC_URL must be an HTTP or HTTPS origin without a path."
  [[ "${HASHTOPOLIS_BACKEND_URL}" =~ ^https?://[^/[:space:]]+/api/v2$ ]] \
    || die "HASHTOPOLIS_BACKEND_URL must be an HTTP(S) URL ending in /api/v2."
  [[ "${HASHTOPOLIS_BACKEND_URL}" != *\"* && "${HASHTOPOLIS_BACKEND_URL}" != *"'"* ]] \
    || die "HASHTOPOLIS_BACKEND_URL contains unsupported quote characters."
  [[ -z "${AGENT_VOUCHER}" || "${AGENT_VOUCHER}" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "AGENT_VOUCHER contains unsupported characters."

  [[ "${MAIN_LOG}" == "${LOG_DIR}/"* ]] \
    || die "MAIN_LOG must be a file below LOG_DIR."
  [[ "${HASHCAT_LOG}" == "${LOG_DIR}/"* ]] \
    || die "HASHCAT_LOG must be a file below LOG_DIR."
  [[ "${MAIN_LOG}" =~ ^/[A-Za-z0-9._/-]+$ && "${HASHCAT_LOG}" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || die "Log file paths contain unsupported characters."
  [[ "${LOCK_FILE}" == /* && "${LOCK_FILE}" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || die "LOCK_FILE must be a safe absolute path."
  case "${LOCK_FILE}" in
    /var/lock/*|"${RUN_DIR}/"*) ;;
    *) die "LOCK_FILE must be below /var/lock or RUN_DIR." ;;
  esac
}

write_dotenv() {
  local temp="${ENV_FILE}.tmp.$$"
  : > "${temp}"
  write_env_line SCRIPT_VERSION "${SCRIPT_VERSION}" "${temp}"
  write_env_line APP_DIR "${APP_DIR}" "${temp}"
  write_env_line INTERNAL_PORT "${INTERNAL_PORT}" "${temp}"
  write_env_line BACKEND_PORT "${BACKEND_PORT}" "${temp}"
  write_env_line DB_PORT "${DB_PORT}" "${temp}"
  write_env_line PUBLIC_URL "${PUBLIC_URL}" "${temp}"
  write_env_line PUBLIC_PORT "${PUBLIC_PORT}" "${temp}"
  write_env_line HASHTOPOLIS_VERSION "${HASHTOPOLIS_VERSION}" "${temp}"
  write_env_line HASHTOPOLIS_FRONTEND_VERSION "${HASHTOPOLIS_FRONTEND_VERSION}" "${temp}"
  write_env_line HASHTOPOLIS_SERVER_REPOSITORY "${HASHTOPOLIS_SERVER_REPOSITORY}" "${temp}"
  write_env_line HASHTOPOLIS_FRONTEND_REPOSITORY "${HASHTOPOLIS_FRONTEND_REPOSITORY}" "${temp}"
  write_env_line MYSQL_ROOT_PASS "${MYSQL_ROOT_PASS}" "${temp}"
  write_env_line MYSQL_DATABASE "${MYSQL_DATABASE}" "${temp}"
  write_env_line MYSQL_USER "${MYSQL_USER}" "${temp}"
  write_env_line MYSQL_PASSWORD "${MYSQL_PASSWORD}" "${temp}"
  write_env_line HASHTOPOLIS_ADMIN_USER "${HASHTOPOLIS_ADMIN_USER}" "${temp}"
  write_env_line HASHTOPOLIS_ADMIN_PASSWORD "${HASHTOPOLIS_ADMIN_PASSWORD}" "${temp}"
  write_env_line HASHTOPOLIS_BACKEND_URL "${HASHTOPOLIS_BACKEND_URL}" "${temp}"
  write_env_line HASHTOPOLIS_FRONTEND_PORT "${HASHTOPOLIS_FRONTEND_PORT}" "${temp}"
  write_env_line AGENT_ENABLED "${AGENT_ENABLED}" "${temp}"
  write_env_line AGENT_VOUCHER "${AGENT_VOUCHER}" "${temp}"
  write_env_line AGENT_DOWNLOAD_URL "${AGENT_DOWNLOAD_URL}" "${temp}"
  write_env_line HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO "${HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO}" "${temp}"
  write_env_line REQUIRE_HASHCAT_GPU "${REQUIRE_HASHCAT_GPU}" "${temp}"
  chmod 600 "${temp}"
  mv -f "${temp}" "${ENV_FILE}"
}
