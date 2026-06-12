#!/bin/bash
set -u # Kiểm tra biến nghiêm ngặt

# Tránh lỗi biến môi trường BASH_SOURCE khi chạy dạng stream qua Docker
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# --- Các biến cấu hình hệ thống của bạn ---
MINING_MODE="GPU" # Chuyển đổi linh hoạt: CPU | GPU | DUAL
WALLET="prllp6l40ns5k4afu7whzgzmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4"
WORKER="rig01"
POOL="asia.rplant.xyz:17168"
ALGO="pearl"

# SỬA LỖI: Dùng đường dẫn tự động điều hướng sang bản Linux x86_64 mới nhất của RPlant chính chủ
URL_DOWNLOAD="https://github.com/rplant8/rgminer/releases/latest/download/rgminer-linux.tar.gz"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💎 Pearl (PRL) Miner - Chế độ: $MINING_MODE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔑 Ví     : $WALLET"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🛠️  Worker : $WORKER"
echo "-------------------------------------------------------"

# --- Hàm cài đặt và kiểm định cấu trúc file ---
install_miner_setup() {
    local mode_suffix=$1 # "cpu" hoặc "gpu"
    local target_bin="/usr/local/bin/rgminer-$mode_suffix"
    
    if [ ! -f "$target_bin" ]; then
        echo "📥 Đang tải gói cài đặt rgminer chuẩn Linux x86_64..."
        rm -rf /tmp/rgminer_extract
        mkdir -p /tmp/rgminer_extract
        
        # Tải trực tiếp không qua gọi API để tránh trùng lặp lỗi 404
        if wget -q --show-progress "$URL_DOWNLOAD" -O /tmp/rgminer.tar.gz; then
            echo "📂 Giải nén gói cài đặt..."
            tar -xzf /tmp/rgminer.tar.gz -C /tmp/rgminer_extract 2>/dev/null || tar -xzf /tmp/rgminer.tar.gz -C /tmp/rgminer_extract
            
            # Tìm kiếm thông minh mọi file có tiền tố rgminer trong gói tải về
            local real_bin=$(find /tmp/rgminer_extract -type f -name "rgminer*" | head -n 1)
            
            if [ -n "$real_bin" ]; then
                mv "$real_bin" "$target_bin"
                chmod +x "$target_bin"
                echo "✅ Đã nạp file thực thi vào hệ thống: $target_bin"
                
                # --- BỘ CHẨN ĐOÁN SÂU CẤU TRÚC FILE ---
                echo "🔍 Phân tích mã định danh File (Magic Bytes):"
                echo -n "   -> Định dạng nhận diện: "
                od -An -t x1 -N 4 "$target_bin" 2>/dev/null || echo "Không thể đọc định dạng"
                echo "   -> Ghi chú: Nếu hiển thị '7f 45 4c 46' thì đó là chuẩn ELF Linux x86_64."
            else
                echo "❌ Lỗi: Không tìm thấy file thực thi phù hợp trong gói tải về!"
                exit 1
            fi
            rm -rf /tmp/rgminer_extract /tmp/rgminer.tar.gz
        else
            echo "❌ Lỗi: Không thể tải file từ kho lưu trữ GitHub!"
            exit 1
        fi
    fi
    chmod +x "$target_bin" 2>/dev/null || true
}

# --- Kích hoạt cài đặt theo Mode ---
if [ "$MINING_MODE" = "GPU" ]; then
    install_miner_setup "gpu"
elif [ "$MINING_MODE" = "CPU" ]; then
    install_miner_setup "cpu"
elif [ "$MINING_MODE" = "DUAL" ]; then
    echo "⚙️ Thiết lập môi trường chạy song song hệ thống (DUAL)..."
    install_miner_setup "cpu"
    install_miner_setup "gpu"
fi

# --- Vòng lặp duy trì tiến trình đào ---
while true; do
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$CURRENT_TIME] 🚀 Khởi chạy trình đào từ phân vùng hệ thống..."
    
    if [ "$MINING_MODE" = "GPU" ]; then
        /usr/local/bin/rgminer-gpu --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-gpu"

    elif [ "$MINING_MODE" = "CPU" ]; then
        /usr/local/bin/rgminer-cpu --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-cpu"

    elif [ "$MINING_MODE" = "DUAL" ]; then
        /usr/local/bin/rgminer-cpu --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-cpu" > /dev/null 2>&1 &
        local cpu_pid=$!
        
        /usr/local/bin/rgminer-gpu --algo "$ALGO" --stratum "$POOL" --wallet "$WALLET" --worker-name "${WORKER}-gpu"
        
        kill $cpu_pid 2>/dev/null || true
    fi
    
    EXIT_CODE=$?
    CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "⚠️ [$CURRENT_TIME] Trình đào thoát (Code=$EXIT_CODE). Khởi động lại sau 5s..."
    sleep 5
    echo "-------------------------------------------------------"
done
