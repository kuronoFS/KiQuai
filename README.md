# Pearl (PRL) Modular Mining Script

Script đào Pearl (PRL) dạng modular — dễ cấu hình, hỗ trợ GPU, CPU, hoặc cả hai đồng thời.

## Cấu trúc

```
├── config.env   ← Cấu hình tập trung (chỉnh sửa file này)
├── run.sh       ← Script chính (không cần sửa)
└── README.md    ← Tài liệu hướng dẫn
```

## Bắt đầu nhanh

### 1. Cấu hình
Mở `config.env` và chỉnh sửa các tham số:

```bash
# Chọn chế độ đào
MINING_MODE="gpu"          # gpu | cpu | dual

# Địa chỉ ví PRL
WALLET="prl1..."

# Tên worker
WORKER_NAME="rig01"
```

### 2. Chạy

```bash
chmod +x run.sh
sudo ./run.sh
```

## Chế độ đào

| Chế độ | Mô tả | Miner sử dụng |
|--------|--------|----------------|
| `gpu`  | Chỉ đào bằng GPU (NVIDIA CUDA) | rgminer |
| `cpu`  | Chỉ đào bằng CPU | bzminer (beta) |
| `dual` | Đào đồng thời GPU + CPU | rgminer + bzminer |

## Cấu hình chi tiết (`config.env`)

### GPU (rgminer)
| Tham số | Mô tả | Mặc định |
|---------|--------|----------|
| `GPU_ALGO` | Thuật toán | `pearl` |
| `GPU_POOL` | Địa chỉ pool | `asia.rplant.xyz:17168` |
| `GPU_PEARL_BATCH` | Batch size (để trống = mặc định) | `""` |

### CPU (bzminer)
| Tham số | Mô tả | Mặc định |
|---------|--------|----------|
| `CPU_ALGO` | Thuật toán | `pearl` |
| `CPU_POOL` | Địa chỉ pool | `stratum+tcp://pearl-asia1.luckypool.io:3360` |
| `CPU_THREADS` | Số luồng (`"auto"` = tự phát hiện) | `"auto"` |
| `CPU_THREADS_CACHE_GROUP` | Cache group cho bzminer | `3` |

### Khởi động lại
| Tham số | Mô tả | Mặc định |
|---------|--------|----------|
| `RESTART_DELAY` | Giây chờ trước khi restart | `5` |
| `MAX_RETRIES` | Số lần thử tối đa (0 = vô hạn) | `0` |

## Lưu ý quan trọng

- **GPU mining (rgminer)**: Chỉ hỗ trợ NVIDIA GPU với CUDA. RTX 30/40/50 series hoạt động tốt nhất.
- **CPU mining (bzminer)**: Đang ở giai đoạn beta. Hiệu suất thấp hơn GPU rất nhiều. Cần CPU hỗ trợ AVX512 để đạt hiệu quả tốt nhất.
- **Chế độ dual**: Có thể chạy đồng thời cả GPU và CPU. Mỗi miner chạy như một tiến trình riêng biệt. Nhấn `Ctrl+C` để dừng cả hai.
- Script tự động tải phiên bản miner mới nhất từ GitHub mỗi lần chạy.

## Pools gợi ý

| Pool | Địa chỉ | Ghi chú |
|------|---------|---------|
| rplant (Asia) | `asia.rplant.xyz:17168` | GPU |
| LuckyPool (Asia) | `stratum+tcp://pearl-asia1.luckypool.io:3360` | CPU + GPU |
| AkoyaPool | `pool.akoyapool.com:3333` | GPU |
| AlphaPool | `pearl.alphapool.tech` | GPU + AMD |
