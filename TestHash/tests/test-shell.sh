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
  grep -qx '# kiquai-release: 3.2.5' scripts/manifest.sha256 \
    || fail "manifest release metadata"
  pass "syntax, release metadata, and manifest checksums"
}

test_readme_operational_contract() {
  [[ "$(grep -c '^## ' README.md)" == "2" ]] \
    || fail "README must have exactly two top-level operational parts"
  grep -Fxq '## Part I — Quick way to deploy and configure' README.md \
    || fail "README quick deployment part"
  grep -Fxq '## Part II — Advanced guide' README.md \
    || fail "README advanced guide part"
  grep -Fq '### Vận hành trực tiếp từng component qua terminal' README.md \
    || fail "README direct component runbook"
  grep -Fq 'Release `3.2.5`' README.md \
    && grep -Fq 'lastAct=getTask' README.md \
    && grep -Fq '/static/7zr.bin' README.md \
    || fail "README agent polling regression notice"
  grep -Fq 'On-start phải chạy `deploy` one-shot' README.md \
    || fail "README SSH/On-start lifecycle"
  grep -Fq 'Docker ENTRYPOINT/workload phải dùng `serve`' README.md \
    || fail "README Docker ENTRYPOINT lifecycle"
  pass "README separates quick/advanced flows and documents direct operations"
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
  env -u CONFIG_DIR bash -u -c '
    source "$1"
    [[ "${CONFIG_DIR}" == "${APP_DIR}/config" ]]
    [[ -x "${CONFIG_DIR}/agent-wrapper.py" ]]
  ' _ "${RUNTIME_ENV_FILE}" \
    || fail "runtime environment must derive CONFIG_DIR for strict launchers"
  grep -qx 'CONFIG_DIR="${APP_DIR}/config"' "${CONFIG_DIR}/start-agent.sh" \
    || fail "agent launcher must re-derive CONFIG_DIR after sourcing runtime state"
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
  grep -q 'flock -n 6' "${CONFIG_DIR}/start-agent.sh" \
    || fail "agent launcher must hold an authoritative runtime flock"
  grep -q 'reconcile_upstream_agent_lock' "${CONFIG_DIR}/start-agent.sh" \
    || fail "agent launcher must reconcile the upstream PID lock"
  grep -q 'cleanup_orphan_agent_crackers' "${CONFIG_DIR}/start-agent.sh" \
    || fail "agent launcher must clean detached managed Hashcat groups"
  grep -q 'length > 0' "${CONFIG_DIR}/start-agent.sh" \
    || fail "agent launcher must require a completed registration token"
  [[ -x "${CONFIG_DIR}/agent-wrapper.py" ]] \
    || fail "agent compatibility wrapper must be generated as an executable"
  grep -q '7f6f00a9f1983e3d0f2db5f76f3bd8f0ffb20327ed77bb11659bb7740bff4da2' \
    "${CONFIG_DIR}/agent-wrapper.py" \
    || fail "agent wrapper must pin the official 0.7.4 archive SHA-256"
  grep -q '/usr/bin/python3 "${CONFIG_DIR}/agent-wrapper.py" --validate-only' \
    "${CONFIG_DIR}/start-agent.sh" \
    || fail "agent launcher must validate the pinned archive with system Python"
  grep -q '/usr/bin/python3 "${CONFIG_DIR}/agent-wrapper.py" "${AGENT_DIR}/hashtopolis.zip"' \
    "${CONFIG_DIR}/start-agent.sh" \
    || fail "agent launcher must keep all runtime execution behind the wrapper"
  grep -q -- '--disable-update' "${CONFIG_DIR}/start-agent.sh" \
    || fail "agent launcher must prevent upstream self-update from bypassing the wrapper"
  grep -q 'import psutil' "${CONFIG_DIR}/agent-wrapper.py" \
    && grep -q 'import requests' "${CONFIG_DIR}/agent-wrapper.py" \
    || fail "agent wrapper must validate its Python runtime dependencies"
  grep -q 'nvidia-smi' "${CONFIG_DIR}/agent-wrapper.py" \
    || fail "agent wrapper must discover NVIDIA GPUs hidden from container PCI enumeration"
  grep -q 'os.replace' "${CONFIG_DIR}/agent-wrapper.py" \
    && grep -q '.kiquai-stage-' "${CONFIG_DIR}/agent-wrapper.py" \
    && grep -q '.kiquai-quarantine' "${CONFIG_DIR}/agent-wrapper.py" \
    && grep -q -- '--version' "${CONFIG_DIR}/agent-wrapper.py" \
    || fail "agent wrapper must stage, validate, atomically install, and quarantine cracker caches"
  grep -q 'JsonRequest.execute = redacted_json_execute' "${CONFIG_DIR}/agent-wrapper.py" \
    && grep -q 'Initialize._Initialize__check_token = managed_check_token' "${CONFIG_DIR}/agent-wrapper.py" \
    && grep -q 'Initialize._Initialize__login = managed_login' "${CONFIG_DIR}/agent-wrapper.py" \
    || fail "agent wrapper must prevent recursive registration/login failures and credential debug logs"
  grep -q 'BinaryDownload._BinaryDownload__check_utils = hardened_check_utils' "${CONFIG_DIR}/agent-wrapper.py" \
    && grep -q 'BinaryDownload.check_prince = hardened_check_prince' "${CONFIG_DIR}/agent-wrapper.py" \
    && grep -q 'BinaryDownload.check_preprocessor = hardened_check_preprocessor' "${CONFIG_DIR}/agent-wrapper.py" \
    && grep -q 'HashcatCracker.preprocessor_keyspace = hardened_preprocessor_keyspace' "${CONFIG_DIR}/agent-wrapper.py" \
    || fail "agent wrapper must harden utility, Prince, preprocessor, and keyspace preparation"
  grep -q 'Deferring 7zr preparation until the first assigned task' \
      "${CONFIG_DIR}/agent-wrapper.py" \
    && grep -q 'This is the first task-dependent preparation step' \
      "${CONFIG_DIR}/agent-wrapper.py" \
    || fail "idle agent polling must not be gated by extractor preparation"
  if grep -q 'while not ensure_utility(self, "7zr", "7zr")' \
      "${CONFIG_DIR}/agent-wrapper.py"; then
    fail "agent wrapper must enter getTask polling before retrying 7zr"
  fi
  [[ "$(awk '$0 == "[program:agent]" {p=1;next} /^\[/ {p=0} p && /^stopsignal=/ {sub(/^stopsignal=/, ""); print}' "${SUPERVISOR_CONFIG}")" == "INT" ]] \
    || fail "Supervisor must stop the Python agent with SIGINT for lock cleanup"
  grep -q '^environment=PYTHONUNBUFFERED="1"$' "${SUPERVISOR_CONFIG}" \
    || fail "agent output must be unbuffered for actionable crash logs"

  KIQUAI_RUNTIME_CONFIG_LOADED=1
  # This must not source SCRIPT_VERSION from .env over the readonly core value.
  # shellcheck disable=SC1090
  source "${RUNTIME_ENV_FILE}"
  [[ "${HASHTOPOLIS_FRONTEND_PORT}" == "8080" ]] \
    || fail "runtime environment exports frontend port"
  pass "runtime environment and generated launchers"
}

test_self_test_helper_contract() (
  local temp_root="$1"
  local helper=""
  local cleanup_block=""
  local task_cleanup_line=""
  local file_cleanup_line=""
  local hashlist_cleanup_line=""
  local expected=""
  local output=""

  APP_DIR="${temp_root}/self-test-helper-app"
  LOG_DIR="${temp_root}/self-test-helper-log"
  INTERNAL_PORT=18088
  apply_defaults
  mkdir -p "${CONFIG_DIR}" "${LOG_DIR}"
  write_self_test_helper
  helper="${CONFIG_DIR}/self-test.py"

  [[ -f "${helper}" && ! -L "${helper}" && -x "${helper}" ]] \
    || fail "generated self-test helper must be an executable regular file"
  grep -Fq 'API_BASE = "http://127.0.0.1:18088/api/v2"' "${helper}" \
    && grep -Fq 'candidate != API_BASE' "${helper}" \
    && grep -Fq 'parsed.hostname != "127.0.0.1"' "${helper}" \
    && grep -Fq 'self.session.trust_env = False' "${helper}" \
    || fail "self-test API access must be pinned to loopback and ignore proxy state"
  grep -Fq 'stat.S_IMODE(info.st_mode) != 0o600' "${helper}" \
    && grep -Fq 'info.st_uid != os.geteuid()' "${helper}" \
    && grep -Fq 'getattr(os, "O_NOFOLLOW", 0)' "${helper}" \
    && grep -Fq 'fd = os.open(temporary, flags, 0o600)' "${helper}" \
    && grep -Fq 'os.chmod(path, 0o600)' "${helper}" \
    && grep -Fq 'chmod 600 "${credentials_file}"' scripts/50-cli.sh \
    || fail "self-test credentials and mutable recovery state must remain mode 0600"

  grep -Fq 'PASSWORD = "KiQuai-22000!"' "${helper}" \
    && grep -Fq '"WPA*01*86bcdc2ba467ec375e3bf879035280c9*020000000001*"' "${helper}" \
    && grep -Fq '"020000000002*4b695175616953656c6654657374***"' "${helper}" \
    || fail "self-test must retain the exact deterministic mode-22000 fixture"
  grep -Fq 'body = {"data": {"type": resource_type, "attributes": attributes}}' "${helper}" \
    && grep -Fq 'headers["Content-Type"] = "application/vnd.api+json"' "${helper}" \
    && grep -Fq 'self.session.headers.update({"Accept": "application/vnd.api+json"})' "${helper}" \
    || fail "self-test model requests must use JSON:API envelopes and media types"

  for expected in \
      '"hashlistSeperator": None' \
      '"sourceType": "paste"' \
      '"format": 0' \
      '"hashTypeId": 22000' \
      '"hashCount": 0' \
      '"separator": None' \
      '"isHexSalt": False' \
      '"isSalted": False' \
      '"useBrain": False' \
      '"brainFeatures": 0'; do
    grep -Fq "${expected}" "${helper}" \
      || fail "self-test hashlist JSON:API payload is missing ${expected}"
  done
  for expected in \
      '"hashlistId": hashlist_id' \
      '"files": [file_id]' \
      '"attackCmd": f"-a 0 {hashlist_alias} {filename}"' \
      '"chunkTime": 30' \
      '"statusTimer": 5' \
      '"priority": 0' \
      '"maxAgents": 1' \
      '"isSmall": True' \
      '"isCpuTask": cpu_only' \
      '"useNewBench": True' \
      '"skipKeyspace": 0' \
      '"crackerBinaryId": cracker_id' \
      '"crackerBinaryTypeId": None' \
      '"isArchived": True' \
      '"staticChunks": 0' \
      '"chunkSize": 0' \
      '"forcePipe": False' \
      '"preprocessorId": 0' \
      '"preprocessorCommand": ""'; do
    grep -Fq "${expected}" "${helper}" \
      || fail "self-test task JSON:API payload is missing ${expected}"
  done
  grep -Fq '"id": resource_id,' "${helper}" \
    && grep -Fq '{"isArchived": False, "priority": MAX_PRIORITY}' "${helper}" \
    || fail "self-test task release PATCH must include JSON:API data.id"
  grep -Fq 'attributes.get("hash") != HC22000' "${helper}" \
    && grep -Fq 'chunk_attributes.get("taskId") != task_id' "${helper}" \
    && grep -Fq 'chunk_attributes.get("agentId") != agent_id' "${helper}" \
    || fail "self-test success must prove the exact hash and chunk agent/task ownership"

  if grep -Eq 'api[.]delete\([^)]*agentassignments|request\("DELETE"[^)]*agentassignments' \
      "${helper}"; then
    fail "self-test must never DELETE an RC2 agent assignment"
  fi
  cleanup_block="$(sed -n '/^def cleanup_resources(/,/^def parse_args(/p' "${helper}")"
  task_cleanup_line="$(grep -nF '"task", "/ui/tasks"' <<< "${cleanup_block}" | head -n1 | cut -d: -f1)"
  file_cleanup_line="$(grep -nF '"file", "/ui/files"' <<< "${cleanup_block}" | head -n1 | cut -d: -f1)"
  hashlist_cleanup_line="$(grep -nF '"hashlist",' <<< "${cleanup_block}" | head -n1 | cut -d: -f1)"
  [[ "${task_cleanup_line}" =~ ^[0-9]+$ \
      && "${file_cleanup_line}" =~ ^[0-9]+$ \
      && "${hashlist_cleanup_line}" =~ ^[0-9]+$ \
      && "${task_cleanup_line}" -lt "${file_cleanup_line}" \
      && "${file_cleanup_line}" -lt "${hashlist_cleanup_line}" ]] \
    || fail "self-test cleanup must delete its exact task before file and hashlist"
  grep -Fq 'record["deleted"] = True' "${helper}" \
    && grep -Fq 'checkpoint(state_path, state_value, f"{key}-deleted")' "${helper}" \
    && grep -Fq 'remove_completed_state(state_path, state_value)' "${helper}" \
    || fail "self-test cleanup must checkpoint mutable exact-ID state until completion"
  grep -Fq 'f"{endpoint}/{resource_id}/{require_empty_relation}"' "${helper}" \
    && grep -Fq 'related = resource_list(' "${helper}" \
    && grep -Fq 'f"cleanup {key} {require_empty_relation} relation"' "${helper}" \
    && grep -Fq 'if related:' "${helper}" \
    && grep -Fq 'validate_cleanup_hashlist,' "${helper}" \
    && grep -Fq '"tasks",' <<< "${cleanup_block}" \
    || fail "hashlist cleanup must prove its task relation is empty before cascade deletion"

  if [[ -x /usr/bin/python3 ]]; then
    /usr/bin/python3 -m py_compile "${helper}" \
      || fail "generated self-test helper Python syntax"
  fi

  if output="$(command_self_test 29 2>&1)"; then
    fail "self-test CLI accepted a timeout below 30 seconds"
  fi
  [[ "${output}" == *"30 to 1800"* ]] \
    || fail "self-test CLI lower timeout rejection was not actionable"
  if output="$(command_self_test 1801 2>&1)"; then
    fail "self-test CLI accepted a timeout above 1800 seconds"
  fi
  [[ "${output}" == *"30 to 1800"* ]] \
    || fail "self-test CLI upper timeout rejection was not actionable"
  if command_self_test 30 extra >/dev/null 2>&1; then
    fail "self-test CLI accepted more than one argument"
  fi
  pass "generated WPA self-test helper payload, proof, cleanup, and CLI guards"
)

test_agent_static_utility_route() (
  local temp_root="$1"
  local static_block=""
  APP_DIR="${temp_root}/static-route-app"
  LOG_DIR="${temp_root}/static-route-log"
  RUN_DIR="${APP_DIR}/run"
  FRONTEND_CURRENT="${APP_DIR}/current/frontend"
  INTERNAL_PORT=8080
  BACKEND_PORT=18080
  NGINX_CONFIG="${APP_DIR}/config/nginx.conf"
  mkdir -p "${LOG_DIR}" "${RUN_DIR}" "${FRONTEND_CURRENT}/dist" \
    "$(dirname "${NGINX_CONFIG}")"
  nginx() { return 0; }

  write_nginx_config
  static_block="$(awk '
    /^[[:space:]]*location \^~ \/static\/ \{/ { active = 1 }
    active { print }
    active && /^[[:space:]]*\}/ { exit }
  ' "${NGINX_CONFIG}")"
  grep -q 'proxy_pass http://127.0.0.1:18080;' <<< "${static_block}" \
    || fail "legacy agent /static utility downloads must proxy to Hashtopolis"
  if grep -q 'try_files' <<< "${static_block}"; then
    fail "legacy agent /static utility downloads must never use SPA fallback"
  fi
  pass "legacy agent utility downloads bypass the frontend SPA"
)

test_agent_launcher_lock_guard() {
  local live_agent_pid=""
  local output=""

  if [[ ! -x /usr/bin/python3 ]]; then
    pass "agent launcher lock guard skipped (/usr/bin/python3 unavailable on this host)"
    return 0
  fi
  mkdir -p "${AGENT_DIR}" "${TOOLS_DIR}/bin" "${RUN_DIR}"
  printf 'placeholder\n' > "${AGENT_DIR}/hashtopolis.zip"
  printf '{"token":"test-token"}\n' > "${AGENT_DIR}/config.json"
  printf '%s\n' '#!/usr/bin/python3' 'raise SystemExit(0)' \
    > "${CONFIG_DIR}/agent-wrapper.py"
  chmod 700 "${CONFIG_DIR}/agent-wrapper.py"
  if ! command -v flock >/dev/null 2>&1; then
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${TOOLS_DIR}/bin/flock"
    chmod 700 "${TOOLS_DIR}/bin/flock"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' '#!/usr/bin/env bash' 'file="${!#}"' \
      'grep -Eq '\''"token"[[:space:]]*:[[:space:]]*"[^"[:space:]]+"'\'' "${file}"' \
      > "${TOOLS_DIR}/bin/jq"
    chmod 700 "${TOOLS_DIR}/bin/jq"
  fi

  printf 'malformed\n' > "${AGENT_DIR}/lock.pid"
  "${CONFIG_DIR}/start-agent.sh" >/dev/null 2>&1 \
    || fail "agent launcher rejected a malformed stale lock"
  [[ ! -e "${AGENT_DIR}/lock.pid" ]] \
    || fail "agent launcher did not remove a malformed stale lock"

  printf '99999999\n' > "${AGENT_DIR}/lock.pid"
  "${CONFIG_DIR}/start-agent.sh" >/dev/null 2>&1 \
    || fail "agent launcher rejected a dead numeric PID lock"
  [[ ! -e "${AGENT_DIR}/lock.pid" ]] \
    || fail "agent launcher did not remove a dead numeric PID lock"

  if [[ -d "/proc/$$" ]]; then
    printf '%s\n' "$$" > "${AGENT_DIR}/lock.pid"
    "${CONFIG_DIR}/start-agent.sh" >/dev/null 2>&1 \
      || fail "agent launcher rejected a lock owned by an unrelated live process"
    [[ ! -e "${AGENT_DIR}/lock.pid" ]] \
      || fail "agent launcher did not remove an unrelated live-process lock"

    (
      cd "${AGENT_DIR}"
      exec -a hashtopolis.zip sleep 30
    ) &
    live_agent_pid=$!
    printf '%s\n' "${live_agent_pid}" > "${AGENT_DIR}/lock.pid"
    if output="$("${CONFIG_DIR}/start-agent.sh" 2>&1)"; then
      kill "${live_agent_pid}" 2>/dev/null || true
      wait "${live_agent_pid}" 2>/dev/null || true
      fail "agent launcher allowed a duplicate live agent"
    fi
    [[ "${output}" == *"live Hashtopolis agent already owns lock.pid"* ]] \
      || fail "duplicate-agent refusal lacked a precise diagnostic"
    [[ "$(<"${AGENT_DIR}/lock.pid")" == "${live_agent_pid}" ]] \
      || fail "duplicate-agent guard removed a live agent lock"
    kill "${live_agent_pid}" 2>/dev/null || true
    wait "${live_agent_pid}" 2>/dev/null || true
    rm -f "${AGENT_DIR}/lock.pid"
  fi

  if [[ "$(command -v flock)" != "${TOOLS_DIR}/bin/flock" ]]; then
    exec 8>"${RUN_DIR}/agent-runtime.lock"
    flock -n 8 || fail "test could not acquire the agent runtime lock"
    if output="$("${CONFIG_DIR}/start-agent.sh" 2>&1)"; then
      flock -u 8 2>/dev/null || true
      exec 8>&-
      fail "agent launcher ignored the authoritative runtime flock"
    fi
    [[ "${output}" == *"holds ${RUN_DIR}/agent-runtime.lock"* ]] \
      || fail "runtime-lock refusal lacked a precise diagnostic"
    flock -u 8 2>/dev/null || true
    exec 8>&-
  fi
  pass "agent launcher safely reconciles stale locks and refuses duplicates"
}

test_agent_registration_contract() (
  local temp_root="$1"
  local secret='registered-token'
  local secret_hex='726567697374657265642d746f6b656e'
  local output_file="${temp_root}/registration-output"
  local mysql_args_file="${temp_root}/registration-mysql-args"
  local registration_rc=0
  local MOCK_DB_RESULT='valid'

  AGENT_DIR="${temp_root}/registration-contract"
  mkdir -p "${AGENT_DIR}"

  # Only the jq operations used by registration are modeled here.  This keeps
  # the regression hermetic while still exercising token extraction, stdin SQL
  # transport, result parsing, and fail-closed state transitions.
  jq() {
    local filter=""
    local file=""
    local data=""
    local join_output=0
    while (( $# > 0 )); do
      case "$1" in
        -j) join_output=1; shift ;;
        -e|-r) shift ;;
        *)
          if [[ -z "${filter}" ]]; then
            filter="$1"
          else
            file="$1"
          fi
          shift
          ;;
      esac
    done
    [[ -n "${file}" && -f "${file}" ]] || return 2
    data="$(<"${file}")"
    case "${filter}" in
      'type == "object"')
        [[ "${data}" =~ ^[[:space:]]*\{.*\}[[:space:]]*$ ]]
        ;;
      '(.token? == null) or (.token? | type == "string")')
        [[ "${data}" != *'"token"'* \
          || "${data}" =~ \"token\"[[:space:]]*:[[:space:]]*\"[^\"]*\" ]]
        ;;
      'type == "object" and (.token? | type == "string" and length > 0)')
        [[ "${data}" =~ ^[[:space:]]*\{.*\}[[:space:]]*$ \
          && "${data}" =~ \"token\"[[:space:]]*:[[:space:]]*\"[^\"]+\" ]]
        ;;
      '.token')
        local token=""
        token="$(sed -nE 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "${file}")"
        if [[ "${join_output}" == "1" ]]; then
          printf '%s' "${token}"
        else
          printf '%s\n' "${token}"
        fi
        ;;
      *) return 2 ;;
    esac
  }

  mysql_app_exec() {
    local sql=""
    printf '%s\n' "$*" > "${mysql_args_file}"
    sql="$(cat)"
    [[ "${sql}" == *"UNHEX('${secret_hex}')"* ]] || return 96
    case "${MOCK_DB_RESULT}" in
      valid) printf '1\t42\n' ;;
      stale) printf '0\t0\n' ;;
      duplicate) printf '2\t42\n' ;;
      database-unavailable) return 97 ;;
      *) return 98 ;;
    esac
  }

  printf '{"token":"%s"}\n' "${secret}" > "${AGENT_DIR}/config.json"
  for MOCK_DB_RESULT in valid stale duplicate database-unavailable; do
    : > "${output_file}"
    : > "${mysql_args_file}"
    if agent_registration_query >"${output_file}" 2>&1; then
      registration_rc=0
    else
      registration_rc=$?
    fi
    case "${MOCK_DB_RESULT}" in
      valid)
        [[ "${registration_rc}" == "0" \
            && "${AGENT_REGISTRATION_STATE}" == "valid" \
            && "${AGENT_ID}" == "42" ]] \
          || fail "valid DB token was not resolved to its unique agentId (rc=${registration_rc}, state=${AGENT_REGISTRATION_STATE}, agentId=${AGENT_ID:-empty})"
        ;;
      stale)
        [[ "${registration_rc}" == "1" \
            && "${AGENT_REGISTRATION_STATE}" == "stale" \
            && -z "${AGENT_ID}" ]] \
          || fail "missing DB token row was not classified as stale"
        ;;
      duplicate)
        [[ "${registration_rc}" == "3" \
            && "${AGENT_REGISTRATION_STATE}" == "duplicate" \
            && -z "${AGENT_ID}" ]] \
          || fail "duplicate DB token rows did not fail closed"
        ;;
      database-unavailable)
        [[ "${registration_rc}" == "2" \
            && "${AGENT_REGISTRATION_STATE}" == "database-unavailable" \
            && -z "${AGENT_ID}" ]] \
          || fail "DB errors were not distinguished from a stale token"
        ;;
    esac
    if grep -Fq "${secret}" "${output_file}" \
        || grep -Fq "${secret_hex}" "${output_file}" \
        || grep -Fq "${secret}" "${mysql_args_file}" \
        || grep -Fq "${secret_hex}" "${mysql_args_file}"; then
      fail "registration exposed the token or its hex transport in output/process arguments"
    fi
  done

  printf '{not-json\n' > "${AGENT_DIR}/config.json"
  : > "${mysql_args_file}"
  if agent_registration_query >"${output_file}" 2>&1; then
    fail "malformed config.json was accepted as a registration"
  else
    registration_rc=$?
  fi
  [[ "${registration_rc}" == "1" \
      && "${AGENT_REGISTRATION_STATE}" == "malformed" \
      && ! -s "${mysql_args_file}" ]] \
    || fail "malformed config did not fail before querying the database"

  printf '{"token":7}\n' > "${AGENT_DIR}/config.json"
  if agent_registration_query >"${output_file}" 2>&1; then
    fail "non-string token was accepted as a registration"
  else
    registration_rc=$?
  fi
  [[ "${registration_rc}" == "1" \
      && "${AGENT_REGISTRATION_STATE}" == "malformed" ]] \
    || fail "non-string token was not classified as malformed"
  pass "agent registration is DB-backed, fail-closed, and secret-safe"
)

test_agent_config_recovery_contract() (
  local temp_root="$1"
  local config=""
  local backup_dir=""
  local backup=""
  local mode_probe=""
  local mode_checks_supported=0
  local -a backups=()

  AGENT_DIR="${temp_root}/agent-config-recovery"
  INTERNAL_PORT=18080
  config="${AGENT_DIR}/config.json"
  backup_dir="${AGENT_DIR}/identity-backups"
  mkdir -p "${AGENT_DIR}"
  mode_probe="${AGENT_DIR}/.mode-probe"
  printf 'probe\n' > "${mode_probe}"
  chmod 600 "${mode_probe}" 2>/dev/null || true
  [[ "$(stat -c '%a' "${mode_probe}" 2>/dev/null || true)" == "600" ]] \
    && mode_checks_supported=1
  rm -f -- "${mode_probe}"
  supervisor_is_running() { return 1; }
  success() { :; }
  info() { :; }

  jq() {
    local filter=""
    local file=""
    local arg_url=""
    local data=""
    local null_input=0
    while (( $# > 0 )); do
      case "$1" in
        -e|-j|-r) shift ;;
        -n) null_input=1; shift ;;
        --arg)
          [[ "${2:-}" == "url" ]] || return 2
          arg_url="${3:-}"
          shift 3
          ;;
        *)
          if [[ -z "${filter}" ]]; then
            filter="$1"
          else
            file="$1"
          fi
          shift
          ;;
      esac
    done
    if [[ "${null_input}" == "0" ]]; then
      [[ -n "${file}" && -f "${file}" ]] || return 2
      data="$(<"${file}")"
    fi
    case "${filter}" in
      'type == "object"')
        [[ "${data}" =~ ^[[:space:]]*\{.*\}[[:space:]]*$ ]]
        ;;
      '.url // empty | strings')
        sed -nE 's/.*"url"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "${file}"
        ;;
      '.url = $url')
        if [[ "${data}" == *'"url"'* ]]; then
          printf '%s\n' "${data}" \
            | sed -E 's#"url"[[:space:]]*:[[:space:]]*"[^"]*"#"url":"'"${arg_url}"'"#'
        else
          printf '%s\n' "${data%\}}\"url\":\"${arg_url}\"}"
        fi
        ;;
      'del(.token, .uuid, .voucher) | .url = $url')
        # The test fixture is deliberately flat; retain its unrelated fields
        # while modeling jq's deletion of the three identity keys.
        printf '{"url":"%s","keep":"preserve","number":7}\n' "${arg_url}"
        ;;
      '{url: $url}')
        printf '{"url":"%s"}\n' "${arg_url}"
        ;;
      *) return 2 ;;
    esac
  }

  printf '{"token":"old-token","uuid":"old-uuid","voucher":"old-voucher","url":"https://wrong.example/api","keep":"preserve","number":7}\n' \
    > "${config}"
  chmod 640 "${config}" 2>/dev/null || true
  normalize_agent_config_url \
    || fail "valid config URL could not be normalized"
  grep -Fq '"url":"http://127.0.0.1:18080/api/server.php"' "${config}" \
    || fail "config URL was not normalized to the loopback API"
  grep -Fq '"token":"old-token"' "${config}" \
    && grep -Fq '"keep":"preserve"' "${config}" \
    && grep -Fq '"number":7' "${config}" \
    || fail "URL normalization changed unrelated config fields"
  if [[ "${mode_checks_supported}" == "1" \
      && "$(stat -c '%a' "${config}")" != "600" ]]; then
    fail "normalized config mode is not 600"
  fi

  backup_and_reset_agent_identity \
    || fail "identity backup/reset failed for a regular config"
  mapfile -t backups < <(find "${backup_dir}" -maxdepth 1 -type f -name 'config.json.*.bak')
  [[ "${#backups[@]}" == "1" ]] \
    || fail "identity reset did not create exactly one backup"
  backup="${backups[0]}"
  grep -Fq '"token":"old-token"' "${backup}" \
    && grep -Fq '"uuid":"old-uuid"' "${backup}" \
    && grep -Fq '"voucher":"old-voucher"' "${backup}" \
    || fail "identity backup did not preserve the original config"
  if grep -Eq '"(token|uuid|voucher)"[[:space:]]*:' "${config}"; then
    fail "identity reset retained a token, uuid, or voucher"
  fi
  grep -Fq '"url":"http://127.0.0.1:18080/api/server.php"' "${config}" \
    && grep -Fq '"keep":"preserve"' "${config}" \
    && grep -Fq '"number":7' "${config}" \
    || fail "identity reset did not preserve unrelated config fields"

  # Git-for-Windows reports synthetic NTFS modes; enforce exact modes whenever
  # chmod semantics are actually observable (Linux CI and Vast.ai).
  if [[ "${mode_checks_supported}" == "1" ]]; then
    [[ "$(stat -c '%a' "${config}")" == "600" ]] \
      || fail "reset config mode is not 600"
    [[ "$(stat -c '%a' "${backup_dir}")" == "700" ]] \
      || fail "identity backup directory mode is not 700"
    [[ "$(stat -c '%a' "${backup}")" == "600" ]] \
      || fail "identity backup mode is not 600"
  fi
  pass "agent config URL and identity are recovered atomically without losing unrelated state"
)

test_agent_semantic_health_contract() (
  local now=""

  now="$(date +%s)"
  agent_registration_query() {
    AGENT_REGISTRATION_STATE=valid
    AGENT_ID=42
    return 0
  }
  agent_server_metadata_query() { return 0; }
  success() { :; }
  info() { :; }
  warn() { :; }
  error() { :; }
  AGENT_NAME=test-agent
  AGENT_TRUSTED=1
  AGENT_LAST_ACT=getTask
  AGENT_ASSIGNMENT_ID=""
  AGENT_ASSIGNMENT_COUNT=0
  AGENT_TASK_ID=""
  AGENT_TIMEOUT=30
  AGENT_LAST_ERROR_ID=""
  AGENT_ACTIVE=1
  AGENT_CPU_ONLY=0
  AGENT_LAST_TIME="${now}"
  REQUIRE_HASHCAT_GPU=1
  check_agent_semantic_health >/dev/null \
    || fail "active GPU agent with a current heartbeat was rejected"

  AGENT_ACTIVE=0
  if check_agent_semantic_health >/dev/null; then
    fail "inactive agent passed semantic health"
  fi
  AGENT_ACTIVE=1
  AGENT_LAST_TIME=$((now - AGENT_TIMEOUT - 1))
  if check_agent_semantic_health >/dev/null; then
    fail "stale agent heartbeat passed semantic health"
  fi
  AGENT_LAST_TIME=$((now - 16))
  AGENT_LAST_ACT=updateInformation
  if check_agent_semantic_health >/dev/null; then
    fail "idle agent which never reached getTask polling passed semantic health"
  fi
  AGENT_LAST_ACT=getTask
  AGENT_LAST_TIME="${now}"
  AGENT_CPU_ONLY=1
  if check_agent_semantic_health >/dev/null; then
    fail "GPU-required agent with cpuOnly=1 passed semantic health"
  fi
  pass "semantic agent health rejects inactive, stale, non-polling, and GPU-mode-mismatched rows"
)

test_agent_log_redaction() (
  local temp_root="$1"
  local output=""
  AGENT_DIR="${temp_root}/agent-log-redaction"
  AGENT_VOUCHER="voucher-secret"
  mkdir -p "${AGENT_DIR}"
  printf '{"token":"token-secret"}\n' > "${AGENT_DIR}/config.json"
  jq() {
    case "$*" in
      *'.token'*) printf 'token-secret\n' ;;
      *'.voucher'*) printf '\n' ;;
      *) return 1 ;;
    esac
  }
  output="$(printf 'token-secret voucher-secret visible\n' | redact_agent_log_stream)"
  [[ "${output}" == '<redacted-token> <redacted-voucher> visible' ]] \
    || fail "agent log token/voucher redaction failed: ${output}"
  pass "agent log tails redact registration credentials"
)

test_hashcat_live_monitor() (
  local temp_root="$1"
  local monitor_root="${temp_root}/hashcat-live"
  local output=""
  local timeout_output=""
  local before_checksums=""
  local after_checksums=""
  local monitor_definition=""

  APP_DIR="${monitor_root}/app"
  LOG_DIR="${monitor_root}/log"
  AGENT_DIR="${APP_DIR}/agent"
  ENV_FILE="${APP_DIR}/.env"
  SUPERVISOR_CONFIG="${APP_DIR}/supervisord.conf"
  AGENT_ENABLED=1
  AGENT_VOUCHER="monitor-voucher"
  HASHTOPOLIS_ADMIN_PASSWORD="monitor-admin"
  MYSQL_PASSWORD="monitor-database"
  MYSQL_ROOT_PASS="monitor-root"
  mkdir -p "${APP_DIR}" "${LOG_DIR}" "${AGENT_DIR}"
  printf '%s\n' "HASHTOPOLIS_ADMIN_PASSWORD='monitor-admin'" > "${ENV_FILE}"
  printf '%s\n' '[supervisord]' > "${SUPERVISOR_CONFIG}"
  printf '%s\n' \
    'visible-agent token=monitor-token password=monitor-admin' \
    > "${LOG_DIR}/agent.log"
  printf '%s\n' \
    'visible-client Authorization: Bearer bearer-secret voucher=monitor-voucher' \
    'endpoint=https://api-user:api-pass@example.test/' \
    > "${AGENT_DIR}/client.log"
  printf '%s\n' '{"token":"monitor-token"}' > "${AGENT_DIR}/config.json"

  jq() {
    case "$*" in
      *'.token'*) printf 'monitor-token\n' ;;
      *'.voucher'*) printf '\n' ;;
      *) return 1 ;;
    esac
  }
  supervisor_is_running() { return 0; }
  supervisor_program_state() { printf 'RUNNING\n'; }
  agent_registration_query() { AGENT_ID=7; return 0; }
  agent_server_metadata_query() {
    AGENT_LAST_ACT='getTask'
    AGENT_ASSIGNMENT_ID=0
    AGENT_TASK_ID=0
    return 0
  }
  agent_heartbeat_age_seconds() { printf '3\n'; }
  nvidia-smi() { printf '0, Mock GPU, 91, 42, 1024, 24576, 65\n'; }
  ps() { printf ' 123 1 123 00:01 R 88.0 1.0 hashcat.bin\n'; }

  monitor_definition="$(declare -f command_hashcat_live)"
  [[ "${monitor_definition}" == *"trap 'hashcat_live_request_stop INT' INT"* \
      && "${monitor_definition}" == *"trap 'hashcat_live_request_stop TERM' TERM"* ]] \
    || fail "hashcat-live does not trap Ctrl-C/termination cleanly"
  before_checksums="$(sha256sum "${ENV_FILE}" "${SUPERVISOR_CONFIG}" \
    "${LOG_DIR}/agent.log" "${AGENT_DIR}/client.log" "${AGENT_DIR}/config.json")"
  output="$(
    sleep() { hashcat_live_request_stop INT; }
    command_hashcat_live
  )"
  [[ "${output}" == *'supervisor_agent_state=RUNNING'* \
      && "${output}" == *'agent_id=7 last_action=getTask heartbeat_age_seconds=3 assignment_id=none task_id=none'* \
      && "${output}" == *'hashcat_process='*'hashcat.bin'* \
      && "${output}" == *'nvidia_gpu=0, Mock GPU, 91, 42, 1024, 24576, 65'* \
      && "${output}" == *'[agent.log] visible-agent'* \
      && "${output}" == *'[agent/client.log] visible-client'* \
      && "${output}" == *'reason=INT'* ]] \
    || fail "hashcat-live did not show the required live state: ${output}"
  [[ "${output}" == *'<redacted'* ]] \
    || fail "hashcat-live did not emit redaction markers"
  for secret in monitor-token monitor-voucher monitor-admin monitor-database \
      monitor-root bearer-secret api-user api-pass; do
    [[ "${output}" != *"${secret}"* ]] \
      || fail "hashcat-live leaked credential material: ${secret}"
  done

  timeout_output="$(command_hashcat_live 1)"
  [[ "${timeout_output}" == *'reason=timeout'* ]] \
    || fail "hashcat-live did not stop on its requested timeout"
  if (command_hashcat_live 0 >/dev/null 2>&1); then
    fail "hashcat-live accepted a zero timeout"
  fi
  if (command_hashcat_live 1 extra >/dev/null 2>&1); then
    fail "hashcat-live accepted extra arguments"
  fi
  after_checksums="$(sha256sum "${ENV_FILE}" "${SUPERVISOR_CONFIG}" \
    "${LOG_DIR}/agent.log" "${AGENT_DIR}/client.log" "${AGENT_DIR}/config.json")"
  [[ "${after_checksums}" == "${before_checksums}" ]] \
    || fail "hashcat-live changed managed configuration or logs"
  pass "hashcat-live is read-only, redacted, live, and signal/timeout bounded"
)

test_detached_cracker_cleanup() (
  local temp_root="$1"
  local cracker_pid=""
  local groups=""
  command -v setsid >/dev/null 2>&1 || {
    pass "detached Hashcat cleanup test skipped (setsid unavailable)"
    return 0
  }
  [[ -d /proc/$$ ]] || {
    pass "detached Hashcat cleanup test skipped (/proc unavailable)"
    return 0
  }
  AGENT_DIR="${temp_root}/detached-cracker-agent"
  mkdir -p "${AGENT_DIR}/crackers/1"
  (
    cd "${AGENT_DIR}/crackers/1"
    exec setsid bash -c 'exec -a hashcat sleep 30'
  ) &
  cracker_pid=$!
  sleep 1
  groups="$(managed_agent_cracker_groups)"
  if [[ -z "${groups}" ]]; then
    kill "${cracker_pid}" 2>/dev/null || true
    wait "${cracker_pid}" 2>/dev/null || true
    fail "detached managed Hashcat process group was not discovered"
  fi
  if ! cleanup_managed_agent_cracker_processes; then
    kill "${cracker_pid}" 2>/dev/null || true
    wait "${cracker_pid}" 2>/dev/null || true
    fail "detached managed Hashcat process group was not terminated"
  fi
  if kill -0 "${cracker_pid}" 2>/dev/null; then
    kill "${cracker_pid}" 2>/dev/null || true
    wait "${cracker_pid}" 2>/dev/null || true
    fail "detached managed Hashcat process survived cleanup"
  fi
  wait "${cracker_pid}" 2>/dev/null || true
  pass "detached managed Hashcat groups are cleaned after agent exit"
)

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
  local MOCK_STATIC_SIGNATURE='7f454c46'
  curl() {
    if [[ "$*" == *api/server.php* ]]; then
      printf '{"action":"testConnection","response":"SUCCESS"}\n%s' "${MOCK_HTTP_STATUS}"
    elif [[ "$*" == *static/7zr.bin* && "$*" == *--range* ]]; then
      if [[ "${MOCK_STATIC_SIGNATURE}" == "7f454c46" ]]; then
        printf '\177ELF'
      else
        printf '<!do'
      fi
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
  MOCK_STATIC_SIGNATURE='3c21646f'
  if check_http_contract; then
    fail "SPA HTML returned for /static/7zr.bin must not pass the health contract"
  fi
  unset -f curl jq
  pass "health check rejects 404/SPA utility responses and accepts the exact API contract"
}

test_task_dispatch_policy() (
  local policy_value=0
  HASHTOPOLIS_AUTO_ASSIGN_PRIORITY_ZERO=1
  mysql_app_exec() {
    case "$*" in
      *"SELECT COUNT("*)
        printf '1\n'
        ;;
      *"SELECT \`value\`"*)
        printf '%s\n' "${policy_value}"
        ;;
      *"UPDATE \`Config\`"*)
        policy_value=1
        ;;
      *)
        return 1
        ;;
    esac
  }
  configure_task_dispatch_policy
  [[ "${policy_value}" == "1" ]] \
    || fail "priority-0 automatic assignment policy was not reconciled"
  pass "default priority-0 tasks are made eligible for automatic assignment"
)

test_agent_reconciliation_state_machine() (
  local temp_root="$1"
  local events="${temp_root}/agent-reconcile-events"
  local registration_marker="${temp_root}/agent-reconcile-registered"
  local output=""
  local MOCK_AGENT_STATE=RUNNING
  local MOCK_REGISTRATION_STATE=valid

  : > "${events}"
  rm -f -- "${registration_marker}"
  agent_registration_query() {
    if [[ "${MOCK_REGISTRATION_STATE}" == "valid" \
        || -f "${registration_marker}" ]]; then
      AGENT_REGISTRATION_STATE=valid
      AGENT_ID=42
      return 0
    fi
    AGENT_REGISTRATION_STATE="${MOCK_REGISTRATION_STATE}"
    AGENT_ID=""
    return 1
  }
  agent_database_is_ready() { return 0; }
  normalize_agent_config_url() { return 0; }
  reconcile_managed_agent_cpu_mode() { return 0; }
  backup_and_reset_agent_identity() {
    printf 'reset-identity\n' >> "${events}"
  }
  write_dotenv() { printf 'write-dotenv\n' >> "${events}"; }
  write_agent_launcher() { printf 'write-launcher\n' >> "${events}"; }
  write_supervisor_config() { printf 'write-supervisor\n' >> "${events}"; }
  supervisor_is_running() { return 0; }
  supervisor_ctl() { printf '%s\n' "$*" >> "${events}"; }
  supervisor_program_state() { printf '%s\n' "${MOCK_AGENT_STATE}"; }
  wait_for_supervisor_running() { printf 'wait-running\n' >> "${events}"; }
  AGENT_ENABLED=1
  AGENT_VOUCHER=""
  reconcile_agent_process
  if grep -qx 'start agent' "${events}"; then
    fail "agent-start restarted an already RUNNING agent"
  fi
  if grep -qxE 'write-launcher|reread|update' "${events}"; then
    fail "agent-start rewrote/reloaded config before preserving a RUNNING task"
  fi

  : > "${events}"
  MOCK_AGENT_STATE=STARTING
  reconcile_agent_process
  if grep -qx 'start agent' "${events}"; then
    fail "agent-start issued a duplicate start for a STARTING agent"
  fi
  grep -qx 'wait-running' "${events}" \
    || fail "STARTING agent state was not verified"

  : > "${events}"
  MOCK_AGENT_STATE=STOPPED
  reconcile_agent_process
  grep -qx 'start agent' "${events}" \
    || fail "STOPPED agent was not started"

  : > "${events}"
  MOCK_AGENT_STATE=BACKOFF
  stop_supervisor_program_if_active() {
    printf 'stop:%s\n' "$1" >> "${events}"
    MOCK_AGENT_STATE=STOPPED
  }
  reconcile_agent_process
  grep -qx 'stop:agent' "${events}" \
    || fail "BACKOFF agent was not stopped before reconciliation"
  grep -qx 'start agent' "${events}" \
    || fail "BACKOFF agent was not cleanly restarted"

  : > "${events}"
  MOCK_REGISTRATION_STATE=valid
  AGENT_VOUCHER=ignored-voucher
  MOCK_AGENT_STATE=RUNNING
  reconcile_agent_process
  [[ -z "${AGENT_VOUCHER}" ]] \
    || fail "valid agent token did not clear an obsolete supplied voucher"
  if grep -qxE 'stop:agent|start agent|write-launcher|write-supervisor' "${events}"; then
    fail "valid token plus voucher disturbed a RUNNING agent identity/task"
  fi
  grep -qx 'write-dotenv' "${events}" \
    || fail "obsolete voucher removal was not persisted"

  : > "${events}"
  rm -f -- "${registration_marker}"
  MOCK_REGISTRATION_STATE=stale
  AGENT_IDENTITY_RESET_PREPARED=0
  AGENT_VOUCHER=new-voucher
  MOCK_AGENT_STATE=RUNNING
  stop_supervisor_program_if_active() {
    printf 'stop:%s\n' "$1" >> "${events}"
    MOCK_AGENT_STATE=STOPPED
  }
  supervisor_ctl() {
    printf '%s\n' "$*" >> "${events}"
    if [[ "$*" == "start agent" ]]; then
      : > "${registration_marker}"
    fi
  }
  reconcile_agent_process
  grep -qx 'stop:agent' "${events}" \
    || fail "stale identity recovery did not stop the previous RUNNING attempt"
  grep -qx 'reset-identity' "${events}" \
    || fail "stale identity recovery did not back up/reset identity before registration"
  grep -qx 'start agent' "${events}" \
    || fail "stale identity recovery did not start a fresh agent process"
  [[ -z "${AGENT_VOUCHER}" ]] \
    || fail "voucher was not cleared after DB recognized the new token"

  : > "${events}"
  MOCK_REGISTRATION_STATE=valid
  AGENT_VOUCHER=""
  MOCK_AGENT_STATE=STOPPED
  supervisor_ctl() {
    printf '%s\n' "$*" >> "${events}"
    if [[ "$*" == "start agent" ]]; then
      printf 'ERROR: spawn error\n'
      return 1
    fi
  }
  print_supervisor_program_diagnostics() {
    printf 'diagnostics:%s\n' "$1" >> "${events}"
  }
  die() {
    printf 'die:%s\n' "$*" >> "${events}"
    exit 1
  }
  if output="$(reconcile_agent_process 2>&1)"; then
    fail "agent reconciliation accepted a Supervisor spawn failure"
  fi
  [[ "${output}" == *"ERROR: spawn error"* ]] \
    || fail "Supervisor spawn output was hidden"
  grep -qx 'diagnostics:agent' "${events}" \
    || fail "agent diagnostics were not printed before the spawn failure"

  local MOCK_FAIL_COMMAND=""
  for MOCK_FAIL_COMMAND in reread update; do
    : > "${events}"
    supervisor_ctl() {
      printf '%s\n' "$*" >> "${events}"
      if [[ "$1" == "${MOCK_FAIL_COMMAND}" ]]; then
        printf 'ERROR: %s failed\n' "${MOCK_FAIL_COMMAND}"
        return 1
      fi
    }
    if output="$(reconcile_agent_process 2>&1)"; then
      fail "agent reconciliation accepted Supervisor ${MOCK_FAIL_COMMAND} failure"
    fi
    [[ "${output}" == *"ERROR: ${MOCK_FAIL_COMMAND} failed"* ]] \
      || fail "Supervisor ${MOCK_FAIL_COMMAND} output was hidden"
    grep -qx 'diagnostics:agent' "${events}" \
      || fail "agent diagnostics were not printed for ${MOCK_FAIL_COMMAND} failure"
  done
  pass "agent reconciliation preserves active tasks and starts stopped agents"
)

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

test_default_admin_password_generation() (
  local temp_root="$1"
  local generated_password=""
  local supplied_password='supplied-password-is-preserved'
  local persisted_password='persisted-password-is-preserved'

  APP_DIR="${temp_root}/admin-password"
  mkdir -p "${APP_DIR}"
  MYSQL_ROOT_PASS='existing-root-password'
  MYSQL_PASSWORD='existing-database-password'
  PUBLIC_URL='http://127.0.0.1:8080'
  PUBLIC_PORT=8080
  HASHTOPOLIS_BACKEND_URL='http://127.0.0.1:8080/api/v2'
  HASHTOPOLIS_FRONTEND_PORT=8080
  CALLER_SET[PUBLIC_URL]=0
  CALLER_SET[HASHTOPOLIS_BACKEND_URL]=0
  CALLER_SET[HASHTOPOLIS_FRONTEND_PORT]=0
  CALLER_SET[HASHTOPOLIS_ADMIN_PASSWORD]=0

  HASHTOPOLIS_ADMIN_PASSWORD=""
  resolve_credentials
  generated_password="${HASHTOPOLIS_ADMIN_PASSWORD}"
  [[ "${#generated_password}" == "10" \
      && "${generated_password}" =~ ^[0-9a-f]{10}$ ]] \
    || fail "generated default admin password is not exactly 10 random hex characters"
  [[ "${MYSQL_ROOT_PASS}" == 'existing-root-password' \
      && "${MYSQL_PASSWORD}" == 'existing-database-password' ]] \
    || fail "admin password generation changed existing database passwords"

  CALLER_SET[HASHTOPOLIS_ADMIN_PASSWORD]=1
  HASHTOPOLIS_ADMIN_PASSWORD="${supplied_password}"
  resolve_credentials
  [[ "${HASHTOPOLIS_ADMIN_PASSWORD}" == "${supplied_password}" ]] \
    || fail "supplied admin password was regenerated or truncated"

  printf "HASHTOPOLIS_ADMIN_PASSWORD='%s'\n" "${persisted_password}" > "${APP_DIR}/.env"
  CALLER_SET[HASHTOPOLIS_ADMIN_PASSWORD]=0
  HASHTOPOLIS_ADMIN_PASSWORD=""
  load_saved_config
  resolve_credentials
  [[ "${HASHTOPOLIS_ADMIN_PASSWORD}" == "${persisted_password}" ]] \
    || fail "persisted admin password was regenerated or truncated"
  pass "default admin password is 10 characters without changing supplied/persisted values"
)

test_deploy_order() (
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
  configure_task_dispatch_policy() { record task-policy; }
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
  local expected='build-server build-frontend quiesce activate write-config mysql-init supervisor restart-mysql mysql-wait db-provision migrate task-policy web-start http-check agent-download agent-reconcile final'
  [[ "${actual}" == "${expected}" ]] \
    || fail "deploy order: expected '${expected}', got '${actual}'"
  pass "deterministic deploy/migration/service order"
)

test_operation_lock_release() (
  local temp_root="$1"
  local loader_path="${PATH}"
  if ! command -v flock >/dev/null 2>&1; then
    mkdir -p "${temp_root}/test-bin"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${temp_root}/test-bin/flock"
    chmod 700 "${temp_root}/test-bin/flock"
    loader_path="${temp_root}/test-bin:${PATH}"
  fi
  PATH="${loader_path}"
  LOCK_FILE="${temp_root}/operation.lock"
  OPERATION_LOCK_HELD=0
  acquire_lock
  [[ "${OPERATION_LOCK_HELD}" == "1" ]] \
    || fail "operation lock must be marked held"
  release_lock
  [[ "${OPERATION_LOCK_HELD}" == "0" ]] \
    || fail "operation lock must be released before foreground monitoring"
  acquire_lock
  release_lock
  pass "operation lock can be released and reacquired"
)

test_serve_lifecycle() (
  local monitor_definition=""
  local shutdown_definition=""
  local credential_definition=""
  local success_definition=""
  local agent_stop_definition=""
  local managed_stop_definition=""
  local -a events=()

  monitor_definition="$(declare -f monitor_supervisor_foreground)"
  shutdown_definition="$(declare -f serve_request_shutdown)"
  credential_definition="$(declare -f print_credentials_to_console)"
  success_definition="$(declare -f print_success)"
  agent_stop_definition="$(declare -f command_agent_stop)"
  managed_stop_definition="$(declare -f stop_managed_services)"
  [[ "${shutdown_definition}" == *"supervisor_ctl shutdown"* \
      && "${monitor_definition}" == *"serve_request_shutdown TERM"* \
      && "${monitor_definition}" == *"supervisord exited unexpectedly"* ]] \
    || fail "foreground monitor must forward TERM and fail if supervisord disappears"
  [[ "${credential_definition}" == *"-t 3"* \
      && "${credential_definition}" == *"Refusing to print"* ]] \
    || fail "credential command must reject non-interactive output"
  [[ "${success_definition}" != *"print_credentials_to_console"* ]] \
    || fail "deploy/serve must not print the admin password automatically"
  [[ "${agent_stop_definition}" == *"stop_supervisor_program_if_active agent"* \
      && "${managed_stop_definition}" == *"stop_supervisor_program_if_active agent"* ]] \
    || fail "agent stop paths must verify shutdown and clean detached crackers"
  grep -q '/root/run.sh serve' README.md \
    || fail "Vast startup documentation must use foreground serve mode"
  [[ "${monitor_definition}" == *"SERVE_STOP_MARKER"* ]] \
    || fail "foreground monitor must distinguish an intentional CLI stop"

  record() { events+=("$1"); }
  acquire_serve_lock() { record serve-lock; }
  deploy() {
    record deploy
    OPERATION_LOCK_HELD=1
    DEPLOYMENT_COMPLETE=1
  }
  release_lock() {
    record release-operation-lock
    OPERATION_LOCK_HELD=0
  }
  monitor_supervisor_foreground() {
    [[ "${OPERATION_LOCK_HELD}" == "0" ]] \
      || fail "serve monitor retained the operation lock"
    record foreground-monitor
    DEPLOYMENT_COMPLETE=0
  }

  command_serve
  [[ "${events[*]}" == "serve-lock deploy release-operation-lock foreground-monitor" ]] \
    || fail "serve lifecycle order: ${events[*]}"
  pass "foreground serve lifecycle and credential redaction"
)

test_foreground_monitor_runtime() {
  local temp_root="$1"
  local output=""

  (
    local running=1
    local shutdown_command=""
    local tick=0
    SUPERVISOR_PID="${temp_root}/supervisord.pid"
    SERVE_STOP_MARKER="${temp_root}/intentional-stop"
    printf '4242\n' > "${SUPERVISOR_PID}"
    rm -f "${SERVE_STOP_MARKER}"
    supervisor_is_running() { [[ "${running}" == "1" ]]; }
    supervisor_ctl() {
      shutdown_command="$*"
      running=0
    }
    sleep() {
      tick=$((tick + 1))
      if (( tick == 1 )); then
        serve_request_shutdown TERM
      fi
    }
    monitor_supervisor_foreground
    [[ "${shutdown_command}" == "shutdown" && "${running}" == "0" ]] \
      || fail "foreground TERM was not forwarded to Supervisor"
  ) || fail "foreground monitor clean TERM path"

  (
    local checks=0
    local tick=0
    local warnings=""
    SUPERVISOR_PID="${temp_root}/supervisord-intentional.pid"
    SERVE_STOP_MARKER="${temp_root}/intentional-stop-marker"
    printf '4292\n' > "${SUPERVISOR_PID}"
    printf 'test stop\n' > "${SERVE_STOP_MARKER}"
    supervisor_is_running() {
      checks=$((checks + 1))
      (( checks == 1 ))
    }
    supervisor_ctl() { :; }
    warn() { warnings+="$*"; }
    sleep() {
      tick=$((tick + 1))
      if (( tick == 1 )); then
        serve_request_shutdown TERM
      fi
    }
    monitor_supervisor_foreground
    [[ "${warnings}" == *"stopped intentionally"* ]] \
      || fail "foreground monitor did not recognize the CLI stop marker"
  ) || fail "foreground monitor intentional stop path"

  if output="$({
    checks=0
    SUPERVISOR_PID="${temp_root}/supervisord-unexpected.pid"
    SERVE_STOP_MARKER="${temp_root}/missing-stop-marker"
    printf '4343\n' > "${SUPERVISOR_PID}"
    rm -f "${SERVE_STOP_MARKER}"
    supervisor_is_running() {
      checks=$((checks + 1))
      (( checks == 1 ))
    }
    sleep() { :; }
    monitor_supervisor_foreground
  } 2>&1)"; then
    fail "foreground monitor accepted an unexpected Supervisor exit"
  fi
  [[ "${output}" == *"supervisord exited unexpectedly"* ]] \
    || fail "unexpected Supervisor exit lacked a precise error"
  pass "foreground monitor forwards TERM and detects Supervisor loss"
}

test_default_command_selection() {
  local command=""
  command="$(resolve_cli_command deploy </dev/null 3>/dev/null)"
  [[ "${command}" == "deploy" ]] \
    || fail "explicit deploy command was changed"
  command="$(resolve_cli_command '' </dev/null 3>/dev/null)"
  [[ "${command}" == "serve" ]] \
    || fail "non-interactive no-argument startup must select serve"
  pass "TTY-safe default command selection"
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
  test_readme_operational_contract
  test_runtime_environment_and_launchers "${TEST_TEMP_ROOT}"
  test_self_test_helper_contract "${TEST_TEMP_ROOT}"
  test_agent_static_utility_route "${TEST_TEMP_ROOT}"
  test_agent_launcher_lock_guard
  test_agent_registration_contract "${TEST_TEMP_ROOT}"
  test_agent_config_recovery_contract "${TEST_TEMP_ROOT}"
  test_agent_semantic_health_contract
  test_agent_log_redaction "${TEST_TEMP_ROOT}"
  test_hashcat_live_monitor "${TEST_TEMP_ROOT}"
  test_detached_cracker_cleanup "${TEST_TEMP_ROOT}"
  test_public_url_rederivation
  test_default_admin_password_generation "${TEST_TEMP_ROOT}"
  test_migration_guard_queries
  test_http_contract
  test_task_dispatch_policy
  test_agent_reconciliation_state_machine "${TEST_TEMP_ROOT}"
  test_deploy_order
  test_operation_lock_release "${TEST_TEMP_ROOT}"
  test_serve_lifecycle
  test_foreground_monitor_runtime "${TEST_TEMP_ROOT}"
  test_default_command_selection
  test_loader_cache "${TEST_TEMP_ROOT}"
  printf 'All shell regression tests passed.\n'
}

export KIQUAI_MODULE_CONTEXT=1
export KIQUAI_LOADER_VERSION=3.2.5
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
