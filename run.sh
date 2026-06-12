#!/bin/bash
###############################################################################
#  Pearl (PRL) Modular Mining Script
#  Hỗ trợ: GPU (rgminer) | CPU (bzminer) | Dual (GPU + CPU đồng thời)
#  Cấu hình: chỉnh sửa file  config.env  — không cần sửa script này.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/miners"

# ─── Load cấu hình ──────────────────────────────────────────────────────────
CONFIG_FILE="${SCRIPT_DIR}/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌  Không tìm thấy config.env tại: $CONFIG_FILE"
    exit 1
fi
# shellcheck source=config.env
source "$CONFIG_FILE"

# ─── Hàm tiện ích ───────────────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "❌  $*"; exit 1; }

install_deps() {
    log "📦  Cài đặt các gói cần thiết..."
    apt-get update -qq && apt-get install -y -qq wget tar curl procps 2>&1 | tail -1
}

# ─── Tải & giải nén miner ───────────────────────────────────────────────────
download_miner() {
    local name="$1" repo="$2" fallback="$3" dest="$4"

    mkdir -p "$dest"

    log "🔍  Tìm bản mới nhất của ${name} từ GitHub..."
    local url
    url=$(curl -sf "https://api.github.com/repos/${repo}/releases/latest" \
        | grep "browser_download_url" \
        | grep ".tar.gz" \
        | grep -v -i "mmpos" \
        | head -n 1 \
        | cut -d '"' -f 4) || true

    if [[ -z "${url:-}" ]]; then
        log "⚠️  GitHub API không phản hồi. Dùng link dự phòng..."
        url="$fallback"
    fi

    log "⬇️  Tải ${name}: ${url}"
    wget -qO "${dest}/${name}-latest.tar.gz" "$url"
    tar -xzf "${dest}/${name}-latest.tar.gz" -C "$dest"

    local exec_path
    exec_path=$(find "$dest" -type f -name "$name" | head -n 1)
    if [[ -z "$exec_path" ]]; then
        die "Không tìm thấy file thực thi ${name} sau khi giải nén."
    fi
    chmod +x "$exec_path"
    echo "$exec_path"
}

# ─── Vòng lặp chạy miner với auto-restart ───────────────────────────────────
run_miner_loop() {
    local label="$1"
    shift
    local cmd=("$@")
    local retries=0

    set +e
    while true; do
        log "🚀  [${label}] Khởi chạy: ${cmd[*]}"
        "${cmd[@]}"
        local exit_code=$?

        retries=$((retries + 1))
        if [[ "$MAX_RETRIES" -gt 0 && "$retries" -gt "$MAX_RETRIES" ]]; then
            log "🛑  [${label}] Đã vượt quá ${MAX_RETRIES} lần thử. Dừng."
            break
        fi

        log "⚠️  [${label}] Miner thoát (code=${exit_code}). Thử lại sau ${RESTART_DELAY}s... (lần ${retries})"
        sleep "$RESTART_DELAY"
    done
    set -e
}

# ─── Khởi chạy GPU miner (rgminer) ──────────────────────────────────────────
start_gpu_miner() {
    log "═══ Thiết lập GPU miner (rgminer) ═══"
    local exec_path
    exec_path=$(download_miner "rgminer" "Printscan/rgminer" \
        "$GPU_MINER_FALLBACK_URL" "${WORK_DIR}/gpu")

    local gpu_cmd=("$exec_path"
        --algo "$GPU_ALGO"
        --stratum "$GPU_POOL"
        --wallet "$WALLET"
        --worker-name "${WORKER_NAME}-gpu"
    )

    # Thêm batch size nếu được cấu hình
    if [[ -n "${GPU_PEARL_BATCH:-}" ]]; then
        gpu_cmd+=(--pearl-batch "$GPU_PEARL_BATCH")
    fi

    run_miner_loop "GPU" "${gpu_cmd[@]}"
}

# ─── Khởi chạy CPU miner (bzminer) ──────────────────────────────────────────
start_cpu_miner() {
    log "═══ Thiết lập CPU miner (bzminer) ═══"
    local exec_path
    exec_path=$(download_miner "bzminer" "bzminer/bzminer" \
        "$CPU_MINER_FALLBACK_URL" "${WORK_DIR}/cpu")

    # Tự phát hiện số lõi vật lý nếu CPU_THREADS="auto"
    local threads="$CPU_THREADS"
    if [[ "$threads" == "auto" ]]; then
        threads=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4)
        # Chia đôi nếu có Hyper-Threading (ước lượng đơn giản)
        local siblings
        siblings=$(grep "siblings" /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $NF}')
        local cores
        cores=$(grep "cpu cores" /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $NF}')
        if [[ -n "${siblings:-}" && -n "${cores:-}" && "$siblings" -gt "$cores" ]]; then
            threads=$((threads / 2))
        fi
        log "🔎  Phát hiện ${threads} lõi vật lý CPU."
    fi

    local cpu_cmd=("$exec_path"
        -a "$CPU_ALGO"
        --cpu 1
        --cpu_threads "$threads"
        --cpu_threads_cache_group "$CPU_THREADS_CACHE_GROUP"
        -w "$WALLET"
        -p "$CPU_POOL"
        --worker "${WORKER_NAME}-cpu"
    )

    run_miner_loop "CPU" "${cpu_cmd[@]}"
}

# ─── Dọn dẹp khi nhận tín hiệu thoát ───────────────────────────────────────
cleanup() {
    log "🧹  Đang dừng tất cả miner con..."
    # Dừng các tiến trình con của script này
    local children
    children=$(jobs -p 2>/dev/null) || true
    if [[ -n "$children" ]]; then
        kill $children 2>/dev/null || true
        wait $children 2>/dev/null || true
    fi
    log "✅  Đã dừng."
    exit 0
}
trap cleanup SIGINT SIGTERM

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    log "═══════════════════════════════════════════════════════"
    log "  Pearl (PRL) Miner — Chế độ: ${MINING_MODE^^}"
    log "  Ví    : ${WALLET:0:20}...${WALLET: -8}"
    log "  Worker: ${WORKER_NAME}"
    log "═══════════════════════════════════════════════════════"

    install_deps

    case "${MINING_MODE,,}" in
        gpu)
            start_gpu_miner
            ;;
        cpu)
            start_cpu_miner
            ;;
        dual)
            log "🔀  Chế độ DUAL: Khởi chạy GPU + CPU song song..."
            start_gpu_miner &
            start_cpu_miner &
            wait
            ;;
        *)
            die "MINING_MODE không hợp lệ: '${MINING_MODE}'. Chọn: gpu | cpu | dual"
            ;;
    esac
}

main "$@"
