#!/usr/bin/env bash
# shellcheck shell=bash

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 077

# Preserve the caller's original stdout. The explicit `credentials` command uses
# fd 3 only when it is attached to an interactive terminal; deploy/serve never
# print the admin password automatically.
exec 3>&1
readonly KIQUAI_CONSOLE_FD=3
export KIQUAI_CONSOLE_FD

# This file is intentionally small. It downloads, validates, caches, and loads
# the version-matched scripts listed in scripts/manifest.sha256.

readonly KIQUAI_LOADER_VERSION="3.2.1"
readonly KIQUAI_MODULE_API="1"
readonly -a KIQUAI_MODULES=(
  "00-core.sh"
  "10-system.sh"
  "20-releases.sh"
  "30-config.sh"
  "40-services.sh"
  "50-cli.sh"
)
readonly -a KIQUAI_REQUIRED_FUNCTIONS=(
  "timestamp"
  "install_packages"
  "build_server_release"
  "write_runtime_configs"
  "wait_for_mysql"
  "main"
)

KIQUAI_REPOSITORY="${KIQUAI_REPOSITORY:-kuronoFS/KiQuai}"
KIQUAI_REF="${KIQUAI_REF:-refs/heads/main}"
KIQUAI_BASE_URL="${KIQUAI_BASE_URL:-https://raw.githubusercontent.com/${KIQUAI_REPOSITORY}/${KIQUAI_REF}/TestHash}"
KIQUAI_MODULE_DIR="${KIQUAI_MODULE_DIR:-${APP_DIR:-/opt/kiquai-hashtopolis}/bootstrap/${KIQUAI_LOADER_VERSION}}"
KIQUAI_LOADER_LOG="${KIQUAI_LOADER_LOG:-${LOG_DIR:-/var/log/kiquai-hashtopolis}/loader.log}"
KIQUAI_REFRESH_MODULES="${KIQUAI_REFRESH_MODULES:-0}"
KIQUAI_REQUIRE_FRESH_MODULES="${KIQUAI_REQUIRE_FRESH_MODULES:-0}"

LOADER_STAGE="initialization"
LOADER_CURRENT_MODULE="run.sh"
LOADER_TEMP_DIR=""
LOADER_ERROR_SOURCE=""
LOADER_ERROR_LINE=""
LOADER_ERROR_FUNCTION=""
LOADER_ERROR_COMMAND=""
LOADER_RUN_ID="$(date '+%Y%m%dT%H%M%S%z')-$$"
LOADER_LOCK_HELD=0
LOADER_PUBLISH_DIR=""
LOADER_BACKUP_DIR=""

loader_timestamp() {
  date '+%Y-%m-%d %H:%M:%S%z'
}

loader_log() {
  local level="$1"
  shift
  printf '[%s] %-7s [run=%s] [module=%s] %s\n' \
    "$(loader_timestamp)" "${level}" "${LOADER_RUN_ID}" \
    "${LOADER_CURRENT_MODULE}" "$*"
}

loader_die() {
  LOADER_ERROR_SOURCE="${BASH_SOURCE[1]:-run.sh}"
  LOADER_ERROR_LINE="${BASH_LINENO[0]:-unknown}"
  LOADER_ERROR_FUNCTION="${FUNCNAME[1]:-loader}"
  LOADER_ERROR_COMMAND="$*"
  loader_log ERROR "$*"
  exit 1
}

loader_record_error() {
  local code="$1"
  local line="$2"
  local command="$3"
  local source="$4"
  local function_name="$5"
  LOADER_ERROR_SOURCE="${source}"
  LOADER_ERROR_LINE="${line}"
  LOADER_ERROR_FUNCTION="${function_name}"
  LOADER_ERROR_COMMAND="${command}"
  return 0
}

loader_cleanup() {
  if [[ -n "${LOADER_TEMP_DIR}" && -d "${LOADER_TEMP_DIR}" ]]; then
    rm -rf -- "${LOADER_TEMP_DIR}" \
      || loader_log WARN "Unable to remove loader temporary directory ${LOADER_TEMP_DIR}."
  fi
  LOADER_TEMP_DIR=""
  if [[ -n "${LOADER_BACKUP_DIR}" && -e "${LOADER_BACKUP_DIR}" ]] \
      && [[ ! -e "${KIQUAI_MODULE_DIR}" && ! -L "${KIQUAI_MODULE_DIR}" ]]; then
    mv "${LOADER_BACKUP_DIR}" "${KIQUAI_MODULE_DIR}" \
      || loader_log ERROR "Unable to restore module cache ${LOADER_BACKUP_DIR}."
  fi
  if [[ -n "${LOADER_PUBLISH_DIR}" && -e "${LOADER_PUBLISH_DIR}" ]]; then
    rm -rf -- "${LOADER_PUBLISH_DIR}" \
      || loader_log WARN "Unable to remove module publish staging ${LOADER_PUBLISH_DIR}."
  fi
  LOADER_PUBLISH_DIR=""
  LOADER_BACKUP_DIR=""
}

release_loader_lock() {
  if [[ "${LOADER_LOCK_HELD}" == "1" ]]; then
    flock -u 8 2>/dev/null || true
    exec 8>&-
    LOADER_LOCK_HELD=0
  fi
}

loader_on_exit() {
  local code="$1"
  trap - ERR EXIT INT TERM HUP
  set +e
  loader_cleanup
  release_loader_lock
  if (( code != 0 )); then
    printf '\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n' >&2
    printf 'MODULE LOADER FAILED (exit=%s, stage=%s)\n' "${code}" "${LOADER_STAGE}" >&2
    printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n' >&2
    printf 'Module  : %s\n' "${LOADER_CURRENT_MODULE}" >&2
    [[ -n "${LOADER_ERROR_SOURCE}" ]] && printf 'Source  : %s\n' "${LOADER_ERROR_SOURCE}" >&2
    [[ -n "${LOADER_ERROR_LINE}" ]] && printf 'Line    : %s\n' "${LOADER_ERROR_LINE}" >&2
    [[ -n "${LOADER_ERROR_FUNCTION}" ]] && printf 'Function: %s\n' "${LOADER_ERROR_FUNCTION}" >&2
    [[ -n "${LOADER_ERROR_COMMAND}" ]] && printf 'Command : %s\n' "${LOADER_ERROR_COMMAND}" >&2
    printf 'Log     : %s\n' "${KIQUAI_LOADER_LOG}" >&2
  fi
  exit "${code}"
}

loader_on_signal() {
  local signal="$1"
  LOADER_ERROR_SOURCE="${BASH_SOURCE[1]:-run.sh}"
  LOADER_ERROR_LINE="${BASH_LINENO[0]:-unknown}"
  LOADER_ERROR_FUNCTION="${FUNCNAME[1]:-loader}"
  LOADER_ERROR_COMMAND="interrupted by ${signal}"
  exit 130
}

setup_loader_logging() {
  local current_size=0
  mkdir -p "$(dirname "${KIQUAI_LOADER_LOG}")"
  if [[ -f "${KIQUAI_LOADER_LOG}" ]]; then
    current_size="$(stat -c '%s' "${KIQUAI_LOADER_LOG}" 2>/dev/null || printf '0')"
    if [[ "${current_size}" =~ ^[0-9]+$ ]] && (( current_size > 10485760 )); then
      mv -f "${KIQUAI_LOADER_LOG}" "${KIQUAI_LOADER_LOG}.1"
    fi
  fi
  touch "${KIQUAI_LOADER_LOG}"
  chmod 600 "${KIQUAI_LOADER_LOG}"
  exec > >(tee -a "${KIQUAI_LOADER_LOG}") 2>&1
}

install_loader_traps() {
  trap 'loader_record_error "$?" "$LINENO" "$BASH_COMMAND" "${BASH_SOURCE[0]:-run.sh}" "${FUNCNAME[0]:-main}"' ERR
  trap 'loader_on_exit "$?"' EXIT
  trap 'loader_on_signal INT' INT
  trap 'loader_on_signal TERM' TERM
  trap 'loader_on_signal HUP' HUP
}

require_loader_tools() {
  local tool
  for tool in awk bash chmod curl date dirname flock grep install mkdir mktemp mv realpath rm sha256sum stat tee touch; do
    command -v "${tool}" >/dev/null 2>&1 \
      || loader_die "Required bootstrap command '${tool}' is missing."
  done
}

validate_loader_config() {
  local canonical_module_dir=""
  local canonical_loader_log=""
  [[ "${KIQUAI_REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || loader_die "KIQUAI_REPOSITORY must use the owner/repository form."
  [[ "${KIQUAI_REF}" =~ ^[A-Za-z0-9._/-]+$ && "${KIQUAI_REF}" != *..* ]] \
    || loader_die "KIQUAI_REF contains unsupported characters."
  [[ "${KIQUAI_BASE_URL}" =~ ^(https?|file)://[^[:space:]]+$ ]] \
    || loader_die "KIQUAI_BASE_URL must be an HTTP(S) or file URL."
  [[ "${KIQUAI_MODULE_DIR}" == /* ]] \
    || loader_die "KIQUAI_MODULE_DIR must be an absolute path."
  [[ "${KIQUAI_LOADER_LOG}" == /* ]] \
    || loader_die "KIQUAI_LOADER_LOG must be an absolute path."
  [[ "${KIQUAI_MODULE_DIR}" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || loader_die "KIQUAI_MODULE_DIR contains unsupported characters."
  [[ "${KIQUAI_LOADER_LOG}" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || loader_die "KIQUAI_LOADER_LOG contains unsupported characters."
  canonical_module_dir="$(realpath -m -- "${KIQUAI_MODULE_DIR}")" \
    || loader_die "Unable to canonicalize KIQUAI_MODULE_DIR."
  canonical_loader_log="$(realpath -m -- "${KIQUAI_LOADER_LOG}")" \
    || loader_die "Unable to canonicalize KIQUAI_LOADER_LOG."
  case "${canonical_module_dir}" in
    /|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/proc|/proc/*|/run|/run/*|/sbin|/sbin/*|/sys|/sys/*|/usr|/usr/*|/var/log|/var/log/*)
      loader_die "Refusing unsafe KIQUAI_MODULE_DIR='${canonical_module_dir}'."
      ;;
  esac
  case "${canonical_loader_log}" in
    /|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/proc|/proc/*|/run|/run/*|/sbin|/sbin/*|/sys|/sys/*|/usr|/usr/*)
      loader_die "Refusing unsafe KIQUAI_LOADER_LOG='${canonical_loader_log}'."
      ;;
  esac
  KIQUAI_MODULE_DIR="${canonical_module_dir}"
  KIQUAI_LOADER_LOG="${canonical_loader_log}"
  [[ "${KIQUAI_REFRESH_MODULES}" == "0" || "${KIQUAI_REFRESH_MODULES}" == "1" ]] \
    || loader_die "KIQUAI_REFRESH_MODULES must be 0 or 1."
  [[ "${KIQUAI_REQUIRE_FRESH_MODULES}" == "0" || "${KIQUAI_REQUIRE_FRESH_MODULES}" == "1" ]] \
    || loader_die "KIQUAI_REQUIRE_FRESH_MODULES must be 0 or 1."
}

acquire_loader_lock() {
  local lock_file="${KIQUAI_MODULE_DIR}.lock"
  mkdir -p "$(dirname "${lock_file}")"
  exec 8>"${lock_file}"
  flock -w 90 8 \
    || loader_die "Timed out waiting for the module cache lock: ${lock_file}."
  LOADER_LOCK_HELD=1
}

fetch_file() {
  local url="$1"
  local destination="$2"
  curl -fsSL --retry 4 --retry-delay 2 --retry-all-errors \
    --connect-timeout 20 "${url}" -o "${destination}"
}

verify_manifest_shape() {
  local manifest="$1"
  local invalid_line
  local entry_count

  grep -qx "# kiquai-release: ${KIQUAI_LOADER_VERSION}" "${manifest}" \
    || loader_die "Manifest release does not match loader ${KIQUAI_LOADER_VERSION}."
  grep -qx "# kiquai-module-api: ${KIQUAI_MODULE_API}" "${manifest}" \
    || loader_die "Manifest module API does not match loader API ${KIQUAI_MODULE_API}."

  invalid_line="$(awk 'NF && $1 !~ /^#/ && NF != 2 { print NR; exit }' "${manifest}")" \
    || loader_die "Unable to parse the module manifest."
  [[ -z "${invalid_line}" ]] \
    || loader_die "Malformed manifest entry at line ${invalid_line}."
  entry_count="$(awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "${manifest}")" \
    || loader_die "Unable to count module manifest entries."
  [[ "${entry_count}" == "${#KIQUAI_MODULES[@]}" ]] \
    || loader_die "Manifest must contain exactly ${#KIQUAI_MODULES[@]} module entries; found ${entry_count}."
}

verify_module() {
  local manifest="$1"
  local module="$2"
  local module_path="$3"
  local expected
  local actual

  expected="$(awk -v wanted="${module}" '$1 !~ /^#/ && $2 == wanted { print $1 }' "${manifest}")" \
    || loader_die "Unable to read the expected SHA-256 for ${module}."
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] \
    || loader_die "Manifest has no unique SHA-256 for ${module}."
  actual="$(sha256sum "${module_path}")" \
    || loader_die "Unable to calculate SHA-256 for ${module}."
  actual="${actual%% *}"
  [[ "${actual}" == "${expected}" ]] \
    || loader_die "SHA-256 mismatch for ${module}: expected ${expected}, got ${actual}."
  grep -qx "# kiquai-module-api: ${KIQUAI_MODULE_API}" "${module_path}" \
    || loader_die "${module} does not declare module API ${KIQUAI_MODULE_API}."
  grep -qx "# kiquai-release: ${KIQUAI_LOADER_VERSION}" "${module_path}" \
    || loader_die "${module} does not declare release ${KIQUAI_LOADER_VERSION}."
  bash -n "${module_path}" \
    || loader_die "Bash syntax validation failed for ${module}."
}

cached_module_set_is_valid() {
  local manifest="${KIQUAI_MODULE_DIR}/manifest.sha256"
  local module=""
  local module_path=""
  local expected=""
  local actual=""
  local entry_count=""

  [[ -f "${manifest}" ]] || return 1
  grep -qx "# kiquai-release: ${KIQUAI_LOADER_VERSION}" "${manifest}" || return 1
  grep -qx "# kiquai-module-api: ${KIQUAI_MODULE_API}" "${manifest}" || return 1
  entry_count="$(awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "${manifest}")" \
    || return 1
  [[ "${entry_count}" == "${#KIQUAI_MODULES[@]}" ]] || return 1

  for module in "${KIQUAI_MODULES[@]}"; do
    module_path="${KIQUAI_MODULE_DIR}/${module}"
    [[ -f "${module_path}" ]] || return 1
    expected="$(awk -v wanted="${module}" '$1 !~ /^#/ && $2 == wanted { print $1 }' "${manifest}")" \
      || return 1
    [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual="$(sha256sum "${module_path}")" || return 1
    actual="${actual%% *}"
    [[ "${actual}" == "${expected}" ]] || return 1
    grep -qx "# kiquai-module-api: ${KIQUAI_MODULE_API}" "${module_path}" || return 1
    grep -qx "# kiquai-release: ${KIQUAI_LOADER_VERSION}" "${module_path}" || return 1
    bash -n "${module_path}" || return 1
  done
}

loader_command_prefers_cache() {
  [[ "${KIQUAI_REFRESH_MODULES}" == "0" ]] || return 1
  [[ "${KIQUAI_REQUIRE_FRESH_MODULES}" == "0" ]] || return 1
  case "${1:-deploy}" in
    help|-h|--help|preflight|status|logs|diagnostics|credentials|stop|agent-start|agent-stop)
      return 0
      ;;
  esac
  return 1
}

recover_interrupted_module_publish() {
  local candidate=""
  local restored=0

  for candidate in "${KIQUAI_MODULE_DIR}.new."*; do
    [[ -e "${candidate}" || -L "${candidate}" ]] || continue
    rm -rf -- "${candidate}" \
      || loader_die "Unable to remove stale module publish staging ${candidate}."
  done

  if [[ ! -e "${KIQUAI_MODULE_DIR}" && ! -L "${KIQUAI_MODULE_DIR}" ]]; then
    for candidate in "${KIQUAI_MODULE_DIR}.old."*; do
      [[ -e "${candidate}" || -L "${candidate}" ]] || continue
      if mv "${candidate}" "${KIQUAI_MODULE_DIR}" && cached_module_set_is_valid; then
        loader_log WARN "Recovered a verified module cache after an interrupted publish."
        restored=1
        break
      fi
      if [[ -e "${KIQUAI_MODULE_DIR}" || -L "${KIQUAI_MODULE_DIR}" ]]; then
        mv "${KIQUAI_MODULE_DIR}" "${candidate}" \
          || loader_die "Unable to put invalid recovered cache back at ${candidate}."
      fi
    done
  fi

  if cached_module_set_is_valid; then
    for candidate in "${KIQUAI_MODULE_DIR}.old."*; do
      [[ -e "${candidate}" || -L "${candidate}" ]] || continue
      rm -rf -- "${candidate}" \
        || loader_log WARN "Unable to remove stale module backup ${candidate}."
    done
  elif (( restored == 1 )); then
    loader_die "Recovered module cache unexpectedly failed revalidation."
  fi
}

download_and_verify_modules() {
  local manifest
  local module
  local module_path
  local publish_dir
  local backup_dir

  LOADER_STAGE="download module manifest"
  if ! LOADER_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kiquai-modules.XXXXXX")"; then
    LOADER_TEMP_DIR=""
    loader_die "Unable to create a loader temporary directory."
  fi
  [[ -n "${LOADER_TEMP_DIR}" && "${LOADER_TEMP_DIR}" == /* ]] \
    || loader_die "mktemp returned an unsafe loader path."
  mkdir -p "${LOADER_TEMP_DIR}/scripts" \
    || loader_die "Unable to create the temporary module staging directory."
  manifest="${LOADER_TEMP_DIR}/scripts/manifest.sha256"
  loader_log INFO "Fetching scripts/manifest.sha256."
  if ! fetch_file "${KIQUAI_BASE_URL}/scripts/manifest.sha256" "${manifest}"; then
    loader_log WARN "Unable to download scripts/manifest.sha256 for ref ${KIQUAI_REF}."
    loader_cleanup
    return 75
  fi
  verify_manifest_shape "${manifest}"

  LOADER_STAGE="download and verify modules"
  for module in "${KIQUAI_MODULES[@]}"; do
    LOADER_CURRENT_MODULE="${module}"
    module_path="${LOADER_TEMP_DIR}/scripts/${module}"
    if ! fetch_file "${KIQUAI_BASE_URL}/scripts/${module}" "${module_path}"; then
      loader_log WARN "Unable to download scripts/${module} for ref ${KIQUAI_REF}."
      loader_cleanup
      return 75
    fi
    verify_module "${manifest}" "${module}" "${module_path}"
    loader_log OK "Checksum, release metadata, and Bash syntax verified."
  done

  LOADER_STAGE="publish verified module cache"
  LOADER_CURRENT_MODULE="run.sh"
  publish_dir="${KIQUAI_MODULE_DIR}.new.$$"
  backup_dir="${KIQUAI_MODULE_DIR}.old.$$"
  LOADER_PUBLISH_DIR="${publish_dir}"
  LOADER_BACKUP_DIR="${backup_dir}"
  rm -rf -- "${publish_dir}" "${backup_dir}" \
    || loader_die "Unable to clear stale module publish directories."
  mkdir -p "${publish_dir}" \
    || loader_die "Unable to create the module publish directory."
  chmod 700 "${publish_dir}" \
    || loader_die "Unable to secure the module publish directory."
  for module in "${KIQUAI_MODULES[@]}"; do
    install -m 600 "${LOADER_TEMP_DIR}/scripts/${module}" "${publish_dir}/${module}" \
      || loader_die "Unable to stage verified module ${module}."
  done
  install -m 600 "${manifest}" "${publish_dir}/manifest.sha256" \
    || loader_die "Unable to stage the verified module manifest."

  if [[ -e "${KIQUAI_MODULE_DIR}" || -L "${KIQUAI_MODULE_DIR}" ]]; then
    mv "${KIQUAI_MODULE_DIR}" "${backup_dir}" \
      || loader_die "Unable to move the previous module cache aside."
  fi
  if ! mv "${publish_dir}" "${KIQUAI_MODULE_DIR}"; then
    [[ ! -e "${backup_dir}" ]] \
      || mv "${backup_dir}" "${KIQUAI_MODULE_DIR}" \
      || loader_log ERROR "Unable to restore the previous module cache."
    loader_die "Unable to atomically publish the verified module directory."
  fi
  LOADER_PUBLISH_DIR=""
  if ! cached_module_set_is_valid; then
    rm -rf -- "${KIQUAI_MODULE_DIR}" \
      || loader_log ERROR "Unable to remove the invalid published cache."
    [[ ! -e "${backup_dir}" ]] \
      || mv "${backup_dir}" "${KIQUAI_MODULE_DIR}" \
      || loader_log ERROR "Unable to restore the previous module cache."
    loader_die "Published module cache failed its post-activation verification."
  fi
  rm -rf -- "${backup_dir}" \
    || loader_log WARN "Unable to remove previous module cache backup ${backup_dir}."
  LOADER_BACKUP_DIR=""
  loader_cleanup
}

prepare_modules() {
  local command="${1:-deploy}"
  local download_rc=0
  if [[ "${command}" == "verify-modules" ]]; then
    KIQUAI_REQUIRE_FRESH_MODULES=1
  fi
  require_loader_tools
  validate_loader_config
  setup_loader_logging
  install_loader_traps
  acquire_loader_lock
  recover_interrupted_module_publish
  loader_log INFO "KiQuai module loader ${KIQUAI_LOADER_VERSION}; ref=${KIQUAI_REF}."
  if loader_command_prefers_cache "${command}" && cached_module_set_is_valid; then
    loader_log OK "Using the verified local module cache for operational command '${command}'."
    return 0
  fi

  if download_and_verify_modules; then
    return 0
  else
    download_rc=$?
  fi
  if (( download_rc == 75 )) && [[ "${KIQUAI_REQUIRE_FRESH_MODULES}" == "0" ]] \
      && cached_module_set_is_valid; then
    LOADER_CURRENT_MODULE="run.sh"
    loader_log WARN "Network refresh failed; falling back to the verified local module cache."
    return 0
  fi
  loader_die "No verified ${KIQUAI_LOADER_VERSION} module set is available (download exit=${download_rc})."
}

prepare_modules "$@"

# Source at the script's top level. Sourcing from inside a function would make
# top-level `declare` statements in a module local to that loader function.
LOADER_STAGE="load verified modules"
export KIQUAI_MODULE_CONTEXT=1
export KIQUAI_LOADER_VERSION KIQUAI_MODULE_DIR KIQUAI_LOADER_LOG
export KIQUAI_RUN_ID="${LOADER_RUN_ID}"
for _kiquai_module in "${KIQUAI_MODULES[@]}"; do
  LOADER_CURRENT_MODULE="${_kiquai_module}"
  # shellcheck disable=SC1090
  source "${KIQUAI_MODULE_DIR}/${_kiquai_module}"
  loader_log OK "Loaded verified module."
done
unset _kiquai_module

for _kiquai_function in "${KIQUAI_REQUIRED_FUNCTIONS[@]}"; do
  declare -F "${_kiquai_function}" >/dev/null \
    || loader_die "Required function '${_kiquai_function}' was not defined by the module set."
done
unset _kiquai_function
release_loader_lock

if [[ "${1:-}" == "verify-modules" ]]; then
  LOADER_CURRENT_MODULE="run.sh"
  LOADER_STAGE="complete"
  loader_log OK "All ${#KIQUAI_MODULES[@]} modules are verified and loadable."
  exit 0
fi

LOADER_CURRENT_MODULE="50-cli.sh"
LOADER_STAGE="dispatch command"
main "$@"
