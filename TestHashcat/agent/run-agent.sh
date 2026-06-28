#!/usr/bin/env bash
set -Eeuo pipefail

HTP_AGENT_DIR="${HTP_AGENT_DIR:-/opt/hashtopolis-agent}"
HTP_API_URL="${HTP_API_URL:-http://hashtopolis-proxy/api/server.php}"
HTP_AGENT_DOWNLOAD_URL="${HTP_AGENT_DOWNLOAD_URL:-http://hashtopolis-proxy/agents.php?download=1}"
HTP_VOUCHER="${HTP_VOUCHER:-}"
HTP_RETRY_SECONDS="${HTP_RETRY_SECONDS:-10}"

mkdir -p "${HTP_AGENT_DIR}"
cd "${HTP_AGENT_DIR}"

echo "=========================================================="
echo "Hashtopolis Agent"
echo "HTP_API_URL=${HTP_API_URL}"
echo "HTP_AGENT_DOWNLOAD_URL=${HTP_AGENT_DOWNLOAD_URL}"
echo "=========================================================="

echo "[1/4] GPU check"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi || true
else
  echo "WARNING: nvidia-smi not found. Did you start container with GPU support?"
fi

echo "[2/4] Server check"
until curl -fsS "${HTP_API_URL}" >/dev/null 2>&1; do
  echo "Waiting for Hashtopolis backend..."
  sleep 5
done

echo "[3/4] Download agent"
if [[ ! -f hashtopolis.zip ]]; then
  curl -fL --retry 10 --retry-delay 3 \
    -o hashtopolis.zip \
    "${HTP_AGENT_DOWNLOAD_URL}"
fi

echo "[4/4] Start agent loop"
while true; do
  if [[ -f config.json ]]; then
    python3 -u hashtopolis.zip --url "${HTP_API_URL}" || true
  else
    if [[ -z "${HTP_VOUCHER}" ]]; then
      echo "No config.json and HTP_VOUCHER is empty."
      echo "Create voucher in WebUI, put it into .env, then recreate agent container."
      sleep "${HTP_RETRY_SECONDS}"
      continue
    fi

    python3 -u hashtopolis.zip \
      --url "${HTP_API_URL}" \
      --voucher "${HTP_VOUCHER}" || true
  fi

  echo "Agent exited. Restarting in ${HTP_RETRY_SECONDS}s..."
  sleep "${HTP_RETRY_SECONDS}"
done
