#!/bin/bash
set -e
set -u 

# =====================================================================
# FIX LỖI DÒNG 10: Tránh crash "unbound variable" khi pipe qua Docker/Curl
# =====================================================================
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# --- Các biến cấu hình gốc của bạn ---
MINING_MODE="DUAL" # Tùy chọn: CPU | GPU | DUAL
WALLET="prllp6l40ns5k4afu7whzgzmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4"
WORKER="rig01"
POOL="asia.rplant.xyz:17168"
ALGO="pearl"
URL_DOWNLOAD="https://github.com/Printscan/rgminer/releases/download/v0.9.4/rgminer-0.9.4.tar.gz"
MINER_ROOT="/miners"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💎 Pearl (PRL) Miner - Chế độ: $MINING_MODE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔑 Ví     : $WALLET"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🛠️  Worker : $WORKER"
echo "-------------------------------------------------------"

# --- Hàm đóng gói logic cài đặt (Fix triệt để lỗi lồng thư mục của lệnh tar) ---
install_miner_setup() {
    local target_dir=$1
    local target_bin="$target_dir/rgminer"
    
    mkdir -p "$target_dir"
    if [ ! -f "$target_bin" ]; then
        echo "📥 Đang tải gói cài đặt vào: $target_dir ..."
        wget -q --show-progress "$URL_DOWNLOAD" -O /tmp/rgminer.tar.gz
        
        echo "📂 Giải nén và làm phẳng cấu trúc thư mục..."
        # Ép bung thẳng ruột file tar vào đích bằng --strip-components=1
        tar -xzf /tmp/rgminer.tar.gz -C "$target_dir" --strip-components=1 2>/dev/null || \
        tar -xzf /tmp/rgminer.tar.gz -C "$target_dir"
        rm -f /tmp/rgminer.tar.gz
        
        # Cơ chế tự tìm kiếm nếu cấu trúc gói thay đổi vị trí file thực thi
        if [ ! -f "$target_bin" ]; then
            local found_bin=$(find "$target_dir" -type f -name "rgminer" | head -n 1)
            if [ -n "$found_bin" ]; then mv "$found_bin" "$target_bin"; fi
        fi
        
        if [ -f "$target_bin" ]; then
            chmod +x "$target_bin"
            echo "✅ Cấu hình thành công tại: $target_bin"
        else
            echo "❌ Lỗi: Không tìm thấy file thực thi 'rgminer' sau khi giải nén!"
            exit 1
        fi
    fi
}

# --- Định tuyến cài đặt theo từng Mode dữ liệu ---
if [ "$MINING_MODE" = "GPU" ]; then
    install_miner_setup "$MINER_ROOT/gpu/rgminer"
elif [ "$MINING_MODE" = "CPU" ]; then
    install_miner_setup "$MINER_ROOT/cpu/rgminer"
elif [ "$MINING_MODE" = "DUAL" ]; then
    echo "⚙️ Thiết lập môi trường chạy song song (DUAL)..."
    install_miner_setup "$MINER_ROOT/cpu/rgminer"
    install_miner_setup "$MINER_ROOT/gpu/rgminer"
fi

# --- Vòng lặp duy trì đào (Auto-Restart) ---
while true; do
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$CURRENT_TIME] 🚀 Kích hoạt miner tiến trình..."
    
    if [ "$MINING_MODE" = "GPU" ]; then
        "$MINER_ROOT/gpu/rgminer/rgminer" --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-gpu"

    elif [ "$MINING_MODE" = "CPU" ]; then
        "$MINER_ROOT/cpu/rgminer/rgminer" --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-cpu"

    elif [ "$MINING_MODE" = "DUAL" ]; then
        echo "⚡ [DUAL] Đang khởi chạy CPU Miner (Chạy ngầm)..."
        "$MINER_ROOT/cpu/rgminer/rgminer" --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-cpu" > /dev/null 2>&1 &
        CPU_PID=$!
        
        echo "⚡ [DUAL] Đang khởi chạy GPU Miner (Tiền cảnh)..."
        "$MINER_ROOT/gpu/rgminer/rgminer" --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-gpu"
        
        # Nếu luồng GPU thoát hoặc lỗi, hạ luôn luồng CPU ngầm để đồng bộ khởi động lại toàn container
        kill $CPU_PID 2>/dev/null || true
    fi
    
    EXIT_CODE=$?
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "⚠️ [$CURRENT_TIME] [$MINING_MODE] Trình đào tạm thoát (code=$EXIT_CODE). Khởi động lại sau 5s..."
    sleep 5
    echo "-------------------------------------------------------"
done
