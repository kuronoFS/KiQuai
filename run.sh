#!/bin/bash
# Ngừng chạy ngay lập tức nếu có bất kỳ lệnh nào phía dưới bị lỗi (Giúp lộ lỗi wget/tar nếu có)
set -e

# 1. Cập nhật và cài đặt công cụ giải nén xz
apt-get update && apt-get install -y wget xz-utils

echo "=== 2. Đang tải WildRig-Multi v0.48.3 ==="
# Ép tên file tải về cố định là wildrig.tar.xz để dễ quản lý
wget -O wildrig.tar.xz https://github.com/andru-kun/wildrig-multi/releases/download/0.48.3/wildrig-multi-linux-0.48.3.tar.xz

echo "=== 3. Đang giải nén vào thư mục riêng ==="
mkdir -p wildrig_extracted
tar -xvf wildrig.tar.xz -C wildrig_extracted
rm wildrig.tar.xz

echo "=== 4. Kiểm tra cấu trúc file đã giải nén (In ra Log) ==="
ls -la wildrig_extracted

# Di chuyển vào thư mục vừa giải nén
cd wildrig_extracted

# 5. Tự động tìm kiếm file thực thi 'wildrig-multi' bất kể nó nằm ở thư mục con nào
BINARY_PATH=$(find . -type f -name "wildrig-multi" | head -n 1)

if [ -z "$BINARY_PATH" ]; then
    echo "LỖI CRITICAL: Không tìm thấy file thực thi wildrig-multi trong gói giải nén!"
    exit 1
fi

# Cấp quyền thực thi cho file vừa tìm được
chmod +x "$BINARY_PATH"

echo "=== 6. Khởi chạy Miner tối ưu cho RTX 5090 từ: $BINARY_PATH ==="
# Sử dụng 'exec' để đưa tiến trình Miner làm tiến trình chính (PID 1) của Docker, giúp quản lý CPU/GPU tốt hơn
exec "$BINARY_PATH" --algo pearlhash --url pearl-sg1.luckypool.io:3360 --user prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4 --worker rtx5090
