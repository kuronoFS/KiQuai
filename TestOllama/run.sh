#!/bin/bash
# =============================================================================
#  Ollama Server Entrypoint
#  - Installs all required system dependencies (including zstd)
#  - Installs Ollama if not already present
#  - Optionally pre-pulls models listed in OLLAMA_MODELS
#  - Binds to OLLAMA_HOST (default: 0.0.0.0:11434) for reverse-proxy use
#  - Launches 'ollama serve' as PID 1 via exec for clean container signals
#
#  Environment variables (all optional):
#    OLLAMA_HOST          Address Ollama listens on       (default: 0.0.0.0:11434)
#    OLLAMA_MODELS        Space-separated models to pull  (default: none)
#    OLLAMA_PULL_TIMEOUT  Seconds allowed per model pull  (default: 300)
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

# Derive the listen port for the readiness check (handles "host:port" and bare "port")
OLLAMA_PORT="${OLLAMA_HOST##*:}"
# Fallback: if the value contains no colon at all, treat the whole string as a port
case "$OLLAMA_HOST" in
    *:*) OLLAMA_PORT="${OLLAMA_HOST##*:}" ;;
    *)   OLLAMA_PORT="11434" ;;
esac

# ---------------------------------------------------------------------------
# Step 1 — Install system dependencies
#
# Ollama's official install.sh downloads a .tar.zst archive and requires:
#   curl, tar, zstd, ca-certificates
# Many minimal base images (ubuntu:22.04, debian:slim, etc.) ship without
# zstd, which causes the installer to fail with "zstd: command not found".
# ---------------------------------------------------------------------------
log_info "=== Step 1/4: Installing system dependencies ==="

REQUIRED_PKGS="curl ca-certificates tar zstd"

if command -v apt-get >/dev/null 2>&1; then
    log_info "Detected apt — updating package lists and installing: $REQUIRED_PKGS"
    apt-get update -qq
    # DEBIAN_FRONTEND=noninteractive prevents any interactive prompts
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $REQUIRED_PKGS
elif command -v yum >/dev/null 2>&1; then
    log_info "Detected yum — installing: $REQUIRED_PKGS"
    yum install -y -q curl ca-certificates tar zstd
elif command -v dnf >/dev/null 2>&1; then
    log_info "Detected dnf — installing: $REQUIRED_PKGS"
    dnf install -y -q curl ca-certificates tar zstd
elif command -v apk >/dev/null 2>&1; then
    log_info "Detected apk — installing: $REQUIRED_PKGS"
    apk add --no-cache curl ca-certificates tar zstd
else
    log_warn "Unknown package manager — skipping automatic dependency install."
    log_warn "Please ensure the following are installed: $REQUIRED_PKGS"
fi

# Hard-fail if the two absolutely critical tools are missing
command -v curl >/dev/null 2>&1 || die "'curl' is required but was not found after install."
command -v zstd >/dev/null 2>&1 || die "'zstd' is required by Ollama's installer but was not found after install."

log_info "All required dependencies are present."

# ---------------------------------------------------------------------------
# Step 2 — Detect NVIDIA GPU
# ---------------------------------------------------------------------------
log_info "=== Step 2/4: Checking NVIDIA GPU environment ==="

if command -v nvidia-smi >/dev/null 2>&1; then
    log_info "nvidia-smi found. Detected GPU(s):"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader \
        2>/dev/null | while IFS= read -r line; do log_info "  -> $line"; done || true
else
    log_warn "nvidia-smi not found — Ollama will run in CPU-only mode."
    log_warn "For GPU support, start the container with:  docker run --gpus all ..."
    log_warn "and ensure the NVIDIA Container Toolkit is installed on the host."
fi

# ---------------------------------------------------------------------------
# Step 3 — Install Ollama
# ---------------------------------------------------------------------------
log_info "=== Step 3/4: Installing Ollama ==="

if command -v ollama >/dev/null 2>&1; then
    INSTALLED_VER=$(ollama --version 2>/dev/null || echo 'unknown')
    log_info "Ollama is already installed ($INSTALLED_VER) — skipping download."
else
    log_info "Downloading and running Ollama install script from https://ollama.com/install.sh ..."
    curl -fsSL https://ollama.com/install.sh | sh
    # Verify the binary is now reachable
    command -v ollama >/dev/null 2>&1 \
        || die "Ollama installation failed — 'ollama' binary not found after running install.sh."
    log_info "Ollama installed successfully: $(ollama --version 2>/dev/null || echo 'unknown')"
fi

# ---------------------------------------------------------------------------
# Step 4 — Optional model pre-pull, then launch server
# ---------------------------------------------------------------------------
log_info "=== Step 4/4: Starting Ollama server ==="

if [ -n "$OLLAMA_MODELS" ]; then
    log_info "OLLAMA_MODELS='$OLLAMA_MODELS' — starting a temporary server to pre-pull models..."

    # Start a background server for pulling; it will be stopped before the
    # final exec so that the main server starts cleanly as PID 1.
    ollama serve &
    SERVE_PID=$!

    # Wait until the REST API responds (up to 60 s)
    log_info "Waiting for Ollama API to become ready on port ${OLLAMA_PORT}..."
    READY=0
    for _i in $(seq 1 60); do
        if curl -sf "http://127.0.0.1:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1; then
            READY=1
            break
        fi
        sleep 1
    done

    if [ "$READY" -ne 1 ]; then
        kill "$SERVE_PID" 2>/dev/null || true
        wait "$SERVE_PID" 2>/dev/null || true
        die "Ollama API did not respond within 60 s. Check for port conflicts or startup errors above."
    fi
    log_info "API is ready."

    # Pull each model in turn
    for model in $OLLAMA_MODELS; do
        log_info "Pulling model: $model  (timeout: ${OLLAMA_PULL_TIMEOUT}s) ..."
        if command -v timeout >/dev/null 2>&1; then
            timeout "$OLLAMA_PULL_TIMEOUT" ollama pull "$model" \
                || log_warn "Could not pull '$model' — skipping (check model name or network)."
        else
            ollama pull "$model" \
                || log_warn "Could not pull '$model' — skipping."
        fi
    done

    # Gracefully stop the temporary server before handing off to exec
    log_info "Stopping temporary server (PID $SERVE_PID)..."
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
    log_info "Temporary server stopped."
fi

# ---------------------------------------------------------------------------
# Launch Ollama as PID 1
#
# 'exec' replaces this shell process with 'ollama serve', so:
#   - Docker SIGTERM (from 'docker stop') goes directly to Ollama
#   - No orphan shell process remains
#   - Ollama handles its own graceful shutdown
# ---------------------------------------------------------------------------
log_info "Launching Ollama server on ${OLLAMA_HOST} ..."
exec ollama serve
