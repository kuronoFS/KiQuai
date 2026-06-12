#!/bin/bash
set -e

echo "=== 1. Cài đặt các thư viện nền tảng trong Docker ==="
apt-get update && apt-get install -y wget tar curl

echo "=== 2. Tự động quét và lấy link rgminer Stable mới nhất từ GitHub ==="
# Truy vấn GitHub API của nhà phát triển rplant8 để lấy link bản Linux
LATEST_URL=$(curl -s https://api.github.com/repos/rplant8/rgminer/releases/latest | grep "browser_download_url" | grep -i "linux" | head -n 1 | cut -d '"' -f 4)

if [ -z "$LATEST_URL" ]; then
    echo "Lỗi: Không thể lấy link từ GitHub API. Đang dùng link fallback cố định..."
    LATEST_URL="https://github.com/rplant8/rgminer/releases/download/v1.1.2/rgminer-linux.tar.gz"
fi

echo "Đã tìm thấy link tải từ GitHub: $LATEST_URL"
wget -O rgminer-linux.tar.gz "$LATEST_URL"

echo "=== 3. Giải nén gói cài đặt ==="
tar -xzvf rgminer-linux.tar.gz

echo "=== 4. Khởi chạy vòng lặp đào PRL siêu bền bỉ ==="
set +e

while [ 1 ]; do
    echo "[$(date)] Khởi động rgminer trên siêu card RTX 5090..."
    
    # Chạy trực tiếp qua cổng SSL của khu vực Asia-Pacific
    ./rgminer --algo pearl \
      --stratum asia.rplant.xyz:17168 \
      --address prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4.rtx5090
      
    echo "[$(date)] Miner bị ngắt kết nối hoặc gặp sự cố. Tự động kết nối lại sau 5 giây..."
    sleep 5
done
