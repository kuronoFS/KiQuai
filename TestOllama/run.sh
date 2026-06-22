#!/bin/bash
set -e

echo "=== 1. Cập nhật hệ thống và cài đặt thư viện cơ bản ==="
apt-get update && apt-get install -y curl ca-certificates

# Kiểm tra xem tài nguyên GPU có được nhận diện không (Tùy chọn để debug)
echo "=== 2. Kiểm tra môi trường NVIDIA CUDA ==="
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi
else
    echo "Cảnh báo: Không tìm thấy nvidia-smi. Hãy chắc chắn bạn đã cài NVIDIA Container Toolkit trên máy host."
fi

echo "=== 3. Kiểm tra và cài đặt Ollama ==="
if ! command -v ollama &> /dev/null; then
    echo "Đang tải và cài đặt Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
else
    echo "Ollama đã được cài đặt trước đó."
fi

# THÀNH PHẦN QUAN TRỌNG: Ép Ollama lắng nghe trên tất cả các IP (0.0.0.0) thay vì localhost (127.0.0.1)
# Điều này cho phép Nginx Proxy Manager đứng từ ngoài forward traffic vào trong container.
export OLLAMA_HOST=0.0.0.0:11434

# (Tùy chọn thêm) Nếu bạn muốn tự động pull sẵn một model nào đó khi container khởi chạy:
# echo "=== Đang tự động kéo model mẫu (ví dụ: qwen2.5:7b) ==="
# ollama serve & 
# sleep 5
# ollama pull qwen2.5:7b
# pkill ollama

echo "=== 4. Khởi chạy Ollama Server ==="
# Dùng 'exec' để Ollama chạy dưới dạng PID 1, giúp container nhận lệnh stop/restart chuẩn xác
exec ollama serve
