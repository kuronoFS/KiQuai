#!/bin/bash
# Dừng script ngay lập tức nếu có bất kỳ lệnh nào bị lỗi
set -e

echo "=== 1. Cập nhật hệ thống & Cài đặt thư viện nền tảng ==="
apt-get update && apt-get install -y wget tar libcurl4 libssl-dev

echo "=== 2. Tải WildRig-Multi v0.48.3 (Định dạng chuẩn .tar.gz) ==="
VALID_URL="https://github.com/andru-kun/wildrig-multi/releases/download/0.48.3/wildrig-multi-linux-0.48.3.tar.gz"
wget -O wildrig-multi.tar.gz "$VALID_URL"

echo "=== 3. Tạo thư mục làm việc và giải nén ==="
mkdir -p /opt/wildrig_miner
tar -xvf wildrig-multi.tar.gz -C /opt/wildrig_miner
rm wildrig-multi.tar.gz

cd /opt/wildrig_miner

echo "=== 4. Định vị file thực thi và cấp quyền ==="
# Tự động tìm file thực thi chính xác trong thư mục giải nén
BINARY_PATH=$(find . -type f -name "wildrig-multi" | head -n 1)

if [ -z "$BINARY_PATH" ]; then
    echo "LỖI: Không tìm thấy file chạy wildrig-multi!"
    exit 1
fi

chmod +x "$BINARY_PATH"

echo "=== 5. Khởi chạy đào PRL tối ưu cho RTX 5090 ==="
# Định dạng ví theo chuẩn wallet.worker tối ưu cho kết nối stratum
# Lưu ý: Bạn có thể thêm tham số '--pearlhash-kernel 2' nếu muốn thử nghiệm kernel cũ xem cái nào hash cao hơn trên RTX 5090 của bạn.
exec "$BINARY_PATH" --algo pearlhash \
    --url pearl-sg1.luckypool.io:3360 \
    --user prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4.rtx5090
