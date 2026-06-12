#!/bin/bash
# ============================================================================
#  Pearl (PRL) Miner Launcher — SRBMiner-Multi (repo: doktor83/SRBMiner-Multi)
#  Pool mặc định: LuckyPool Asia (pearl-sg1.luckypool.io, Singapore)
# ----------------------------------------------------------------------------
#  - Tự tải, kiểm định (MD5/ELF/arch) và chạy SRBMiner-MULTI, log từng bước.
#  - GPU chạy STOCK — script KHÔNG can thiệp clock/power limit (ưu tiên ổn
#    định, nhiệt độ). Bảo vệ nhiệt qua --gpu-off-temperature (mặc định 90°C).
#  - Mọi biến cấu hình đều override được bằng biến môi trường khi chạy:
#       WALLET=prl1... WORKER=rig02 DEBUG=0 ./run.sh
#       curl -fsSL <url>/run.sh | WORKER=rig02 bash
#  - QUAN TRỌNG: mỗi lần sửa file này, hãy TĂNG SCRIPT_VERSION bên dưới
#    để khi xem log biết chính xác đang chạy bản code cũ hay mới.
# ============================================================================
set -u   # Báo lỗi khi dùng biến chưa khai báo
set -E   # Cho phép ERR trap hoạt động bên trong function

# ----------------------------------------------------------------------------
# [PHIÊN BẢN SCRIPT] — tăng số này mỗi lần chỉnh sửa code
# ----------------------------------------------------------------------------
SCRIPT_VERSION="3.0.1"
SCRIPT_BUILD_DATE="2026-06-12"
# CHANGELOG:
#  3.0.1: SỬA LỖI smoke test: '--list-algorithms' của SRBMiner KHÔNG in gì khi
#         stdout không phải TTY (chạy trong docker) => script kết luận nhầm
#         "không hỗ trợ pearlhash" rồi dừng. Giờ chỉ CẢNH BÁO và chạy tiếp.
#         SỬA VÍ MẶC ĐỊNH đúng chuẩn bech32 'prl1...' (bản cũ sai 'prllp...').
#         WORKER mặc định 'rtx5090'. Thêm MD5 chính chủ cho 3.3.1 → 3.3.7.
#  3.0.0: CHUYỂN HẲN sang SRBMiner-Multi 3.3.7 (thuật toán 'pearlhash') +
#         LuckyPool Asia (pearl-sg1.luckypool.io, failover sg2/eu2).
#         Tự chọn port 3360/3361/3362 theo tổng hashrate ước tính (số GPU ×
#         GPU_TH_EST). GPU chạy STOCK — không OC. API giám sát cổng 21550.
#         Bỏ toàn bộ logic launcher/cache/Plan B của rgminer và mode CPU/DUAL.
#  2.x  : các bản dùng rgminer + rplant (đã ngừng dùng).

# ----------------------------------------------------------------------------
# [CẤU HÌNH ĐÀO]
# ----------------------------------------------------------------------------
WALLET="${WALLET:-prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4}"
WORKER="${WORKER:-rtx5090}"
ALGO="${ALGO:-pearlhash}"

# POOL để TRỐNG = script tự ghép POOL_HOST + các host failover với port tự
# chọn theo hashrate ước tính (xem BƯỚC 4). Muốn chỉ định cứng thì đặt:
#   POOL="pearl-sg1.luckypool.io:3360"  (nhiều pool phân cách bằng dấu phẩy)
POOL="${POOL:-}"
POOL_HOST="${POOL_HOST:-pearl-sg1.luckypool.io}"
POOL_FAILOVER_HOSTS="${POOL_FAILOVER_HOSTS:-pearl-sg2.luckypool.io pearl-eu2.luckypool.io}"
# Ước tính TH/s mỗi GPU để chọn port LuckyPool (RTX 5090 stock ~344-400 TH/s).
# Port chỉ khác nhau ở độ khó khởi điểm (vardiff tự điều chỉnh sau đó):
#   3360: < 500 TH/s | 3361: 500-1000 TH/s | 3362: > 1000 TH/s
GPU_TH_EST="${GPU_TH_EST:-350}"
EXTRA_ARGS="${EXTRA_ARGS:-}"        # Tham số thêm cho SRBMiner, vd: "--tls true"

# ----------------------------------------------------------------------------
# [GIÁM SÁT / AN TOÀN] — tính năng có sẵn của SRBMiner, không phải OC
# ----------------------------------------------------------------------------
API_ENABLE="${API_ENABLE:-1}"            # 1 = bật API thống kê (http://<host>:API_PORT/stats)
API_PORT="${API_PORT:-21550}"
GPU_OFF_TEMP="${GPU_OFF_TEMP:-90}"       # GPU vượt N°C => miner tự tắt GPU đó (0 = tắt tính năng)
NO_SHARE_RESTART="${NO_SHARE_RESTART:-900}"  # Giây không có share được chấp nhận => miner tự restart (0 = tắt)

# ----------------------------------------------------------------------------
# [CẤU HÌNH MINER] — SRBMiner-Multi chính chủ: github.com/doktor83/SRBMiner-Multi
# ----------------------------------------------------------------------------
SRB_VERSION="${SRB_VERSION:-3.3.7}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/srbminer}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"  # 1 = xoá bản cài cũ và tải lại từ đầu
EXPECTED_MD5="${EXPECTED_MD5:-}"         # Để trống = tự áp MD5 chính chủ nếu biết version

# MD5 chính chủ công bố trên trang release — chỉ tự áp khi version khớp
# (các bản hỗ trợ pearlhash: 3.3.1 trở lên)
if [ -z "$EXPECTED_MD5" ]; then
    case "$SRB_VERSION" in
        3.3.7) EXPECTED_MD5="8862183218550e39b0571d0716fadc8e" ;;
        3.3.6) EXPECTED_MD5="ba01e71a354c853d0b58cd75ff991ac7" ;;
        3.3.5) EXPECTED_MD5="4ea7f7f974e907f1212085880cbdc620" ;;
        3.3.4) EXPECTED_MD5="a9838b4c770a805633c93099274d871d" ;;
        3.3.3) EXPECTED_MD5="c7db03dd1d79cd3b56c2a4c703cb433d" ;;
        3.3.2) EXPECTED_MD5="d5661a432fa9847961ec5ef99dec44ba" ;;
        3.3.1) EXPECTED_MD5="eb287d5a49f08410c072b3c0eccec3dd" ;;
    esac
fi

SRB_VER_DASH=${SRB_VERSION//./-}
URL_DEFAULT="https://github.com/doktor83/SRBMiner-Multi/releases/download/${SRB_VERSION}/SRBMiner-Multi-${SRB_VER_DASH}-Linux.tar.gz"
URL_DOWNLOAD="${URL_DOWNLOAD:-$URL_DEFAULT}"

# Driver NVIDIA khuyến nghị cho 'pearlhash' (ghi chú chính thức của SRBMiner);
# RTX 50xx (Blackwell) tối thiểu cần driver nhánh 570.
RECOMMENDED_DRIVER="580"
MIN_BLACKWELL_DRIVER="570"

# ----------------------------------------------------------------------------
# [CẤU HÌNH DEBUG / RESTART]
# ----------------------------------------------------------------------------
DEBUG="${DEBUG:-1}"                            # 1 = hiện log [DEBUG] chi tiết + --extended-log
RESTART_DELAY="${RESTART_DELAY:-5}"            # Giây chờ giữa các lần restart
LONG_RESTART_DELAY="${LONG_RESTART_DELAY:-60}" # Giây chờ khi crash liên tục
MAX_RETRIES="${MAX_RETRIES:-0}"                # Tổng số lần chạy tối đa, 0 = vô hạn
MIN_UPTIME="${MIN_UPTIME:-20}"                 # Chạy dưới N giây => tính là "crash nhanh"
FAST_FAIL_LIMIT="${FAST_FAIL_LIMIT:-5}"        # N lần crash nhanh liên tiếp => chẩn đoán sâu

TOTAL_STEPS=7
VERSION_FILE="$INSTALL_DIR/.installed_version"
TMP_DIR=""
MINER_PID=""
BIN_PATH=""        # xác định ở BƯỚC 5 (sau khi cài/tìm thấy binary)
BIN_DIR=""
POOL_LIST=""       # xác định ở BƯỚC 4 (sau khi đếm GPU)
GPU_COUNT=0

# ============================================================================
#  HÀM LOG — mọi dòng đều có timestamp + cấp độ để dễ truy vết
# ============================================================================
if [ -t 1 ]; then
    C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_CYN=$'\e[36m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_RED=""; C_YEL=""; C_CYN=""; C_DIM=""; C_RST=""
fi

ts()        { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { echo "[$(ts)] [INFO ] $*"; }
log_warn()  { echo "${C_YEL}[$(ts)] [WARN ] $*${C_RST}" >&2; }
log_error() { echo "${C_RED}[$(ts)] [ERROR] $*${C_RST}" >&2; }
log_debug() { if [ "$DEBUG" = "1" ]; then echo "${C_DIM}[$(ts)] [DEBUG] $*${C_RST}"; fi; }
log_step()  { echo; echo "${C_CYN}[$(ts)] [BƯỚC $1/$TOTAL_STEPS] ===== $2 =====${C_RST}"; }
hr()        { echo "-------------------------------------------------------------"; }

die() {
    log_error "$*"
    log_error "Script DỪNG tại đây (run.sh v$SCRIPT_VERSION). Sửa lỗi trên rồi chạy lại."
    exit 1
}

# Bắt các lệnh thất bại ngoài dự kiến — in ra đúng dòng và lệnh gây lỗi
trap 'log_error "Lệnh thất bại ngoài dự kiến tại DÒNG $LINENO: \"$BASH_COMMAND\""' ERR

cleanup() { if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR" 2>/dev/null || true; fi; }
trap cleanup EXIT

on_signal() {
    echo
    log_warn "Nhận tín hiệu dừng (Ctrl+C / docker stop) — đang tắt miner sạch sẽ..."
    if [ -n "$MINER_PID" ]; then kill "$MINER_PID" 2>/dev/null || true; fi
    wait 2>/dev/null || true
    log_warn "Đã dừng toàn bộ tiến trình đào."
    exit 130
}
trap on_signal INT TERM

# Cho phép kiểm tra nhanh phiên bản: ./run.sh --version
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
    echo "run.sh v$SCRIPT_VERSION (build $SCRIPT_BUILD_DATE)"
    exit 0
fi

# ============================================================================
#  HÀM CHẨN ĐOÁN
# ============================================================================

# Đọc 4 byte đầu của file — ELF chuẩn Linux phải là "7f 45 4c 46"
# (echo không ngoặc kép để gom khoảng trắng thừa của od)
magic_of() { local m; m=$(od -An -N4 -t x1 "$1" 2>/dev/null) || true; echo $m; }
is_elf()   { [ "$(magic_of "$1")" = "7f 45 4c 46" ]; }

# Đọc kiến trúc CPU mà binary được build cho (offset 18 của ELF header)
elf_arch_of() {
    local m
    m=$(od -An -j18 -N2 -t x1 "$1" 2>/dev/null | tr -d ' \n')
    case "$m" in
        3e00) echo "x86_64" ;;
        b700) echo "aarch64" ;;
        0300) echo "i386 (32-bit)" ;;
        *)    echo "không rõ (mã: $m)" ;;
    esac
}

md5_of()    { md5sum "$1" 2>/dev/null | awk '{print $1}'; }
sha256_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# So sánh version dạng a.b.c — version_ge A B nghĩa là A >= B
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

# In toàn bộ thông tin về 1 file để biết chính xác nó là gì / hỏng chỗ nào
dump_file_info() {
    local p=$1
    hr
    log_warn "CHẨN ĐOÁN SÂU FILE: $p"
    if [ ! -e "$p" ]; then
        log_warn "  -> File KHÔNG TỒN TẠI."
        hr
        return 0
    fi
    log_warn "  -> ls -ld : $(ls -ld "$p" 2>&1)"
    if [ -d "$p" ]; then
        log_warn "  -> Đây là THƯ MỤC, không phải file!"
        hr
        return 0
    fi
    log_warn "  -> Kích thước : $(stat -c %s "$p" 2>/dev/null || echo '?') bytes"
    log_warn "  -> Magic bytes: '$(magic_of "$p")' (ELF Linux chuẩn = '7f 45 4c 46')"
    log_warn "  -> MD5        : $(md5_of "$p")"
    if command -v file >/dev/null 2>&1; then
        log_warn "  -> file(1)    : $(file -b "$p" 2>&1)"
    fi
    if is_elf "$p"; then
        log_warn "  -> Build cho  : $(elf_arch_of "$p") | Máy này: $(uname -m)"
        if command -v ldd >/dev/null 2>&1; then
            local missing
            missing=$(ldd "$p" 2>&1 | grep "not found" || true)
            if [ -n "$missing" ]; then
                log_warn "  -> THIẾU THƯ VIỆN (nguyên nhân không chạy được):"
                echo "$missing" | while IFS= read -r line; do log_warn "       $line"; done
            else
                log_warn "  -> Thư viện   : đầy đủ (ldd OK)"
            fi
        fi
    else
        log_warn "  -> KHÔNG PHẢI binary ELF Linux => không thể thực thi."
        log_warn "  -> Nội dung đầu file: $(head -c 200 "$p" 2>/dev/null | tr -cd '[:print:]' | head -c 150)"
    fi
    if [ ! -x "$p" ]; then
        log_warn "  -> File CHƯA có quyền thực thi (cần chmod +x)."
    fi
    # Kiểm tra phân vùng có bị mount noexec không
    local mp
    mp=$(df -P "$p" 2>/dev/null | awk 'NR==2{print $6}') || true
    if [ -n "${mp:-}" ] && grep -E "[[:space:]]${mp}[[:space:]]" /proc/mounts 2>/dev/null | grep -q noexec; then
        log_warn "  -> Phân vùng '$mp' bị mount NOEXEC => không cho chạy file!"
    fi
    hr
}

# Giải thích ý nghĩa exit code của miner + gợi ý cách sửa
explain_exit_code() {
    local code=$1
    case "$code" in
        0)   log_warn "Code=0: miner tự thoát bình thường — thường do lỗi cấu hình được in ngay phía trên (sai wallet/pool/tham số) hoặc pool ngắt kết nối." ;;
        1)   log_error "Code=1: lỗi chung — thường do sai tham số, sai wallet/pool, hoặc pool từ chối. Đọc log miner ngay phía trên." ;;
        2)   log_error "Code=2: sai cú pháp tham số dòng lệnh." ;;
        126) log_error "Code=126: file TỒN TẠI nhưng KHÔNG THỂ THỰC THI (mất quyền +x, phân vùng noexec, hoặc file hỏng)." ;;
        127) log_error "Code=127: không tìm thấy file, hoặc thiếu dynamic loader/thư viện hệ thống (glibc quá cũ?)." ;;
        130) log_warn  "Code=130: bị dừng bởi Ctrl+C (SIGINT)." ;;
        132) log_error "Code=132 (SIGILL): CPU không hỗ trợ tập lệnh binary cần — sai kiến trúc hoặc CPU quá cũ." ;;
        134) log_error "Code=134 (SIGABRT): miner tự abort — thường do lỗi CUDA runtime/driver không tương thích." ;;
        137) log_error "Code=137 (SIGKILL): bị hệ thống kill — thường do HẾT RAM (OOM killer) hoặc docker stop."
             log_error "  => Kiểm tra giới hạn RAM của container (docker run -m) và RAM còn trống." ;;
        139) log_error "Code=139 (SIGSEGV): miner crash — thường do driver NVIDIA/CUDA không tương thích với GPU." ;;
        143) log_warn  "Code=143: bị dừng bởi SIGTERM (docker stop?)." ;;
        *)   log_error "Code=$code: xem log miner phía trên để biết chi tiết." ;;
    esac
}

# ============================================================================
#  BƯỚC 1: THÔNG TIN MÔI TRƯỜNG & PHIÊN BẢN
# ============================================================================
echo "============================================================="
echo "  💎 Pearl (PRL) Miner Launcher — SRBMiner-Multi + LuckyPool"
echo "  📌 PHIÊN BẢN SCRIPT : v$SCRIPT_VERSION (build $SCRIPT_BUILD_DATE)"
echo "============================================================="

log_step 1 "Thông tin môi trường"

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_SOURCE="file: ${BASH_SOURCE[0]}"
    log_debug "SHA256 của script: $(sha256_of "${BASH_SOURCE[0]}" | head -c 16)..."
else
    SCRIPT_SOURCE="stdin/pipe (vd: curl ... | bash)"
fi
log_info "Nguồn script  : $SCRIPT_SOURCE"
log_info "Thời gian     : $(date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)')"
OS_NAME=$(grep -s PRETTY_NAME /etc/os-release | cut -d'"' -f2) || true
log_info "OS            : ${OS_NAME:-$(uname -s)}"
log_info "Kernel / Arch : $(uname -r) / $(uname -m)"
log_info "User          : $(id -un 2>/dev/null || echo '?') (uid=$(id -u 2>/dev/null || echo '?'))"
if [ -f /.dockerenv ] || grep -qs docker /proc/1/cgroup 2>/dev/null; then
    log_info "Container     : Docker (đã phát hiện)"
else
    log_info "Container     : không phát hiện (chạy trực tiếp trên máy)"
fi
log_debug "Bash version  : $BASH_VERSION"
log_debug "CPU cores     : $(nproc 2>/dev/null || echo '?')"
if command -v free >/dev/null 2>&1; then
    log_debug "RAM           : $(free -h | awk 'NR==2{printf "tổng %s / trống %s", $2, $7}')"
fi
log_debug "Dung lượng đĩa: /tmp = $(df -h /tmp 2>/dev/null | awk 'NR==2{print $4}') trống, $INSTALL_DIR = $(df -h "$INSTALL_DIR" 2>/dev/null | awk 'NR==2{print $4}') trống"

# ============================================================================
#  BƯỚC 2: KIỂM TRA CẤU HÌNH
# ============================================================================
log_step 2 "Kiểm tra cấu hình"

# Đảm bảo các biến cấu hình dạng số là số hợp lệ (tránh lỗi so sánh số học)
ensure_number() {
    local name=$1 def=$2 val
    eval "val=\${$name}"
    case "$val" in
        ''|*[!0-9]*)
            log_warn "$name='$val' không phải số hợp lệ — dùng giá trị mặc định: $def"
            eval "$name=$def"
            ;;
    esac
}
ensure_number RESTART_DELAY 5
ensure_number LONG_RESTART_DELAY 60
ensure_number MAX_RETRIES 0
ensure_number MIN_UPTIME 20
ensure_number FAST_FAIL_LIMIT 5
ensure_number GPU_TH_EST 350
ensure_number API_PORT 21550
ensure_number GPU_OFF_TEMP 90
ensure_number NO_SHARE_RESTART 900

log_info "WALLET        : $WALLET"
log_info "WORKER        : $WORKER"
log_info "ALGO          : $ALGO"
if [ -n "$POOL" ]; then
    log_info "POOL          : $POOL (chỉ định cứng — bỏ qua auto-chọn port)"
else
    log_info "POOL          : (tự chọn) $POOL_HOST + failover: $POOL_FAILOVER_HOSTS"
    log_info "                port sẽ chọn ở BƯỚC 4 theo số GPU × ${GPU_TH_EST} TH/s"
fi
log_info "GPU           : chạy STOCK — script không OC/không chỉnh clock, power limit"
log_info "EXTRA_ARGS    : ${EXTRA_ARGS:-(không có)}"
log_info "SRB_VERSION   : $SRB_VERSION"
log_debug "URL_DOWNLOAD  : $URL_DOWNLOAD"
log_debug "EXPECTED_MD5  : ${EXPECTED_MD5:-(không kiểm)}"
log_debug "INSTALL_DIR   : $INSTALL_DIR"
log_debug "API_ENABLE=$API_ENABLE API_PORT=$API_PORT GPU_OFF_TEMP=${GPU_OFF_TEMP}°C NO_SHARE_RESTART=${NO_SHARE_RESTART}s"
log_debug "DEBUG=$DEBUG FORCE_REINSTALL=$FORCE_REINSTALL RESTART_DELAY=${RESTART_DELAY}s MAX_RETRIES=$MAX_RETRIES MIN_UPTIME=${MIN_UPTIME}s"

if [ -z "$WALLET" ]; then
    die "WALLET đang để trống!"
fi
# LuckyPool hỗ trợ đào solo bằng cách thêm tiền tố "solo:" trước địa chỉ ví
WALLET_CHECK=${WALLET#solo:}
case "$WALLET_CHECK" in
    prl*) log_debug "Định dạng ví: tiền tố 'prl' hợp lệ (độ dài ${#WALLET_CHECK} ký tự)" ;;
    *)    log_warn "Ví '$WALLET' không bắt đầu bằng 'prl' — kiểm tra lại địa chỉ ví Pearl!" ;;
esac
if [ "$WALLET" != "$WALLET_CHECK" ]; then
    log_warn "Phát hiện tiền tố 'solo:' — bạn đang đào SOLO (tự chịu may rủi tìm block, không chia thưởng PPLNS)."
fi

if [ "$ALGO" != "pearlhash" ]; then
    log_warn "ALGO='$ALGO' khác mặc định 'pearlhash' — chắc chắn SRBMiner hỗ trợ thuật toán này?"
fi

# ============================================================================
#  BƯỚC 3: KIỂM TRA CÔNG CỤ HỆ THỐNG (DEPENDENCIES)
# ============================================================================
log_step 3 "Kiểm tra công cụ hệ thống"

MISSING=""
for tool in od md5sum sha256sum awk grep tar gzip; do
    if command -v "$tool" >/dev/null 2>&1; then
        log_debug "OK: $tool ($(command -v "$tool"))"
    else
        MISSING="$MISSING $tool"
    fi
done

DOWNLOADER=""
if command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
    log_debug "OK: wget ($(wget --version 2>/dev/null | head -1))"
elif command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
    log_debug "OK: curl ($(curl --version 2>/dev/null | head -1))"
else
    MISSING="$MISSING wget/curl"
fi

if [ -n "$MISSING" ]; then
    log_error "Thiếu công cụ:$MISSING"
    die "Cài đặt bằng: apt-get update && apt-get install -y wget tar gzip coreutils ca-certificates"
fi

if [ ! -d /etc/ssl/certs ] || [ -z "$(ls -A /etc/ssl/certs 2>/dev/null)" ]; then
    log_warn "Không thấy chứng chỉ SSL (/etc/ssl/certs trống) — tải HTTPS có thể lỗi. Cài: apt-get install -y ca-certificates"
fi
for opt_tool in file timeout getent ldd; do
    command -v "$opt_tool" >/dev/null 2>&1 || log_debug "Thiếu tool phụ '$opt_tool' (không bắt buộc, chỉ giảm khả năng chẩn đoán)"
done
log_info "✅ Đủ công cụ cần thiết (trình tải: $DOWNLOADER)"

# ============================================================================
#  BƯỚC 4: KIỂM TRA GPU / DRIVER NVIDIA + CHỌN POOL/PORT
# ============================================================================
log_step 4 "Kiểm tra GPU / Driver NVIDIA + chọn pool/port"

if ! command -v nvidia-smi >/dev/null 2>&1; then
    log_warn "KHÔNG tìm thấy nvidia-smi! Miner GPU gần như chắc chắn sẽ không chạy được."
    log_warn "  Nếu đang dùng Docker, container PHẢI chạy với: docker run --gpus all ..."
    log_warn "  và máy chủ phải cài nvidia-container-toolkit + driver NVIDIA."
else
    GPU_INFO=$(timeout 15 nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1) || true
    if [ -n "$GPU_INFO" ] && ! echo "$GPU_INFO" | grep -qi "failed\|error"; then
        GPU_COUNT=$(echo "$GPU_INFO" | wc -l)
        log_info "✅ Phát hiện $GPU_COUNT GPU:"
        echo "$GPU_INFO" | while IFS= read -r line; do log_info "   -> $line"; done

        DRIVER_VER=$(echo "$GPU_INFO" | head -n1 | awk -F',' '{print $2}' | tr -d ' ')

        # Phát hiện thế hệ GPU qua compute capability (RTX 50xx/Blackwell = 12.x)
        GPU_CAPS=$(timeout 15 nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader 2>/dev/null) || true
        MAX_CAP_MAJOR=0
        if [ -n "${GPU_CAPS:-}" ]; then
            while IFS= read -r cap_line; do
                cap=$(echo "$cap_line" | awk -F',' '{print $NF}' | tr -d ' ')
                cap_major=${cap%%.*}
                case "$cap_major" in ''|*[!0-9]*) continue ;; esac
                log_debug "Compute capability: $cap_line (sm_${cap/./})"
                if [ "$cap_major" -gt "$MAX_CAP_MAJOR" ]; then MAX_CAP_MAJOR=$cap_major; fi
            done <<< "$GPU_CAPS"
        fi

        # Kiểm tra driver: SRBMiner khuyến nghị >= 580 cho 'pearlhash';
        # RTX 50xx (Blackwell) tối thiểu cần nhánh 570 mới nhận GPU.
        if [ -n "$DRIVER_VER" ]; then
            if [ "$MAX_CAP_MAJOR" -ge 12 ] && ! version_ge "$DRIVER_VER" "$MIN_BLACKWELL_DRIVER"; then
                log_error "GPU RTX 50xx (Blackwell) nhưng driver host = $DRIVER_VER < $MIN_BLACKWELL_DRIVER —"
                log_error "  driver này KHÔNG nhận diện được RTX 50xx, miner sẽ không thấy GPU."
                log_error "  => Nâng driver NVIDIA trên MÁY HOST (container dùng driver của host)."
            elif ! version_ge "$DRIVER_VER" "$RECOMMENDED_DRIVER"; then
                log_warn "Driver $DRIVER_VER < $RECOMMENDED_DRIVER — SRBMiner khuyến nghị driver >= $RECOMMENDED_DRIVER"
                log_warn "  cho 'pearlhash' (bản cũ từng gây rejected shares). Vẫn chạy được nhưng nên nâng cấp."
            else
                log_info "✅ Driver $DRIVER_VER >= $RECOMMENDED_DRIVER — đạt khuyến nghị của SRBMiner cho pearlhash."
            fi
        fi
    else
        log_warn "nvidia-smi có nhưng chạy lỗi: $GPU_INFO"
        log_warn "  => Driver chưa được nạp vào container? Kiểm tra lại '--gpus all'."
    fi
fi

# --- Chọn port LuckyPool theo tổng hashrate ước tính rồi ghép danh sách pool ---
if [ -n "$POOL" ]; then
    POOL_LIST="$POOL"
    log_info "Dùng pool chỉ định cứng: $POOL_LIST"
else
    EST_TH=$(( GPU_COUNT * GPU_TH_EST ))
    if [ "$EST_TH" -gt 1000 ]; then
        LUCKY_PORT=3362
    elif [ "$EST_TH" -ge 500 ]; then
        LUCKY_PORT=3361
    else
        LUCKY_PORT=3360
    fi
    if [ "$GPU_COUNT" -eq 0 ]; then
        log_warn "Chưa phát hiện GPU nào — tạm dùng port mặc định 3360 (vardiff sẽ tự điều chỉnh)."
    else
        log_info "Tổng hashrate ước tính: ${GPU_COUNT} GPU × ${GPU_TH_EST} TH/s = ~${EST_TH} TH/s => chọn port $LUCKY_PORT"
        log_debug "Ngưỡng port LuckyPool: 3360 (<500 TH/s) | 3361 (500-1000) | 3362 (>1000) — chỉ khác độ khó khởi điểm"
    fi
    POOL_LIST="${POOL_HOST}:${LUCKY_PORT}"
    for fh in $POOL_FAILOVER_HOSTS; do
        POOL_LIST="${POOL_LIST},${fh}:${LUCKY_PORT}"
    done
    log_info "Danh sách pool (chính → failover): $POOL_LIST"
fi

# ============================================================================
#  BƯỚC 5: CÀI ĐẶT & KIỂM ĐỊNH SRBMINER-MULTI
# ============================================================================
log_step 5 "Cài đặt & kiểm định SRBMiner-Multi v$SRB_VERSION"

# Kiểm định toàn diện 1 binary; trả về 0 nếu dùng được
validate_binary() {
    local p=$1 ok=1
    if [ ! -e "$p" ]; then log_debug "Kiểm định: $p chưa tồn tại"; return 1; fi
    if [ ! -f "$p" ]; then log_error "Kiểm định FAIL: $p không phải file thường (là thư mục/symlink hỏng?)"; return 1; fi
    local size
    size=$(stat -c %s "$p" 2>/dev/null || echo 0)
    if [ "$size" -lt 1000000 ]; then
        log_error "Kiểm định FAIL: file quá nhỏ ($size bytes) — có thể là trang lỗi HTML thay vì binary."
        ok=0
    fi
    if ! is_elf "$p"; then
        log_error "Kiểm định FAIL: magic bytes = '$(magic_of "$p")' — không phải ELF Linux (chuẩn: '7f 45 4c 46')."
        ok=0
    else
        local barch sarch
        barch=$(elf_arch_of "$p"); sarch=$(uname -m)
        if [ "$barch" != "$sarch" ]; then
            log_error "Kiểm định FAIL: binary build cho '$barch' nhưng máy là '$sarch' (=> Exec format error)."
            ok=0
        fi
    fi
    [ "$ok" = "1" ] || return 1
    chmod +x "$p" 2>/dev/null || true
    if [ ! -x "$p" ]; then log_error "Kiểm định FAIL: không gán được quyền thực thi (+x) cho $p"; return 1; fi
    log_debug "Kiểm định OK: ELF $(elf_arch_of "$p"), $size bytes, md5=$(md5_of "$p")"
    return 0
}

download_file() {
    local url=$1 out=$2 errlog="$TMP_DIR/download.err" rc=0
    log_info "📥 Đang tải: $url"
    if [ "$DOWNLOADER" = "wget" ]; then
        wget --tries=3 --connect-timeout=15 --read-timeout=120 -nv -O "$out" "$url" >"$errlog" 2>&1 || rc=$?
    else
        curl -fSL --retry 3 --connect-timeout 15 -o "$out" "$url" >"$errlog" 2>&1 || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        log_error "Tải thất bại (mã lỗi $DOWNLOADER: $rc). Chi tiết:"
        while IFS= read -r line; do log_error "   | $line"; done < <(tail -5 "$errlog")
        if grep -qi "404" "$errlog"; then
            log_error "   => Lỗi 404: URL sai hoặc release đã đổi tên file. Kiểm tra: https://github.com/doktor83/SRBMiner-Multi/releases"
        elif grep -qi "certificate\|ssl" "$errlog"; then
            log_error "   => Lỗi SSL: cài ca-certificates (apt-get install -y ca-certificates)"
        elif grep -qi "resolve\|unknown host" "$errlog"; then
            log_error "   => Lỗi DNS: container không phân giải được github.com — kiểm tra mạng/DNS của Docker."
        fi
        return 1
    fi
    log_debug "Đã tải xong: $(stat -c %s "$out" 2>/dev/null) bytes, md5=$(md5_of "$out")"
    return 0
}

# Tìm binary SRBMiner-MULTI trong thư mục cài đặt (gói tar có 1 thư mục con)
locate_installed_binary() {
    BIN_PATH=$(find "$INSTALL_DIR" -maxdepth 2 -type f -name "SRBMiner-MULTI" 2>/dev/null | head -n1)
    if [ -n "$BIN_PATH" ]; then
        BIN_DIR=$(dirname "$BIN_PATH")
        return 0
    fi
    return 1
}

install_miner() {
    TMP_DIR=$(mktemp -d /tmp/srbminer.XXXXXX) || die "Không tạo được thư mục tạm trong /tmp (đĩa đầy?)"
    local pkg="$TMP_DIR/pkg.tar.gz"

    download_file "$URL_DOWNLOAD" "$pkg" || die "Không tải được SRBMiner-Multi. Xem chi tiết lỗi phía trên."

    if [ -n "$EXPECTED_MD5" ]; then
        local actual
        actual=$(md5_of "$pkg")
        if [ "$actual" != "$EXPECTED_MD5" ]; then
            log_error "MD5 thực tế : $actual"
            log_error "MD5 mong đợi: $EXPECTED_MD5 (công bố trên trang release chính chủ)"
            dump_file_info "$pkg"
            die "Checksum MD5 KHÔNG khớp — file tải về không đúng như mong đợi!"
        fi
        log_info "✅ Checksum MD5 khớp bản chính chủ."
    else
        log_warn "Không có MD5 mong đợi cho version '$SRB_VERSION' — bỏ qua bước so checksum (đặt EXPECTED_MD5 nếu muốn kiểm)."
    fi

    log_info "📂 Đang giải nén gói tar.gz..."
    mkdir -p "$TMP_DIR/extract"
    tar -xzf "$pkg" -C "$TMP_DIR/extract" 2>"$TMP_DIR/tar.err" || {
        log_error "Giải nén thất bại: $(cat "$TMP_DIR/tar.err")"
        dump_file_info "$pkg"
        die "File tải về không phải gói tar.gz hợp lệ."
    }
    log_debug "Nội dung gói: $(tar -tzf "$pkg" 2>/dev/null | head -10 | tr '\n' ' ')"

    local src_bin
    src_bin=$(find "$TMP_DIR/extract" -type f -name "SRBMiner-MULTI" 2>/dev/null | head -n1)
    if [ -z "$src_bin" ]; then
        log_error "Không tìm thấy binary 'SRBMiner-MULTI' trong gói. Danh sách file:"
        find "$TMP_DIR/extract" -type f | head -20 | while IFS= read -r f; do log_error "   | $f"; done
        die "Cấu trúc gói tải về không như mong đợi."
    fi
    if ! validate_binary "$src_bin"; then
        dump_file_info "$src_bin"
        die "Binary trong gói KHÔNG hợp lệ — xem chẩn đoán phía trên."
    fi

    # Dọn bản cũ rồi chuyển cả thư mục đã giải nén vào INSTALL_DIR
    rm -rf "${INSTALL_DIR:?}"/* 2>/dev/null || true
    local src_dir
    src_dir=$(dirname "$src_bin")
    mv -f "$src_dir" "$INSTALL_DIR/" || die "Không ghi được vào $INSTALL_DIR (thiếu quyền?)"
    echo "$SRB_VERSION" > "$VERSION_FILE" 2>/dev/null || true
    rm -rf "$TMP_DIR"; TMP_DIR=""

    locate_installed_binary || die "Cài xong nhưng không tìm thấy binary trong $INSTALL_DIR?!"
    chmod +x "$BIN_PATH" 2>/dev/null || true
    log_info "✅ Đã cài SRBMiner-Multi vào: $BIN_PATH"
}

mkdir -p "$INSTALL_DIR" 2>/dev/null || true
if [ ! -w "$INSTALL_DIR" ]; then
    die "Không có quyền ghi vào '$INSTALL_DIR'. Chạy bằng root, hoặc đặt INSTALL_DIR=\$HOME/srbminer"
fi

INSTALLED_VERSION=""
if [ -f "$VERSION_FILE" ]; then INSTALLED_VERSION=$(head -n1 "$VERSION_FILE" 2>/dev/null | tr -d ' \r\n'); fi

if [ "$FORCE_REINSTALL" = "1" ]; then
    log_warn "FORCE_REINSTALL=1 — xoá bản cài cũ trong $INSTALL_DIR để tải lại."
    rm -rf "${INSTALL_DIR:?}"/* "$VERSION_FILE" 2>/dev/null || true
    INSTALLED_VERSION=""
fi

if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" = "$SRB_VERSION" ] && locate_installed_binary && validate_binary "$BIN_PATH"; then
    log_info "✅ Đã có sẵn SRBMiner-Multi v$INSTALLED_VERSION hợp lệ: $BIN_PATH (muốn tải mới: FORCE_REINSTALL=1)"
else
    if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" != "$SRB_VERSION" ]; then
        log_info "Bản cài cũ là v$INSTALLED_VERSION ≠ v$SRB_VERSION yêu cầu — tải lại."
    fi
    install_miner
fi

# Chạy thử nhẹ (smoke test): chỉ để chắc binary THỰC THI ĐƯỢC trên máy này.
# LƯU Ý: SRBMiner thường KHÔNG in danh sách thuật toán khi stdout không phải
# TTY (chạy trong docker/pipe) — nên "không thấy pearlhash trong output"
# KHÔNG được coi là lỗi chặn. Lỗi chặn chỉ là: binary không exec được/GLIBC.
SMOKE_RUNNER=()
if command -v timeout >/dev/null 2>&1; then SMOKE_RUNNER=(timeout 30); fi

log_info "🔬 Chạy thử binary ($BIN_PATH --list-algorithms)..."
SMOKE_RC=0
SMOKE_OUT=$(cd "$BIN_DIR" && "${SMOKE_RUNNER[@]}" "$BIN_PATH" --list-algorithms 2>&1) || SMOKE_RC=$?

if echo "$SMOKE_OUT" | grep -qi "$ALGO"; then
    log_info "✅ Binary chạy được và CÓ hỗ trợ thuật toán '$ALGO'."
    echo "$SMOKE_OUT" | grep -i "$ALGO" | head -3 | while IFS= read -r line; do log_debug "   | $line"; done
elif [ "$SMOKE_RC" -eq 0 ]; then
    log_info "✅ Binary thực thi được (Code=0)."
    log_warn "Miner không in danh sách thuật toán để đối chiếu '$ALGO' (bình thường khi chạy"
    log_warn "  không có TTY, vd trong docker) — tiếp tục. Nếu thuật toán không được hỗ trợ,"
    log_warn "  miner sẽ tự báo lỗi rõ ràng ngay khi khởi chạy ở BƯỚC 7."
    if [ "$ALGO" = "pearlhash" ] && version_ge "$SRB_VERSION" "3.3.1"; then
        log_info "Đối chiếu trang release: SRBMiner v$SRB_VERSION >= 3.3.1 chắc chắn hỗ trợ 'pearlhash'."
    fi
elif [ "$SMOKE_RC" -eq 124 ]; then
    log_warn "Chạy thử bị timeout sau 30s (bất thường nhưng không chặn) — tiếp tục."
elif echo "$SMOKE_OUT" | grep -qi "GLIBC"; then
    log_error "Output: $(echo "$SMOKE_OUT" | head -3)"
    die "Thiếu GLIBC — image/OS quá cũ so với binary. Dùng Ubuntu 22.04/24.04 (vd image nvidia/cuda:12.x-base-ubuntu22.04)."
else
    log_error "Chạy thử thất bại (Code=$SMOKE_RC). Output:"
    echo "$SMOKE_OUT" | head -10 | while IFS= read -r line; do log_error "   | $line"; done
    explain_exit_code "$SMOKE_RC"
    dump_file_info "$BIN_PATH"
    die "Binary SRBMiner-MULTI không chạy được trên máy này — xem chẩn đoán phía trên."
fi

# ============================================================================
#  BƯỚC 6: KIỂM TRA KẾT NỐI POOL
# ============================================================================
log_step 6 "Kiểm tra kết nối pool"

POOL_OK=0
POOL_ARR=()
IFS=',' read -r -a POOL_ARR <<< "$POOL_LIST" || true
for pool_entry in "${POOL_ARR[@]}"; do
    p_stripped=${pool_entry#*://}
    p_host=${p_stripped%%:*}
    p_port=${p_stripped##*:}
    if [ "$p_host" = "$p_port" ]; then
        log_warn "Pool '$pool_entry' thiếu cổng (định dạng đúng: host:port)"
        p_port=""
    fi
    if command -v getent >/dev/null 2>&1; then
        p_ips=$(getent hosts "$p_host" 2>/dev/null | awk '{print $1}' | tr '\n' ' ') || true
        if [ -n "${p_ips:-}" ]; then
            log_debug "DNS OK: $p_host -> $p_ips"
        else
            log_warn "Không phân giải được DNS '$p_host' — kiểm tra mạng/DNS container."
        fi
    fi
    if [ -n "$p_port" ] && command -v timeout >/dev/null 2>&1; then
        if timeout 7 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$p_host" "$p_port" 2>/dev/null; then
            log_info "✅ Kết nối TCP tới $p_host:$p_port thành công."
            POOL_OK=1
        else
            log_warn "KHÔNG kết nối TCP được tới $p_host:$p_port (firewall? pool sập? sai port?)"
        fi
    fi
done
if [ "$POOL_OK" -eq 0 ]; then
    log_warn "Chưa kết nối được pool nào trong danh sách — miner vẫn sẽ khởi chạy và tự thử lại,"
    log_warn "  nhưng nếu miner thoát ngay thì mạng/firewall là nguyên nhân chính."
fi

# ============================================================================
#  BƯỚC 7: VÒNG LẶP ĐÀO
# ============================================================================
log_step 7 "Bắt đầu vòng lặp đào (SRBMiner-Multi v$SRB_VERSION, GPU stock)"

EXTRA_ARR=()
if [ -n "$EXTRA_ARGS" ]; then read -r -a EXTRA_ARR <<< "$EXTRA_ARGS" || true; fi

# Lệnh đào: GPU stock — KHÔNG có bất kỳ cờ OC nào (--gpu-cclock/--gpu-plimit...)
MINER_CMD=(
    "$BIN_PATH"
    --algorithm "$ALGO"
    --pool "$POOL_LIST"
    --wallet "$WALLET"
    --worker "$WORKER"
    --disable-cpu
    --keepalive true
    --give-up-limit 3
    --retry-time 10
    --enable-restart-on-rejected
)
if [ "$NO_SHARE_RESTART" -gt 0 ]; then
    MINER_CMD+=(--max-no-share-sent "$NO_SHARE_RESTART")
fi
if [ "$GPU_OFF_TEMP" -gt 0 ]; then
    MINER_CMD+=(--gpu-off-temperature "$GPU_OFF_TEMP")
fi
if [ "$API_ENABLE" = "1" ]; then
    MINER_CMD+=(--api-enable --api-port "$API_PORT" --api-rig-name "$WORKER")
fi
if [ "$DEBUG" = "1" ]; then
    MINER_CMD+=(--extended-log)
fi
if [ ${#EXTRA_ARR[@]} -gt 0 ]; then MINER_CMD+=("${EXTRA_ARR[@]}"); fi

if [ "$API_ENABLE" = "1" ]; then
    log_info "📊 API giám sát: http://<ip-máy>:$API_PORT/stats (Docker cần -p $API_PORT:$API_PORT)"
fi

launch_miner() {
    log_info "🚀 Lệnh chạy: ${MINER_CMD[*]}"
    # launch_miner luôn được gọi trong subshell nền nên cd ở đây an toàn —
    # chạy trong thư mục binary để file Autotune/log của miner nằm gọn một chỗ.
    # exec để subshell BIẾN THÀNH tiến trình miner => kill MINER_PID khi nhận
    # SIGTERM (docker stop) sẽ tắt đúng miner, không bỏ rơi tiến trình mồ côi.
    cd "$BIN_DIR" 2>/dev/null || true
    exec "${MINER_CMD[@]}"
}

# Chạy miner ở tiến trình nền rồi 'wait' — nhờ vậy script nhận được SIGTERM
# (docker stop) NGAY LẬP TỨC và tắt miner sạch sẽ thay vì bị SIGKILL sau 10s.
run_fg() {
    local rc=0
    launch_miner &
    MINER_PID=$!
    wait "$MINER_PID" || rc=$?
    MINER_PID=""
    return "$rc"
}

ATTEMPT=0
FAST_FAILS=0
DEEP_DIAG_DONE=0

while :; do
    ATTEMPT=$((ATTEMPT + 1))
    if [ "$MAX_RETRIES" -gt 0 ] && [ "$ATTEMPT" -gt "$MAX_RETRIES" ]; then
        die "Đã vượt quá MAX_RETRIES=$MAX_RETRIES lần chạy — dừng hẳn."
    fi

    hr
    log_info "▶️  Lần chạy #$ATTEMPT (script v$SCRIPT_VERSION, miner v$SRB_VERSION, $(date '+%H:%M:%S'))"
    if [ ! -x "$BIN_PATH" ]; then
        dump_file_info "$BIN_PATH"
        die "Binary $BIN_PATH biến mất hoặc mất quyền thực thi giữa chừng!"
    fi

    START_TS=$(date +%s)
    EXIT_CODE=0
    run_fg || EXIT_CODE=$?

    DURATION=$(( $(date +%s) - START_TS ))
    log_warn "⚠️  Miner thoát: Code=$EXIT_CODE sau khi chạy được ${DURATION}s (lần #$ATTEMPT)"
    explain_exit_code "$EXIT_CODE"

    DELAY=$RESTART_DELAY
    if [ "$DURATION" -lt "$MIN_UPTIME" ]; then
        FAST_FAILS=$((FAST_FAILS + 1))
        log_warn "Crash nhanh (chạy <${MIN_UPTIME}s) lần thứ $FAST_FAILS/$FAST_FAIL_LIMIT liên tiếp."
        if [ "$FAST_FAILS" -ge "$FAST_FAIL_LIMIT" ]; then
            if [ "$DEEP_DIAG_DONE" -eq 0 ]; then
                log_error "Crash liên tục $FAST_FAILS lần — chạy chẩn đoán sâu:"
                dump_file_info "$BIN_PATH"
                DEEP_DIAG_DONE=1
            fi
            DELAY=$LONG_RESTART_DELAY
            log_error "Lỗi có vẻ KHÔNG tự hết (crash $FAST_FAILS lần liên tiếp). Giãn thời gian chờ lên ${DELAY}s."
            log_error "Gợi ý: đọc kỹ log [ERROR] phía trên; thử FORCE_REINSTALL=1; kiểm tra '--gpus all' và driver >= $RECOMMENDED_DRIVER."
        fi
    else
        FAST_FAILS=0
        DEEP_DIAG_DONE=0
    fi

    log_info "⏳ Khởi động lại sau ${DELAY}s... (Ctrl+C để dừng hẳn)"
    sleep "$DELAY"
done
