# KiQuai Hashtopolis + Hashcat on Vast.ai

## Mục tiêu

Triển khai Hashtopolis Server + Hashcat trên Vast.ai bằng một file `run.sh` duy nhất.

Thiết kế triển khai:

- Hashcat chạy trực tiếp trong Vast.ai instance để dùng GPU qua NVIDIA runtime của template.
- Hashtopolis chạy bằng Docker Compose thông qua rootless Docker daemon để giảm lỗi nested Docker như `failed to create NAT chain DOCKER`, `operation not permitted`, `unable to setup quota`, hoặc lỗi iptables/cgroup.
- Chỉ expose một port public, mặc định là `8080`, qua Nginx reverse proxy.
- Script fail-fast, tự dump log container khi lỗi, thay vì để container restart loop mà không biết nguyên nhân.

> Chỉ dùng cho password recovery, internal security audit, lab hoặc workload hợp pháp mà bạn có quyền xử lý.

---

## 1. Cấu hình Vast.ai khuyến nghị

Image:

```text
nvidia/cuda:12.9.1-devel-ubuntu24.04
```

Docker options:

```bash
--privileged -p 8080:8080 -e OPEN_BUTTON_PORT=8080 --shm-size=8g
```

Giải thích:

- `--privileged`: cần cho môi trường Vast.ai nested/containerized để rootless Docker và user namespace có khả năng hoạt động ổn định hơn.
- `-p 8080:8080`: expose Hashtopolis UI/proxy.
- `-e OPEN_BUTTON_PORT=8080`: để nút Open của Vast.ai trỏ đúng port.
- `--shm-size=8g`: tăng shared memory cho workload lớn.

---

## 2. One-liner triển khai

Sau khi SSH vào Vast.ai instance, chạy:

```bash
bash -lc "apt-get update && apt-get install -y curl ca-certificates && curl -fsSL https://raw.githubusercontent.com/kuronoFS/KiQuai/refs/heads/main/TestDiD/run.sh -o run.sh && chmod +x run.sh && ./run.sh"
```

Nếu bạn upload file `run.sh` thủ công vào máy, chạy:

```bash
chmod +x run.sh
./run.sh
```

---

## 3. Biến môi trường quan trọng

### Port và URL

```bash
INTERNAL_PORT=8080
PUBLIC_URL="http://PUBLIC_IP:EXTERNAL_PORT"
```

Nếu Vast.ai không tự cung cấp đúng `VAST_TCP_PORT_8080`, hãy override thủ công:

```bash
PUBLIC_URL="http://YOUR_PUBLIC_IP:YOUR_EXTERNAL_PORT" ./run.sh
```

### Reset sạch toàn bộ database và volume

```bash
WIPE_DATA=1 ./run.sh
```

### Không reset data, chỉ recreate container

Mặc định script đã dùng:

```bash
FORCE_RECREATE=1
```

Có thể tắt bằng:

```bash
FORCE_RECREATE=0 ./run.sh
```

### Override image nếu upstream tag thay đổi

```bash
HASHTOPOLIS_BACKEND_IMAGE=hashtopolis/backend:latest \
HASHTOPOLIS_FRONTEND_IMAGE=hashtopolis/frontend:latest \
./run.sh
```

Mặc định script đang dùng:

```text
hashtopolis/backend:v1.0.0-rc1
hashtopolis/frontend:master
mysql:9.7
nginx:alpine
```

---

## 4. Sau khi deploy xong

Script sẽ in ra:

```text
Hashtopolis URL:
  http://PUBLIC_IP:EXTERNAL_PORT

Admin username:
  admin

Admin password:
  RANDOM_PASSWORD

Backend API v2:
  http://PUBLIC_IP:EXTERNAL_PORT/api/v2

Legacy agent API:
  http://PUBLIC_IP:EXTERNAL_PORT/api/server.php
```

Lưu lại password ngay. File `.env` nằm tại:

```bash
/home/kiquai/kiquai-hashtopolis/.env
```

---

## 5. Kiểm tra trạng thái

Nạp Docker socket rootless:

```bash
source /etc/profile.d/kiquai-rootless-docker.sh
```

Xem container:

```bash
cd /home/kiquai/kiquai-hashtopolis
docker compose ps -a
```

Xem log:

```bash
cd /home/kiquai/kiquai-hashtopolis
./kiquai-logs.sh
```

Hoặc log từng service:

```bash
docker compose logs --tail 200 hashtopolis-backend
docker compose logs --tail 200 hashtopolis-frontend
docker compose logs --tail 200 db
docker compose logs --tail 200 hashtopolis-proxy
```

Kiểm tra HTTP local:

```bash
curl -I http://127.0.0.1:8080
curl -I http://127.0.0.1:8080/api/v2
curl -I http://127.0.0.1:8080/api/server.php
```

Kiểm tra GPU:

```bash
nvidia-smi
hashcat -I
```

---

## 6. Troubleshooting nhanh

### Container cứ exit/restart

Chạy:

```bash
source /etc/profile.d/kiquai-rootless-docker.sh
cd /home/kiquai/kiquai-hashtopolis
docker compose ps -a
docker compose logs --tail 300
```

Script mới cũng tự dump diagnostics nếu lỗi xảy ra trong quá trình deploy.

### Port 8080 bị chiếm

Nếu Vast.ai template/Jupyter chiếm port 8080, dùng port khác:

```bash
INTERNAL_PORT=18080 PUBLIC_URL="http://PUBLIC_IP:EXTERNAL_PORT" ./run.sh
```

Vast.ai Docker options cũng phải đổi tương ứng:

```bash
--privileged -p 18080:18080 -e OPEN_BUTTON_PORT=18080 --shm-size=8g
```

### Rootless Docker không chạy được

Nếu gặp lỗi user namespace, phần lớn là provider/template đang chặn. Cách xử lý thực tế:

1. Bảo đảm Docker options có `--privileged`.
2. Đổi sang Vast.ai offer/provider khác.
3. Không dùng nested Docker, chuyển sang VM/bare-metal nếu cần ổn định production.

### URL public sai

Kiểm tra:

```bash
echo "$PUBLIC_IPADDR"
echo "$VAST_TCP_PORT_8080"
```

Nếu rỗng hoặc sai, dùng:

```bash
PUBLIC_URL="http://PUBLIC_IP:EXTERNAL_PORT" ./run.sh
```

---

## 7. Quản trị thường dùng

Restart stack:

```bash
source /etc/profile.d/kiquai-rootless-docker.sh
cd /home/kiquai/kiquai-hashtopolis
docker compose restart
```

Stop stack:

```bash
source /etc/profile.d/kiquai-rootless-docker.sh
cd /home/kiquai/kiquai-hashtopolis
docker compose down
```

Start lại:

```bash
source /etc/profile.d/kiquai-rootless-docker.sh
cd /home/kiquai/kiquai-hashtopolis
docker compose up -d
```

Xóa sạch và deploy lại:

```bash
WIPE_DATA=1 ./run.sh
```

---

## 8. Agent Hashtopolis

Server đã expose legacy agent API tại:

```text
http://PUBLIC_IP:EXTERNAL_PORT/api/server.php
```

Luồng dùng agent:

1. Mở Hashtopolis UI.
2. Tạo voucher agent.
3. Chạy Hashtopolis Python Agent trực tiếp trên Vast.ai instance.
4. Agent gọi `hashcat` trực tiếp trên máy, nơi GPU đã được expose.

Không nên chạy cracking agent bên trong container backend/frontend. Backend/frontend chỉ là server/API/UI.
