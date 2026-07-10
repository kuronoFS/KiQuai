#!/usr/bin/env bash
# shellcheck shell=bash

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# KiQuai Hashtopolis + Hashcat bootstrap for nested-container environments.
#
# Architecture:
#   Vast.ai outer container -> rootful inner dockerd -> Hashtopolis Compose stack
#   Vast.ai port mapping -> host socat watchdog -> inner Nginx proxy container
#   Hashcat runs directly in the outer CUDA container, not inside the stack.
#
# IMPORTANT: rootful Docker-in-Docker requires real CAP_SYS_ADMIN and
# CAP_NET_ADMIN capabilities. The preflight check deliberately stops before APT
# installation when the outer runtime did not grant them.

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="KiQuai Hashtopolis bootstrap"
readonly TOTAL_STEPS=11

umask 077

# Remember which values were supplied by the caller. Saved runtime settings
# are loaded only when the caller did not explicitly override them.
if [[ -v INTERNAL_PORT ]]; then INPUT_INTERNAL_PORT_SET=1; else INPUT_INTERNAL_PORT_SET=0; fi
if [[ -v DOCKER_SOCK ]]; then INPUT_DOCKER_SOCK_SET=1; else INPUT_DOCKER_SOCK_SET=0; fi
if [[ -v DOCKER_DATA_ROOT ]]; then INPUT_DOCKER_DATA_ROOT_SET=1; else INPUT_DOCKER_DATA_ROOT_SET=0; fi
if [[ -v DOCKER_EXEC_ROOT ]]; then INPUT_DOCKER_EXEC_ROOT_SET=1; else INPUT_DOCKER_EXEC_ROOT_SET=0; fi

############################
# Configuration             #
############################

APP_DIR="${APP_DIR:-/opt/kiquai-hashtopolis}"
INTERNAL_PORT="${INTERNAL_PORT:-8080}"
PUBLIC_URL="${PUBLIC_URL-}"
PUBLIC_IP=""
PUBLIC_PORT=""

# Keep backend/frontend on the same release channel. Mixing rc and master tags
# is a common source of frontend/API incompatibility.
HASHTOPOLIS_BACKEND_IMAGE="${HASHTOPOLIS_BACKEND_IMAGE:-hashtopolis/backend:v1.0.0-rc1}"
HASHTOPOLIS_FRONTEND_IMAGE="${HASHTOPOLIS_FRONTEND_IMAGE:-hashtopolis/frontend:v1.0.0-rc1}"
DB_IMAGE="${DB_IMAGE:-mysql:8.4}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"

MYSQL_DATABASE_DEFAULT="${MYSQL_DATABASE_DEFAULT:-hashtopolis}"
MYSQL_USER_DEFAULT="${MYSQL_USER_DEFAULT:-hashtopolis}"
HASHTOPOLIS_ADMIN_USER_DEFAULT="${HASHTOPOLIS_ADMIN_USER_DEFAULT:-admin}"

DOCKER_SOCK="${DOCKER_SOCK:-/var/run/kiquai-docker.sock}"
DOCKER_PID="${DOCKER_PID:-/var/run/kiquai-dockerd.pid}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-/var/lib/kiquai-docker}"
DOCKER_EXEC_ROOT="${DOCKER_EXEC_ROOT:-/var/run/kiquai-docker}"
DOCKER_STORAGE_DRIVER="${DOCKER_STORAGE_DRIVER:-auto}"
DOCKER_START_TIMEOUT="${DOCKER_START_TIMEOUT:-60}"
DOCKER_LOG_LEVEL="${DOCKER_LOG_LEVEL:-info}"
ALLOW_VFS_FALLBACK="${ALLOW_VFS_FALLBACK:-1}"
ALLOW_UNPRIVILEGED_ATTEMPT="${ALLOW_UNPRIVILEGED_ATTEMPT:-0}"

# Empty/auto means: reuse a saved subnet or select a non-overlapping subnet.
COMPOSE_SUBNET="${COMPOSE_SUBNET-}"
PROXY_STATIC_IP="${PROXY_STATIC_IP-}"
SMOKE_SUBNET=""

LOG_DIR="${LOG_DIR:-/var/log/kiquai-hashtopolis}"
MAIN_LOG="${MAIN_LOG:-${LOG_DIR}/bootstrap.log}"
DOCKER_LOG="${DOCKER_LOG:-${LOG_DIR}/dockerd.log}"
LEGACY_DOCKER_LOG="${LEGACY_DOCKER_LOG:-/var/log/kiquai-dockerd.log}"
PROXY_LOG="${PROXY_LOG:-${LOG_DIR}/proxy.log}"
HASHCAT_LOG="${HASHCAT_LOG:-${LOG_DIR}/hashcat-devices.log}"
PROXY_PID="${PROXY_PID:-/var/run/kiquai-hashtopolis-proxy.pid}"
LEGACY_SOCAT_PID="${LEGACY_SOCAT_PID:-/var/run/kiquai-hashtopolis-socat.pid}"
LOCK_DIR="${LOCK_DIR:-/var/lock/kiquai-hashtopolis.lock}"

WIPE_DATA="${WIPE_DATA:-0}"
FORCE_RECREATE="${FORCE_RECREATE:-0}"
PULL_IMAGES="${PULL_IMAGES:-missing}" # always | missing | never; 1/0 also accepted
SKIP_APT="${SKIP_APT:-0}"
REQUIRE_HASHCAT_GPU="${REQUIRE_HASHCAT_GPU:-1}"
DIAGNOSTICS_ON_FAILURE="${DIAGNOSTICS_ON_FAILURE:-1}"
FORCE_COLOR="${FORCE_COLOR:-0}"

export DEBIAN_FRONTEND=noninteractive
export DOCKER_HOST="unix://${DOCKER_SOCK}"

############################
# Runtime state             #
############################

CURRENT_STEP=0
CURRENT_STAGE="initialization"
STAGE_STARTED_AT=0
SCRIPT_STARTED_AT=$SECONDS
LAST_ERROR_CODE=0
LAST_ERROR_LINE=""
LAST_ERROR_COMMAND=""
LAST_ERROR_MESSAGE=""
LAST_DIAGNOSTIC_FILE=""
LOCK_OWNED=0
DEPLOYMENT_COMPLETE=0
SELECTED_STORAGE_DRIVER=""
DATA_ROOT_RESET_SAFE=0
TEMP_POLICY_RC_CREATED=0

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

############################
# Logging and error handling#
############################

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

release_lock() {
  if [[ "${LOCK_OWNED}" == "1" ]]; then
    rm -rf -- "${LOCK_DIR}" 2>/dev/null || true
    LOCK_OWNED=0
  fi
}

on_signal() {
  local signal="$1"
  LAST_ERROR_MESSAGE="Interrupted by ${signal}"
  error "Interrupted by ${signal}; stopping the active operation."
  exit 130
}

on_exit() {
  local code="$1"
  trap - ERR EXIT INT TERM HUP
  set +e
  release_lock
  if [[ "${TEMP_POLICY_RC_CREATED}" == "1" ]]; then
    rm -f /usr/sbin/policy-rc.d 2>/dev/null || true
    TEMP_POLICY_RC_CREATED=0
  fi

  if (( code != 0 )); then
    printf '\n' >&2
    printf '%s' "${C_RED}" >&2
    printf '%s\n' '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' >&2
    printf 'DEPLOYMENT FAILED (exit=%s, stage=%s)\n' "${code}" "${CURRENT_STAGE}" >&2
    printf '%s\n' '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' >&2
    printf '%s' "${C_RESET}" >&2
    [[ -n "${LAST_ERROR_MESSAGE}" ]] && printf 'Reason : %s\n' "${LAST_ERROR_MESSAGE}" >&2
    [[ -n "${LAST_ERROR_LINE}" ]] && printf 'Line   : %s\n' "${LAST_ERROR_LINE}" >&2
    [[ -n "${LAST_ERROR_COMMAND}" ]] && printf 'Command: %s\n' "${LAST_ERROR_COMMAND}" >&2
    printf 'Log    : %s\n' "${MAIN_LOG}" >&2

    if [[ "${DIAGNOSTICS_ON_FAILURE}" == "1" ]]; then
      collect_diagnostics || true
      [[ -n "${LAST_DIAGNOSTIC_FILE}" ]] && printf 'Report : %s\n' "${LAST_DIAGNOSTIC_FILE}" >&2
    fi

    if [[ -s "${DOCKER_LOG}" ]]; then
      printf '\n--- Last 40 dockerd log lines ---\n' >&2
      tail -n 40 "${DOCKER_LOG}" >&2 || true
    fi
  elif [[ "${DEPLOYMENT_COMPLETE}" == "1" ]]; then
    success "All deployment stages completed in $((SECONDS - SCRIPT_STARTED_AT))s"
  fi

  exit "${code}"
}

init_logging() {
  mkdir -p "${LOG_DIR}"
  chmod 700 "${LOG_DIR}" 2>/dev/null || true

  if [[ -f "${MAIN_LOG}" ]] && [[ $(stat -c '%s' "${MAIN_LOG}" 2>/dev/null || echo 0) -gt 5242880 ]]; then
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

############################
# Generic helpers           #
############################

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  [[ "$(id -u)" == "0" ]] || die "Run this script as root inside the Vast.ai instance."
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

validate_bool() {
  local name="$1" value="$2"
  [[ "${value}" == "0" || "${value}" == "1" ]] || die "${name} must be 0 or 1; received '${value}'."
}

validate_port() {
  local name="$1" value="$2"
  if ! is_uint "${value}"; then
    die "${name} must be an integer from 1 to 65535; received '${value}'."
  fi
  local numeric=$((10#${value}))
  if (( numeric < 1 || numeric > 65535 )); then
    die "${name} must be an integer from 1 to 65535; received '${value}'."
  fi
  printf -v "${name}" '%d' "${numeric}"
}

validate_safe_absolute_path() {
  local name="$1" value="$2"
  [[ "${value}" == /* ]] || die "${name} must be an absolute path."
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || die "${name} cannot contain newline characters."
  [[ "${value}" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || die "${name} may contain only letters, numbers, dot, underscore, slash, and hyphen."
  local canonical
  canonical="$(realpath -m -- "${value}")"
  case "${canonical}" in
    /|/bin|/boot|/data|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/var/lib|/var/lock|/var/log|/var/run)
      die "Refusing unsafe ${name}='${value}'. Choose a dedicated subdirectory."
      ;;
  esac
  printf -v "${name}" '%s' "${canonical}"
}

validate_log_config_early() {
  validate_safe_absolute_path LOG_DIR "${LOG_DIR}"
  local path_name path_value canonical
  for path_name in MAIN_LOG DOCKER_LOG PROXY_LOG HASHCAT_LOG; do
    path_value="${!path_name}"
    [[ "${path_value}" == /* ]] || die "${path_name} must be an absolute path."
    [[ "${path_value}" =~ ^/[A-Za-z0-9._/-]+$ ]] \
      || die "${path_name} contains unsupported characters."
    canonical="$(realpath -m -- "${path_value}")"
    [[ "${canonical}" == "${LOG_DIR}/"* ]] \
      || die "${path_name} must be located beneath LOG_DIR='${LOG_DIR}'."
    printf -v "${path_name}" '%s' "${canonical}"
  done
}

validate_runtime_file_path() {
  local name="$1" value="$2" canonical
  [[ "${value}" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "${name} must be a safe absolute path."
  canonical="$(realpath -m -- "${value}")"
  [[ "${canonical}" == /run/* ]] || die "${name} must be located beneath /run or /var/run."
  printf -v "${name}" '%s' "${canonical}"
}

retry() {
  local attempts="$1" delay="$2"
  shift 2
  local try=1 rc=0

  while (( try <= attempts )); do
    if "$@"; then
      return 0
    else
      rc=$?
    fi
    if (( try == attempts )); then
      break
    fi
    warn "Command failed (attempt ${try}/${attempts}, exit=${rc}); retrying in ${delay}s."
    sleep "${delay}"
    try=$((try + 1))
  done
  return "${rc}"
}

acquire_lock() {
  mkdir -p "$(dirname "${LOCK_DIR}")"
  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    printf '%s\n' "$$" > "${LOCK_DIR}/pid"
    LOCK_OWNED=1
    return 0
  fi

  local owner=""
  [[ -r "${LOCK_DIR}/pid" ]] && owner="$(<"${LOCK_DIR}/pid")"
  if is_uint "${owner}" && kill -0 "${owner}" 2>/dev/null; then
    die "Another bootstrap process is running with PID ${owner}."
  fi

  warn "Removing a stale deployment lock."
  rm -rf -- "${LOCK_DIR}"
  mkdir "${LOCK_DIR}"
  printf '%s\n' "$$" > "${LOCK_DIR}/pid"
  LOCK_OWNED=1
}

rand_secret() {
  openssl rand -hex 24
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
  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  printf "'%s'" "${value}"
}

write_env_line() {
  local key="$1" value="$2" file="$3"
  printf '%s=%s\n' "${key}" "$(dotenv_quote "${value}")" >> "${file}"
}

resolve_saved_or_default() {
  local name="$1" default="$2" saved="" current=""
  if [[ -v "${name}" ]]; then
    current="${!name}"
  fi
  if [[ -n "${current}" ]]; then
    return 0
  fi
  if [[ "${WIPE_DATA}" != "1" ]]; then
    saved="$(dotenv_get "${name}" 2>/dev/null || true)"
  fi
  printf -v "${name}" '%s' "${saved:-${default}}"
}

resolve_saved_or_generate() {
  local name="$1" saved="" current=""
  if [[ -v "${name}" ]]; then
    current="${!name}"
  fi
  if [[ -n "${current}" ]]; then
    return 0
  fi
  if [[ "${WIPE_DATA}" != "1" ]]; then
    saved="$(dotenv_get "${name}" 2>/dev/null || true)"
  fi
  printf -v "${name}" '%s' "${saved:-$(rand_secret)}"
}

load_saved_runtime_setting() {
  local name="$1" was_set="$2" saved=""
  if [[ "${was_set}" == "0" ]]; then
    saved="$(dotenv_get "${name}" 2>/dev/null || true)"
    if [[ -n "${saved}" ]]; then
      printf -v "${name}" '%s' "${saved}"
    fi
  fi
}

load_saved_runtime_config() {
  load_saved_runtime_setting INTERNAL_PORT "${INPUT_INTERNAL_PORT_SET}"
  load_saved_runtime_setting DOCKER_SOCK "${INPUT_DOCKER_SOCK_SET}"
  load_saved_runtime_setting DOCKER_DATA_ROOT "${INPUT_DOCKER_DATA_ROOT_SET}"
  load_saved_runtime_setting DOCKER_EXEC_ROOT "${INPUT_DOCKER_EXEC_ROOT_SET}"
  export DOCKER_HOST="unix://${DOCKER_SOCK}"
}

############################
# Diagnostics               #
############################

container_summary() {
  local name="$1"
  docker inspect --format='name={{.Name}} state={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}} oom={{.State.OOMKilled}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} ip={{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${name}" 2>/dev/null || true
}

collect_diagnostics() {
  local diagnostic_dir diagnostic_file
  diagnostic_dir="${LOG_DIR}/diagnostics"
  diagnostic_file="${diagnostic_dir}/diagnostic-$(date '+%Y%m%d-%H%M%S').log"
  mkdir -p "${diagnostic_dir}"
  chmod 700 "${diagnostic_dir}" 2>/dev/null || true

  set +e
  {
    echo "KiQuai diagnostic report"
    echo "generated=$(timestamp)"
    echo "script_version=${SCRIPT_VERSION}"
    echo "stage=${CURRENT_STAGE}"
    echo "last_error_code=${LAST_ERROR_CODE}"
    echo "last_error_line=${LAST_ERROR_LINE}"
    echo "last_error_command=${LAST_ERROR_COMMAND}"
    echo
    echo "===== OS / runtime ====="
    uname -a
    cat /etc/os-release
    id
    printf 'uptime='; cat /proc/uptime
    printf 'cgroup='; cat /proc/self/cgroup
    grep -E '^(Cap(Inh|Prm|Eff|Bnd|Amb)|NoNewPrivs|Seccomp):' /proc/self/status
    command -v capsh >/dev/null && capsh --print
    echo
    echo "===== mounts / storage ====="
    findmnt -T "${DOCKER_DATA_ROOT}" 2>/dev/null
    findmnt /sys/fs/cgroup 2>/dev/null
    df -hT "${APP_DIR}" "${DOCKER_DATA_ROOT}" 2>/dev/null
    df -ih "${APP_DIR}" "${DOCKER_DATA_ROOT}" 2>/dev/null
    echo
    echo "===== networking ====="
    ip -br address
    ip -4 route
    ss -ltnp
    echo
    echo "===== NVIDIA / Hashcat ====="
    nvidia-smi
    [[ -r "${HASHCAT_LOG}" ]] && tail -n 200 "${HASHCAT_LOG}"
    echo
    echo "===== Docker ====="
    docker version
    docker info
    docker network ls
    docker ps -a --no-trunc
    if [[ -d "${APP_DIR}" && -f "${APP_DIR}/docker-compose.yml" ]]; then
      echo
      echo "===== Compose services ====="
      (cd "${APP_DIR}" && docker compose config --services)
      (cd "${APP_DIR}" && docker compose ps -a)
      for service in hashtopolis-db hashtopolis-backend hashtopolis-frontend hashtopolis-proxy; do
        echo
        echo "===== ${service}: state ====="
        container_summary "${service}"
        echo "===== ${service}: logs ====="
        docker logs --tail 220 "${service}"
      done
    fi
    echo
    echo "===== dockerd tail ====="
    tail -n 300 "${DOCKER_LOG}" 2>/dev/null
    echo
    echo "===== host proxy tail ====="
    tail -n 160 "${PROXY_LOG}" 2>/dev/null
  } > "${diagnostic_file}" 2>&1
  chmod 600 "${diagnostic_file}"
  LAST_DIAGNOSTIC_FILE="${diagnostic_file}"
  set -e
}

############################
# Validation / preflight    #
############################

cap_effective_hex() {
  awk '/^CapEff:/ {print $2}' /proc/self/status
}

has_effective_cap() {
  local bit="$1" hex value
  hex="$(cap_effective_hex)"
  [[ -n "${hex}" ]] || hex=0
  value=$((16#${hex}))
  (( (value & (1 << bit)) != 0 ))
}

validate_base_config() {
  validate_port INTERNAL_PORT "${INTERNAL_PORT}"
  validate_bool WIPE_DATA "${WIPE_DATA}"
  validate_bool FORCE_RECREATE "${FORCE_RECREATE}"
  validate_bool SKIP_APT "${SKIP_APT}"
  validate_bool REQUIRE_HASHCAT_GPU "${REQUIRE_HASHCAT_GPU}"
  validate_bool ALLOW_VFS_FALLBACK "${ALLOW_VFS_FALLBACK}"
  validate_bool ALLOW_UNPRIVILEGED_ATTEMPT "${ALLOW_UNPRIVILEGED_ATTEMPT}"
  validate_safe_absolute_path APP_DIR "${APP_DIR}"
  validate_safe_absolute_path DOCKER_DATA_ROOT "${DOCKER_DATA_ROOT}"
  validate_safe_absolute_path DOCKER_EXEC_ROOT "${DOCKER_EXEC_ROOT}"
  validate_safe_absolute_path LOCK_DIR "${LOCK_DIR}"
  validate_runtime_file_path DOCKER_SOCK "${DOCKER_SOCK}"
  validate_runtime_file_path DOCKER_PID "${DOCKER_PID}"
  validate_runtime_file_path PROXY_PID "${PROXY_PID}"
  validate_runtime_file_path LEGACY_SOCAT_PID "${LEGACY_SOCAT_PID}"
  export DOCKER_HOST="unix://${DOCKER_SOCK}"

  local app_real data_real
  app_real="$(realpath -m -- "${APP_DIR}")"
  data_real="$(realpath -m -- "${DOCKER_DATA_ROOT}")"
  if [[ "${app_real}" == "${data_real}" || "${app_real}" == "${data_real}/"* || "${data_real}" == "${app_real}/"* ]]; then
    die "APP_DIR and DOCKER_DATA_ROOT must be separate, non-nested directories."
  fi

  is_uint "${DOCKER_START_TIMEOUT}" || die "DOCKER_START_TIMEOUT must be an integer from 10 to 300."
  DOCKER_START_TIMEOUT=$((10#${DOCKER_START_TIMEOUT}))
  (( DOCKER_START_TIMEOUT >= 10 && DOCKER_START_TIMEOUT <= 300 )) \
    || die "DOCKER_START_TIMEOUT must be an integer from 10 to 300."

  case "${DOCKER_LOG_LEVEL}" in
    debug|info|warn|error|fatal) ;;
    *) die "DOCKER_LOG_LEVEL must be debug, info, warn, error, or fatal." ;;
  esac

  local image
  for image in "${HASHTOPOLIS_BACKEND_IMAGE}" "${HASHTOPOLIS_FRONTEND_IMAGE}" "${DB_IMAGE}" "${NGINX_IMAGE}"; do
    [[ -n "${image}" && "${image}" != *[[:space:]]* ]] || die "Container image references cannot be empty or contain whitespace."
  done

  case "${PULL_IMAGES}" in
    1) PULL_IMAGES=always ;;
    0) PULL_IMAGES=never ;;
    always|missing|never) ;;
    *) die "PULL_IMAGES must be always, missing, never, 1, or 0." ;;
  esac

  case "${DOCKER_STORAGE_DRIVER}" in
    auto|overlay2|vfs) ;;
    *) die "DOCKER_STORAGE_DRIVER must be auto, overlay2, or vfs." ;;
  esac

  if [[ -n "${PUBLIC_URL}" ]]; then
    [[ "${PUBLIC_URL}" =~ ^https?://(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+)(:[0-9]+)?/?$ ]] \
      || die "PUBLIC_URL must be an HTTP(S) origin without credentials, path, query, or fragment."
    PUBLIC_URL="${PUBLIC_URL%/}"
  fi
}

show_capability_summary() {
  local sys_admin="missing" net_admin="missing"
  has_effective_cap 21 && sys_admin="present"
  has_effective_cap 12 && net_admin="present"
  info "Outer runtime capabilities: CAP_SYS_ADMIN=${sys_admin}, CAP_NET_ADMIN=${net_admin}"
  info "CapEff=$(cap_effective_hex), Seccomp=$(awk '/^Seccomp:/ {print $2}' /proc/self/status)"
}

validate_nested_runtime() {
  show_capability_summary

  if ! has_effective_cap 21 || ! has_effective_cap 12; then
    if [[ "${ALLOW_UNPRIVILEGED_ATTEMPT}" == "1" ]]; then
      warn "Required capabilities are missing, but ALLOW_UNPRIVILEGED_ATTEMPT=1 was set. dockerd will probably fail."
    else
      cat >&2 <<'EOF'

ROOTFUL DOCKER-IN-DOCKER IS NOT AVAILABLE

The outer container did not receive CAP_SYS_ADMIN and CAP_NET_ADMIN.
Installing more packages or changing dockerd flags cannot create capabilities
which the provider removed. Current Vast.ai template documentation accepts
ports/environment/hostname options and ignores other docker-run flags such as
--privileged. Use './run.sh preflight' before deployment.

Use a runtime that actually grants privileged nested containers, or replace
this architecture with a single prebuilt/native Hashtopolis image.
EOF
      die "Missing capabilities required by rootful Docker-in-Docker."
    fi
  fi

  local probe_dir="/tmp/kiquai-mount-probe.$$"
  mkdir -p "${probe_dir}"
  if mount -t tmpfs -o size=1m tmpfs "${probe_dir}" 2>/dev/null; then
    umount "${probe_dir}" 2>/dev/null || true
    rmdir "${probe_dir}" 2>/dev/null || true
    success "Mount namespace probe passed."
  else
    rmdir "${probe_dir}" 2>/dev/null || true
    die "CAP_SYS_ADMIN is visible, but a tmpfs mount is blocked by the outer runtime."
  fi

  if unshare -n true 2>/dev/null; then
    success "Network namespace probe passed."
  else
    die "Network namespace creation is blocked by the outer runtime/seccomp profile."
  fi
}

validate_gpu() {
  have_cmd nvidia-smi || die "nvidia-smi is unavailable. Use an NVIDIA/CUDA Vast.ai image."
  nvidia-smi -L || die "The NVIDIA GPU is not exposed to the outer container."
  nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader
}

resolve_public_url() {
  local port_var detected_port authority scheme effective_port
  PUBLIC_IP="${PUBLIC_IPADDR-}"
  port_var="VAST_TCP_PORT_${INTERNAL_PORT}"
  detected_port="${!port_var-}"
  PUBLIC_PORT="${detected_port:-${INTERNAL_PORT}}"
  validate_port PUBLIC_PORT "${PUBLIC_PORT}"

  if [[ -z "${PUBLIC_IP}" ]] && have_cmd curl; then
    PUBLIC_IP="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "${PUBLIC_IP}" ]]; then
    PUBLIC_IP="127.0.0.1"
    warn "PUBLIC_IPADDR is empty and public-IP discovery failed. Set PUBLIC_URL manually."
  fi

  if [[ -z "${PUBLIC_URL}" ]]; then
    PUBLIC_URL="http://${PUBLIC_IP}:${PUBLIC_PORT}"
  fi

  scheme="${PUBLIC_URL%%://*}"
  authority="${PUBLIC_URL#*://}"
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
  validate_port PUBLIC_PORT "${PUBLIC_PORT}"

  if [[ -z "${detected_port}" ]]; then
    warn "${port_var} is not set. The displayed public URL may need a manual PUBLIC_URL override."
  fi
}

port_is_listening() {
  ss -ltnH "sport = :$1" 2>/dev/null | grep -q .
}

proxy_pid_is_ours() {
  local pid=""
  [[ -r "${PROXY_PID}" ]] || return 1
  pid="$(<"${PROXY_PID}")"
  is_uint "${pid}" || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  [[ -r "/proc/${pid}/cmdline" ]] || return 1
  tr '\0' ' ' < "/proc/${pid}/cmdline" | grep -Fq "${APP_DIR}/kiquai-proxy-watchdog.sh"
}

legacy_socat_pid_is_ours() {
  local pid="" command_line=""
  [[ -r "${LEGACY_SOCAT_PID}" ]] || return 1
  pid="$(<"${LEGACY_SOCAT_PID}")"
  is_uint "${pid}" || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  [[ -r "/proc/${pid}/cmdline" ]] || return 1
  command_line="$(tr '\0' ' ' < "/proc/${pid}/cmdline")"
  [[ "${command_line}" == *socat*"TCP-LISTEN:${INTERNAL_PORT}"*"${PROXY_STATIC_IP}:80"* ]]
}

validate_host_port() {
  if proxy_pid_is_ours; then
    info "Port ${INTERNAL_PORT} is owned by the existing KiQuai proxy and will be reused."
    return 0
  fi
  if legacy_socat_pid_is_ours; then
    info "Port ${INTERNAL_PORT} is owned by the legacy KiQuai socat process and will be migrated."
    return 0
  fi
  if port_is_listening "${INTERNAL_PORT}"; then
    ss -ltnp "sport = :${INTERNAL_PORT}" || true
    die "Port ${INTERNAL_PORT} is occupied by another process."
  fi
}

############################
# Packages and Hashcat      #
############################

install_packages() {
  if [[ "${SKIP_APT}" == "1" ]]; then
    info "SKIP_APT=1; validating existing commands instead of installing packages."
    local command
    for command in curl jq openssl python3 socat ss mount unshare hashcat; do
      have_cmd "${command}" || die "SKIP_APT=1 but '${command}' is missing."
    done
    return 0
  fi

  retry 4 5 apt-get -o Acquire::Retries=3 update
  retry 3 5 apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    iproute2 \
    iptables \
    jq \
    kmod \
    libcap2-bin \
    ocl-icd-libopencl1 \
    clinfo \
    openssl \
    p7zip-full \
    procps \
    psmisc \
    python3 \
    python3-pip \
    python3-psutil \
    python3-requests \
    python3-venv \
    socat \
    unzip \
    util-linux \
    hashcat
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
      die "hashcat -I failed with exit code ${rc}; the deployment would not be able to use the GPU."
    fi
    warn "Hashcat device detection failed, but REQUIRE_HASHCAT_GPU=0 allows server-only deployment."
    return 0
  fi

  if ! grep -Eq '(Backend Device ID|Device #[[:space:]]*[0-9]+)' "${HASHCAT_LOG}"; then
    if [[ "${REQUIRE_HASHCAT_GPU}" == "1" ]]; then
      die "Hashcat returned successfully but no compute device was detected."
    fi
    warn "No Hashcat compute device was detected."
  else
    success "Hashcat detected at least one compute device."
  fi
}

install_docker_engine() {
  if have_cmd docker && have_cmd dockerd && docker compose version >/dev/null 2>&1; then
    info "Docker Engine CLI, dockerd, and Compose plugin are already installed."
    docker --version
    docker compose version
    return 0
  fi

  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Automatic Docker installation supports Ubuntu only; detected ID='${ID:-unknown}'."

  install -m 0755 -d /etc/apt/keyrings
  retry 4 5 curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  local architecture
  architecture="$(dpkg --print-architecture)"
  tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: ${architecture}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  retry 4 5 apt-get -o Acquire::Retries=3 update
  local install_rc=0
  if [[ ! -e /usr/sbin/policy-rc.d ]]; then
    cat > /usr/sbin/policy-rc.d <<'POLICY'
#!/bin/sh
exit 101
POLICY
    chmod 755 /usr/sbin/policy-rc.d
    TEMP_POLICY_RC_CREATED=1
  fi

  if retry 3 5 apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
      docker-ce \
      docker-ce-cli \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin; then
    install_rc=0
  else
    install_rc=$?
  fi
  if [[ "${TEMP_POLICY_RC_CREATED}" == "1" ]]; then
    rm -f /usr/sbin/policy-rc.d
    TEMP_POLICY_RC_CREATED=0
  fi
  (( install_rc == 0 )) || return "${install_rc}"

  docker --version
  docker compose version
}

############################
# Network selection         #
############################

subnet_overlaps_host() {
  local candidate="$1" routes
  routes="$(ip -4 route show table main 2>/dev/null || true)"
  python3 - "${candidate}" "${routes}" <<'PY'
import ipaddress
import sys

candidate = ipaddress.ip_network(sys.argv[1], strict=False)
for line in sys.argv[2].splitlines():
    token = line.split(maxsplit=1)[0] if line.split() else ""
    if token in {"", "default", "broadcast", "local", "unreachable", "blackhole"}:
        continue
    try:
        route = ipaddress.ip_network(token, strict=False)
    except ValueError:
        continue
    if candidate.overlaps(route):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

subnet_valid() {
  python3 - "$1" <<'PY'
import ipaddress
import sys
try:
    network = ipaddress.ip_network(sys.argv[1], strict=True)
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if network.version == 4 and network.prefixlen <= 28 else 1)
PY
}

ip_in_subnet() {
  python3 - "$1" "$2" <<'PY'
import ipaddress
import sys
try:
    address = ipaddress.ip_address(sys.argv[1])
    network = ipaddress.ip_network(sys.argv[2], strict=True)
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if address in network and address not in {network.network_address, network.broadcast_address} else 1)
PY
}

subnet_host_ip() {
  python3 - "$1" "$2" <<'PY'
import ipaddress
import sys
network = ipaddress.ip_network(sys.argv[1], strict=True)
offset = int(sys.argv[2])
address = network.network_address + offset
if address not in network or address in {network.network_address, network.broadcast_address}:
    raise SystemExit(1)
print(address)
PY
}

select_free_subnet() {
  local candidate
  for candidate in \
    172.30.44.0/24 \
    172.29.44.0/24 \
    172.31.44.0/24 \
    10.254.44.0/24 \
    10.253.44.0/24; do
    if ! subnet_overlaps_host "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

select_smoke_subnet() {
  local candidate
  for candidate in 172.30.253.0/24 172.29.253.0/24 10.254.253.0/24; do
    if [[ "${candidate}" != "${COMPOSE_SUBNET}" ]] && ! subnet_overlaps_host "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

resolve_network_config() {
  local saved_subnet="" saved_proxy_ip=""
  if [[ "${WIPE_DATA}" != "1" ]]; then
    saved_subnet="$(dotenv_get COMPOSE_SUBNET 2>/dev/null || true)"
    saved_proxy_ip="$(dotenv_get PROXY_STATIC_IP 2>/dev/null || true)"
  fi

  if [[ -z "${COMPOSE_SUBNET}" || "${COMPOSE_SUBNET}" == "auto" ]]; then
    if [[ -n "${saved_subnet}" ]]; then
      COMPOSE_SUBNET="${saved_subnet}"
      info "Reusing saved Compose subnet ${COMPOSE_SUBNET}."
    else
      COMPOSE_SUBNET="$(select_free_subnet)" || die "No non-overlapping private /24 subnet was found. Set COMPOSE_SUBNET manually."
      info "Selected Compose subnet ${COMPOSE_SUBNET}."
    fi
  fi
  subnet_valid "${COMPOSE_SUBNET}" || die "COMPOSE_SUBNET='${COMPOSE_SUBNET}' is not a valid IPv4 subnet (maximum /28)."

  if [[ -z "${PROXY_STATIC_IP}" || "${PROXY_STATIC_IP}" == "auto" ]]; then
    if [[ -n "${saved_proxy_ip}" && "${COMPOSE_SUBNET}" == "${saved_subnet}" ]]; then
      PROXY_STATIC_IP="${saved_proxy_ip}"
    else
      PROXY_STATIC_IP="$(subnet_host_ip "${COMPOSE_SUBNET}" 10)"
    fi
  fi
  ip_in_subnet "${PROXY_STATIC_IP}" "${COMPOSE_SUBNET}" \
    || die "PROXY_STATIC_IP='${PROXY_STATIC_IP}' is not a usable address in ${COMPOSE_SUBNET}."

  SMOKE_SUBNET="$(select_smoke_subnet)" || die "No free subnet was found for the Docker bridge smoke test."
}

############################
# Inner Docker daemon       #
############################

docker_is_ready() {
  have_cmd docker && timeout 6 docker info >/dev/null 2>&1
}

pid_cmdline_contains() {
  local pid="$1" pattern="$2"
  [[ -r "/proc/${pid}/cmdline" ]] || return 1
  tr '\0' ' ' < "/proc/${pid}/cmdline" | grep -Fq -- "${pattern}"
}

find_owned_dockerd_pid() {
  local candidate
  while read -r candidate; do
    is_uint "${candidate}" || continue
    if pid_cmdline_contains "${candidate}" "${DOCKER_SOCK}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done < <(pgrep -x dockerd 2>/dev/null || true)
  return 1
}

stop_owned_dockerd() {
  local pid="" elapsed=0
  [[ -r "${DOCKER_PID}" ]] && pid="$(<"${DOCKER_PID}")"
  if ! is_uint "${pid}" || ! kill -0 "${pid}" 2>/dev/null; then
    pid="$(find_owned_dockerd_pid || true)"
    if [[ -z "${pid}" ]]; then
      rm -f "${DOCKER_PID}" "${DOCKER_SOCK}"
      return 0
    fi
  fi
  if ! pid_cmdline_contains "${pid}" "${DOCKER_SOCK}"; then
    die "PID file ${DOCKER_PID} points to PID ${pid}, but that process is not the KiQuai dockerd."
  fi

  info "Stopping stale KiQuai dockerd (PID ${pid})."
  kill -TERM "${pid}" 2>/dev/null || true
  while kill -0 "${pid}" 2>/dev/null && (( elapsed < 20 )); do
    sleep 1
    elapsed=$((elapsed + 1))
  done
  if kill -0 "${pid}" 2>/dev/null; then
    warn "dockerd did not stop within 20s; sending SIGKILL."
    kill -KILL "${pid}" 2>/dev/null || true
  fi
  rm -f "${DOCKER_PID}" "${DOCKER_SOCK}"
}

data_root_reset_is_safe() {
  [[ -d "${DOCKER_DATA_ROOT}" ]] || return 0

  # Images and failed daemon metadata are reproducible. Containers and named
  # volume _data directories may contain user state, so their presence blocks
  # automatic cleanup and storage-driver fallback.
  if [[ -n "$(find "${DOCKER_DATA_ROOT}/containers" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    return 1
  fi
  if [[ -n "$(find "${DOCKER_DATA_ROOT}/volumes" -mindepth 2 -maxdepth 2 -type d -name _data -print -quit 2>/dev/null)" ]]; then
    return 1
  fi
  return 0
}

infer_existing_storage_driver() {
  local marker="${DOCKER_DATA_ROOT}/.kiquai-storage-driver"
  if [[ -r "${marker}" ]]; then
    local value
    value="$(<"${marker}")"
    [[ "${value}" == "overlay2" || "${value}" == "vfs" ]] && printf '%s' "${value}" && return 0
  fi
  [[ -d "${DOCKER_DATA_ROOT}/overlay2" ]] && printf '%s' overlay2 && return 0
  [[ -d "${DOCKER_DATA_ROOT}/vfs" ]] && printf '%s' vfs && return 0
  return 1
}

choose_storage_driver() {
  local existing="" backing=""
  existing="$(infer_existing_storage_driver || true)"
  if [[ -n "${existing}" ]]; then
    if [[ "${DOCKER_STORAGE_DRIVER}" != "auto" && "${DOCKER_STORAGE_DRIVER}" != "${existing}" ]]; then
      die "Docker data root already uses ${existing}; refusing requested driver ${DOCKER_STORAGE_DRIVER} because volumes would become invisible."
    fi
    SELECTED_STORAGE_DRIVER="${existing}"
    info "Detected existing Docker storage driver ${SELECTED_STORAGE_DRIVER}."
    return 0
  fi

  if [[ "${DOCKER_STORAGE_DRIVER}" != "auto" ]]; then
    SELECTED_STORAGE_DRIVER="${DOCKER_STORAGE_DRIVER}"
    return 0
  fi

  mkdir -p "${DOCKER_DATA_ROOT}"
  backing="$(stat -f -c '%T' "${DOCKER_DATA_ROOT}" 2>/dev/null || echo unknown)"
  case "${backing}" in
    ext2/ext3|xfs)
      SELECTED_STORAGE_DRIVER=overlay2
      info "Backing filesystem is ${backing}; selecting overlay2."
      ;;
    overlayfs)
      SELECTED_STORAGE_DRIVER=vfs
      warn "Docker data root is on overlayfs; selecting vfs to avoid nested-overlay mount/quota failures."
      warn "vfs is reliable but consumes more disk. Put DOCKER_DATA_ROOT on /data (ext4/xfs) for overlay2 performance."
      ;;
    *)
      SELECTED_STORAGE_DRIVER=vfs
      warn "Backing filesystem '${backing}' is not in the conservative overlay2 allow-list; selecting vfs."
      ;;
  esac
}

prepare_cgroups_best_effort() {
  if [[ ! -d /sys/fs/cgroup ]]; then
    mkdir -p /sys/fs/cgroup || true
  fi

  if ! mountpoint -q /sys/fs/cgroup; then
    if mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null; then
      success "Mounted cgroup v2 inside the outer namespace."
    else
      warn "Could not mount /sys/fs/cgroup; the container smoke test will determine whether cgroups are usable."
      return 0
    fi
  fi

  if [[ -r /sys/fs/cgroup/cgroup.controllers ]]; then
    local probe="/sys/fs/cgroup/kiquai-probe-$$"
    if mkdir "${probe}" 2>/dev/null; then
      rmdir "${probe}" 2>/dev/null || true
      success "cgroup v2 child-creation probe passed."
    else
      warn "cgroup v2 is mounted but child creation is blocked; runc may fail."
    fi
  fi
}

start_dockerd_once() {
  local driver="$1" pid="" elapsed=0
  mkdir -p "${DOCKER_DATA_ROOT}" "${DOCKER_EXEC_ROOT}" "$(dirname "${DOCKER_SOCK}")" "$(dirname "${DOCKER_PID}")"
  rm -f "${DOCKER_SOCK}" "${DOCKER_PID}"
  : > "${DOCKER_LOG}"
  chmod 600 "${DOCKER_LOG}"

  info "Starting dockerd: storage=${driver}, socket=${DOCKER_SOCK}"
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
    --exec-opt native.cgroupdriver=cgroupfs \
    --log-level="${DOCKER_LOG_LEVEL}" \
    --shutdown-timeout=20 \
    > "${DOCKER_LOG}" 2>&1 &
  pid=$!

  while (( elapsed < DOCKER_START_TIMEOUT )); do
    if docker_is_ready; then
      SELECTED_STORAGE_DRIVER="$(docker info --format '{{.Driver}}')"
      printf '%s\n' "${SELECTED_STORAGE_DRIVER}" > "${DOCKER_DATA_ROOT}/.kiquai-storage-driver"
      return 0
    fi
    if ! kill -0 "${pid}" 2>/dev/null; then
      warn "dockerd exited before it became ready."
      return 1
    fi
    if (( elapsed > 0 && elapsed % 10 == 0 )); then
      info "Waiting for dockerd (${elapsed}/${DOCKER_START_TIMEOUT}s)..."
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  warn "dockerd readiness timed out after ${DOCKER_START_TIMEOUT}s."
  return 1
}

start_or_reuse_dockerd() {
  if docker_is_ready; then
    local root
    root="$(docker info --format '{{.DockerRootDir}}')"
    [[ "${root}" == "${DOCKER_DATA_ROOT}" ]] \
      || die "The configured socket points to a daemon with unexpected DockerRootDir='${root}'."
    SELECTED_STORAGE_DRIVER="$(docker info --format '{{.Driver}}')"
    if [[ ! -s "${DOCKER_LOG}" && -s "${LEGACY_DOCKER_LOG}" ]]; then
      DOCKER_LOG="${LEGACY_DOCKER_LOG}"
      info "Reused daemon is writing to legacy log ${DOCKER_LOG}."
    fi
    success "Reusing healthy KiQuai dockerd (driver=${SELECTED_STORAGE_DRIVER})."
  else
    stop_owned_dockerd
    prepare_cgroups_best_effort
    if data_root_reset_is_safe; then DATA_ROOT_RESET_SAFE=1; else DATA_ROOT_RESET_SAFE=0; fi
    choose_storage_driver

    if start_dockerd_once "${SELECTED_STORAGE_DRIVER}"; then
      :
    else
      tail -n 120 "${DOCKER_LOG}" >&2 || true
      stop_owned_dockerd

      if [[ "${SELECTED_STORAGE_DRIVER}" == "overlay2" && "${ALLOW_VFS_FALLBACK}" == "1" && "${DATA_ROOT_RESET_SAFE}" == "1" ]]; then
        warn "overlay2 failed and no containers/volume data exist; removing reproducible daemon state and retrying with vfs."
        find "${DOCKER_DATA_ROOT}" -mindepth 1 -delete 2>/dev/null || true
        start_dockerd_once vfs || die "dockerd failed with both overlay2 and vfs."
      else
        die "dockerd failed. Automatic driver switching was blocked to protect existing Docker volumes."
      fi
    fi
  fi

  cat > /etc/profile.d/kiquai-docker.sh <<EOF
export DOCKER_HOST='unix://${DOCKER_SOCK}'
EOF
  chmod 644 /etc/profile.d/kiquai-docker.sh

  docker info --format 'Docker ready: server={{.ServerVersion}} driver={{.Driver}} cgroup={{.CgroupDriver}} root={{.DockerRootDir}}'
}

cleanup_smoke_test() {
  docker rm -f kiquai-smoke-nginx >/dev/null 2>&1 || true
  docker network rm kiquai-smoke-net >/dev/null 2>&1 || true
}

smoke_test_docker() {
  cleanup_smoke_test

  if ! docker image inspect "${NGINX_IMAGE}" >/dev/null 2>&1; then
    [[ "${PULL_IMAGES}" != "never" ]] || die "${NGINX_IMAGE} is missing while PULL_IMAGES=never."
    retry 3 5 docker pull "${NGINX_IMAGE}"
  fi

  docker run --rm --network none "${NGINX_IMAGE}" nginx -v >/dev/null
  docker network create --driver bridge --subnet "${SMOKE_SUBNET}" kiquai-smoke-net >/dev/null
  local smoke_ip
  smoke_ip="$(subnet_host_ip "${SMOKE_SUBNET}" 10)"
  docker run -d --rm --name kiquai-smoke-nginx \
    --network kiquai-smoke-net --ip "${smoke_ip}" "${NGINX_IMAGE}" >/dev/null

  local elapsed=0
  while (( elapsed < 30 )); do
    if curl -fsS --max-time 2 "http://${smoke_ip}/" >/dev/null 2>&1; then
      cleanup_smoke_test
      success "runc and user-defined bridge smoke tests passed."
      return 0
    fi
    if ! docker inspect kiquai-smoke-nginx >/dev/null 2>&1; then
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  docker logs kiquai-smoke-nginx 2>/dev/null || true
  cleanup_smoke_test
  die "The outer namespace cannot reach an inner bridge container."
}

############################
# Stack configuration       #
############################

safe_wipe_app_dir() {
  validate_safe_absolute_path APP_DIR "${APP_DIR}"
  rm -rf -- "${APP_DIR}"
}

resolve_credentials() {
  resolve_saved_or_generate MYSQL_ROOT_PASS
  resolve_saved_or_default MYSQL_DATABASE "${MYSQL_DATABASE_DEFAULT}"
  resolve_saved_or_default MYSQL_USER "${MYSQL_USER_DEFAULT}"
  resolve_saved_or_generate MYSQL_PASSWORD
  resolve_saved_or_default HASHTOPOLIS_ADMIN_USER "${HASHTOPOLIS_ADMIN_USER_DEFAULT}"
  resolve_saved_or_generate HASHTOPOLIS_ADMIN_PASSWORD

  HASHTOPOLIS_APIV2_ENABLE="${HASHTOPOLIS_APIV2_ENABLE:-1}"
  HASHTOPOLIS_BACKEND_URL="${HASHTOPOLIS_BACKEND_URL:-${PUBLIC_URL}/api/v2}"
  HASHTOPOLIS_FRONTEND_PORT="${HASHTOPOLIS_FRONTEND_PORT:-${PUBLIC_PORT}}"

  [[ "${MYSQL_DATABASE}" =~ ^[A-Za-z0-9_]+$ ]] || die "MYSQL_DATABASE may contain only letters, numbers, and underscore."
  [[ "${MYSQL_USER}" =~ ^[A-Za-z0-9_]+$ ]] || die "MYSQL_USER may contain only letters, numbers, and underscore."
  [[ -n "${MYSQL_ROOT_PASS}" && "${MYSQL_ROOT_PASS}" =~ ^[A-Za-z0-9_.:@%+=,-]+$ ]] \
    || die "MYSQL_ROOT_PASS contains characters which are unsafe for the Hashtopolis/MySQL entrypoint."
  [[ -n "${MYSQL_PASSWORD}" && "${MYSQL_PASSWORD}" =~ ^[A-Za-z0-9_.:@%+=,-]+$ ]] \
    || die "MYSQL_PASSWORD contains characters which are unsafe for the Hashtopolis/MySQL entrypoint."
  [[ -n "${HASHTOPOLIS_ADMIN_USER}" ]] || die "HASHTOPOLIS_ADMIN_USER cannot be empty."
}

prepare_app_dir() {
  if [[ "${WIPE_DATA}" == "1" ]]; then
    warn "WIPE_DATA=1: database, Hashtopolis files, and saved credentials will be permanently deleted."
    stop_host_proxy
    if [[ -d "${APP_DIR}" && -f "${APP_DIR}/docker-compose.yml" ]]; then
      (cd "${APP_DIR}" && docker compose down -v --remove-orphans) || true
    fi
    safe_wipe_app_dir
  fi
  mkdir -p "${APP_DIR}"
  chmod 700 "${APP_DIR}"
  resolve_credentials
}

write_dotenv() {
  local target="${APP_DIR}/.env" temp="${APP_DIR}/.env.tmp.$$"
  : > "${temp}"
  write_env_line COMPOSE_PROJECT_NAME kiquai-hashtopolis "${temp}"
  write_env_line INTERNAL_PORT "${INTERNAL_PORT}" "${temp}"
  write_env_line DOCKER_SOCK "${DOCKER_SOCK}" "${temp}"
  write_env_line DOCKER_DATA_ROOT "${DOCKER_DATA_ROOT}" "${temp}"
  write_env_line DOCKER_EXEC_ROOT "${DOCKER_EXEC_ROOT}" "${temp}"
  write_env_line PUBLIC_URL "${PUBLIC_URL}" "${temp}"
  write_env_line PUBLIC_PORT "${PUBLIC_PORT}" "${temp}"
  write_env_line COMPOSE_SUBNET "${COMPOSE_SUBNET}" "${temp}"
  write_env_line PROXY_STATIC_IP "${PROXY_STATIC_IP}" "${temp}"
  write_env_line HASHTOPOLIS_BACKEND_IMAGE "${HASHTOPOLIS_BACKEND_IMAGE}" "${temp}"
  write_env_line HASHTOPOLIS_FRONTEND_IMAGE "${HASHTOPOLIS_FRONTEND_IMAGE}" "${temp}"
  write_env_line DB_IMAGE "${DB_IMAGE}" "${temp}"
  write_env_line NGINX_IMAGE "${NGINX_IMAGE}" "${temp}"
  write_env_line MYSQL_ROOT_PASS "${MYSQL_ROOT_PASS}" "${temp}"
  write_env_line MYSQL_DATABASE "${MYSQL_DATABASE}" "${temp}"
  write_env_line MYSQL_USER "${MYSQL_USER}" "${temp}"
  write_env_line MYSQL_PASSWORD "${MYSQL_PASSWORD}" "${temp}"
  write_env_line HASHTOPOLIS_ADMIN_USER "${HASHTOPOLIS_ADMIN_USER}" "${temp}"
  write_env_line HASHTOPOLIS_ADMIN_PASSWORD "${HASHTOPOLIS_ADMIN_PASSWORD}" "${temp}"
  write_env_line HASHTOPOLIS_APIV2_ENABLE "${HASHTOPOLIS_APIV2_ENABLE}" "${temp}"
  write_env_line HASHTOPOLIS_BACKEND_URL "${HASHTOPOLIS_BACKEND_URL}" "${temp}"
  write_env_line HASHTOPOLIS_FRONTEND_PORT "${HASHTOPOLIS_FRONTEND_PORT}" "${temp}"
  chmod 600 "${temp}"
  mv -f "${temp}" "${target}"
}

write_compose_file() {
  cat > "${APP_DIR}/docker-compose.yml" <<'YAML'
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
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot --password=\"$${MYSQL_ROOT_PASSWORD}\" --silent"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 30s
    stop_grace_period: 45s
    logging: &default-logging
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
    networks:
      - hashtopolis-net

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
      HASHTOPOLIS_FRONTEND_PORT: ${HASHTOPOLIS_FRONTEND_PORT}
      HASHTOPOLIS_APIV2_ENABLE: ${HASHTOPOLIS_APIV2_ENABLE}
    volumes:
      - hash_data:/usr/local/share/hashtopolis
      - ./php-overrides.ini:/usr/local/etc/php/conf.d/zz-kiquai.ini:ro
    depends_on:
      hashtopolis-db:
        condition: service_started
    healthcheck:
      test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/80"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 45s
    stop_grace_period: 30s
    logging: *default-logging
    networks:
      - hashtopolis-net

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
      retries: 24
      start_period: 20s
    stop_grace_period: 15s
    logging: *default-logging
    networks:
      - hashtopolis-net

  hashtopolis-proxy:
    image: ${NGINX_IMAGE}
    container_name: hashtopolis-proxy
    restart: unless-stopped
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      hashtopolis-backend:
        condition: service_started
      hashtopolis-frontend:
        condition: service_started
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1/healthz || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 18
      start_period: 10s
    stop_grace_period: 15s
    logging: *default-logging
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
YAML
  chmod 600 "${APP_DIR}/docker-compose.yml"
}

write_nginx_file() {
  cat > "${APP_DIR}/nginx.conf" <<'NGINX'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /var/run/nginx.pid;

events {
  worker_connections 2048;
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  server_tokens off;
  sendfile on;

  client_max_body_size 20G;
  client_body_timeout 3600s;
  proxy_connect_timeout 30s;
  proxy_read_timeout 3600s;
  proxy_send_timeout 3600s;

  map $http_x_forwarded_proto $kiquai_forwarded_proto {
    default $http_x_forwarded_proto;
    "" $scheme;
  }

  upstream frontend {
    server hashtopolis-frontend:80;
    keepalive 16;
  }

  upstream backend {
    server hashtopolis-backend:80;
    keepalive 16;
  }

  server {
    listen 80 default_server;

    location = /healthz {
      access_log off;
      add_header Content-Type text/plain;
      return 200 "ok\n";
    }

    location ^~ /api/ {
      proxy_pass http://backend;
      proxy_request_buffering off;
      proxy_http_version 1.1;
      proxy_set_header Connection "";
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $kiquai_forwarded_proto;
    }

    location ^~ /binaries/ {
      proxy_pass http://backend;
      proxy_request_buffering off;
      proxy_http_version 1.1;
      proxy_set_header Connection "";
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $kiquai_forwarded_proto;
    }

    location = /agents.php {
      proxy_pass http://backend;
      proxy_request_buffering off;
      proxy_http_version 1.1;
      proxy_set_header Connection "";
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $kiquai_forwarded_proto;
    }

    location / {
      proxy_pass http://frontend;
      proxy_http_version 1.1;
      proxy_set_header Connection "";
      proxy_set_header Host $http_host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $kiquai_forwarded_proto;
    }
  }
}
NGINX
  chmod 600 "${APP_DIR}/nginx.conf"
}

write_php_overrides() {
  cat > "${APP_DIR}/php-overrides.ini" <<'INI'
memory_limit = 512M
upload_max_filesize = 20G
post_max_size = 20G
max_execution_time = 3600
max_input_time = 3600
INI
  chmod 644 "${APP_DIR}/php-overrides.ini"
}

write_proxy_watchdog() {
  cat > "${APP_DIR}/kiquai-proxy-watchdog.sh" <<EOF
#!/usr/bin/env bash
set -u

child_pid=0
terminate() {
  if (( child_pid > 0 )); then
    kill -TERM "\${child_pid}" 2>/dev/null || true
    wait "\${child_pid}" 2>/dev/null || true
  fi
  exit 0
}
trap terminate INT TERM HUP

while :; do
  printf '[%s] starting socat: 0.0.0.0:${INTERNAL_PORT} -> ${PROXY_STATIC_IP}:80\n' "\$(date '+%F %T%z')"
  socat TCP4-LISTEN:${INTERNAL_PORT},fork,reuseaddr,bind=0.0.0.0 TCP4:${PROXY_STATIC_IP}:80 &
  child_pid=\$!
  wait "\${child_pid}"
  rc=\$?
  child_pid=0
  printf '[%s] socat exited with code %s; restarting in 2s\n' "\$(date '+%F %T%z')" "\${rc}"
  sleep 2
done
EOF
  chmod 700 "${APP_DIR}/kiquai-proxy-watchdog.sh"
}

write_log_helper() {
  cat > "${APP_DIR}/kiquai-logs.sh" <<EOF
#!/usr/bin/env bash
set -u
export DOCKER_HOST='unix://${DOCKER_SOCK}'
cd '${APP_DIR}' || exit 1

printf '\n===== docker compose ps -a =====\n'
docker compose ps -a || true
for service in hashtopolis-db hashtopolis-backend hashtopolis-frontend hashtopolis-proxy; do
  printf '\n===== %s: state =====\n' "\${service}"
  docker inspect --format='name={{.Name}} state={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}} oom={{.State.OOMKilled}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} ip={{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "\${service}" || true
  printf '\n===== %s: logs =====\n' "\${service}"
  docker logs --tail 220 "\${service}" || true
done
printf '\n===== dockerd tail =====\n'
tail -n 220 '${DOCKER_LOG}' || true
printf '\n===== host proxy tail =====\n'
tail -n 120 '${PROXY_LOG}' || true
EOF
  chmod 700 "${APP_DIR}/kiquai-logs.sh"
}

write_stack_files() {
  write_dotenv
  write_compose_file
  write_nginx_file
  write_php_overrides
  write_proxy_watchdog
  write_log_helper
  (cd "${APP_DIR}" && docker compose config --quiet)
  success "Compose and Nginx configuration validation passed."
}

############################
# Stack lifecycle           #
############################

pull_images() {
  local -a images=(
    "${DB_IMAGE}"
    "${HASHTOPOLIS_BACKEND_IMAGE}"
    "${HASHTOPOLIS_FRONTEND_IMAGE}"
    "${NGINX_IMAGE}"
  )
  local image

  for image in "${images[@]}"; do
    case "${PULL_IMAGES}" in
      always)
        info "Pulling ${image}"
        retry 3 5 docker pull "${image}"
        ;;
      missing)
        if docker image inspect "${image}" >/dev/null 2>&1; then
          info "Using cached image ${image}"
        else
          info "Image ${image} is missing; pulling it."
          retry 3 5 docker pull "${image}"
        fi
        ;;
      never)
        docker image inspect "${image}" >/dev/null 2>&1 \
          || die "Image ${image} is missing while PULL_IMAGES=never."
        ;;
    esac
  done
}

start_stack() {
  cd "${APP_DIR}"
  local -a args=(up -d --remove-orphans)
  [[ "${FORCE_RECREATE}" == "1" ]] && args+=(--force-recreate)
  docker compose "${args[@]}"

  # Nginx resolves Compose service names when it starts. Recreate only the
  # lightweight proxy after a normal reconciliation so it cannot retain stale
  # backend/frontend IPs when another service was recreated.
  if [[ "${FORCE_RECREATE}" != "1" ]]; then
    docker compose up -d --no-deps --force-recreate hashtopolis-proxy
  fi
}

wait_for_container() {
  local name="$1" max_seconds="$2" elapsed=0 previous=""
  while (( elapsed < max_seconds )); do
    local status health exit_code state
    status="$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || echo missing)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${name}" 2>/dev/null || echo missing)"
    exit_code="$(docker inspect -f '{{.State.ExitCode}}' "${name}" 2>/dev/null || echo 999)"
    state="status=${status}, health=${health}"

    if [[ "${state}" != "${previous}" ]] || (( elapsed % 30 == 0 )); then
      info "Waiting for ${name}: ${state} (${elapsed}/${max_seconds}s)"
      previous="${state}"
    fi

    if [[ "${status}" == "running" && ( "${health}" == "healthy" || "${health}" == "none" ) ]]; then
      success "${name} is ready (${state})."
      return 0
    fi
    if [[ "${status}" == "exited" || "${status}" == "dead" ]]; then
      docker logs --tail 180 "${name}" >&2 || true
      die "${name} is ${status} with exit code ${exit_code}."
    fi
    if [[ "${health}" == "unhealthy" ]]; then
      docker inspect -f '{{range .State.Health.Log}}{{println .End .ExitCode .Output}}{{end}}' "${name}" >&2 || true
      docker logs --tail 180 "${name}" >&2 || true
      die "${name} became unhealthy."
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  docker logs --tail 180 "${name}" >&2 || true
  die "Timed out after ${max_seconds}s waiting for ${name}."
}

wait_for_stack() {
  wait_for_container hashtopolis-db 360
  wait_for_container hashtopolis-backend 360
  wait_for_container hashtopolis-frontend 300
  wait_for_container hashtopolis-proxy 240

  local actual_ip
  actual_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' hashtopolis-proxy)"
  [[ "${actual_ip}" == "${PROXY_STATIC_IP}" ]] \
    || die "Proxy container IP is ${actual_ip}; expected ${PROXY_STATIC_IP}."
  curl -fsS --max-time 5 "http://${PROXY_STATIC_IP}/healthz" >/dev/null \
    || die "The outer namespace cannot reach the healthy proxy container at ${PROXY_STATIC_IP}."
}

stop_host_proxy() {
  if proxy_pid_is_ours; then
    local pid elapsed=0
    pid="$(<"${PROXY_PID}")"
    info "Stopping existing host proxy watchdog (PID ${pid})."
    kill -TERM "${pid}" 2>/dev/null || true
    while kill -0 "${pid}" 2>/dev/null && (( elapsed < 10 )); do
      sleep 1
      elapsed=$((elapsed + 1))
    done
    kill -KILL "${pid}" 2>/dev/null || true
  fi
  rm -f "${PROXY_PID}"

  if legacy_socat_pid_is_ours; then
    local legacy_pid
    legacy_pid="$(<"${LEGACY_SOCAT_PID}")"
    info "Stopping legacy KiQuai socat process (PID ${legacy_pid})."
    kill -TERM "${legacy_pid}" 2>/dev/null || true
    sleep 1
    kill -KILL "${legacy_pid}" 2>/dev/null || true
  fi
  rm -f "${LEGACY_SOCAT_PID}"
}

start_host_proxy() {
  stop_host_proxy
  if port_is_listening "${INTERNAL_PORT}"; then
    ss -ltnp "sport = :${INTERNAL_PORT}" || true
    die "Port ${INTERNAL_PORT} became occupied before the host proxy could start."
  fi

  if [[ -f "${PROXY_LOG}" ]] && [[ $(stat -c '%s' "${PROXY_LOG}" 2>/dev/null || echo 0) -gt 2097152 ]]; then
    mv -f "${PROXY_LOG}" "${PROXY_LOG}.1"
  fi
  touch "${PROXY_LOG}"
  chmod 600 "${PROXY_LOG}"

  nohup "${APP_DIR}/kiquai-proxy-watchdog.sh" >> "${PROXY_LOG}" 2>&1 &
  printf '%s\n' "$!" > "${PROXY_PID}"
  chmod 600 "${PROXY_PID}"

  local elapsed=0
  while (( elapsed < 60 )); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${INTERNAL_PORT}/healthz" >/dev/null 2>&1; then
      success "Host proxy is listening on 0.0.0.0:${INTERNAL_PORT}."
      return 0
    fi
    proxy_pid_is_ours || die "Host proxy watchdog exited unexpectedly."
    sleep 1
    elapsed=$((elapsed + 1))
  done
  die "Host proxy did not become reachable within 60s."
}

verify_http_routes() {
  local base="http://127.0.0.1:${INTERNAL_PORT}"
  curl -fsS --max-time 8 "${base}/healthz" >/dev/null
  curl -fsS --max-time 15 "${base}/" >/dev/null

  # API endpoints may return application-level errors for unauthenticated GETs;
  # connectivity is accepted for any non-5xx response.
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "${base}/api/server.php" || echo 000)"
  [[ "${code}" =~ ^[1-4][0-9][0-9]$ ]] || die "Legacy API connectivity check returned HTTP ${code}."
  success "Local frontend and legacy API route checks passed."
}

############################
# User-facing commands      #
############################

print_header() {
  print_rule
  printf '%s%s v%s%s\n' "${C_BOLD}" "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${C_RESET}"
  printf 'Rootful Docker-in-Docker / fail-fast diagnostics / idempotent reruns\n'
  print_rule
}

print_runtime_summary() {
  cat <<EOF
Configuration summary (secrets redacted):
  APP_DIR                 ${APP_DIR}
  INTERNAL_PORT           ${INTERNAL_PORT}
  PUBLIC_URL              ${PUBLIC_URL}
  DOCKER_HOST             ${DOCKER_HOST}
  DOCKER_DATA_ROOT        ${DOCKER_DATA_ROOT}
  STORAGE_DRIVER_REQUEST  ${DOCKER_STORAGE_DRIVER}
  COMPOSE_SUBNET          ${COMPOSE_SUBNET}
  PROXY_STATIC_IP         ${PROXY_STATIC_IP}
  BACKEND_IMAGE           ${HASHTOPOLIS_BACKEND_IMAGE}
  FRONTEND_IMAGE          ${HASHTOPOLIS_FRONTEND_IMAGE}
  DB_IMAGE                ${DB_IMAGE}
  PULL_IMAGES             ${PULL_IMAGES}
  MAIN_LOG                ${MAIN_LOG}
EOF
}

print_success() {
  cd "${APP_DIR}"
  docker compose ps -a

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
Credentials     : ${APP_DIR}/.env (mode 600)
Bootstrap log   : ${MAIN_LOG}
Dockerd log     : ${DOCKER_LOG}
Proxy log       : ${PROXY_LOG}
Docker socket   : ${DOCKER_HOST}

Useful commands:
  source /etc/profile.d/kiquai-docker.sh
  cd ${APP_DIR} && docker compose ps -a
  ${APP_DIR}/kiquai-logs.sh
  $(realpath "$0") status
  $(realpath "$0") diagnostics

Security notice: unless PUBLIC_URL points through a trusted HTTPS endpoint,
traffic is plain HTTP. Do not expose sensitive hashes or credentials without
TLS, a VPN, or a trusted tunnel.
EOF
}

usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Usage:
  ./run.sh                 Deploy or reconcile the stack (default)
  ./run.sh deploy          Same as above
  ./run.sh preflight       Check GPU and required outer capabilities only
  ./run.sh status          Show daemon, container, HTTP, and GPU status
  ./run.sh logs            Print bounded service/runtime logs
  ./run.sh diagnostics     Create a diagnostic report under ${LOG_DIR}
  ./run.sh stop            Stop public proxy and Compose services
  ./run.sh restart         Reconcile stack and force container recreation
  ./run.sh help            Show this help

Common overrides:
  PUBLIC_URL=http://IP:PORT ./run.sh
  APP_DIR=/data/kiquai-hashtopolis DOCKER_DATA_ROOT=/data/kiquai-docker ./run.sh
  FORCE_RECREATE=1 ./run.sh
  WIPE_DATA=1 ./run.sh
  PULL_IMAGES=always ./run.sh
  REQUIRE_HASHCAT_GPU=0 ./run.sh       # server-only deployment
EOF
}

command_preflight() {
  CURRENT_STAGE="preflight"
  require_root
  validate_base_config
  print_header
  validate_gpu
  validate_nested_runtime
  success "Preflight passed. The runtime exposes the minimum capabilities required to attempt DinD."
}

require_existing_docker() {
  docker_is_ready || die "KiQuai dockerd is not ready at ${DOCKER_HOST}; run './run.sh deploy' first."
  [[ -f "${APP_DIR}/docker-compose.yml" ]] || die "No stack configuration exists under ${APP_DIR}."
}

command_status() {
  require_root
  require_existing_docker
  docker info --format 'Docker: server={{.ServerVersion}} driver={{.Driver}} root={{.DockerRootDir}}'
  (cd "${APP_DIR}" && docker compose ps -a)
  if curl -fsS --max-time 5 "http://127.0.0.1:${INTERNAL_PORT}/healthz" >/dev/null 2>&1; then
    success "HTTP health check passed on 127.0.0.1:${INTERNAL_PORT}."
  else
    error "HTTP health check failed on 127.0.0.1:${INTERNAL_PORT}."
  fi
  nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader || true
  hashcat -I 2>/dev/null | sed -n '1,100p' || true
}

command_logs() {
  require_root
  require_existing_docker
  if [[ -x "${APP_DIR}/kiquai-logs.sh" ]]; then
    "${APP_DIR}/kiquai-logs.sh"
  else
    (cd "${APP_DIR}" && docker compose logs --tail 220)
  fi
}

command_diagnostics() {
  require_root
  collect_diagnostics
  success "Diagnostic report created: ${LAST_DIAGNOSTIC_FILE}"
}

command_stop() {
  require_root
  validate_base_config
  acquire_lock
  stop_host_proxy
  if docker_is_ready && [[ -f "${APP_DIR}/docker-compose.yml" ]]; then
    (cd "${APP_DIR}" && docker compose down --remove-orphans)
  fi
  success "Hashtopolis stack stopped. Docker volumes were preserved."
}

deploy() {
  require_root
  validate_base_config
  acquire_lock
  print_header

  begin_step "Preflight: outer runtime and NVIDIA GPU"
  validate_gpu
  validate_nested_runtime
  end_step

  begin_step "Install required system packages"
  install_packages
  end_step

  begin_step "Validate Hashcat GPU backend"
  validate_hashcat
  end_step

  begin_step "Install or validate Docker Engine and Compose"
  install_docker_engine
  end_step

  begin_step "Start or reuse isolated inner Docker daemon"
  start_or_reuse_dockerd
  end_step

  begin_step "Run runc and bridge-network smoke tests"
  resolve_public_url
  resolve_network_config
  validate_host_port
  smoke_test_docker
  end_step

  begin_step "Prepare credentials and stack configuration"
  prepare_app_dir
  write_stack_files
  print_runtime_summary
  end_step

  begin_step "Pull required container images"
  pull_images
  end_step

  begin_step "Create or reconcile Hashtopolis services"
  start_stack
  end_step

  begin_step "Wait for database, backend, frontend, and proxy health"
  wait_for_stack
  end_step

  begin_step "Expose and verify Hashtopolis HTTP service"
  start_host_proxy
  verify_http_routes
  end_step

  print_success
  DEPLOYMENT_COMPLETE=1
}

main() {
  local command="${1:-deploy}"
  case "${command}" in
    help|-h|--help)
      usage
      return 0
      ;;
    deploy|preflight|status|logs|diagnostics|stop|restart)
      ;;
    *)
      usage >&2
      printf '\nUnknown command: %s\n' "${command}" >&2
      return 2
      ;;
  esac

  require_root
  load_saved_runtime_config
  validate_log_config_early
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
      FORCE_RECREATE=1
      deploy
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
