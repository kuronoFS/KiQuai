#!/usr/bin/env bash
# shellcheck shell=bash

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

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

readonly SCRIPT_VERSION="3.0.0"
readonly SCRIPT_NAME="KiQuai Hashtopolis single-container bootstrap"
readonly TOTAL_STEPS=10

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
  AGENT_ENABLED AGENT_VOUCHER AGENT_DOWNLOAD_URL; do
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

CURRENT_STEP=0
CURRENT_STAGE="initialization"
STAGE_STARTED_AT=0
SCRIPT_STARTED_AT=$SECONDS
DEPLOYMENT_COMPLETE=0
LAST_ERROR_CODE=0
LAST_ERROR_LINE=""
LAST_ERROR_COMMAND=""
LAST_ERROR_MESSAGE=""
LAST_DIAGNOSTIC_FILE=""
POLICY_RC_CREATED=0

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
  local level="$1" color="$2"
  shift 2
  printf '%s[%s] %-5s%s %s\n' "${color}" "$(timestamp)" "${level}" "${C_RESET}" "$*"
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
  STAGE_STARTED_AT=$SECONDS
  printf '\n'
  print_rule
  printf '%s[%02d/%02d] %s%s\n' "${C_BOLD}" "${CURRENT_STEP}" "${TOTAL_STEPS}" "${CURRENT_STAGE}" "${C_RESET}"
  print_rule
}

end_step() {
  success "Completed '${CURRENT_STAGE}' in $((SECONDS - STAGE_STARTED_AT))s"
}

die() {
  LAST_ERROR_MESSAGE="$*"
  LAST_ERROR_CODE=1
  LAST_ERROR_LINE="${BASH_LINENO[0]:-unknown}"
  LAST_ERROR_COMMAND="${FUNCNAME[1]:-unknown}"
  error "$*"
  exit 1
}

record_error() {
  local code="$1" line="$2" command="$3"
  LAST_ERROR_CODE="${code}"
  LAST_ERROR_LINE="${line}"
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
    printf 'DEPLOYMENT FAILED (exit=%s, stage=%s)\n' "${code}" "${CURRENT_STAGE}" >&2
    printf '%s\n' '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' >&2
    printf '%s' "${C_RESET}" >&2
    [[ -n "${LAST_ERROR_MESSAGE}" ]] && printf 'Reason : %s\n' "${LAST_ERROR_MESSAGE}" >&2
    [[ -n "${LAST_ERROR_LINE}" ]] && printf 'Line   : %s\n' "${LAST_ERROR_LINE}" >&2
    [[ -n "${LAST_ERROR_COMMAND}" ]] && printf 'Command: %s\n' "${LAST_ERROR_COMMAND}" >&2
    printf 'Log    : %s\n' "${MAIN_LOG}" >&2
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
}

install_traps() {
  trap 'record_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
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
    AGENT_ENABLED AGENT_VOUCHER AGENT_DOWNLOAD_URL; do
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
}

resolve_public_url() {
  local port_var detected_port scheme authority effective_port
  port_var="VAST_TCP_PORT_${INTERNAL_PORT}"
  detected_port="${!port_var-}"
  PUBLIC_IP="${PUBLIC_IPADDR-}"
  PUBLIC_PORT="${detected_port:-${INTERNAL_PORT}}"

  if [[ -z "${PUBLIC_IP}" ]] && have_cmd curl; then
    PUBLIC_IP="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "${PUBLIC_IP}" ]]; then
    PUBLIC_IP="127.0.0.1"
    warn "PUBLIC_IPADDR is unavailable. Set PUBLIC_URL if this is a public deployment."
  fi
  if [[ -z "${PUBLIC_URL}" ]]; then
    PUBLIC_URL="http://${PUBLIC_IP}:${PUBLIC_PORT}"
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

  if [[ -z "${detected_port}" ]]; then
    warn "${port_var} is not set; verify the public URL shown after deployment."
  fi
}

resolve_credentials() {
  [[ -n "${MYSQL_ROOT_PASS}" ]] || MYSQL_ROOT_PASS="$(rand_secret)"
  [[ -n "${MYSQL_PASSWORD}" ]] || MYSQL_PASSWORD="$(rand_secret)"
  [[ -n "${HASHTOPOLIS_ADMIN_PASSWORD}" ]] || HASHTOPOLIS_ADMIN_PASSWORD="$(rand_secret)"
  [[ -n "${HASHTOPOLIS_BACKEND_URL}" ]] \
    || HASHTOPOLIS_BACKEND_URL="${PUBLIC_URL}/api/v2"
  [[ -n "${HASHTOPOLIS_FRONTEND_PORT}" ]] \
    || HASHTOPOLIS_FRONTEND_PORT="${PUBLIC_PORT}"
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
  [[ -z "${AGENT_VOUCHER}" || "${AGENT_VOUCHER}" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "AGENT_VOUCHER contains unsupported characters."
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
  chmod 600 "${temp}"
  mv -f "${temp}" "${ENV_FILE}"
}

acquire_lock() {
  mkdir -p "$(dirname "${LOCK_FILE}")"
  exec 9>"${LOCK_FILE}"
  flock -n 9 || die "Another KiQuai operation is already running."
}

print_header() {
  print_rule
  printf '%s%s v%s%s\n' "${C_BOLD}" "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${C_RESET}"
  printf 'Native services in the outer CUDA container; no Docker-in-Docker\n'
  print_rule
}

check_free_space() {
  local available_kb required_kb
  available_kb="$(df -Pk "$(dirname "${APP_DIR}")" | awk 'NR==2 {print $4}')"
  required_kb=$((MIN_FREE_GB * 1024 * 1024))
  if is_uint "${available_kb}" && (( available_kb < required_kb )); then
    die "At least ${MIN_FREE_GB} GiB free is required while building; only $((available_kb / 1024 / 1024)) GiB is available."
  fi
}

validate_outer_runtime() {
  [[ "$(uname -m)" == "x86_64" ]] \
    || die "This bootstrap currently supports x86_64 Vast.ai GPU instances only."
  have_cmd nvidia-smi || die "nvidia-smi is unavailable. Use an NVIDIA/CUDA Vast.ai image."
  nvidia-smi -L || die "The NVIDIA GPU is not exposed to the outer container."
  nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader
  check_free_space
  success "Outer-container preflight passed; no privileged DinD capabilities are required."
}

create_policy_rcd() {
  if [[ ! -e /usr/sbin/policy-rc.d ]]; then
    printf '%s\n' '#!/bin/sh' 'exit 101' > /usr/sbin/policy-rc.d
    chmod 755 /usr/sbin/policy-rc.d
    POLICY_RC_CREATED=1
  fi
}

install_packages() {
  if [[ "${SKIP_APT}" == "1" ]]; then
    local command
    for command in apache2ctl composer curl envsubst git hashcat jq mysql mysqladmin mysqld nginx openssl php python3 sha256sum supervisorctl supervisord xz; do
      have_cmd "${command}" || die "SKIP_APT=1 but '${command}' is missing."
    done
    return 0
  fi

  create_policy_rcd
  retry 4 5 apt-get -o Acquire::Retries=3 update
  retry 3 5 apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
    apache2 \
    build-essential \
    ca-certificates \
    clinfo \
    composer \
    curl \
    gettext-base \
    git \
    hashcat \
    iproute2 \
    jq \
    libapache2-mod-php \
    libssl-dev \
    mysql-client \
    mysql-server \
    nginx \
    ocl-icd-libopencl1 \
    openssl \
    p7zip-full \
    pciutils \
    php \
    php-bcmath \
    php-cli \
    php-curl \
    php-gd \
    php-mbstring \
    php-mysql \
    php-xml \
    php-zip \
    pkg-config \
    procps \
    psmisc \
    python3 \
    python3-psutil \
    python3-requests \
    python3-venv \
    rsync \
    supervisor \
    unzip \
    util-linux \
    zip \
    xz-utils
  remove_temporary_policy
  a2enmod rewrite headers >/dev/null
}

configure_nvidia_runtime() {
  mkdir -p /etc/OpenCL/vendors
  printf '%s\n' 'libnvidia-opencl.so.1' > /etc/OpenCL/vendors/nvidia.icd
  {
    [[ -d /usr/local/nvidia/lib ]] && printf '%s\n' /usr/local/nvidia/lib
    [[ -d /usr/local/nvidia/lib64 ]] && printf '%s\n' /usr/local/nvidia/lib64
  } > /etc/ld.so.conf.d/kiquai-nvidia.conf
  ldconfig 2>/dev/null || true
  export PATH="/usr/local/nvidia/bin:${PATH}"
  export LD_LIBRARY_PATH="/usr/local/nvidia/lib:/usr/local/nvidia/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
}

validate_hashcat() {
  : > "${HASHCAT_LOG}"
  chmod 600 "${HASHCAT_LOG}"
  if hashcat -I > "${HASHCAT_LOG}" 2>&1; then
    sed -n '1,180p' "${HASHCAT_LOG}"
  else
    local rc=$?
    sed -n '1,220p' "${HASHCAT_LOG}" >&2
    if [[ "${REQUIRE_HASHCAT_GPU}" == "1" ]]; then
      die "hashcat -I failed with exit code ${rc}."
    fi
    warn "Hashcat device detection failed; continuing because REQUIRE_HASHCAT_GPU=0."
    return 0
  fi

  if grep -Eq '(Backend Device ID|Device #[[:space:]]*[0-9]+)' "${HASHCAT_LOG}" \
      && grep -Eiq '(NVIDIA|CUDA)' "${HASHCAT_LOG}"; then
    success "Hashcat detected an NVIDIA compute device."
  elif [[ "${REQUIRE_HASHCAT_GPU}" == "1" ]]; then
    die "Hashcat returned successfully but did not report an NVIDIA compute device."
  else
    warn "Hashcat did not report an NVIDIA compute device."
  fi
}

prepare_layout() {
  mkdir -p \
    "${APP_DIR}" "${CONFIG_DIR}" "${DATA_DIR}" "${RELEASES_DIR}" \
    "${CURRENT_DIR}" "${TOOLS_DIR}/bin" "${RUN_DIR}" "${AGENT_DIR}" \
    "${MYSQL_DATA_DIR}" "${MYSQL_RUN_DIR}" \
    "${HASHTOPOLIS_DATA_DIR}/files" \
    "${HASHTOPOLIS_DATA_DIR}/import" \
    "${HASHTOPOLIS_DATA_DIR}/log" \
    "${HASHTOPOLIS_DATA_DIR}/config" \
    "${HASHTOPOLIS_DATA_DIR}/binaries" \
    "${HASHTOPOLIS_DATA_DIR}/tus/uploads" \
    "${HASHTOPOLIS_DATA_DIR}/tus/meta"
  chown root:root \
    "${APP_DIR}" "${CONFIG_DIR}" "${DATA_DIR}" "${RELEASES_DIR}" \
    "${CURRENT_DIR}" "${TOOLS_DIR}" "${RUN_DIR}" "${AGENT_DIR}"
  chmod 755 \
    "${APP_DIR}" "${DATA_DIR}" "${RELEASES_DIR}" \
    "${CURRENT_DIR}" "${TOOLS_DIR}" "${TOOLS_DIR}/bin" "${RUN_DIR}"
  chmod 711 "${CONFIG_DIR}"
  chmod 700 "${AGENT_DIR}"
  chown -R mysql:mysql "${MYSQL_DATA_DIR}" "${MYSQL_RUN_DIR}"
  chmod 700 "${MYSQL_DATA_DIR}" "${MYSQL_RUN_DIR}"
  chown -R www-data:www-data "${HASHTOPOLIS_DATA_DIR}"
  chmod 750 "${HASHTOPOLIS_DATA_DIR}"
}

supervisor_is_running() {
  local pid=""
  [[ -r "${SUPERVISOR_PID}" ]] || return 1
  pid="$(<"${SUPERVISOR_PID}")"
  is_uint "${pid}" || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  [[ -r "/proc/${pid}/cmdline" ]] || return 1
  tr '\0' ' ' < "/proc/${pid}/cmdline" | grep -Fq "${SUPERVISOR_CONFIG}"
}

supervisor_ctl() {
  supervisorctl -c "${SUPERVISOR_CONFIG}" "$@"
}

stop_managed_services() {
  if supervisor_is_running; then
    supervisor_ctl shutdown >/dev/null 2>&1 || true
    local deadline=$((SECONDS + 30))
    while supervisor_is_running && (( SECONDS < deadline )); do
      sleep 1
    done
  fi
  rm -f "${SUPERVISOR_SOCKET}" "${SUPERVISOR_PID}" 2>/dev/null || true
}

wipe_data_if_requested() {
  [[ "${WIPE_DATA}" == "1" ]] || return 0
  warn "WIPE_DATA=1: stopping services and deleting the single-container database, files, releases, agent state, and credentials."
  stop_managed_services
  validate_safe_absolute_path APP_DIR "${APP_DIR}"
  rm -rf -- "${APP_DIR}"
  apply_defaults
}

archive_legacy_dind_config() {
  [[ -f "${APP_DIR}/docker-compose.yml" ]] || return 0
  local archive="${APP_DIR}/legacy-dind-config"
  mkdir -p "${archive}"
  local file
  for file in docker-compose.yml nginx.conf php-overrides.ini kiquai-logs.sh kiquai-proxy-watchdog.sh; do
    if [[ -e "${APP_DIR}/${file}" ]]; then
      mv -f "${APP_DIR}/${file}" "${archive}/${file}"
    fi
  done
  warn "Archived legacy DinD configuration under ${archive}. Inner Docker volumes were not modified or imported."
}

stop_verified_legacy_process() {
  local pid_file="$1" required_text="$2" pid="" command_line=""
  [[ -r "${pid_file}" ]] || return 0
  pid="$(<"${pid_file}")"
  is_uint "${pid}" || return 0
  kill -0 "${pid}" 2>/dev/null || return 0
  [[ -r "/proc/${pid}/cmdline" ]] || return 0
  command_line="$(tr '\0' ' ' < "/proc/${pid}/cmdline")"
  [[ "${command_line}" == *"${required_text}"* ]] || return 0
  warn "Stopping verified legacy process ${pid}: ${required_text}"
  kill -TERM "${pid}" 2>/dev/null || true
  local deadline=$((SECONDS + 30))
  while kill -0 "${pid}" 2>/dev/null && (( SECONDS < deadline )); do
    sleep 1
  done
}

stop_legacy_dind_runtime() {
  stop_verified_legacy_process \
    /var/run/kiquai-hashtopolis-proxy.pid \
    kiquai-proxy-watchdog.sh
  stop_verified_legacy_process \
    /var/run/kiquai-hashtopolis-socat.pid \
    socat
  stop_verified_legacy_process \
    /var/run/kiquai-dockerd.pid \
    kiquai-docker
}

validate_service_ports() {
  supervisor_is_running && return 0
  local port
  for port in "${INTERNAL_PORT}" "${BACKEND_PORT}" "${DB_PORT}"; do
    if ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .; then
      ss -ltnp "sport = :${port}" || true
      die "TCP port ${port} is already occupied by a process outside this installation."
    fi
  done
}

install_sqlx() {
  if [[ -x "${TOOLS_DIR}/bin/sqlx" ]]; then
    "${TOOLS_DIR}/bin/sqlx" --version
    return 0
  fi
  if have_cmd sqlx; then
    install -m 755 "$(command -v sqlx)" "${TOOLS_DIR}/bin/sqlx"
    return 0
  fi

  local build_root="${TOOLS_DIR}/sqlx-build"
  local rustup_home="${build_root}/rustup"
  local cargo_home="${build_root}/cargo"
  local temp
  temp="$(mktemp -d)"
  local rustup_url="https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init"

  info "Installing the sqlx migration CLI used by the official Hashtopolis backend."
  retry 4 5 curl -fsSL "${rustup_url}" -o "${temp}/rustup-init"
  retry 4 5 curl -fsSL "${rustup_url}.sha256" -o "${temp}/rustup-init.sha256"
  local expected
  expected="$(awk '{print $1}' "${temp}/rustup-init.sha256")"
  [[ "${expected}" =~ ^[a-fA-F0-9]{64}$ ]] || die "Invalid rustup checksum response."
  printf '%s  %s\n' "${expected}" "${temp}/rustup-init" | sha256sum -c -
  chmod 700 "${temp}/rustup-init"

  CARGO_HOME="${cargo_home}" RUSTUP_HOME="${rustup_home}" \
    "${temp}/rustup-init" -y --no-modify-path --profile minimal --default-toolchain stable
  CARGO_HOME="${cargo_home}" RUSTUP_HOME="${rustup_home}" \
    retry 2 10 "${cargo_home}/bin/cargo" install --locked sqlx-cli \
      --no-default-features --features native-tls,mysql --root "${TOOLS_DIR}"
  rm -rf "${temp}"
  "${TOOLS_DIR}/bin/sqlx" --version

  if [[ "${KEEP_BUILD_TOOLCHAINS}" == "0" ]]; then
    rm -rf "${build_root}"
  fi
}

install_node_version() {
  local version="$1"
  version="${version#v}"
  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "The frontend .nvmrc does not contain an exact Node.js version: '${version}'."
  local node_root="${TOOLS_DIR}/node-v${version}-linux-x64"
  if [[ ! -x "${node_root}/bin/node" ]]; then
    local temp
    temp="$(mktemp -d)"
    local archive="node-v${version}-linux-x64.tar.xz"
    local base="https://nodejs.org/dist/v${version}"
    retry 4 5 curl -fsSL "${base}/${archive}" -o "${temp}/${archive}"
    retry 4 5 curl -fsSL "${base}/SHASUMS256.txt" -o "${temp}/SHASUMS256.txt"
    (
      cd "${temp}"
      grep "  ${archive}$" SHASUMS256.txt | sha256sum -c -
    ) || die "Node.js checksum verification failed."
    tar -xJf "${temp}/${archive}" -C "${TOOLS_DIR}"
    rm -rf "${temp}"
  fi
  NODE_HOME="${node_root}"
  export NODE_HOME
  export PATH="${NODE_HOME}/bin:${TOOLS_DIR}/bin:${PATH}"
  node --version
  npm --version
}

atomic_symlink() {
  local target="$1" link="$2" temp="${link}.tmp.$$"
  ln -s "${target}" "${temp}"
  mv -Tf "${temp}" "${link}"
}

build_server_release() {
  local suffix="${HASHTOPOLIS_VERSION#v}"
  local target="${RELEASES_DIR}/server-${suffix}"
  if [[ -f "${target}/.kiquai-ready" && "${FORCE_REBUILD}" == "0" ]]; then
    info "Reusing Hashtopolis backend ${HASHTOPOLIS_VERSION}."
    atomic_symlink "${target}" "${SERVER_CURRENT}"
    return 0
  fi

  local temp="${RELEASES_DIR}/.server-${suffix}.tmp.$$"
  local backup="${RELEASES_DIR}/.server-${suffix}.old.$$"
  rm -rf -- "${temp}" "${backup}"
  retry 3 5 git clone --depth 1 --branch "${HASHTOPOLIS_VERSION}" \
    "${HASHTOPOLIS_SERVER_REPOSITORY}" "${temp}"
  COMPOSER_ALLOW_SUPERUSER=1 composer install \
    --working-dir="${temp}" \
    --no-dev --no-interaction --prefer-dist --optimize-autoloader
  [[ -f "${temp}/src/inc/startup/setup.php" ]] \
    || die "The backend source tree is incomplete."
  printf '%s\n' "${HASHTOPOLIS_VERSION}" > "${temp}/.kiquai-ready"
  chown -R www-data:www-data "${temp}"
  if [[ -e "${target}" ]]; then
    mv "${target}" "${backup}"
  fi
  mv "${temp}" "${target}"
  atomic_symlink "${target}" "${SERVER_CURRENT}"
  rm -rf -- "${backup}"
}

build_frontend_release() {
  local suffix="${HASHTOPOLIS_FRONTEND_VERSION#v}"
  local target="${RELEASES_DIR}/frontend-${suffix}"
  if [[ -f "${target}/.kiquai-ready" && "${FORCE_REBUILD}" == "0" ]]; then
    info "Reusing Hashtopolis frontend ${HASHTOPOLIS_FRONTEND_VERSION}."
    atomic_symlink "${target}" "${FRONTEND_CURRENT}"
    return 0
  fi

  local temp="${RELEASES_DIR}/.frontend-${suffix}.tmp.$$"
  local backup="${RELEASES_DIR}/.frontend-${suffix}.old.$$"
  rm -rf -- "${temp}" "${backup}"
  retry 3 5 git clone --depth 1 --branch "${HASHTOPOLIS_FRONTEND_VERSION}" \
    "${HASHTOPOLIS_FRONTEND_REPOSITORY}" "${temp}"
  [[ -r "${temp}/.nvmrc" ]] || die "The frontend release does not contain .nvmrc."
  local node_version
  node_version="$(tr -d '[:space:]' < "${temp}/.nvmrc")"
  install_node_version "${node_version}"
  (
    cd "${temp}"
    export PUPPETEER_SKIP_DOWNLOAD=true
    retry 2 10 npm ci
    npm run build
  )
  [[ -f "${temp}/dist/index.html" ]] || die "The frontend build did not produce dist/index.html."
  if [[ "${KEEP_BUILD_TOOLCHAINS}" == "0" ]]; then
    rm -rf "${temp}/node_modules"
  fi
  printf '%s\n' "${HASHTOPOLIS_FRONTEND_VERSION}" > "${temp}/.kiquai-ready"
  chown -R root:www-data "${temp}"
  chmod -R g+rX "${temp}"
  if [[ -e "${target}" ]]; then
    mv "${target}" "${backup}"
  fi
  mv "${temp}" "${target}"
  atomic_symlink "${target}" "${FRONTEND_CURRENT}"
  rm -rf -- "${backup}"
}

write_mysql_config() {
  touch "${LOG_DIR}/mysql.log"
  chown mysql:mysql "${LOG_DIR}/mysql.log"
  chmod 640 "${LOG_DIR}/mysql.log"
  cat > "${MYSQL_CONFIG}" <<EOF
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
  chown mysql:mysql "${MYSQL_CONFIG}"
  chmod 600 "${MYSQL_CONFIG}"
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
  [[ -f "${example}" ]] || die "Frontend config template is missing: ${example}"
  HASHTOPOLIS_BACKEND_URL="${HASHTOPOLIS_BACKEND_URL}" \
    envsubst '${HASHTOPOLIS_BACKEND_URL}' < "${example}" > "${target}"
  mkdir -p "${FRONTEND_CURRENT}/dist/assets/themes"
  printf '%s\n' '[]' > "${FRONTEND_CURRENT}/dist/assets/themes/custom-themes.json"
  chown root:www-data "${target}" "${FRONTEND_CURRENT}/dist/assets/themes/custom-themes.json"
  chmod 640 "${target}" "${FRONTEND_CURRENT}/dist/assets/themes/custom-themes.json"
}

write_nginx_config() {
  cat > "${NGINX_CONFIG}" <<EOF
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
  chmod 640 "${NGINX_CONFIG}"
  nginx -t -c "${NGINX_CONFIG}"
}

write_backend_launcher() {
  cat > "${CONFIG_DIR}/start-backend.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
set -a
source "__ENV_FILE__"
set +a

SERVER_CURRENT="${APP_DIR}/current/server"
HASHTOPOLIS_DATA_DIR="${APP_DIR}/data/hashtopolis"
export PATH="${APP_DIR}/tools/bin:${PATH}"
export PATH="/usr/local/nvidia/bin:${PATH}"
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

for _attempt in $(seq 1 120); do
  if MYSQL_PWD="${MYSQL_PASSWORD}" mysql --protocol=tcp \
      -h 127.0.0.1 -P "${DB_PORT}" -u "${MYSQL_USER}" \
      -D "${MYSQL_DATABASE}" -Nse 'SELECT 1' >/dev/null 2>&1; then
    break
  fi
  if [[ "${_attempt}" == "120" ]]; then
    echo "Backend timed out waiting for the application database." >&2
    exit 1
  fi
  sleep 2
done

runuser -u www-data --preserve-environment -- \
  php -f "${SERVER_CURRENT}/src/inc/startup/setup.php"
exec /usr/sbin/apache2ctl -DFOREGROUND
EOF
  sed -i "s|__ENV_FILE__|${ENV_FILE}|g" "${CONFIG_DIR}/start-backend.sh"
  chmod 700 "${CONFIG_DIR}/start-backend.sh"
}

write_agent_launcher() {
  cat > "${CONFIG_DIR}/start-agent.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
set -a
source "__ENV_FILE__"
set +a
AGENT_DIR="${APP_DIR}/agent"
export PATH="/usr/local/nvidia/bin:${PATH}"
export LD_LIBRARY_PATH="/usr/local/nvidia/lib:/usr/local/nvidia/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
cd "${AGENT_DIR}"

for _attempt in $(seq 1 150); do
  [[ -f "${AGENT_DIR}/hashtopolis.zip" ]] && break
  if [[ "${_attempt}" == "150" ]]; then
    echo "Agent package did not become available." >&2
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
    echo "No agent config or AGENT_VOUCHER is available." >&2
    exit 1
  }
  args+=(--voucher "${AGENT_VOUCHER}")
fi
exec "${args[@]}"
EOF
  sed -i "s|__ENV_FILE__|${ENV_FILE}|g" "${CONFIG_DIR}/start-agent.sh"
  chmod 700 "${CONFIG_DIR}/start-agent.sh"
}

write_supervisor_config() {
  local agent_autostart="false"
  if [[ "${AGENT_ENABLED}" == "1" ]]; then
    agent_autostart="true"
  fi
  cat > "${SUPERVISOR_CONFIG}" <<EOF
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
autostart=true
autorestart=true
startsecs=10
startretries=30
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
autostart=true
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
autostart=${agent_autostart}
autorestart=unexpected
startsecs=10
startretries=10
stopasgroup=true
killasgroup=true
stopsignal=TERM
stopwaitsecs=30
redirect_stderr=true
stdout_logfile=${LOG_DIR}/agent.log
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=3
EOF
  chmod 600 "${SUPERVISOR_CONFIG}"
}

write_runtime_configs() {
  write_mysql_config
  write_apache_config
  write_frontend_config
  write_nginx_config
  write_backend_launcher
  write_agent_launcher
  write_supervisor_config
}

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

restart_web_services() {
  supervisor_ctl restart backend >/dev/null
  supervisor_ctl restart nginx >/dev/null
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

redacted_environment() {
  [[ -r "${ENV_FILE}" ]] || return 0
  awk -F= '
    BEGIN { IGNORECASE=1 }
    {
      key=$1
      if (key ~ /(PASS|PASSWORD|VOUCHER|TOKEN|SECRET)/) {
        print key "='\''<redacted>'\''"
      } else {
        print
      }
    }
  ' "${ENV_FILE}"
}

collect_diagnostics() {
  local diagnostics_dir="${LOG_DIR}/diagnostics"
  mkdir -p "${diagnostics_dir}"
  chmod 700 "${diagnostics_dir}"
  LAST_DIAGNOSTIC_FILE="${diagnostics_dir}/diagnostic-$(date '+%Y%m%d-%H%M%S').log"
  {
    printf 'KiQuai diagnostic report\n'
    printf 'generated=%s\nscript_version=%s\nstage=%s\n\n' \
      "$(timestamp)" "${SCRIPT_VERSION}" "${CURRENT_STAGE}"
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
    "${TOOLS_DIR}/bin/sqlx" --version 2>&1 || true
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
    for log in mysql.log backend.log apache-error.log nginx-error.log agent.log supervisord.log; do
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

print_success() {
  supervisor_ctl status
  printf '\n%s' "${C_GREEN}"
  print_rule
  printf '%sDEPLOYMENT COMPLETE%s\n' "${C_BOLD}" "${C_RESET}${C_GREEN}"
  print_rule
  printf '%s' "${C_RESET}"
  cat <<EOF
Hashtopolis URL : ${PUBLIC_URL}
Admin username  : ${HASHTOPOLIS_ADMIN_USER}
Admin password  : ${HASHTOPOLIS_ADMIN_PASSWORD}
API v2          : ${PUBLIC_URL}/api/v2
Legacy agent API: ${PUBLIC_URL}/api/server.php

Application dir : ${APP_DIR}
Credentials     : ${ENV_FILE} (mode 600)
Bootstrap log   : ${MAIN_LOG}

Useful commands:
  $(realpath "$0") status
  $(realpath "$0") logs
  $(realpath "$0") diagnostics
  $(realpath "$0") agent-start YOUR_VOUCHER

Security notice: traffic is plain HTTP unless PUBLIC_URL is provided through a
trusted HTTPS reverse proxy or tunnel. Use Hashtopolis only for authorized work.
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
  ./run.sh                         Deploy or reconcile everything
  ./run.sh deploy                  Same as above
  ./run.sh preflight               Check root, disk, and NVIDIA visibility
  ./run.sh status                  Show service, HTTP, database, and GPU status
  ./run.sh logs                    Print bounded service logs
  ./run.sh diagnostics             Create a diagnostic report
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
  if supervisor_is_running; then
    supervisor_ctl status
  else
    error "KiQuai supervisord is not running."
  fi
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 \
    "http://127.0.0.1:${INTERNAL_PORT}/" 2>/dev/null || true)"
  [[ "${code}" =~ ^[0-9]{3}$ ]] || code=000
  printf 'HTTP status: %s\n' "${code}"
  if MYSQL_PWD="${MYSQL_PASSWORD}" mysql --protocol=tcp -h 127.0.0.1 \
      -P "${DB_PORT}" -u "${MYSQL_USER}" -Nse 'SELECT 1' >/dev/null 2>&1; then
    success "Database login passed."
  else
    error "Database login failed."
  fi
  nvidia-smi --query-gpu=index,name,driver_version,memory.total,utilization.gpu \
    --format=csv,noheader 2>/dev/null || true
  hashcat -I 2>/dev/null | sed -n '1,100p' || true
}

command_logs() {
  require_existing_installation
  supervisor_is_running && supervisor_ctl status || true
  local log
  for log in mysql.log backend.log apache-error.log nginx-error.log agent.log supervisord.log; do
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
  supervisor_is_running || start_or_reload_supervisor
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

  begin_step "Generate MySQL, Apache, Nginx, and supervisor configuration"
  write_runtime_configs
  initialize_mysql_data
  end_step

  begin_step "Start native processes and provision the database"
  start_or_reload_supervisor
  wait_for_mysql
  provision_database
  restart_web_services
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
    deploy|preflight|status|logs|diagnostics|stop|restart|agent-start|agent-stop)
      ;;
    *)
      usage >&2
      printf '\nUnknown command: %s\n' "${command}" >&2
      return 2
      ;;
  esac

  require_root
  load_saved_config
  apply_defaults
  resolve_public_url
  resolve_credentials
  validate_config
  mkdir -p "${LOG_DIR}"
  init_logging
  install_traps

  case "${command}" in
    deploy) deploy ;;
    preflight) command_preflight ;;
    status) command_status ;;
    logs) command_logs ;;
    diagnostics) command_diagnostics ;;
    stop) command_stop ;;
    restart)
      deploy
      ;;
    agent-start) command_agent_start "${2-}" ;;
    agent-stop) command_agent_stop ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
