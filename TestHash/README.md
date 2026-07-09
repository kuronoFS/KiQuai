# KiQuai Hashtopolis + Hashcat Bootstrap for Vast.ai

Triển khai tự động **Hashtopolis Server + Hashcat** trên máy GPU thuê từ **Vast.ai** chỉ bằng một lệnh `run.sh`.

Mục tiêu của project này là tạo một bootstrap script có thể chạy trực tiếp trong Vast.ai instance để:

* Cài các package hệ thống cần thiết.
* Kiểm tra GPU bằng `nvidia-smi`.
* Cài `hashcat` trong chính Vast.ai instance.
* Cài và khởi động Docker daemon bên trong instance.
* Dựng Hashtopolis stack bằng Docker Compose.
* Tự động cấu hình URL public dựa trên biến môi trường của Vast.ai.
* In ra URL truy cập giao diện Hashtopolis sau khi triển khai xong.

> Chỉ sử dụng hệ thống này cho password recovery, security audit hoặc kiểm thử bảo mật khi có quyền hợp pháp. Không sử dụng cho hành vi truy cập trái phép.

---

## 1. Kiến trúc tổng quan

Trên Vast.ai, instance mà bạn thuê thường đã chạy bên trong một Docker container do provider khởi tạo. Vì vậy project này không tạo thêm một “root container” nữa. Thay vào đó, chính Vast.ai instance được dùng làm lớp root.

```text
Vast.ai GPU instance
├── NVIDIA GPU access
├── nvidia-smi
├── hashcat
├── Docker daemon chạy bên trong instance
│   ├── hashtopolis-db
│   ├── hashtopolis-backend
│   ├── hashtopolis-frontend
│   └── hashtopolis-proxy
└── Public access qua Vast.ai port mapping
```

Thiết kế này ít lớp hơn so với mô hình:

```text
Vast.ai instance
└── root container
    └── Docker-in-Docker
        └── Hashtopolis containers
```

Lý do chọn thiết kế hiện tại:

* Tránh Docker-in-Docker lồng quá nhiều tầng.
* Giảm lỗi liên quan đến cgroup, mount, network và GPU runtime.
* Hashcat chạy trực tiếp trong instance nên dễ kiểm tra GPU hơn.
* Hashtopolis server stack vẫn được quản lý sạch bằng Docker Compose.
* Phù hợp với mô hình port mapping của Vast.ai.

---

## 2. Thành phần được triển khai

Script sẽ tạo Hashtopolis stack gồm:

```text
hashtopolis-db         MariaDB database
hashtopolis-backend    Hashtopolis backend API
hashtopolis-frontend   Hashtopolis frontend UI
hashtopolis-proxy      Nginx reverse proxy
```

Port nội bộ mặc định:

```text
8080
```

Public URL sẽ được script tự tính theo môi trường Vast.ai:

```text
http://PUBLIC_IPADDR:VAST_TCP_PORT_8080
```

Nếu không phát hiện được biến `VAST_TCP_PORT_8080`, script sẽ fallback về:

```text
http://PUBLIC_IPADDR:8080
```

---

## 3. Yêu cầu trước khi chạy

### 3.1. Yêu cầu Vast.ai instance

Nên chọn instance có:

* NVIDIA GPU.
* CUDA image.
* Dung lượng disk đủ lớn.
* Internet access.
* Docker options cho phép privileged mode.
* Port `8080` được expose.

Khuyến nghị image:

```text
nvidia/cuda:12.6.0-devel-ubuntu24.04
```

Hoặc image CUDA Ubuntu mới hơn nếu host Vast.ai hỗ trợ tốt.

Ví dụ:

```text
nvidia/cuda:12.9.1-devel-ubuntu24.04
```

### 3.2. Docker options trên Vast.ai

Trong Vast.ai template hoặc launch configuration, thêm Docker options:

```bash
--privileged -p 8080:8080 -e OPEN_BUTTON_PORT=8080 --shm-size=8g
```

Ý nghĩa:

```text
--privileged
  Cho phép chạy Docker daemon bên trong Vast.ai instance.

-p 8080:8080
  Expose Hashtopolis proxy port từ instance.

-e OPEN_BUTTON_PORT=8080
  Cho Vast.ai biết port nào nên được dùng cho nút Open.

--shm-size=8g
  Tăng shared memory, hữu ích cho workload lớn.
```

Nếu không có `--privileged`, Docker daemon bên trong instance có thể không khởi động được.

---

## 4. Cấu trúc repo đề xuất

```text
KiQuai/
└── TestDiD/
    ├── run.sh
    └── README.md
```

File chính:

```text
TestDiD/run.sh
```

URL raw GitHub dự kiến:

```text
https://raw.githubusercontent.com/kuronoFS/KiQuai/refs/heads/main/TestDiD/run.sh
```

---

## 5. Cách triển khai nhanh

SSH vào Vast.ai instance hoặc dùng on-start script, chạy một dòng:

```bash
bash -lc "apt-get update && apt-get install -y curl ca-certificates && curl -fsSL https://raw.githubusercontent.com/kuronoFS/KiQuai/refs/heads/main/TestDiD/run.sh | bash"
```

Sau khi chạy xong, script sẽ in ra thông tin dạng:

```text
============================================================
Hashtopolis URL:
  http://PUBLIC_IP:EXTERNAL_PORT

Admin username:
  admin

Admin password:
  RANDOM_GENERATED_PASSWORD

Backend API v2:
  http://PUBLIC_IP:EXTERNAL_PORT/api/v2

Legacy agent API:
  http://PUBLIC_IP:EXTERNAL_PORT/api/server.php

Check GPU:
  nvidia-smi
  hashcat -I

Check containers:
  docker compose -f /opt/kiquai-hashtopolis/docker-compose.yml ps
============================================================
```

Truy cập giao diện Hashtopolis bằng URL được in ra.

Ví dụ:

```text
http://65.130.162.74:33526
```

Không nên mặc định truy cập:

```text
http://65.130.162.74:8080
```

Vì trên Vast.ai, external port có thể khác internal port `8080`.

---

## 6. Biến môi trường hỗ trợ

Có thể tùy chỉnh triển khai bằng cách truyền biến môi trường trước lệnh `bash`.

### 6.1. Biến hệ thống

| Biến            |                  Mặc định | Ý nghĩa                             |
| --------------- | ------------------------: | ----------------------------------- |
| `APP_DIR`       | `/opt/kiquai-hashtopolis` | Thư mục chứa Compose stack và data  |
| `INTERNAL_PORT` |                    `8080` | Port nội bộ của Hashtopolis proxy   |
| `PUBLIC_URL`    |         Tự động phát hiện | URL public custom nếu muốn override |

### 6.2. Biến database

| Biến              |      Mặc định | Ý nghĩa                   |
| ----------------- | ------------: | ------------------------- |
| `MYSQL_ROOT_PASS` |        Random | Root password cho MariaDB |
| `MYSQL_DATABASE`  | `hashtopolis` | Tên database              |
| `MYSQL_USER`      | `hashtopolis` | User database             |
| `MYSQL_PASSWORD`  |        Random | Password database         |

### 6.3. Biến Hashtopolis

| Biến                         | Mặc định | Ý nghĩa                 |
| ---------------------------- | -------: | ----------------------- |
| `HASHTOPOLIS_ADMIN_USER`     |  `admin` | Tài khoản admin ban đầu |
| `HASHTOPOLIS_ADMIN_PASSWORD` |   Random | Password admin ban đầu  |

---

## 7. Ví dụ chạy với password tự đặt

```bash
HASHTOPOLIS_ADMIN_USER="admin" \
HASHTOPOLIS_ADMIN_PASSWORD="ChangeMe_StrongPassword_123" \
MYSQL_ROOT_PASS="ChangeMe_DBRoot_123" \
MYSQL_PASSWORD="ChangeMe_DBUser_123" \
bash -lc "apt-get update && apt-get install -y curl ca-certificates && curl -fsSL https://raw.githubusercontent.com/kuronoFS/KiQuai/refs/heads/main/TestDiD/run.sh | bash"
```

Không khuyến nghị commit password thật vào GitHub.

---

## 8. Ví dụ chạy với URL public override

Nếu Vast.ai port mapping không được phát hiện đúng, có thể tự đặt `PUBLIC_URL`:

```bash
PUBLIC_URL="http://YOUR_PUBLIC_IP:YOUR_EXTERNAL_PORT" \
bash -lc "apt-get update && apt-get install -y curl ca-certificates && curl -fsSL https://raw.githubusercontent.com/kuronoFS/KiQuai/refs/heads/main/TestDiD/run.sh | bash"
```

Ví dụ:

```bash
PUBLIC_URL="http://65.130.162.74:33526" \
bash -lc "apt-get update && apt-get install -y curl ca-certificates && curl -fsSL https://raw.githubusercontent.com/kuronoFS/KiQuai/refs/heads/main/TestDiD/run.sh | bash"
```

---

## 9. Cách kiểm tra sau khi triển khai

### 9.1. Kiểm tra GPU

```bash
nvidia-smi
```

Kiểm tra Hashcat thấy GPU:

```bash
hashcat -I
```

Nếu `hashcat -I` không thấy GPU, cần kiểm tra:

```bash
nvidia-smi
clinfo
ls -lah /dev/nvidia*
```

### 9.2. Kiểm tra Docker daemon

```bash
docker version
docker info
```

### 9.3. Kiểm tra container Hashtopolis

```bash
docker ps
```

Hoặc:

```bash
docker compose -f /opt/kiquai-hashtopolis/docker-compose.yml ps
```

Kết quả mong muốn:

```text
hashtopolis-db          running
hashtopolis-backend     running
hashtopolis-frontend    running
hashtopolis-proxy       running
```

### 9.4. Kiểm tra HTTP local

```bash
curl -I http://127.0.0.1:8080
```

Kiểm tra backend API v2:

```bash
curl -I http://127.0.0.1:8080/api/v2
```

Kiểm tra legacy agent API:

```bash
curl -I http://127.0.0.1:8080/api/server.php
```

---

## 10. Cách lấy URL public trên Vast.ai

Kiểm tra biến môi trường:

```bash
echo "$PUBLIC_IPADDR"
echo "$VAST_TCP_PORT_8080"
```

In URL:

```bash
echo "http://${PUBLIC_IPADDR}:${VAST_TCP_PORT_8080}"
```

Nếu `VAST_TCP_PORT_8080` rỗng, xem trong Vast.ai UI:

```text
Instance → IP Port Info
```

Tìm dòng tương tự:

```text
PUBLIC_IP:EXTERNAL_PORT -> 8080/tcp
```

Sau đó truy cập:

```text
http://PUBLIC_IP:EXTERNAL_PORT
```

---

## 11. Log và troubleshooting

### 11.1. Xem log tổng quan

```bash
docker ps
```

```bash
docker logs hashtopolis-db
docker logs hashtopolis-backend
docker logs hashtopolis-frontend
docker logs hashtopolis-proxy
```

### 11.2. Xem log Docker daemon bên trong Vast instance

```bash
cat /var/log/dockerd.log
```

### 11.3. Restart Hashtopolis stack

```bash
cd /opt/kiquai-hashtopolis
docker compose down
docker compose up -d
```

### 11.4. Pull image mới nhất và recreate

```bash
cd /opt/kiquai-hashtopolis
docker compose pull
docker compose up -d
```

### 11.5. Xóa toàn bộ stack nhưng giữ data

```bash
cd /opt/kiquai-hashtopolis
docker compose down
```

### 11.6. Xóa toàn bộ stack và data

Cẩn thận: lệnh này xóa database và dữ liệu Hashtopolis.

```bash
rm -rf /opt/kiquai-hashtopolis
```

Sau đó chạy lại one-liner.

---

## 12. Lỗi thường gặp

### Lỗi 1: Không vào được giao diện Hashtopolis

Kiểm tra container proxy:

```bash
docker logs hashtopolis-proxy
docker ps
```

Kiểm tra local port:

```bash
curl -I http://127.0.0.1:8080
```

Kiểm tra public port trên Vast.ai:

```bash
echo "$PUBLIC_IPADDR"
echo "$VAST_TCP_PORT_8080"
```

Nếu local truy cập được nhưng public không truy cập được, lỗi thường nằm ở Vast.ai port mapping hoặc Docker options chưa có:

```bash
-p 8080:8080 -e OPEN_BUTTON_PORT=8080
```

---

### Lỗi 2: Docker daemon không start

Xem log:

```bash
cat /var/log/dockerd.log
```

Nguyên nhân thường gặp:

* Vast.ai instance không chạy với `--privileged`.
* Image không tương thích.
* Thiếu kernel capability cần thiết cho Docker-in-Docker.
* Storage driver `overlay2` không hoạt động trong môi trường hiện tại.

Cách xử lý:

1. Đảm bảo Docker options có:

```bash
--privileged
```

2. Nếu vẫn lỗi, thử đổi image CUDA Ubuntu khác.

---

### Lỗi 3: `nvidia-smi` không hoạt động

Kiểm tra:

```bash
ls -lah /dev/nvidia*
```

```bash
nvidia-smi
```

Nếu không có `/dev/nvidia*`, instance chưa được cấp GPU đúng cách hoặc image/template không được cấu hình GPU passthrough.

Cách xử lý:

* Chọn lại Vast.ai offer có GPU.
* Dùng CUDA image chính thức.
* Kiểm tra template có bật GPU access.
* Kiểm tra provider có hỗ trợ Docker options cần thiết hay không.

---

### Lỗi 4: `hashcat -I` không thấy GPU

Kiểm tra:

```bash
nvidia-smi
hashcat -I
clinfo
```

Nếu `nvidia-smi` thấy GPU nhưng `hashcat -I` không thấy backend phù hợp, có thể thiếu OpenCL runtime hoặc package trong image không phù hợp.

Thử cài lại package liên quan:

```bash
apt-get update
apt-get install -y ocl-icd-libopencl1 clinfo hashcat
```

Sau đó kiểm tra lại:

```bash
hashcat -I
```

---

### Lỗi 5: Backend không kết nối được database

Kiểm tra database:

```bash
docker logs hashtopolis-db
```

Kiểm tra backend:

```bash
docker logs hashtopolis-backend
```

Kiểm tra container status:

```bash
docker compose -f /opt/kiquai-hashtopolis/docker-compose.yml ps
```

Nếu database chưa healthy, backend có thể cần thêm thời gian để khởi động.

---

### Lỗi 6: Frontend gọi sai backend URL

Kiểm tra file `.env`:

```bash
cat /opt/kiquai-hashtopolis/.env
```

Dòng quan trọng:

```text
HASHTOPOLIS_BACKEND_URL=http://PUBLIC_IP:EXTERNAL_PORT/api/v2
```

Nếu URL sai, sửa lại:

```bash
nano /opt/kiquai-hashtopolis/.env
```

Sau đó recreate frontend/backend:

```bash
cd /opt/kiquai-hashtopolis
docker compose up -d --force-recreate
```

---

## 13. Bảo mật vận hành

### 13.1. Không dùng password mặc định

Script tự sinh password random nếu không truyền biến môi trường. Sau khi chạy xong, password admin sẽ được in ra terminal.

Nên lưu password ngay sau khi deploy.

### 13.2. Không public lâu dài nếu chưa có bảo vệ

Hashtopolis không nên expose public Internet lâu dài nếu chưa có:

* Password mạnh.
* Firewall.
* Reverse proxy có TLS.
* IP allowlist nếu có thể.
* Backup database.
* Monitoring log.

### 13.3. Không lưu secret trong GitHub

Không commit:

```text
.env
hash_db/
hash_data/
```

Nên thêm `.gitignore`:

```gitignore
.env
hash_db/
hash_data/
*.log
```

### 13.4. Cẩn trọng với `--privileged`

Deployment này cần `--privileged` để chạy Docker daemon bên trong Vast.ai instance. Đây là quyền rất mạnh. Chỉ chạy script từ repo bạn kiểm soát.

Không chạy script lạ bằng:

```bash
curl URL | bash
```

trừ khi bạn đã đọc và hiểu toàn bộ nội dung script.

---

## 14. Gợi ý production hardening

Nếu dùng lâu dài, nên bổ sung:

* Pin image version thay vì dùng `latest`.
* Pin GitHub script bằng commit SHA thay vì branch `main`.
* Bật HTTPS bằng Caddy, Traefik hoặc Nginx + cert.
* Giới hạn IP truy cập Hashtopolis.
* Tách database volume ra persistent disk nếu Vast.ai offer hỗ trợ.
* Log rotation cho Docker.
* Backup định kỳ thư mục `/opt/kiquai-hashtopolis`.
* Không chạy workload không tin cậy trong cùng instance.

Ví dụ pin script bằng commit SHA:

```bash
curl -fsSL https://raw.githubusercontent.com/kuronoFS/KiQuai/<COMMIT_SHA>/TestDiD/run.sh | bash
```

---

## 15. Các lệnh quản trị nhanh

### Xem tất cả container

```bash
docker ps -a
```

### Vào container backend

```bash
docker exec -it hashtopolis-backend sh
```

### Vào container database

```bash
docker exec -it hashtopolis-db bash
```

### Restart proxy

```bash
docker restart hashtopolis-proxy
```

### Restart toàn bộ stack

```bash
cd /opt/kiquai-hashtopolis
docker compose restart
```

### Stop toàn bộ stack

```bash
cd /opt/kiquai-hashtopolis
docker compose down
```

### Start lại stack

```bash
cd /opt/kiquai-hashtopolis
docker compose up -d
```

---

## 16. Kiểm tra file được tạo bởi script

Sau khi chạy thành công:

```bash
ls -lah /opt/kiquai-hashtopolis
```

Kỳ vọng có:

```text
.env
docker-compose.yml
nginx.conf
hash_db/
hash_data/
```

Xem Compose file:

```bash
cat /opt/kiquai-hashtopolis/docker-compose.yml
```

Xem Nginx config:

```bash
cat /opt/kiquai-hashtopolis/nginx.conf
```

---

## 17. Luồng triển khai chuẩn

Quy trình khuyến nghị:

```text
1. Tạo Vast.ai instance bằng CUDA Ubuntu image.
2. Thêm Docker options:
   --privileged -p 8080:8080 -e OPEN_BUTTON_PORT=8080 --shm-size=8g

3. Chạy one-liner:
   curl raw run.sh | bash

4. Đọc URL và admin password do script in ra.

5. Mở Hashtopolis UI bằng:
   http://PUBLIC_IP:EXTERNAL_PORT

6. Kiểm tra GPU:
   nvidia-smi
   hashcat -I

7. Kiểm tra stack:
   docker ps
```

---

## 18. Ghi chú về Hashtopolis Agent

Script này dựng Hashtopolis server và cài Hashcat trong Vast.ai instance.

Để dùng Hashtopolis đúng mô hình distributed cracking, bạn cần đăng ký Hashtopolis Agent trỏ về API server của Hashtopolis.

Legacy agent API thường có dạng:

```text
http://PUBLIC_IP:EXTERNAL_PORT/api/server.php
```

Luồng cơ bản:

```text
1. Vào Hashtopolis UI.
2. Tạo agent voucher.
3. Tải hoặc cấu hình Hashtopolis Python Agent.
4. Chạy agent trên cùng Vast.ai instance.
5. Agent gọi hashcat để xử lý task.
```

Khuyến nghị: để agent chạy trực tiếp trong Vast.ai instance, cùng nơi có `hashcat` và GPU. Không nên chạy agent trong container backend/frontend, vì backend/frontend chỉ là server web/API.

---

## 19. Disclaimer

Project này chỉ cung cấp automation triển khai môi trường Hashtopolis + Hashcat cho mục đích hợp pháp như:

* Password recovery cho hệ thống của chính bạn.
* Internal security audit.
* Lab nghiên cứu bảo mật.
* Benchmark GPU được phép.

Không sử dụng để tấn công, truy cập trái phép hoặc xử lý dữ liệu không thuộc quyền kiểm soát của bạn.
