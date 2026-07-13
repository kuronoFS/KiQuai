#!/usr/bin/env bash
# shellcheck shell=bash
# KiQuai module: releases
# kiquai-module-api: 1
# kiquai-release: 3.2.5

if [[ "${KIQUAI_MODULE_CONTEXT:-0}" != "1" ]]; then
  printf 'This file is a KiQuai module; run ../run.sh instead.\n' >&2
  return 64 2>/dev/null || exit 64
fi

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
  local target="$1"
  local link="$2"
  local temp="${link}.tmp.$$"

  rm -f -- "${temp}" || return 1
  if ! ln -s -- "${target}" "${temp}"; then
    rm -f -- "${temp}" 2>/dev/null || true
    return 1
  fi
  if ! mv -Tf "${temp}" "${link}"; then
    rm -f -- "${temp}" 2>/dev/null || true
    return 1
  fi
}

harden_server_release_permissions() {
  local target="$1"
  [[ -d "${target}/src/inc/utils/locks" ]] \
    || die "Backend lock directory is missing: ${target}/src/inc/utils/locks."
  chown -R root:www-data "${target}"
  chmod -R u=rwX,g=rX,o= "${target}"
  chown -R www-data:www-data "${target}/src/inc/utils/locks"
  chmod 770 "${target}/src/inc/utils/locks"
}

build_server_release() {
  local suffix="${HASHTOPOLIS_VERSION#v}"
  local target="${RELEASES_DIR}/server-${suffix}"
  if [[ -f "${target}/.kiquai-ready" && "${FORCE_REBUILD}" == "0" ]]; then
    SERVER_RELEASE_TARGET="${target}"
    harden_server_release_permissions "${target}"
    info "Reusing Hashtopolis backend ${HASHTOPOLIS_VERSION}."
    return 0
  fi
  if [[ -e "${target}" ]]; then
    target="${target}-rebuild-${RUN_ID}"
  fi
  SERVER_RELEASE_TARGET="${target}"

  local temp="${RELEASES_DIR}/.server-${suffix}.tmp.$$"
  rm -rf -- "${temp}"
  retry 3 5 git clone --depth 1 --branch "${HASHTOPOLIS_VERSION}" \
    "${HASHTOPOLIS_SERVER_REPOSITORY}" "${temp}"
  COMPOSER_ALLOW_SUPERUSER=1 composer install \
    --working-dir="${temp}" \
    --no-dev --no-interaction --prefer-dist --optimize-autoloader
  [[ -f "${temp}/src/inc/startup/setup.php" ]] \
    || die "The backend source tree is incomplete."
  printf '%s\n' "${HASHTOPOLIS_VERSION}" > "${temp}/.kiquai-ready"
  harden_server_release_permissions "${temp}"
  mv "${temp}" "${target}"
}

build_frontend_release() {
  local suffix="${HASHTOPOLIS_FRONTEND_VERSION#v}"
  local target="${RELEASES_DIR}/frontend-${suffix}"
  if [[ -f "${target}/.kiquai-ready" && "${FORCE_REBUILD}" == "0" ]]; then
    FRONTEND_RELEASE_TARGET="${target}"
    info "Reusing Hashtopolis frontend ${HASHTOPOLIS_FRONTEND_VERSION}."
    return 0
  fi
  if [[ -e "${target}" ]]; then
    target="${target}-rebuild-${RUN_ID}"
  fi
  FRONTEND_RELEASE_TARGET="${target}"

  local temp="${RELEASES_DIR}/.frontend-${suffix}.tmp.$$"
  rm -rf -- "${temp}"
  retry 3 5 git clone --depth 1 --branch "${HASHTOPOLIS_FRONTEND_VERSION}" \
    "${HASHTOPOLIS_FRONTEND_REPOSITORY}" "${temp}"
  [[ -r "${temp}/.nvmrc" ]] || die "The frontend release does not contain .nvmrc."
  local node_version
  node_version="$(tr -d '[:space:]' < "${temp}/.nvmrc")"
  install_node_version "${node_version}"
  (
    cd "${temp}" || exit 1
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
  mv "${temp}" "${target}"
}

activate_releases() {
  local previous_server=""
  local previous_frontend=""
  [[ -f "${SERVER_RELEASE_TARGET}/.kiquai-ready" ]] \
    || die "The staged backend release is not ready: ${SERVER_RELEASE_TARGET:-unset}."
  [[ -f "${FRONTEND_RELEASE_TARGET}/.kiquai-ready" ]] \
    || die "The staged frontend release is not ready: ${FRONTEND_RELEASE_TARGET:-unset}."

  previous_server="$(readlink -f "${SERVER_CURRENT}" 2>/dev/null || true)"
  previous_frontend="$(readlink -f "${FRONTEND_CURRENT}" 2>/dev/null || true)"
  atomic_symlink "${SERVER_RELEASE_TARGET}" "${SERVER_CURRENT}" \
    || die "Unable to activate the staged backend release."
  if ! atomic_symlink "${FRONTEND_RELEASE_TARGET}" "${FRONTEND_CURRENT}"; then
    if [[ -n "${previous_server}" ]]; then
      atomic_symlink "${previous_server}" "${SERVER_CURRENT}" || true
    else
      rm -f "${SERVER_CURRENT}"
    fi
    if [[ -n "${previous_frontend}" ]]; then
      atomic_symlink "${previous_frontend}" "${FRONTEND_CURRENT}" || true
    fi
    die "Unable to activate the staged frontend release; backend pointer was rolled back."
  fi
  success "Activated backend ${HASHTOPOLIS_VERSION} and frontend ${HASHTOPOLIS_FRONTEND_VERSION}."
}
