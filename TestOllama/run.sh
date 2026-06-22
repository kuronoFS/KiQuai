#!/bin/bash
# =============================================================================
#  Ollama Server Entrypoint
#  Supports GPU (NVIDIA CUDA) and CPU-only mode.
#
#  All settings can be overridden by environment variables at runtime:
#       OLLAMA_HOST=0.0.0.0:8080 OLLAMA_MODELS="qwen2.5:7b" ./run.sh
#       curl -fsSL <url>/run.sh | OLLAMA_MODELS="llama3.2" bash
#
#  Each time you edit this file, bump SCRIPT_VERSION below so logs show
#  exactly which version is running.
# =============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# [SCRIPT VERSION] — bump this every time you make changes
# ----------------------------------------------------------------------------
SCRIPT_VERSION="1.2.0"
SCRIPT_BUILD_DATE="2026-06-22"

# ============================================================================
#  ⚙️  CONFIGURATION — edit everything in this block to customise behaviour
# ============================================================================

# --- Server ---
# Address Ollama binds to. MUST be 0.0.0.0 (not 127.0.0.1) so traffic can
# reach the container from outside (reverse proxy, direct access, etc.).
OLLAMA_BIND_ADDR="${OLLAMA_BIND_ADDR:-0.0.0.0}"

# Port Ollama listens on.
# Make sure your docker run / docker-compose exposes this same port:
#   docker run -p 45000:45000 ...
OLLAMA_PORT="${OLLAMA_PORT:-45000}"

# --- Model pre-pull (optional) ---
# Space-separated list of models to download before the server starts serving.
# Leave empty ("") to skip pre-pulling entirely.
# Examples: "qwen2.5:7b"  |  "llama3.2 mistral:7b"  |  ""
OLLAMA_MODELS="${OLLAMA_MODELS:-}"

# Seconds to wait for each model pull before giving up (0 = no timeout).
OLLAMA_PULL_TIMEOUT="${OLLAMA_PULL_TIMEOUT:-300}"

# --- Keep-alive ---
# How long Ollama keeps a model loaded in VRAM after the last request.
# Examples: "5m"  |  "1h"  |  "0" (unload immediately)  |  "-1" (never unload)
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-5m}"

# --- GPU memory (optional) ---
# Fraction of VRAM Ollama is allowed to use (0.0 – 1.0).
# Leave empty ("") to use Ollama's default (auto).
OLLAMA_GPU_MEMORY_FRACTION="${OLLAMA_GPU_MEMORY_FRACTION:-}"

# --- Concurrency (optional) ---
# Maximum number of requests processed in parallel.
# Leave empty ("") to use Ollama's default.
OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-}"

# --- Debug ---
# Set to 1 to show verbose [DEBUG] log lines from this script.
DEBUG="${DEBUG:-0}"

# Seconds to wait for the API to become ready during model pre-pull.
API_READY_TIMEOUT="${API_READY_TIMEOUT:-60}"

# ============================================================================
#  (end of configuration block — no need to edit below this line)
# ============================================================================

# ----------------------------------------------------------------------------
# Logging helpers
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
    C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_RED=$'\e[31m'; C_DIM=$'\e[2m'; C_CYN=$'\e[36m'; C_RST=$'\e[0m'
else
    C_GRN=""; C_YEL=""; C_RED=""; C_DIM=""; C_CYN=""; C_RST=""
fi

TOTAL_STEPS=4
ts()        { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { echo "${C_GRN}[$(ts)] [INFO ]${C_RST}  $*"; }
log_warn()  { echo "${C_YEL}[$(ts)] [WARN ]${C_RST}  $*" >&2; }
log_error() { echo "${C_RED}[$(ts)] [ERROR]${C_RST}  $*" >&2; }
log_debug() { [ "$DEBUG" = "1" ] && echo "${C_DIM}[$(ts)] [DEBUG]${C_RST}  $*" || true; }
log_step()  { echo; echo "${C_CYN}[$(ts)] [STEP $1/$TOTAL_STEPS] ===== $2 =====${C_RST}"; }
hr()        { echo "------------------------------------------------------------------------"; }
die()       { log_error "$*"; log_error "Script stopped (run.sh v$SCRIPT_VERSION). Fix the error above and re-run."; exit 1; }

# Quick version flag:  ./run.sh --version
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
    echo "run.sh v$SCRIPT_VERSION (build $SCRIPT_BUILD_DATE)"
    exit 0
fi

# ----------------------------------------------------------------------------
# Build the full OLLAMA_HOST string from BIND_ADDR + PORT
# Keeping them separate avoids ambiguity and makes the port easy to change.
# ----------------------------------------------------------------------------
OLLAMA_HOST="${OLLAMA_BIND_ADDR}:${OLLAMA_PORT}"

# Export ALL Ollama env vars NOW, before any 'ollama' command is executed,
# so both the pre-pull server and the final server inherit the same config.
export OLLAMA_HOST
export OLLAMA_KEEP_ALIVE
[ -n "$OLLAMA_GPU_MEMORY_FRACTION" ] && export OLLAMA_GPU_MEMORY_FRACTION || true
[ -n "$OLLAMA_NUM_PARALLEL" ]        && export OLLAMA_NUM_PARALLEL        || true

# ----------------------------------------------------------------------------
# Banner
# ----------------------------------------------------------------------------
hr
echo "  🦙  Ollama Server Entrypoint"
echo "  📌  Script version : v$SCRIPT_VERSION (build $SCRIPT_BUILD_DATE)"
hr
log_info "Listen address  : ${OLLAMA_HOST}"
log_info "Pre-pull models : ${OLLAMA_MODELS:-(none)}"
log_info "Keep-alive      : ${OLLAMA_KEEP_ALIVE}"
log_debug "OLLAMA_PULL_TIMEOUT   : ${OLLAMA_PULL_TIMEOUT}s"
log_debug "OLLAMA_GPU_MEMORY_FRACTION : ${OLLAMA_GPU_MEMORY_FRACTION:-(auto)}"
log_debug "OLLAMA_NUM_PARALLEL        : ${OLLAMA_NUM_PARALLEL:-(auto)}"
log_debug "API_READY_TIMEOUT          : ${API_READY_TIMEOUT}s"

# ============================================================================
#  STEP 1 — Install system dependencies
#
#  Ollama's install.sh fetches a .tar.zst archive — without 'zstd' the
#  extraction fails with "zstd: command not found". Install it first.
# ============================================================================
log_step 1 "Installing system dependencies"

REQUIRED_PKGS="curl ca-certificates tar zstd"

if command -v apt-get >/dev/null 2>&1; then
    log_info "Package manager: apt — installing: $REQUIRED_PKGS"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $REQUIRED_PKGS
elif command -v dnf >/dev/null 2>&1; then
    log_info "Package manager: dnf — installing: $REQUIRED_PKGS"
    dnf install -y -q curl ca-certificates tar zstd
elif command -v yum >/dev/null 2>&1; then
    log_info "Package manager: yum — installing: $REQUIRED_PKGS"
    yum install -y -q curl ca-certificates tar zstd
elif command -v apk >/dev/null 2>&1; then
    log_info "Package manager: apk — installing: $REQUIRED_PKGS"
    apk add --no-cache curl ca-certificates tar zstd
else
    log_warn "Unknown package manager — skipping automatic install."
    log_warn "Please ensure the following tools are present: $REQUIRED_PKGS"
fi

command -v curl >/dev/null 2>&1 || die "'curl' is required but was not found after install attempt."
command -v zstd >/dev/null 2>&1 || die "'zstd' is required by Ollama's installer but was not found after install attempt."
log_info "✅ All required dependencies are present."

# ============================================================================
#  STEP 2 — Detect NVIDIA GPU
# ============================================================================
log_step 2 "Checking NVIDIA GPU environment"

if command -v nvidia-smi >/dev/null 2>&1; then
    log_info "nvidia-smi found. Detected GPU(s):"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader \
        2>/dev/null | while IFS= read -r line; do log_info "   -> $line"; done || true
    log_info "✅ GPU detected — Ollama will use CUDA acceleration."
else
    log_warn "nvidia-smi not found — Ollama will run in CPU-only mode."
    log_warn "  For GPU support, launch the container with:  docker run --gpus all ..."
    log_warn "  and ensure the NVIDIA Container Toolkit is installed on the host."
fi

# ============================================================================
#  STEP 3 — Install Ollama
# ============================================================================
log_step 3 "Installing Ollama"

if command -v ollama >/dev/null 2>&1; then
    INSTALLED_VER=$(ollama --version 2>/dev/null || echo 'unknown')
    log_info "✅ Ollama already installed: $INSTALLED_VER — skipping download."
else
    log_info "Downloading Ollama via https://ollama.com/install.sh ..."
    curl -fsSL https://ollama.com/install.sh | sh
    command -v ollama >/dev/null 2>&1 \
        || die "Ollama installation failed — binary not found after running install.sh."
    log_info "✅ Ollama installed: $(ollama --version 2>/dev/null || echo 'unknown')"
fi

# ============================================================================
#  STEP 4 — (Optional) pre-pull models, then launch server as PID 1
# ============================================================================
log_step 4 "Starting Ollama server"

if [ -n "$OLLAMA_MODELS" ]; then
    log_info "OLLAMA_MODELS='$OLLAMA_MODELS' — starting temporary server for pre-pull..."

    # Start a background server to do the pulls.
    # OLLAMA_HOST is already exported above, so this server binds to the
    # correct address/port (e.g. 0.0.0.0:45000) right away.
    ollama serve &
    SERVE_PID=$!

    # Wait for the API to respond before attempting pulls.
    # We probe 127.0.0.1 (loopback) regardless of OLLAMA_BIND_ADDR because
    # we are on the same host as the server process.
    log_info "Waiting up to ${API_READY_TIMEOUT}s for Ollama API on port ${OLLAMA_PORT}..."
    READY=0
    for _i in $(seq 1 "$API_READY_TIMEOUT"); do
        if curl -sf "http://127.0.0.1:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1; then
            READY=1; break
        fi
        sleep 1
    done

    if [ "$READY" -ne 1 ]; then
        kill "$SERVE_PID" 2>/dev/null || true
        wait "$SERVE_PID" 2>/dev/null || true
        die "Ollama API did not respond on port ${OLLAMA_PORT} within ${API_READY_TIMEOUT}s. Check for port conflicts or errors above."
    fi
    log_info "API is ready."

    for model in $OLLAMA_MODELS; do
        log_info "Pulling model: $model  (timeout: ${OLLAMA_PULL_TIMEOUT}s)..."
        if [ "${OLLAMA_PULL_TIMEOUT}" -gt 0 ] 2>/dev/null && command -v timeout >/dev/null 2>&1; then
            timeout "$OLLAMA_PULL_TIMEOUT" ollama pull "$model" \
                || log_warn "Could not pull '$model' — skipping (check model name or network)."
        else
            ollama pull "$model" \
                || log_warn "Could not pull '$model' — skipping."
        fi
    done

    log_info "Stopping temporary server (PID $SERVE_PID)..."
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
    log_info "Temporary server stopped. Launching main server..."
else
    log_info "OLLAMA_MODELS is empty — skipping model pre-pull."
fi

# ----------------------------------------------------------------------------
# Launch Ollama as PID 1
#
# 'exec' replaces this shell with 'ollama serve' so that:
#   - Docker SIGTERM ('docker stop') is delivered directly to Ollama
#   - No orphan shell process lingers
#   - Ollama handles its own graceful shutdown
#
# OLLAMA_HOST is already exported, so Ollama picks it up automatically.
# No need to pass --host on the command line.
# ----------------------------------------------------------------------------
log_info "🚀 Launching Ollama server — listening on ${OLLAMA_HOST} ..."
log_info "   Access from other machines: http://<host-ip>:${OLLAMA_PORT}/api/tags"
exec ollama serve
