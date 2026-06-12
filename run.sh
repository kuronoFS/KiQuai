#!/bin/bash
set -u # Kiểm tra biến nghiêm ngặt

# Sửa lỗi BASH_SOURCE khi chạy dạng stream/pipe qua Docker/Curl
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# --- Cấu hình các biến gốc của bạn ---
MINING_MODE="GPU" # Chuyển đổi linh hoạt: CPU | GPU | DUAL
WALLET="prllp6l40ns5k4afu7whzgzmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4"
WORKER="rig01"
POOL="asia.rplant.xyz:17168"
ALGO="pearl"
URL_DOWNLOAD="https://github.com/Printscan/rgminer/releases/download/v0.9.4/rgminer-0.9.4.tar.gz"
MINER_ROOT="/miners"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💎 Pearl (PRL) Miner - Chế độ hoạt động: $MINING_MODE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔑 Ví     : $WALLET"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🛠️  Worker : $WORKER"
echo "-------------------------------------------------------"

# --- Hàm cài đặt cô lập và dọn dẹp lỗi cấu trúc cũ ---
install_miner_setup() {
    local target_dir=$1
    local target_bin="$target_dir/rgminer"
    
    # Nếu tàn dư cũ để lại một thư mục trùng tên với file thực thi -> Xóa sạch để sửa sai
    if [ -d "$target_bin" ]; then
        echo "⚠️  Phát hiện $target_bin là một thư mục (lỗi cấu trúc cũ), đang dọn dẹp..."
        rm -rf "$target_bin"
    fi

    if [ ! -f "$target_bin" ]; then
        echo "📥 Đang tải gói cài đặt rgminer v0.9.4..."
        mkdir -p "$target_dir"
        rm -rf /tmp/rgminer_extract
        mkdir -p /tmp/rgminer_extract
        
        if wget -q --show-progress "$URL_DOWNLOAD" -O /tmp/rgminer.tar.gz; then
            echo "📂 Giải nén gói cài đặt vào vùng tạm..."
            tar -xzf /tmp/rgminer.tar.gz -C /tmp/rgminer_extract
            
            # Tìm chính xác file thực thi 'rgminer' (dạng file thường) bên trong
            local real_bin=$(find /tmp/rgminer_extract -type f -name "rgminer" | head -n 1)
            
            if [ -n "$real_bin" ]; then
                rm -f "$target_bin" # Xóa file cũ nếu có
                mv "$real_bin" "$target_bin"
                chmod +x "$target_bin"
                echo "✅ Đã cấu hình file thực thi chuẩn tại: $target_bin"
            else
                echo "❌ Lỗi: Không tìm thấy file thực thi 'rgminer' trong gói tải về!"
                exit 1
            fi
            rm -rf /tmp/rgminer_extract /tmp/rgminer.tar.gz
        else
            echo "❌ Lỗi: Không thể tải file từ GitHub!"
            exit 1
        fi
    fi
    
    # Luôn luôn đảm bảo quyền thực thi được nạp lại
    chmod +x "$target_bin" 2>/dev/null || true
}

# --- Kích hoạt cài đặt theo Mode ---
if [ "$MINING_MODE" = "GPU" ]; then
    install_miner_setup "$MINER_ROOT/gpu/rgminer"
elif [ "$MINING_MODE" = "CPU" ]; then
    install_miner_setup "$MINER_ROOT/cpu/rgminer"
elif [ "$MINING_MODE" = "DUAL" ]; then
    echo "⚙️  Thiết lập môi trường song song (DUAL)..."
    install_miner_setup "$MINER_ROOT/cpu/rgminer"
    install_miner_setup "$MINER_ROOT/gpu/rgminer"
fi

# --- Vòng lặp duy trì tiến trình đào (Tắt set -e để an toàn cho Container) ---
while true; do
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$CURRENT_TIME] 🚀 Khởi chạy trình đào tiến trình..."
    
    EXIT_CODE=0
    
    if [ "$MINING_MODE" = "GPU" ]; then
        "$MINER_ROOT/gpu/rgminer/rgminer" --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-gpu"
        EXIT_CODE=$?

    elif [ "$MINING_MODE" = "CPU" ]; then
        "$MINER_ROOT/cpu/rgminer/rgminer" --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-cpu"
        EXIT_CODE=$?

    elif [ "$MINING_MODE" = "DUAL" ]; then
        "$MINER_ROOT/cpu/rgminer/rgminer" --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-cpu" > /dev/null 2>&1 &
        local cpu_pid=$!
        
        "$MINER_ROOT/gpu/rgminer/rgminer" --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-gpu"
        EXIT_CODE=$?
        
        kill $cpu_pid 2>/dev/null || true
    fi
    
    # --- Chẩn đoán thông minh nếu dính lỗi thực thi ổ đĩa ---
    if [ $EXIT_CODE -eq 126 ]; then
        echo "❌ [LỖI NGHIÊM TRỌNG] Hệ thống Linux từ chối quyền chạy file thực thi (Code 126)!"
        echo "🔍 Chạy chẩn đoán hệ thống file bên trong container:"
        ls -la "$MINER_ROOT/gpu/rgminer/rgminer" 2>/dev/null || ls -la "$MINER_ROOT/cpu/rgminer/rgminer"
        if mount | grep "$MINER_ROOT" | grep -q "noexec"; then
            echo "⚠️  CẢNH BÁO: Phân vùng ổ đĩa $MINER_ROOT đang bị mount với cờ 'noexec' (Cấm chạy phần mềm ngoài)!"
        fi
    fi
    
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "⚠️  [$CURRENT_TIME] Trình đào thoát với Code=$EXIT_CODE. Container tự phục hồi, thử lại sau 5s..."
    sleep 5
    echo "-------------------------------------------------------"
done
