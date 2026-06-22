#!/bin/bash
# =============================================================================
#  Ollama Server Entrypoint
#  - Installs Ollama if not already present
#  - Optionally pre-pulls models listed in OLLAMA_MODELS
#  - Binds to OLLAMA_HOST (default: 0.0.0.0:11434) so reverse proxies work
#  - Launches 'ollama serve' as PID 1 via exec for clean container signals
#
#  Environment variables:
#    OLLAMA_HOST          Address Ollama listens on  (default: 0.0.0.0:11434)
#    OLLAMA_MODELS        Space-separated models to pull at startup (optional)
#    OLLAMA_PULL_TIMEOUT  Seconds allowed per model pull (default: 300)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_RED=$'\e[31m'; C_RST=$'\e[0m'
else
    C_GRN=""; C_YEL=""; C_RED=""; C_RST=""
fi

ts()        { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { echo "${C_GRN}[$(ts)] [INFO]${C_RST}  $*"; }
log_warn()  { echo "${C_YEL}[$(ts)] [WARN]${C_RST}  $*" >&2; }
log_error() { echo "${C_RED}[$(ts)] [ERROR]${C_RST} $*" >&2; }
die()       { log_error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Configuration (override via environment variables)
# ---------------------------------------------------------------------------
export OLLAMA_HOST="${OLLAMA_HOST:-0.0.0.0:11434}"
OLLAMA_MODELS="${OLLAMA_MODELS:-}"
OLLAMA_PULL_TIMEOUT="${OLLAMA_PULL_TIMEOUT:-300}"

# ---------------------------------------------------------------------------
# Step 1 — Install system dependencies
# ---------------------------------------------------------------------------
log_info "=== Step 1/4: Installing system dependencies ==="

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl ca-certificates
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl ca-certificates
else
    log_warn "Unknown package manager — skipping dependency installation."
    log_warn "Ensure 'curl' and 'ca-certificates' are already installed."
fi

# Verify curl is available
command -v curl >/dev/null 2>&1 || die "'curl' is required but could not be installed."

# ---------------------------------------------------------------------------
# Step 2 — Detect NVIDIA GPU
# ---------------------------------------------------------------------------
log_info "=== Step 2/4: Checking NVIDIA GPU environment ==="

if command -v nvidia-smi >/dev/null 2>&1; then
    log_info "nvidia-smi found. GPU information:"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader \
        2>/dev/null | while IFS= read -r line; do log_info "  -> $line"; done || true
else
    log_warn "nvidia-smi not found. Ollama will run in CPU-only mode."
    log_warn "To enable GPU support, start the container with: docker run --gpus all ..."
    log_warn "and ensure the NVIDIA Container Toolkit is installed on the host."
fi

# ---------------------------------------------------------------------------
# Step 3 — Install Ollama
# ---------------------------------------------------------------------------
log_info "=== Step 3/4: Installing Ollama ==="

if command -v ollama >/dev/null 2>&1; then
    INSTALLED_VER=$(ollama --version 2>/dev/null || echo 'unknown')
    log_info "Ollama is already installed: $INSTALLED_VER — skipping installation."
else
    log_info "Downloading and installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    command -v ollama >/dev/null 2>&1 || die "Ollama installation failed — 'ollama' binary not found after install."
    log_info "Ollama installed successfully: $(ollama --version 2>/dev/null || echo 'unknown')"
fi

# ---------------------------------------------------------------------------
# Step 4 — Optional: pre-pull models
# ---------------------------------------------------------------------------
log_info "=== Step 4/4: Starting Ollama server ==="

if [ -n "$OLLAMA_MODELS" ]; then
    log_info "OLLAMA_MODELS is set — starting a temporary server to pull models..."
    ollama serve &
    SERVE_PID=$!

    # Wait until the API is ready (up to 30 s)
    log_info "Waiting for Ollama API to become ready..."
    READY=0
    for i in $(seq 1 30); do
        if curl -sf "http://127.0.0.1:${OLLAMA_HOST##*:}/api/tags" >/dev/null 2>&1; then
            READY=1
            break
        fi
        sleep 1
    done

    if [ "$READY" -ne 1 ]; then
        kill "$SERVE_PID" 2>/dev/null || true
        die "Ollama API did not become ready in time. Check for port conflicts or startup errors."
    fi

    # Pull each model
    for model in $OLLAMA_MODELS; do
        log_info "Pulling model: $model (timeout: ${OLLAMA_PULL_TIMEOUT}s)..."
        if command -v timeout >/dev/null 2>&1; then
            timeout "$OLLAMA_PULL_TIMEOUT" ollama pull "$model" \
                || log_warn "Failed to pull '$model' — it may not be available or the pull timed out."
        else
            ollama pull "$model" \
                || log_warn "Failed to pull '$model' — it may not be available."
        fi
    done

    # Stop the temporary server
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
    log_info "Temporary server stopped. Launching main server..."
fi

# ---------------------------------------------------------------------------
# Launch Ollama as PID 1
# Using 'exec' replaces this shell with the Ollama process, so Docker signals
# (SIGTERM from 'docker stop') are delivered directly to Ollama for a clean
# shutdown instead of being caught by a wrapper shell.
# ---------------------------------------------------------------------------
log_info "Launching Ollama server on ${OLLAMA_HOST} ..."
exec ollama serve
