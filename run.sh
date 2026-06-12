#!/bin/bash
set -e

echo "=== 1. Cập nhật & Cài đặt thư viện nền tảng ==="
apt-get update && apt-get install -y wget tar curl

echo "=== 2. Tự động quét và lấy link Rigel Miner mới nhất ==="
LATEST_URL=$(curl -s https://api.github.com/repos/rigelminer/rigel/releases/latest | grep "browser_download_url" | grep "linux.tar.gz" | head -n 1 | cut -d '"' -f 4)
wget -O rigel-latest.tar.gz "$LATEST_URL"

echo "=== 3. Giải nén gói cài đặt ==="
tar -xzvf rigel-latest.tar.gz
cd rigel-*/

echo "=== 4. Khởi chạy Rigel tối ưu riêng cho RTX 5090 ==="
# SỬA LỖI: Đổi 'pearlhash' thành 'pearl' để khớp với định dạng của Rigel và Rplant
./rigel -a pearl \
  -o stratum+tcp://stratum.rplant.xyz:7084 \
  -u prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4 \
  -w rtx5090
