# KiQuai Hashtopolis + Hashcat trên Vast.ai

`run.sh` triển khai toàn bộ stack trực tiếp trong **một CUDA container gốc của Vast.ai**. Script không cài Docker Engine, không khởi động `dockerd`, không dùng Docker Compose, không tạo nested container, bridge network hay `socat`.

Các process MySQL, Apache/PHP, Nginx và Hashtopolis Python Agent được quản lý bởi một `supervisord` riêng. Hashcat chạy trực tiếp trong cùng container để sử dụng GPU NVIDIA do Vast.ai gắn vào container đó.

> Chỉ sử dụng Hashtopolis và Hashcat cho hệ thống, dữ liệu và bài kiểm tra mà bạn được phép thực hiện.

## Kiến trúc

```mermaid
flowchart TD
    User["Browser / remote agent"] --> Vast["Vast.ai public port"]
    Vast --> Nginx["Nginx :8080"]
    Nginx --> Frontend["Angular frontend (static)"]
    Nginx --> Backend["Apache + PHP :18080"]
    Backend --> DB["MySQL :13306"]
    LocalAgent["Python agent"] --> Backend
    LocalAgent --> Hashcat["Hashcat → NVIDIA GPU"]
```

Tất cả node trong sơ đồ đều là process hoặc file nằm trong cùng outer container:

| Component | Bind mặc định | Public |
|---|---|---|
| Nginx + frontend | `0.0.0.0:8080` | Có, thông qua port mapping của Vast.ai |
| Apache/PHP backend | `127.0.0.1:18080` | Không; chỉ đi qua Nginx |
| MySQL | `127.0.0.1:13306` | Không |
| Python agent | Không mở port | Không |
| Hashcat | Không phải daemon | Không |

`supervisord` dùng socket riêng trong `APP_DIR/run/`; nó không thay thế supervisor hoặc entrypoint do image/Vast.ai cung cấp.

## Trạng thái hỗ trợ upstream

Hashtopolis chính thức khuyến nghị Docker từ phiên bản 0.14.0. Hướng dẫn cài trực tiếp không Docker vẫn tồn tại nhưng được upstream ghi rõ là **không được hỗ trợ chính thức**:

- [Hashtopolis basic installation](https://docs.hashtopolis.org/installation_guidelines/basic_install/)
- [Hashtopolis install without Docker](https://github.com/hashtopolis/server/wiki/Install-without-Docker)

Script này cố ý sử dụng phương thức native để tránh DinD trong môi trường Vast.ai. Nó bám theo dependency và startup flow trong Dockerfile/entrypoint chính thức: PHP extensions, Composer, `sqlx` migration CLI, thư mục dữ liệu, `setup.php`, frontend build và runtime config.

Phiên bản mặc định:

| Component | Phiên bản |
|---|---|
| Hashtopolis backend | `v1.0.0-rc2` |
| Hashtopolis frontend | `v1.0.0-rc2` |
| Python agent | Bản do backend cung cấp tại `agents.php?download=1` |
| Node.js | Đọc chính xác từ `.nvmrc` của frontend tag |
| PHP, MySQL, Nginx, Apache, Hashcat | Package của Ubuntu 24.04 |

Backend và frontend phải dùng tag tương thích. `v1.0.0-rc2` của cả hai repo được phát hành ngày 24/06/2026:

- [Backend tags](https://github.com/hashtopolis/server/tags)
- [Frontend tags](https://github.com/hashtopolis/web-ui/tags)

## 1. Cấu hình template Vast.ai

### Image

```text
nvidia/cuda:12.9.1-devel-ubuntu24.04
```

Script hiện hỗ trợ host `x86_64`.

### Launch mode

Chọn **SSH**. Jupyter thường sử dụng port nội bộ `8080` và có thể xung đột với Nginx của stack.

### Docker Options

```bash
-p 8080:8080 -e OPEN_BUTTON_PORT=8080
```

Không thêm `--privileged`, `--cap-add`, `--shm-size` hoặc mount Docker socket. Kiến trúc mới không cần các quyền đó. Tài liệu Vast.ai hiện chỉ hỗ trợ port, biến môi trường và hostname trong trường Docker Options:

- [Vast.ai Docker execution environment](https://docs.vast.ai/guides/instances/docker-environment)
- [Vast.ai networking and ports](https://docs.vast.ai/guides/instances/connect/networking)

Vast.ai map port nội bộ sang external port ngẫu nhiên và cung cấp external port qua `VAST_TCP_PORT_8080`. Script kết hợp biến này với `PUBLIC_IPADDR` để tạo `PUBLIC_URL`.

Nếu dùng port khác:

```bash
-p 18000:18000 -e OPEN_BUTTON_PORT=18000
```

và chạy:

```bash
INTERNAL_PORT=18000 ./run.sh
```

## 2. Download và chạy

Download:

```bash
apt-get update && apt-get install -y curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/kuronoFS/KiQuai/refs/heads/main/TestDiD/run.sh -o /root/run.sh
chmod 700 /root/run.sh
```

Preflight:

```bash
/root/run.sh preflight
```

Preflight chỉ yêu cầu:

- chạy bằng `root`;
- host `x86_64`;
- GPU và `nvidia-smi` nhìn thấy từ outer container;
- đủ dung lượng build tạm thời.

Không còn kiểm tra `CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, mount namespace hoặc network namespace vì không còn DinD.

Triển khai:

```bash
/root/run.sh
```

One-liner:

```bash
bash -lc "apt-get update && apt-get install -y curl ca-certificates && curl -fsSL https://raw.githubusercontent.com/kuronoFS/KiQuai/refs/heads/main/TestDiD/run.sh -o /root/run.sh && chmod 700 /root/run.sh && /root/run.sh"
```

Nên dành tối thiểu 15 GB trống cho lần build đầu. Script hard-fail ở ngưỡng `MIN_FREE_GB=10` theo mặc định.

Nếu muốn các service tự khởi động lại khi Vast.ai restart container, đặt one-liner trên vào trường **On-start Script** của template SSH.

## 3. Mười giai đoạn triển khai

Script và README sử dụng cùng flow:

1. Kiểm tra root, dung lượng và GPU NVIDIA.
2. Cài Apache, PHP, MySQL, Nginx, supervisor, Hashcat và build dependencies.
3. Tạo layout persistent, tiếp nhận credential cũ nếu có và lưu cấu hình.
4. Chạy `hashcat -I` để xác nhận compute device.
5. Cài `sqlx` migration CLI giống backend image chính thức.
6. Checkout và build backend/frontend ở hai tag tương thích.
7. Sinh cấu hình MySQL, Apache, Nginx, supervisor và initialize MySQL khi cần.
8. Khởi động process, tạo database/user và chạy migration/setup của Hashtopolis.
9. Kiểm tra frontend/API rồi cài Python agent.
10. In trạng thái và credential.

Lần đầu có thể mất nhiều thời gian ở bước build `sqlx` và Angular frontend. Các lần chạy sau tái sử dụng tool và release đã build.

## 4. Kết quả

Sau khi thành công, script in:

```text
Hashtopolis URL : http://PUBLIC_IP:EXTERNAL_PORT
Admin username  : admin
Admin password  : RANDOM_PASSWORD
API v2          : http://PUBLIC_IP:EXTERNAL_PORT/api/v2
Legacy agent API: http://PUBLIC_IP:EXTERNAL_PORT/api/server.php
```

Credential và runtime settings nằm tại:

```text
/opt/kiquai-hashtopolis/.env
```

File có mode `600`. Không commit, upload hoặc đính kèm file này vào diagnostic report.

Data persistent:

```text
/opt/kiquai-hashtopolis/data/mysql
/opt/kiquai-hashtopolis/data/hashtopolis
/opt/kiquai-hashtopolis/agent
```

Source/build:

```text
/opt/kiquai-hashtopolis/releases
/opt/kiquai-hashtopolis/current
/opt/kiquai-hashtopolis/tools
```

## 5. Đăng ký GPU agent trong cùng container

Agent package được cài sẵn nhưng mặc định không chạy vì Hashtopolis cần voucher một lần.

1. Mở UI.
2. Vào **Agents → New Agent**.
3. Tạo voucher.
4. Chạy:

```bash
/root/run.sh agent-start YOUR_VOUCHER
```

Hoặc truyền voucher ngay lần deploy đầu:

```bash
AGENT_VOUCHER=YOUR_VOUCHER /root/run.sh
```

Agent kết nối qua loopback:

```text
http://127.0.0.1:8080/api/server.php
```

Sau khi agent tạo thành công `agent/config.json`, script xóa one-time voucher khỏi `.env`. Token/UUID đăng ký nằm trong `agent/config.json`.

Dừng agent nhưng giữ đăng ký:

```bash
/root/run.sh agent-stop
```

Khởi động lại agent đã đăng ký:

```bash
/root/run.sh agent-start
```

CLI options `--voucher` và `--url` được agent chính thức hỗ trợ; xem [Hashtopolis Python Agent](https://github.com/hashtopolis/agent-python).

Hashtopolis có thể yêu cầu agent tải một Hashcat package riêng cho task. `hashcat -I` trong bootstrap là preflight GPU; nó không ép server phải chọn đúng package Hashcat hệ thống cho mọi task.

## 6. Biến môi trường

### Runtime và version

| Biến | Mặc định | Mục đích |
|---|---:|---|
| `APP_DIR` | `/opt/kiquai-hashtopolis` | Data, release, tool, agent và config |
| `LOG_DIR` | `/var/log/kiquai-hashtopolis` | Log bootstrap và service |
| `INTERNAL_PORT` | `8080` | Nginx public bind trong outer container |
| `BACKEND_PORT` | `18080` | Apache loopback |
| `DB_PORT` | `13306` | MySQL loopback |
| `PUBLIC_URL` | Tự nhận diện | URL trình duyệt và frontend API config |
| `HASHTOPOLIS_VERSION` | `v1.0.0-rc2` | Backend Git tag |
| `HASHTOPOLIS_FRONTEND_VERSION` | Cùng backend | Frontend Git tag |
| `HASHTOPOLIS_SERVER_REPOSITORY` | Repo chính thức | Backend Git URL |
| `HASHTOPOLIS_FRONTEND_REPOSITORY` | Repo chính thức | Frontend Git URL |

Nếu `APP_DIR` thay đổi, phải truyền cùng giá trị cho các lệnh sau vì `APP_DIR` quyết định vị trí của chính `.env`:

```bash
APP_DIR=/data/kiquai-hashtopolis /root/run.sh
APP_DIR=/data/kiquai-hashtopolis /root/run.sh status
APP_DIR=/data/kiquai-hashtopolis /root/run.sh logs
```

### Credential

| Biến | Mặc định |
|---|---|
| `MYSQL_ROOT_PASS` | Random 48 ký tự hex |
| `MYSQL_DATABASE` | `hashtopolis` |
| `MYSQL_USER` | `hashtopolis` |
| `MYSQL_PASSWORD` | Random 48 ký tự hex |
| `HASHTOPOLIS_ADMIN_USER` | `admin` |
| `HASHTOPOLIS_ADMIN_PASSWORD` | Random 48 ký tự hex |
| `HASHTOPOLIS_BACKEND_URL` | `PUBLIC_URL/api/v2` |
| `HASHTOPOLIS_FRONTEND_PORT` | Port được suy ra từ `PUBLIC_URL` |

Giá trị caller truyền trực tiếp có ưu tiên cao nhất; nếu không truyền, script tái sử dụng giá trị trong `.env`; nếu chưa có thì mới sinh mặc định.

### Agent và vận hành

| Biến | Mặc định | Mục đích |
|---|---:|---|
| `AGENT_ENABLED` | `0` | Tự chạy local agent |
| `AGENT_VOUCHER` | rỗng | Voucher đăng ký một lần |
| `AGENT_DOWNLOAD_URL` | Local `agents.php?download=1` | Override nguồn agent ZIP |
| `REQUIRE_HASHCAT_GPU` | `1` | Dừng nếu Hashcat không phát hiện device |
| `SKIP_APT` | `0` | Không chạy APT; dependency phải tồn tại |
| `FORCE_REBUILD` | `0` | Build lại release dù tag đã có |
| `KEEP_BUILD_TOOLCHAINS` | `0` | Giữ Rust cache và frontend `node_modules` |
| `MIN_FREE_GB` | `10` | Dung lượng trống tối thiểu |
| `DIAGNOSTICS_ON_FAILURE` | `1` | Tạo diagnostic report khi lỗi |
| `WIPE_DATA` | `0` | Xóa toàn bộ data/config của kiến trúc mới |

Server-only, không bắt buộc GPU Hashcat:

```bash
REQUIRE_HASHCAT_GPU=0 /root/run.sh
```

Rebuild đúng tag:

```bash
FORCE_REBUILD=1 /root/run.sh
```

Đổi version phải đổi cả backend và frontend sang cặp tương thích:

```bash
HASHTOPOLIS_VERSION=vX.Y.Z \
HASHTOPOLIS_FRONTEND_VERSION=vX.Y.Z \
FORCE_REBUILD=1 \
/root/run.sh
```

## 7. Quản trị

Status:

```bash
/root/run.sh status
```

Log:

```bash
/root/run.sh logs
```

Diagnostic:

```bash
/root/run.sh diagnostics
```

Stop toàn bộ process được quản lý, giữ data:

```bash
/root/run.sh stop
```

Reconcile config và restart web services:

```bash
/root/run.sh restart
```

Rerun bình thường cũng idempotent:

```bash
/root/run.sh
```

Reset hoàn toàn kiến trúc mới:

```bash
WIPE_DATA=1 /root/run.sh
```

`WIPE_DATA=1` xóa database, Hashtopolis files, releases, agent registration và credential trong `APP_DIR`. Log mặc định ở `/var/log/kiquai-hashtopolis` được giữ.

## 8. Backup trước update/reset

Database:

```bash
set -a
source /opt/kiquai-hashtopolis/.env
set +a
MYSQL_PWD="$MYSQL_PASSWORD" mysqldump \
  --single-transaction \
  -h 127.0.0.1 -P "$DB_PORT" -u "$MYSQL_USER" \
  "$MYSQL_DATABASE" > /root/hashtopolis.sql
```

Files và agent state:

```bash
tar -C /opt/kiquai-hashtopolis \
  -czf /root/hashtopolis-files.tar.gz \
  data/hashtopolis agent
```

Không đưa các backup chứa hash, credential hoặc agent token lên nơi công khai.

## 9. Chuyển từ bản DinD cũ

Khi phát hiện `APP_DIR/docker-compose.yml`, script mới:

- chỉ dừng proxy/socat/dockerd cũ nếu PID file và command line đều xác nhận đó là process KiQuai;
- chuyển các file cấu hình DinD cũ vào `APP_DIR/legacy-dind-config/`;
- giữ lại credential chung từ `.env`;
- không gọi Docker CLI;
- không xóa `/var/lib/kiquai-docker`;
- không tự nhập Docker named volume cũ.

MySQL data trong inner Docker volume **không tương thích bằng cách copy thẳng thư mục**. Nếu instance cũ có dữ liệu quan trọng, hãy dump database và archive Hashtopolis volume từ bản cũ trước khi thay script, sau đó restore có kiểm soát vào bản mới. Cách an toàn nhất cho lần thử đầu là dùng một Vast.ai instance mới.

## 10. Log layout

| File | Nội dung |
|---|---|
| `bootstrap.log` | Toàn bộ output của `run.sh` |
| `supervisord.log` | Process supervisor riêng |
| `mysql.log` | MySQL server |
| `backend.log` | Migration/setup và Apache launcher |
| `apache-error.log` | PHP/Apache errors |
| `nginx-error.log` | Nginx errors |
| `agent.log` | Python agent và Hashcat task output |
| `hashcat-devices.log` | Kết quả `hashcat -I` |
| `diagnostics/` | Snapshot chẩn đoán đã redact secret |

Mặc định:

```text
/var/log/kiquai-hashtopolis/
```

## 11. Troubleshooting

### Port đã bị chiếm

```bash
ss -ltnp | grep -E ':(8080|18080|13306)\b'
```

Trong SSH mode, port `8080` thường trống. Nếu đang dùng Jupyter, đổi launch mode hoặc đổi `INTERNAL_PORT` và port mapping đồng thời.

### Build `sqlx` lâu

Lần đầu script cài Rust toolchain tối thiểu và compile `sqlx-cli` với MySQL support vì backend dùng SQLx migrations. Binary cuối được cache tại:

```text
APP_DIR/tools/bin/sqlx
```

Rust cache được xóa sau build nếu `KEEP_BUILD_TOOLCHAINS=0`.

### Frontend build lỗi Node.js

Script không dùng Node.js cũ từ Ubuntu. Nó đọc version chính xác trong frontend `.nvmrc`, tải official Node tarball, kiểm tra SHA-256 rồi chạy `npm ci && npm run build`.

Kiểm tra:

```bash
find /opt/kiquai-hashtopolis/tools -maxdepth 2 -name node -o -name npm
tail -n 200 /var/log/kiquai-hashtopolis/bootstrap.log
```

### Backend restart liên tục

```bash
/root/run.sh status
tail -n 200 /var/log/kiquai-hashtopolis/backend.log
tail -n 200 /var/log/kiquai-hashtopolis/apache-error.log
tail -n 200 /var/log/kiquai-hashtopolis/mysql.log
```

Backend launcher đợi MySQL, chạy `src/inc/startup/setup.php` dưới user `www-data`, rồi mới start Apache. Lỗi migration sẽ được giữ trong `backend.log`.

### Public URL hoặc CORS sai

```bash
PUBLIC_URL="http://YOUR_PUBLIC_IP:YOUR_EXTERNAL_PORT" /root/run.sh
```

`PUBLIC_URL` được ghi vào frontend `assets/config.json`. Sau khi sửa, script restart Nginx/backend.

### Agent không đăng ký

```bash
/root/run.sh status
tail -n 250 /var/log/kiquai-hashtopolis/agent.log
```

Voucher là one-time token. Nếu voucher đã dùng hoặc hết hạn, tạo voucher mới rồi chạy:

```bash
/root/run.sh agent-start NEW_VOUCHER
```

### `hashcat -I` không thấy GPU

```bash
nvidia-smi
hashcat -I
ldconfig -p | grep -i -E 'libcuda|libOpenCL'
```

`nvidia-smi` thành công chưa đảm bảo OpenCL/CUDA backend mà Hashcat sử dụng đã được nhận diện. Dùng `REQUIRE_HASHCAT_GPU=0` chỉ khi cố ý triển khai server-only.

## 12. Bảo mật

- Nginx public mặc định dùng HTTP; đặt sau HTTPS tunnel/reverse proxy hoặc VPN khi có dữ liệu nhạy cảm.
- MySQL và Apache chỉ bind loopback.
- `.env`, agent `config.json`, database backup và hashlist là dữ liệu nhạy cảm.
- Không đặt credential trong public Vast.ai template.
- Đổi admin password sau lần đăng nhập đầu.
- `v1.0.0-rc2` là pre-release; backup trước khi đổi tag hoặc chạy migration.

## 13. Tài liệu tham chiếu

- [Hashtopolis server](https://github.com/hashtopolis/server)
- [Hashtopolis web UI](https://github.com/hashtopolis/web-ui)
- [Hashtopolis Python agent](https://github.com/hashtopolis/agent-python)
- [Hashtopolis official documentation](https://docs.hashtopolis.org/)
- [Hashtopolis backend Dockerfile](https://github.com/hashtopolis/server/blob/master/Dockerfile)
- [Hashtopolis backend entrypoint](https://github.com/hashtopolis/server/blob/master/docker-entrypoint.sh)
- [Hashtopolis frontend Dockerfile](https://github.com/hashtopolis/web-ui/blob/master/Dockerfile)
- [Vast.ai Docker environment](https://docs.vast.ai/guides/instances/docker-environment)
- [Vast.ai networking and ports](https://docs.vast.ai/guides/instances/connect/networking)
- [Hashcat official site](https://hashcat.net/hashcat/)
