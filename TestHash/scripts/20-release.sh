#!/usr/bin/env bash
# shellcheck shell=bash
# KiQuai module: releases
# kiquai-module-api: 1
# kiquai-release: 3.1.0

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

  rm -f -- "${temp}"
  ln -s -- "${target}" "${temp}"
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

