#!/usr/bin/env bash
# shellcheck shell=bash
# KiQuai module: system
# kiquai-module-api: 1
# kiquai-release: 3.2.3

if [[ "${KIQUAI_MODULE_CONTEXT:-0}" != "1" ]]; then
  printf 'This file is a KiQuai module; run ../run.sh instead.\n' >&2
  return 64 2>/dev/null || exit 64
fi

acquire_lock() {
  have_cmd flock || die "Required command 'flock' is missing; install util-linux first."
  [[ "${OPERATION_LOCK_HELD}" == "0" ]] \
    || die "The current KiQuai process already holds the operation lock."
  mkdir -p "$(dirname "${LOCK_FILE}")"
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    exec 9>&-
    die "Another KiQuai operation is already running."
  fi
  OPERATION_LOCK_HELD=1
}

release_lock() {
  [[ "${OPERATION_LOCK_HELD}" == "1" ]] || return 0
  flock -u 9 2>/dev/null || true
  exec 9>&-
  OPERATION_LOCK_HELD=0
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
  if ! have_cmd nvidia-smi; then
    [[ "${REQUIRE_HASHCAT_GPU}" == "0" ]] \
      || die "nvidia-smi is unavailable. Use an NVIDIA/CUDA Vast.ai image."
    warn "nvidia-smi is unavailable; continuing in explicit server-only mode."
  elif ! nvidia-smi -L; then
    [[ "${REQUIRE_HASHCAT_GPU}" == "0" ]] \
      || die "The NVIDIA GPU is not exposed to the outer container."
    warn "No NVIDIA GPU is exposed; continuing in explicit server-only mode."
  else
    nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader
  fi
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
    for command in 7z apache2ctl awk base64 composer curl df envsubst find flock git hashcat install jq mysql mysqladmin mysqld nginx od openssl pgrep php ps python3 readlink realpath runuser sed seq sha256sum ss stat supervisorctl supervisord tar tee tr xz; do
      have_cmd "${command}" || die "SKIP_APT=1 but '${command}' is missing."
    done
    [[ -x /usr/bin/python3 ]] \
      || die "SKIP_APT=1 but the managed interpreter /usr/bin/python3 is missing."
    /usr/bin/python3 -c 'import psutil, requests' \
      || die "SKIP_APT=1 but /usr/bin/python3 cannot import psutil and requests."
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
  [[ -x /usr/bin/python3 ]] \
    || die "The managed interpreter /usr/bin/python3 is missing after package installation."
  /usr/bin/python3 -c 'import psutil, requests' \
    || die "The managed Python agent dependencies psutil and requests are unavailable."
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
  stop_supervisor_program_if_active agent
  if supervisor_is_running; then
    info "Stopping KiQuai Supervisor and all managed processes."
    supervisor_ctl shutdown >/dev/null 2>&1 || true
    local deadline=$((SECONDS + 90))
    while supervisor_is_running && (( SECONDS < deadline )); do
      sleep 1
    done
    if supervisor_is_running; then
      supervisor_ctl status 2>&1 || true
      tail -n 120 "${LOG_DIR}/supervisord.log" 2>/dev/null || true
      die "KiQuai supervisord did not stop within 90 seconds; data was left untouched."
    fi
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

sqlx_version_matches() {
  local binary="$1"
  [[ -x "${binary}" ]] || return 1
  [[ "$("${binary}" --version 2>/dev/null || true)" == "sqlx-cli ${SQLX_CLI_VERSION}" ]]
}

publish_sqlx_runtime_binary() {
  local cached_binary="${TOOLS_DIR}/bin/sqlx"
  sqlx_version_matches "${cached_binary}" \
    || die "The cached SQLx binary is missing or is not sqlx-cli ${SQLX_CLI_VERSION}: ${cached_binary}."

  # Hashtopolis v1.0.0-rc2 setup.php invokes /usr/bin/sqlx explicitly. This
  # mirrors the COPY --from=prebuild ... /usr/bin/ step in its Dockerfile.
  install -m 755 "${cached_binary}" /usr/bin/sqlx
  sqlx_version_matches /usr/bin/sqlx \
    || die "Published /usr/bin/sqlx failed its exact version check."
  /usr/bin/sqlx --version
}

install_sqlx() {
  if sqlx_version_matches "${TOOLS_DIR}/bin/sqlx"; then
    publish_sqlx_runtime_binary
    return 0
  fi
  if [[ -e "${TOOLS_DIR}/bin/sqlx" ]]; then
    warn "Replacing cached SQLx because version ${SQLX_CLI_VERSION} is required."
    rm -f "${TOOLS_DIR}/bin/sqlx"
  fi
  if have_cmd sqlx && sqlx_version_matches "$(command -v sqlx)"; then
    install -m 755 "$(command -v sqlx)" "${TOOLS_DIR}/bin/sqlx"
    publish_sqlx_runtime_binary
    return 0
  fi

  local build_root="${TOOLS_DIR}/sqlx-build-${SQLX_CLI_VERSION}"
  local rustup_home="${build_root}/rustup"
  local cargo_home="${build_root}/cargo"
  local temp
  temp="$(mktemp -d)"
  local rustup_url="https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init"

  info "Installing pinned sqlx-cli ${SQLX_CLI_VERSION} with Rust ${RUST_TOOLCHAIN_VERSION}."
  retry 4 5 curl -fsSL "${rustup_url}" -o "${temp}/rustup-init"
  retry 4 5 curl -fsSL "${rustup_url}.sha256" -o "${temp}/rustup-init.sha256"
  local expected
  expected="$(awk '{print $1}' "${temp}/rustup-init.sha256")"
  [[ "${expected}" =~ ^[a-fA-F0-9]{64}$ ]] || die "Invalid rustup checksum response."
  printf '%s  %s\n' "${expected}" "${temp}/rustup-init" | sha256sum -c -
  chmod 700 "${temp}/rustup-init"

  CARGO_HOME="${cargo_home}" RUSTUP_HOME="${rustup_home}" \
    "${temp}/rustup-init" -y --no-modify-path --profile minimal \
      --default-toolchain "${RUST_TOOLCHAIN_VERSION}"
  CARGO_HOME="${cargo_home}" RUSTUP_HOME="${rustup_home}" \
    retry 2 10 "${cargo_home}/bin/cargo" install --locked \
      --version "${SQLX_CLI_VERSION}" sqlx-cli \
      --no-default-features --features native-tls,mysql --root "${TOOLS_DIR}"
  rm -rf "${temp}"
  publish_sqlx_runtime_binary

  if [[ "${KEEP_BUILD_TOOLCHAINS}" == "0" ]]; then
    rm -rf "${build_root}"
  fi
}
