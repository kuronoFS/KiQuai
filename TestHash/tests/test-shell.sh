#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TEMP_ROOT=""
cd "${ROOT_DIR}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

test_syntax_and_manifest() {
  local file
  for file in run.sh scripts/00-core.sh scripts/10-system.sh scripts/20-releases.sh \
      scripts/30-config.sh scripts/40-services.sh scripts/50-cli.sh; do
    bash -n "${file}" || fail "bash -n ${file}"
  done
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --external-sources --severity=error \
      run.sh scripts/00-core.sh scripts/10-system.sh scripts/20-releases.sh \
      scripts/30-config.sh scripts/40-services.sh scripts/50-cli.sh \
      tests/test-shell.sh || fail "ShellCheck error-level analysis"
  fi
  (
    cd scripts
    sha256sum -c manifest.sha256
  ) >/dev/null || fail "module manifest checksum"
  grep -qx '# kiquai-release: 3.2.0' scripts/manifest.sha256 \
    || fail "manifest release metadata"
  pass "syntax, release metadata, and manifest checksums"
}

test_runtime_environment_and_launchers() {
  local temp_root="$1"
  APP_DIR="${temp_root}/app"
  LOG_DIR="${temp_root}/log"
  LOCK_FILE="${temp_root}/app/run/test.lock"
  MAIN_LOG="${LOG_DIR}/bootstrap.log"
  HASHCAT_LOG="${LOG_DIR}/hashcat.log"
  INTERNAL_PORT=8080
  BACKEND_PORT=18080
  DB_PORT=13306
  PUBLIC_URL=http://127.0.0.1:8080
  PUBLIC_PORT=8080
  HASHTOPOLIS_VERSION=v1.0.0-rc2
  HASHTOPOLIS_FRONTEND_VERSION=v1.0.0-rc2
  HASHTOPOLIS_SERVER_REPOSITORY=https://github.com/hashtopolis/server.git
  HASHTOPOLIS_FRONTEND_REPOSITORY=https://github.com/hashtopolis/web-ui.git
  MYSQL_ROOT_PASS=test-root
  MYSQL_DATABASE=hashtopolis
  MYSQL_USER=hashtopolis
  MYSQL_PASSWORD=test-app
  HASHTOPOLIS_ADMIN_USER="admin"
  HASHTOPOLIS_ADMIN_PASSWORD=test-admin
  HASHTOPOLIS_BACKEND_URL=http://127.0.0.1:8080/api/v2
  HASHTOPOLIS_FRONTEND_PORT=8080
  AGENT_ENABLED=0
  AGENT_VOUCHER=""
  AGENT_DOWNLOAD_URL=""
  apply_defaults
  mkdir -p "${CONFIG_DIR}" "${RUN_DIR}" "${LOG_DIR}"
  write_dotenv
  printf 'test-run\n' > "${RUN_DIR}/current-run-id"
  write_runtime_environment
  write_backend_launcher
  write_agent_launcher
  write_supervisor_config

  bash -n "${RUNTIME_ENV_FILE}" "${CONFIG_DIR}/start-backend.sh" \
    "${CONFIG_DIR}/start-agent.sh" || fail "generated launcher syntax"
  if grep -q 'setup[.]php' "${CONFIG_DIR}/start-backend.sh"; then
    fail "backend launcher must not execute migrations"
  fi
  grep -q 'BACKEND_READY_FILE' "${CONFIG_DIR}/start-backend.sh" \
    || fail "backend migration gate"
  [[ "$(awk '$0 == "[program:mysql]" {p=1;next} /^\[/ {p=0} p && /^autostart=/ {sub(/^autostart=/, ""); print}' "${SUPERVISOR_CONFIG}")" == "true" ]] \
    || fail "MySQL must be the only service allowed to autostart"
  local program
  for program in backend nginx agent; do
    [[ "$(awk -v wanted="program:${program}" '$0 == "[" wanted "]" {p=1;next} /^\[/ {p=0} p && /^autostart=/ {sub(/^autostart=/, ""); print}' "${SUPERVISOR_CONFIG}")" == "false" ]] \
      || fail "${program} must wait for explicit orchestration"
  done

  KIQUAI_RUNTIME_CONFIG_LOADED=1
  # This must not source SCRIPT_VERSION from .env over the readonly core value.
  # shellcheck disable=SC1090
  source "${RUNTIME_ENV_FILE}"
  [[ "${HASHTOPOLIS_FRONTEND_PORT}" == "8080" ]] \
    || fail "runtime environment exports frontend port"
  pass "runtime environment and generated launchers"
}

test_migration_guard_queries() {
  if (
    mysql_app_exec() { return 2; }
    failed_migration_rows
  ); then
    fail "migration inspection errors must not be treated as a clean database"
  fi

  local rows=""
  rows="$(
    mysql_app_exec() {
      if [[ "$*" == *information_schema.tables* ]]; then
        printf '1\n'
      else
        printf '20251127000000\tinitial\t2026-07-11 14:29:50\n'
      fi
    }
    failed_migration_rows
  )" || fail "dirty migration query"
  [[ "${rows}" == 20251127000000$'\t'* ]] \
    || fail "dirty migration row must be surfaced"
  pass "migration state inspection fails closed and exposes dirty rows"
}

test_http_contract() {
  local MOCK_HTTP_STATUS=404
  curl() {
    if [[ "$*" == *api/server.php* ]]; then
      printf '{"action":"testConnection","response":"SUCCESS"}\n%s' "${MOCK_HTTP_STATUS}"
    else
      printf '%s' "${MOCK_HTTP_STATUS}"
    fi
  }
  jq() { return 0; }

  if check_http_contract; then
    fail "HTTP 404 must not pass the health contract"
  fi
  MOCK_HTTP_STATUS=200
  check_http_contract || fail "valid frontend/API contract"
  unset -f curl jq
  pass "health check rejects 404 and accepts the exact API contract"
}

test_public_url_rederivation() {
  CALLER_SET[PUBLIC_URL]=1
  CALLER_SET[HASHTOPOLIS_BACKEND_URL]=0
  CALLER_SET[HASHTOPOLIS_FRONTEND_PORT]=0
  PUBLIC_URL=https://new.example.test
  PUBLIC_PORT=443
  HASHTOPOLIS_BACKEND_URL=http://old.example.test/api/v2
  HASHTOPOLIS_FRONTEND_PORT=80
  resolve_credentials
  [[ "${HASHTOPOLIS_BACKEND_URL}" == "https://new.example.test/api/v2" ]] \
    || fail "PUBLIC_URL must refresh derived backend URL"
  [[ "${HASHTOPOLIS_FRONTEND_PORT}" == "443" ]] \
    || fail "PUBLIC_URL must refresh derived frontend port"
  pass "PUBLIC_URL dependent values are re-derived"
}

test_deploy_order() {
  local -a events=()
  record() { events+=("$1"); }
  acquire_lock() { :; }
  print_header() { :; }
  begin_step() { :; }
  end_step() { :; }
  validate_outer_runtime() { :; }
  install_packages() { :; }
  wipe_data_if_requested() { :; }
  prepare_layout() { :; }
  stop_legacy_dind_runtime() { :; }
  archive_legacy_dind_config() { :; }
  validate_service_ports() { :; }
  write_dotenv() { :; }
  print_runtime_summary() { :; }
  configure_nvidia_runtime() { :; }
  validate_hashcat() { :; }
  install_sqlx() { :; }
  build_server_release() { record build-server; }
  build_frontend_release() { record build-frontend; }
  quiesce_application_services() { record quiesce; }
  activate_releases() { record activate; }
  write_runtime_configs() { record write-config; }
  initialize_mysql_data() { record mysql-init; }
  start_or_reload_supervisor() { record supervisor; }
  restart_or_start_supervisor_program() { record "restart-$1"; }
  wait_for_mysql() { record mysql-wait; }
  provision_database() { record db-provision; }
  run_backend_setup() { record migrate; }
  start_web_services_after_migration() { record web-start; }
  wait_for_http() { record http-check; }
  download_agent() { record agent-download; }
  reconcile_agent_process() { record agent-reconcile; }
  print_success() { record final; }

  AGENT_ENABLED=0
  RUN_ID=test-order
  mkdir -p "${RUN_DIR}"
  deploy
  local actual="${events[*]}"
  local expected='build-server build-frontend quiesce activate write-config mysql-init supervisor restart-mysql mysql-wait db-provision migrate web-start http-check agent-download agent-reconcile final'
  [[ "${actual}" == "${expected}" ]] \
    || fail "deploy order: expected '${expected}', got '${actual}'"
  pass "deterministic deploy/migration/service order"
}

test_loader_cache() {
  local temp_root="$1"
  local cache_dir="${temp_root}/module-cache"
  local loader_log="${temp_root}/loader.log"
  local base_url="file://${ROOT_DIR}"
  local loader_path="${PATH}"
  local windows_root=""

  if command -v cygpath >/dev/null 2>&1; then
    windows_root="$(cygpath -w "${ROOT_DIR}")"
    windows_root="${windows_root//\\//}"
    base_url="file:///${windows_root}"
  fi

  if ! command -v flock >/dev/null 2>&1; then
    mkdir -p "${temp_root}/test-bin"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${temp_root}/test-bin/flock"
    chmod 700 "${temp_root}/test-bin/flock"
    loader_path="${temp_root}/test-bin:${PATH}"
  fi

  PATH="${loader_path}" \
  KIQUAI_BASE_URL="${base_url}" \
  KIQUAI_MODULE_DIR="${cache_dir}" \
  KIQUAI_LOADER_LOG="${loader_log}" \
    bash run.sh verify-modules \
    || fail "loader local verification"

  PATH="${loader_path}" \
  KIQUAI_BASE_URL="file://${temp_root}/missing" \
  KIQUAI_MODULE_DIR="${cache_dir}" \
  KIQUAI_LOADER_LOG="${loader_log}" \
    bash run.sh help >/dev/null \
    || fail "operational command from verified offline cache"
  pass "loader verification and offline operational cache"
}

run_tests() {
  TEST_TEMP_ROOT="$(mktemp -d)"
  trap 'rm -rf -- "${TEST_TEMP_ROOT}"' EXIT
  test_syntax_and_manifest
  test_runtime_environment_and_launchers "${TEST_TEMP_ROOT}"
  test_public_url_rederivation
  test_migration_guard_queries
  test_http_contract
  test_deploy_order
  test_loader_cache "${TEST_TEMP_ROOT}"
  printf 'All shell regression tests passed.\n'
}

export KIQUAI_MODULE_CONTEXT=1
export KIQUAI_LOADER_VERSION=3.2.0
export KIQUAI_MODULE_DIR=/tmp/kiquai-test-modules
export KIQUAI_LOADER_LOG=/tmp/kiquai-test-loader.log
# Modules must be sourced at script top level so their declare statements remain global.
# shellcheck disable=SC1091
source scripts/00-core.sh
# shellcheck disable=SC1091
source scripts/10-system.sh
# shellcheck disable=SC1091
source scripts/20-releases.sh
# shellcheck disable=SC1091
source scripts/30-config.sh
# shellcheck disable=SC1091
source scripts/40-services.sh
# shellcheck disable=SC1091
source scripts/50-cli.sh

run_tests "$@"
