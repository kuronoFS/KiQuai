#!/bin/bash
set -e

echo "=== 1. Cập nhật & Cài đặt thư viện nền tảng ==="
apt-get update && apt-get install -y wget tar curl

echo "=== 2. Tự động quét và lấy link Rigel Miner mới nhất ==="
# Lệnh này gọi đến API của GitHub để lấy đúng link "linux.tar.gz" của phiên bản mới nhất hiện tại
LATEST_URL=$(curl -s https://api.github.com/repos/rigelminer/rigel/releases/latest | grep "browser_download_url" | grep "linux.tar.gz" | head -n 1 | cut -d '"' -f 4)

echo "Đã tìm thấy link tải chuẩn: $LATEST_URL"

# Tiến hành tải file với tên cố định để dễ quản lý
wget -O rigel-latest.tar.gz "$LATEST_URL"

echo "=== 3. Giải nén gói cài đặt ==="
tar -xzvf rigel-latest.tar.gz

# Tự động di chuyển vào thư mục vừa giải nén dựa theo tiền tố tên file
cd rigel-*/

echo "=== 4. Khởi chạy Rigel tối ưu riêng cho RTX 5090 ==="
# Mặc định cấu hình chạy ổn định trên Rplant Pool cổng VarDiff
./rigel -a pearlhash \
  -o stratum+tcp://stratum.rplant.xyz:7084 \
  -u prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4 \
  -w rtx5090
