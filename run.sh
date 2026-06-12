#!/bin/bash
set -e

echo "=== 1. Cài đặt thư viện ==="
apt-get update && apt-get install -y wget tar

echo "=== 2. Tải và giải nén Rigel Miner ==="
wget https://github.com/rigelminer/rigel/releases/download/v1.19.0/rigel-v1.19.0-linux.tar.gz
tar -xzvf rigel-v1.19.0-linux.tar.gz
cd rigel-v1.19.0

echo "=== 3. Khởi chạy Rigel tối ưu riêng cho NVIDIA ==="
# Rigel sử dụng định danh thuật toán là 'pearlhash'
./rigel -a pearlhash \
  -o stratum+tcp://stratum.rplant.xyz:7084 \
  -u prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4 \
  -w rtx5090
