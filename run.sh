#!/bin/bash
set -e

echo "=== 1. Cài đặt các thư viện nền tảng trong Docker ==="
apt-get update && apt-get install -y wget tar curl

echo "=== 2. Tự động quét và lấy link rgminer từ Printscan GitHub ==="
# Truy vấn API GitHub chính thức để lấy bản phát hành Linux (.tar.gz) mới nhất, loại bỏ bản mmpos
LATEST_URL=$(curl -s https://api.github.com/repos/Printscan/rgminer/releases/latest | grep "browser_download_url" | grep ".tar.gz" | grep -v -i "mmpos" | head -n 1 | cut -d '"' -f 4)

if [ -z "$LATEST_URL" ]; then
    echo "Lỗi: Không thể gọi GitHub API. Đang dùng link cấu hình dự phòng..."
    LATEST_URL="https://github.com/Printscan/rgminer/releases/download/v0.9.4/rgminer-0.9.4.tar.gz"
fi

echo "Đã tìm thấy link tải chuẩn: $LATEST_URL"
wget -O rgminer-latest.tar.gz "$LATEST_URL"

echo "=== 3. Giải nén và cấu hình quyền thực thi ==="
tar -xzvf rgminer-latest.tar.gz

# Định vị chính xác file chạy rgminer bất kể cấu trúc thư mục sau giải nén
MINER_EXEC=$(find . -type f -name "rgminer" | head -n 1)
chmod +x "$MINER_EXEC"

echo "=== 4. Khởi chạy vòng lặp đào PRL siêu bền bỉ ==="
set +e
while [ 1 ]; do
    echo "[$(date)] Kích hoạt sức mạnh Tensor-Core trên RTX 5090..."
    
    # Cấu hình tham số theo chuẩn tài liệu hướng dẫn của Printscan GitHub
    "$MINER_EXEC" --algo pearl \
      --stratum asia.rplant.xyz:17168 \
      --wallet prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4 \
      --worker-name rtx5090
      
    echo "[$(date)] Miner bị ngắt kết nối hoặc crash. Tự động kết nối lại sau 5 giây..."
    sleep 5
done
