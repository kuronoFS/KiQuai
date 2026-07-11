#!/usr/bin/env bash
# shellcheck shell=bash

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 077

# Preserve the caller's original stdout. Credential output uses fd 3 so secrets
# remain visible to the operator without being copied into loader/bootstrap logs.
exec 3>&1
readonly KIQUAI_CONSOLE_FD=3
export KIQUAI_CONSOLE_FD

# This file is intentionally small. It downloads, validates, caches, and loads
# the version-matched scripts listed in scripts/manifest.sha256.

readonly KIQUAI_LOADER_VERSION="3.1.1"
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

LOADER_STAGE="initialization"
LOADER_CURRENT_MODULE="run.sh"
LOADER_TEMP_DIR=""
LOADER_ERROR_SOURCE=""
LOADER_ERROR_LINE=""
LOADER_ERROR_FUNCTION=""
LOADER_ERROR_COMMAND=""

loader_timestamp() {
  date '+%Y-%m-%d %H:%M:%S%z'
}

loader_log() {
  local level="$1"
  shift
  printf '[%s] %-7s [module=%s] %s\n' \
    "$(loader_timestamp)" "${level}" "${LOADER_CURRENT_MODULE}" "$*"
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
    rm -rf -- "${LOADER_TEMP_DIR}"
  fi
  LOADER_TEMP_DIR=""
}

loader_on_exit() {
  local code="$1"
  trap - ERR EXIT INT TERM HUP
  set +e
  loader_cleanup
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
  for tool in bash curl sha256sum awk grep install mv mktemp tee; do
    command -v "${tool}" >/dev/null 2>&1 \
      || loader_die "Required bootstrap command '${tool}' is missing."
  done
}

validate_loader_config() {
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

  invalid_line="$(awk 'NF && $1 !~ /^#/ && NF != 2 { print NR; exit }' "${manifest}")"
  [[ -z "${invalid_line}" ]] \
    || loader_die "Malformed manifest entry at line ${invalid_line}."
  entry_count="$(awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "${manifest}")"
  [[ "${entry_count}" == "${#KIQUAI_MODULES[@]}" ]] \
    || loader_die "Manifest must contain exactly ${#KIQUAI_MODULES[@]} module entries; found ${entry_count}."
}

verify_module() {
  local manifest="$1"
  local module="$2"
  local module_path="$3"
  local expected
  local actual

  expected="$(awk -v wanted="${module}" '$1 !~ /^#/ && $2 == wanted { print $1 }' "${manifest}")"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] \
    || loader_die "Manifest has no unique SHA-256 for ${module}."
  actual="$(sha256sum "${module_path}")"
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

download_and_verify_modules() {
  local manifest
  local module
  local module_path
  local staged_path

  LOADER_STAGE="download module manifest"
  LOADER_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kiquai-modules.XXXXXX")"
  mkdir -p "${LOADER_TEMP_DIR}/scripts"
  manifest="${LOADER_TEMP_DIR}/scripts/manifest.sha256"
  loader_log INFO "Fetching scripts/manifest.sha256."
  if ! fetch_file "${KIQUAI_BASE_URL}/scripts/manifest.sha256" "${manifest}"; then
    loader_die "Unable to download scripts/manifest.sha256 for ref ${KIQUAI_REF}."
  fi
  verify_manifest_shape "${manifest}"

  LOADER_STAGE="download and verify modules"
  for module in "${KIQUAI_MODULES[@]}"; do
    LOADER_CURRENT_MODULE="${module}"
    module_path="${LOADER_TEMP_DIR}/scripts/${module}"
    if ! fetch_file "${KIQUAI_BASE_URL}/scripts/${module}" "${module_path}"; then
      loader_die "Unable to download scripts/${module} for ref ${KIQUAI_REF}."
    fi
    verify_module "${manifest}" "${module}" "${module_path}"
    loader_log OK "Checksum, release metadata, and Bash syntax verified."
  done

  LOADER_STAGE="publish verified module cache"
  LOADER_CURRENT_MODULE="run.sh"
  mkdir -p "${KIQUAI_MODULE_DIR}"
  chmod 700 "${KIQUAI_MODULE_DIR}"
  for module in "${KIQUAI_MODULES[@]}"; do
    staged_path="${KIQUAI_MODULE_DIR}/.${module}.new.$$"
    install -m 600 "${LOADER_TEMP_DIR}/scripts/${module}" "${staged_path}"
    mv -f "${staged_path}" "${KIQUAI_MODULE_DIR}/${module}"
  done
  staged_path="${KIQUAI_MODULE_DIR}/.manifest.sha256.new.$$"
  install -m 600 "${manifest}" "${staged_path}"
  mv -f "${staged_path}" "${KIQUAI_MODULE_DIR}/manifest.sha256"
  loader_cleanup
}

prepare_modules() {
  setup_loader_logging
  install_loader_traps
  require_loader_tools
  validate_loader_config
  loader_log INFO "KiQuai module loader ${KIQUAI_LOADER_VERSION}; ref=${KIQUAI_REF}."
  download_and_verify_modules
}

prepare_modules

# Source at the script's top level. Sourcing from inside a function would make
# top-level `declare` statements in a module local to that loader function.
LOADER_STAGE="load verified modules"
export KIQUAI_MODULE_CONTEXT=1
export KIQUAI_LOADER_VERSION KIQUAI_MODULE_DIR KIQUAI_LOADER_LOG
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

if [[ "${1:-}" == "verify-modules" ]]; then
  LOADER_CURRENT_MODULE="run.sh"
  LOADER_STAGE="complete"
  loader_log OK "All ${#KIQUAI_MODULES[@]} modules are verified and loadable."
  exit 0
fi

LOADER_CURRENT_MODULE="50-cli.sh"
LOADER_STAGE="dispatch command"
main "$@"
