#!/bin/bash
set -e

echo "=== 1. Cập nhật & Cài đặt thư viện (Bổ sung ca-certificates) ==="
# Cài đặt thêm ca-certificates để thông suốt các kết nối bảo mật nội bộ của Miner
apt-get update && apt-get install -y wget tar libcurl4 libssl-dev ocl-icd-libopencl1 ca-certificates

echo "=== 2. Tải WildRig-Multi v0.48.3 bản chuẩn ==="
wget -O wildrig-multi-linux-0.48.3.tar.gz https://github.com/andru-kun/wildrig-multi/releases/download/0.48.3/wildrig-multi-linux-0.48.3.tar.gz

echo "=== 3. Giải nén gói cài đặt ==="
tar -xzvf wildrig-multi-linux-0.48.3.tar.gz
rm wildrig-multi-linux-0.48.3.tar.gz
chmod +x wildrig-multi

echo "=== 4. Khởi chạy đào PRL với cấu hình Stratum chuẩn hóa ==="
# - Tách biệt rõ ràng --user và --worker để Pool không bẻ gãy kết nối
# - Bổ sung --pass x để hoàn thiện gói tin handshake gửi tới Luckypool
./wildrig-multi --algo pearlhash \
  --url stratum+tcp://stratum.rplant.xyz:7084 \
  --user prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4.rtx5090 \
  --pass x
