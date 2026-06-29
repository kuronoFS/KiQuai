#!/bin/bash
# ============================================================================
#  Pearl (PRL) Miner Launcher — SRBMiner-Multi (repo: doktor83/SRBMiner-Multi)
#  Default Pool: LuckyPool Asia (pearl-sg1.luckypool.io, Singapore)
# ----------------------------------------------------------------------------
#  - Auto-downloads, verifies (MD5/ELF/arch) and runs SRBMiner-MULTI, logs each step.
#  - GPU power limiting is OPTIONAL via environment variables:
#       GPU_POWER_MODE=off|percent|minus|fixed
#       GPU_POWER_MODE=percent GPU_POWER_PERCENT=80      => cap at 80% of default/TDP
#       GPU_POWER_MODE=minus   GPU_POWER_MINUS_W=100     => cap at default/TDP minus 100W
#       GPU_POWER_MODE=fixed   GPU_POWER_LIMIT_W=350     => cap at exactly 350W
#    The limit is read back from nvidia-smi after applying to VERIFY it took effect
#    (needs root / Docker --cap-add SYS_ADMIN to set a power limit).
#    Thermal protection remains available via --gpu-off-temperature (default 90°C).
#  - OPTIONAL working-hours schedule: only mine within a daily HH:MM–HH:MM window:
#       SCHEDULE_ENABLE=1 WORK_START=08:00 WORK_END=22:00 SCHEDULE_TZ=Asia/Bangkok
#       OFFHOURS_MODE=off    => stop the miner and wait until the next WORK_START
#       OFFHOURS_MODE=reduce => keep mining at the lower OFFHOURS_POWER_PERCENT power
#  - All config variables can be overridden via environment variables when running:
#       WALLET=prl1... WORKER=rig02 DEBUG=0 ./run.sh
#       curl -fsSL <url>/run.sh | WORKER=rig02 bash
#  - IMPORTANT: each time you modify this file, INCREMENT SCRIPT_VERSION below
#    so logs clearly show whether you're running old or new code.
# ============================================================================
set -u   # Report error when using undeclared variables
set -E   # Allow ERR trap to work inside functions

# ----------------------------------------------------------------------------
# [SCRIPT VERSION] — increment this number each time you edit the code
# ----------------------------------------------------------------------------
SCRIPT_VERSION="3.2.0"
SCRIPT_BUILD_DATE="2026-06-30"
# CHANGELOG:
#  3.2.0: FIX GPU power limit reliability — capture and surface the real nvidia-smi
#         error (was discarded to /dev/null), READ BACK the enforced limit to verify
#         it actually applied, warn when not running as root, and fall back to
#         max_limit as the base when power.default_limit reports [N/A].
#         ADD optional working-hours scheduler (SCHEDULE_ENABLE): mine only within a
#         daily WORK_START–WORK_END window (SCHEDULE_TZ aware, overnight supported).
#         Off-hours behaviour via OFFHOURS_MODE: 'off' stops the miner and waits for
#         the next WORK_START, 'reduce' lowers power live via OFFHOURS_POWER_* (no
#         restart). Boundaries are checked every SCHEDULE_POLL seconds.
#  3.1.0: ADD optional NVIDIA GPU power limiting before miner launch. Supports
#         percent of default/TDP, default/TDP minus watts, or fixed watts.
#         Controlled by GPU_POWER_MODE=off|percent|minus|fixed.
#  3.0.1: FIX smoke test: '--list-algorithms' of SRBMiner outputs NOTHING when
#         stdout is not a TTY (running in docker) => script wrongly concluded
#         "no pearlhash support" and stopped. Now only WARN and continue.
#         FIX DEFAULT WALLET to correct bech32 format 'prl1...' (old was 'prllp...').
#         DEFAULT WORKER is 'rtx5090'. Add MD5 hashes for 3.3.1 → 3.3.7.
#  3.0.0: SWITCHED to SRBMiner-Multi 3.3.7 (algorithm 'pearlhash') +
#         LuckyPool Asia (pearl-sg1.luckypool.io, failover sg2/eu2).
#         Auto-selects port 3360/3361/3362 based on estimated hashrate (GPU count ×
#         GPU_TH_EST). GPU runs stock unless optional GPU_POWER_MODE is enabled. Monitoring API on port 21550.
#         Removed all launcher/cache/Plan B logic from rgminer and CPU/DUAL modes.
#  2.x  : versions using rgminer + rplant (deprecated).

# ----------------------------------------------------------------------------
# [MINING CONFIGURATION]
# ----------------------------------------------------------------------------
WALLET="${WALLET:-prl1p6l40ns5k4afu7whgzgmmr9jlczuf2n8s96jaej98rfvhzvus35tsz65jk4}"
WORKER="${WORKER:-rtx5090}"
ALGO="${ALGO:-pearlhash}"

# Leave POOL empty = script auto-builds POOL_HOST + failover hosts with port auto-
# selected based on hashrate estimate (see STEP 4). To hardcode, set:
#   POOL="pearl-sg1.luckypool.io:3360"  (multiple pools separated by comma)
POOL="${POOL:-}"
POOL_HOST="${POOL_HOST:-pearl-sg1.luckypool.io}"
POOL_FAILOVER_HOSTS="${POOL_FAILOVER_HOSTS:-pearl-sg2.luckypool.io pearl-eu2.luckypool.io}"
# Estimated TH/s per GPU to select LuckyPool port (RTX 5090 stock ~344-400 TH/s).
# Ports only differ in initial difficulty (vardiff auto-adjusts afterwards):
#   3360: < 500 TH/s | 3361: 500-1000 TH/s | 3362: > 1000 TH/s
GPU_TH_EST="${GPU_TH_EST:-350}"
EXTRA_ARGS="${EXTRA_ARGS:-}"        # Extra arguments for SRBMiner, e.g. "--tls true"

# ----------------------------------------------------------------------------
# [MONITORING / SAFETY] — built-in SRBMiner features, not OC-related
# ----------------------------------------------------------------------------
API_ENABLE="${API_ENABLE:-1}"            # 1 = enable stats API (http://<host>:API_PORT/stats)
API_PORT="${API_PORT:-21550}"
GPU_OFF_TEMP="${GPU_OFF_TEMP:-90}"       # GPU exceeds N°C => miner auto-disables that GPU (0 = disable feature)
NO_SHARE_RESTART="${NO_SHARE_RESTART:-900}"  # Seconds without accepted share => miner auto-restarts (0 = disable)

# ----------------------------------------------------------------------------
# [GPU POWER LIMIT] — optional NVIDIA power cap, applied before miner launch
# ----------------------------------------------------------------------------
# GPU_POWER_MODE options:
#   off     = do not change GPU power limit
#   percent = target = default/TDP × GPU_POWER_PERCENT / 100
#   minus   = target = default/TDP - GPU_POWER_MINUS_W
#   fixed   = target = GPU_POWER_LIMIT_W
#
# Examples:
#   GPU_POWER_MODE=percent GPU_POWER_PERCENT=80 ./run.sh
#   GPU_POWER_MODE=minus GPU_POWER_MINUS_W=100 ./run.sh
#   GPU_POWER_MODE=fixed GPU_POWER_LIMIT_W=350 ./run.sh
#
# Notes:
#   - Values are clamped to each GPU's NVIDIA min/max power-limit range.
#   - In Docker, run with --gpus all and expose NVIDIA utility capability:
#       -e NVIDIA_DRIVER_CAPABILITIES=compute,utility
#   - Setting power limit may require root/admin privileges on the host/container.
GPU_POWER_MODE="${GPU_POWER_MODE:-minus}"
GPU_POWER_PERCENT="${GPU_POWER_PERCENT:-70}"
GPU_POWER_MINUS_W="${GPU_POWER_MINUS_W:-150}"
GPU_POWER_LIMIT_W="${GPU_POWER_LIMIT_W:-}"
GPU_POWER_PERSISTENCE="${GPU_POWER_PERSISTENCE:-1}"

# ----------------------------------------------------------------------------
# [WORKING-HOURS SCHEDULE] — optional: only mine during a daily time window
# ----------------------------------------------------------------------------
# Opt-in (SCHEDULE_ENABLE=1). Define a daily window [WORK_START, WORK_END) in
# 24h HH:MM. Overnight windows (e.g. 22:00 -> 06:00) are supported, and equal
# start/end means run 24/7. The current time is evaluated in SCHEDULE_TZ (or the
# system local time when SCHEDULE_TZ is empty). When OUTSIDE the window,
# OFFHOURS_MODE decides what happens:
#   off    = stop the miner and wait until the next WORK_START
#   reduce = keep mining but apply the lower OFFHOURS_POWER_* limit (live, no restart)
#
# Examples:
#   SCHEDULE_ENABLE=1 WORK_START=08:00 WORK_END=22:00 OFFHOURS_MODE=off SCHEDULE_TZ=Asia/Bangkok ./run.sh
#   SCHEDULE_ENABLE=1 WORK_START=08:00 WORK_END=22:00 OFFHOURS_MODE=reduce OFFHOURS_POWER_PERCENT=40 ./run.sh
SCHEDULE_ENABLE="${SCHEDULE_ENABLE:-1}"      # 1 = enable working-hours scheduling
WORK_START="${WORK_START:-06:00}"            # window start, HH:MM (24h)
WORK_END="${WORK_END:-02:40}"                # window end,   HH:MM (24h)
SCHEDULE_TZ="${SCHEDULE_TZ:-Asia/Bangkok}"               # e.g. Asia/Bangkok; empty = system local time
OFFHOURS_MODE="${OFFHOURS_MODE:-reduce}"        # off = stop & wait | reduce = lower power limit
SCHEDULE_POLL="${SCHEDULE_POLL:-30}"         # seconds between schedule boundary checks (min 5)

# Off-hours reduced power profile — only used when OFFHOURS_MODE=reduce.
# Same semantics as the GPU_POWER_* settings above.
OFFHOURS_POWER_MODE="${OFFHOURS_POWER_MODE:-percent}"
OFFHOURS_POWER_PERCENT="${OFFHOURS_POWER_PERCENT:-40}"
OFFHOURS_POWER_MINUS_W="${OFFHOURS_POWER_MINUS_W:-200}"
OFFHOURS_POWER_LIMIT_W="${OFFHOURS_POWER_LIMIT_W:-}"

# ----------------------------------------------------------------------------
# [MINER CONFIGURATION] — Official SRBMiner-Multi: github.com/doktor83/SRBMiner-Multi
# ----------------------------------------------------------------------------
SRB_VERSION="${SRB_VERSION:-3.3.7}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/srbminer}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"  # 1 = delete old install and re-download from scratch
EXPECTED_MD5="${EXPECTED_MD5:-}"         # Leave empty = auto-apply official MD5 if version known

# Official MD5 hashes announced on release page — only auto-apply when version matches
# (versions supporting pearlhash: 3.3.1 onwards)
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

# Recommended NVIDIA driver for 'pearlhash' (official SRBMiner note);
# RTX 50xx (Blackwell) minimum requires driver branch 570.
RECOMMENDED_DRIVER="580"
MIN_BLACKWELL_DRIVER="570"

# ----------------------------------------------------------------------------
# [DEBUG / RESTART CONFIGURATION]
# ----------------------------------------------------------------------------
DEBUG="${DEBUG:-1}"                            # 1 = show detailed [DEBUG] logs + --extended-log
RESTART_DELAY="${RESTART_DELAY:-5}"            # Seconds to wait between restarts
LONG_RESTART_DELAY="${LONG_RESTART_DELAY:-60}" # Seconds to wait on continuous crashes
MAX_RETRIES="${MAX_RETRIES:-0}"                # Total max run attempts, 0 = unlimited
MIN_UPTIME="${MIN_UPTIME:-20}"                 # Running under N seconds = "fast crash"
FAST_FAIL_LIMIT="${FAST_FAIL_LIMIT:-5}"        # N consecutive fast crashes => deep diagnosis

TOTAL_STEPS=7
VERSION_FILE="$INSTALL_DIR/.installed_version"
TMP_DIR=""
MINER_PID=""
BIN_PATH=""        # determined at STEP 5 (after install/locate binary)
BIN_DIR=""
POOL_LIST=""       # determined at STEP 4 (after GPU count check)
GPU_COUNT=0
SCHED_START_MIN=0  # WORK_START in minutes since midnight (set in STEP 2)
SCHED_END_MIN=0    # WORK_END in minutes since midnight (set in STEP 2)
SCHEDULE_STOP=0    # set to 1 when the miner is intentionally stopped for off-hours
CURRENT_PROFILE="" # "working" | "offhours" — last-applied GPU power profile

# ============================================================================
#  LOGGING FUNCTIONS — every line has timestamp + level for easy tracing
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
log_step()  { echo; echo "${C_CYN}[$(ts)] [STEP $1/$TOTAL_STEPS] ===== $2 =====${C_RST}"; }
hr()        { echo "-------------------------------------------------------------"; }

die() {
    log_error "$*"
    log_error "Script STOPPED here (run.sh v$SCRIPT_VERSION). Fix the issue and run again."
    exit 1
}

# Catch unexpected command failures — print exact line and failed command
trap 'log_error "Command failed unexpectedly at LINE $LINENO: \"$BASH_COMMAND\""' ERR

cleanup() { if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR" 2>/dev/null || true; fi; }
trap cleanup EXIT

on_signal() {
    echo
    log_warn "Received stop signal (Ctrl+C / docker stop) — shutting down miner cleanly..."
    if [ -n "$MINER_PID" ]; then kill "$MINER_PID" 2>/dev/null || true; fi
    wait 2>/dev/null || true
    log_warn "All mining processes stopped."
    exit 130
}
trap on_signal INT TERM

# Allow quick version check: ./run.sh --version
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
    echo "run.sh v$SCRIPT_VERSION (build $SCRIPT_BUILD_DATE)"
    exit 0
fi

# ============================================================================
#  DIAGNOSTIC FUNCTIONS
# ============================================================================

# Read first 4 bytes of file — standard Linux ELF must be "7f 45 4c 46"
# (echo without quotes to consolidate extra whitespace from od)
magic_of() { local m; m=$(od -An -N4 -t x1 "$1" 2>/dev/null) || true; echo $m; }
is_elf()   { [ "$(magic_of "$1")" = "7f 45 4c 46" ]; }

# Read CPU architecture that binary was built for (offset 18 of ELF header)
elf_arch_of() {
    local m
    m=$(od -An -j18 -N2 -t x1 "$1" 2>/dev/null | tr -d ' \n')
    case "$m" in
        3e00) echo "x86_64" ;;
        b700) echo "aarch64" ;;
        0300) echo "i386 (32-bit)" ;;
        *)    echo "unknown (code: $m)" ;;
    esac
}

md5_of()    { md5sum "$1" 2>/dev/null | awk '{print $1}'; }
sha256_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# Compare versions in a.b.c format — version_ge A B means A >= B
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

# Return success if value looks like a positive decimal number.
is_positive_number() {
    awk -v v="$1" 'BEGIN { exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v > 0) }'
}

# Core: apply an NVIDIA power limit using the given policy. Reusable for both the
# normal "working" profile and the reduced "off-hours" profile. This is the most
# reliable way to enforce lower power draw inside Docker (no native GPU-TDP knob).
#   $1 mode   : off|percent|minus|fixed
#   $2 pct    : percent of base   (mode=percent)
#   $3 minus  : watts below base  (mode=minus)
#   $4 fixed  : exact watts       (mode=fixed)
#   $5 label  : human label for logs (e.g. "working", "off-hours")
# Always returns 0 so callers (and the ERR trap) never treat a soft-skip as fatal.
_set_gpu_power_limit() {
    local mode=$1 pct=$2 minus=$3 fixed=$4 label=$5

    if [ "$mode" = "off" ]; then
        log_info "GPU power limit ($label): disabled — using current/default GPU power limit."
        return 0
    fi

    case "$mode" in
        percent|minus|fixed) ;;
        *)
            log_warn "Invalid power mode='$mode' ($label) — use off|percent|minus|fixed. Skipping GPU power limit."
            return 0
            ;;
    esac

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log_warn "Power mode=$mode ($label) requested, but nvidia-smi was not found. Skipping GPU power limit."
        log_warn "Docker hint: run with --gpus all and -e NVIDIA_DRIVER_CAPABILITIES=compute,utility"
        return 0
    fi

    if [ "$mode" = "fixed" ] && [ -z "${fixed:-}" ]; then
        log_warn "Power mode=fixed ($label) requires a fixed watt value (e.g. 350). Skipping GPU power limit."
        return 0
    fi
    if [ "$mode" = "fixed" ] && ! is_positive_number "$fixed"; then
        log_warn "Fixed watt value '$fixed' ($label) is not a positive number. Skipping GPU power limit."
        return 0
    fi
    if [ "$mode" = "percent" ] && ! is_positive_number "$pct"; then
        log_warn "Percent value '$pct' ($label) is not a positive number. Skipping GPU power limit."
        return 0
    fi
    if [ "$mode" = "minus" ] && ! is_positive_number "$minus"; then
        log_warn "Minus-watt value '$minus' ($label) is not a positive number. Skipping GPU power limit."
        return 0
    fi

    # Setting a power limit needs elevated privileges; warn early so a silent
    # permission failure is not mistaken for "power limit not working".
    local uid
    uid=$(id -u 2>/dev/null || echo 0)
    if [ "$uid" -ne 0 ]; then
        log_warn "Not running as root (uid=$uid) — setting a GPU power limit usually requires root."
        log_warn "  Docker hint: add --cap-add SYS_ADMIN (or --privileged) plus -e NVIDIA_DRIVER_CAPABILITIES=compute,utility"
    fi

    if [ "$GPU_POWER_PERSISTENCE" = "1" ]; then
        nvidia-smi -pm ENABLED >/dev/null 2>&1 || \
            log_warn "Could not enable NVIDIA persistence mode. Continuing with power-limit attempt."
    fi

    local query rc
    rc=0
    query=$(nvidia-smi --query-gpu=index,name,power.default_limit,power.min_limit,power.max_limit --format=csv,noheader,nounits 2>&1) || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$query" ]; then
        log_warn "Cannot query GPU power-limit range with nvidia-smi. Output: $query"
        log_warn "Docker hint: add -e NVIDIA_DRIVER_CAPABILITIES=compute,utility"
        return 0
    fi

    log_info "Applying GPU power policy ($label): mode=$mode percent=${pct}% minus=${minus}W fixed=${fixed:-unset}W"

    # Use process substitution (not a pipe) so the counters below live in THIS
    # shell, letting us print an accurate applied/failed summary at the end.
    local total=0 applied=0 failed=0
    while IFS=',' read -r gpu name def min max; do
        [ -n "${gpu:-}" ] || continue
        gpu=$(echo "$gpu" | sed 's/^ *//;s/ *$//')
        name=$(echo "$name" | sed 's/^ *//;s/ *$//')
        def=$(echo "$def" | sed 's/^ *//;s/ *$//')
        min=$(echo "$min" | sed 's/^ *//;s/ *$//')
        max=$(echo "$max" | sed 's/^ *//;s/ *$//')
        total=$((total + 1))

        # Some GPUs/drivers report default_limit as [N/A]; fall back to max_limit
        # as the base for percent/minus so we do not skip the GPU entirely.
        local base="$def"
        if ! is_positive_number "$base"; then
            if is_positive_number "$max"; then
                log_warn "GPU $gpu ($name): default power limit unavailable ('$def') — using max=${max}W as base."
                base="$max"
            else
                log_warn "GPU $gpu ($name): power-limit data unavailable/invalid: default='$def' min='$min' max='$max'. Skipping this GPU."
                failed=$((failed + 1))
                continue
            fi
        fi
        if ! is_positive_number "$min" || ! is_positive_number "$max"; then
            log_warn "GPU $gpu ($name): min/max power-limit invalid: min='$min' max='$max'. Skipping this GPU."
            failed=$((failed + 1))
            continue
        fi

        local target
        target=$(awk \
            -v mode="$mode" \
            -v pct="$pct" \
            -v minus="$minus" \
            -v fixed="$fixed" \
            -v base="$base" \
            -v min="$min" \
            -v max="$max" '
            BEGIN {
                if (mode == "percent")      t = base * pct / 100.0;
                else if (mode == "minus")   t = base - minus;
                else if (mode == "fixed")   t = fixed;
                else exit 1;

                if (t < min) t = min;
                if (t > max) t = max;
                printf "%.0f", t;
            }'
        )

        if [ -z "$target" ] || ! is_positive_number "$target"; then
            log_warn "GPU $gpu ($name): failed to calculate target power limit. Skipping this GPU."
            failed=$((failed + 1))
            continue
        fi

        # Apply the limit, capturing nvidia-smi's real message (the old code
        # threw it away into /dev/null, hiding the actual reason for failure).
        local set_out set_rc=0
        set_out=$(nvidia-smi -i "$gpu" -pl "$target" 2>&1) || set_rc=$?
        if [ "$set_rc" -ne 0 ]; then
            log_warn "GPU $gpu ($name): failed to set power limit to ${target}W (nvidia-smi exit $set_rc)."
            if [ -n "$set_out" ]; then
                echo "$set_out" | while IFS= read -r line; do [ -n "$line" ] && log_warn "    | $line"; done
            fi
            case "$set_out" in
                *"Insufficient Permissions"*|*"permission"*|*"privile"*)
                    log_warn "    => Permission denied: run as root / Docker --cap-add SYS_ADMIN (or --privileged)." ;;
                *"not supported"*|*"Not Supported"*)
                    log_warn "    => This GPU/driver does not support setting a power limit via nvidia-smi." ;;
                *"out of range"*|*"Invalid"*|*"range"*)
                    log_warn "    => Target ${target}W rejected; allowed range is ${min}-${max}W." ;;
            esac
            failed=$((failed + 1))
            continue
        fi

        # Read back the ENFORCED limit to prove it actually changed.
        local enforced verify
        enforced=$(nvidia-smi -i "$gpu" --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -n1 | sed 's/^ *//;s/ *$//')
        if is_positive_number "$enforced"; then
            verify=$(awk -v e="$enforced" -v t="$target" 'BEGIN { d = e - t; if (d < 0) d = -d; print (d <= 2) ? "ok" : "mismatch"; }')
            if [ "$verify" = "ok" ]; then
                log_info "✅ GPU $gpu ($name): power limit set to ${target}W, enforced=${enforced}W (base=${base}W, min=${min}W, max=${max}W)"
                applied=$((applied + 1))
            else
                log_warn "GPU $gpu ($name): requested ${target}W but enforced=${enforced}W — limit did NOT apply as expected (driver clamp / unsupported?)."
                failed=$((failed + 1))
            fi
        else
            log_info "✅ GPU $gpu ($name): power limit set to ${target}W (base=${base}W, min=${min}W, max=${max}W; read-back unavailable)"
            applied=$((applied + 1))
        fi
    done < <(printf '%s\n' "$query")

    if [ "$applied" -gt 0 ]; then
        if [ "$failed" -gt 0 ]; then
            log_info "GPU power ($label): applied to $applied/$total GPU(s), $failed failed — see warnings above."
        else
            log_info "GPU power ($label): applied to all $applied/$total GPU(s)."
        fi
    else
        log_warn "GPU power ($label): could NOT apply to any GPU ($failed/$total failed). Power limit is NOT active — see messages above."
    fi
    return 0
}

# Apply the normal/working GPU power profile (the GPU_POWER_* settings).
apply_gpu_power_limit() {
    _set_gpu_power_limit "$GPU_POWER_MODE" "$GPU_POWER_PERCENT" "$GPU_POWER_MINUS_W" "$GPU_POWER_LIMIT_W" "working"
}

# Apply the reduced off-hours GPU power profile (the OFFHOURS_POWER_* settings).
apply_offhours_power_limit() {
    _set_gpu_power_limit "$OFFHOURS_POWER_MODE" "$OFFHOURS_POWER_PERCENT" "$OFFHOURS_POWER_MINUS_W" "$OFFHOURS_POWER_LIMIT_W" "off-hours"
}

# ============================================================================
#  WORKING-HOURS SCHEDULE HELPERS
# ============================================================================

# Echo the current time (in SCHEDULE_TZ when set, else system local) as minutes
# since midnight. The 10# prefix forces base-10 so values like 08/09 are NOT
# misread as invalid octal by bash arithmetic.
now_minutes() {
    local hm h m
    if [ -n "$SCHEDULE_TZ" ]; then
        hm=$(TZ="$SCHEDULE_TZ" date +'%H %M')
    else
        hm=$(date +'%H %M')
    fi
    h=${hm%% *}; m=${hm##* }
    echo $(( 10#$h * 60 + 10#$m ))
}

# Parse an HH:MM (24h) string into minutes since midnight; echoes -1 if invalid.
hhmm_to_min() {
    case "$1" in
        [0-2][0-9]:[0-5][0-9])
            local h=${1%%:*} m=${1##*:}
            if [ "$((10#$h))" -gt 23 ]; then echo -1; else echo $(( 10#$h * 60 + 10#$m )); fi
            ;;
        *) echo -1 ;;
    esac
}

# Return 0 (true) when 'now' is within the working window, else 1. Handles
# normal (start<end), overnight (start>end) and 24/7 (start==end) windows.
# Call only in if/while conditions so set -E's ERR trap is not tripped.
in_working_hours() {
    if [ "$SCHEDULE_ENABLE" != "1" ]; then return 0; fi
    local now; now=$(now_minutes)
    if [ "$SCHED_START_MIN" -eq "$SCHED_END_MIN" ]; then
        return 0
    elif [ "$SCHED_START_MIN" -lt "$SCHED_END_MIN" ]; then
        [ "$now" -ge "$SCHED_START_MIN" ] && [ "$now" -lt "$SCHED_END_MIN" ]
    else
        [ "$now" -ge "$SCHED_START_MIN" ] || [ "$now" -lt "$SCHED_END_MIN" ]
    fi
}

# Minutes from now until the next WORK_START (0 when now == WORK_START).
minutes_until_work_start() {
    local now; now=$(now_minutes)
    echo $(( (SCHED_START_MIN - now + 1440) % 1440 ))
}

# Block (in SCHEDULE_POLL increments) until we re-enter working hours. Sleeping
# in small slices keeps Ctrl+C / docker stop responsive (the trap interrupts it),
# and a heartbeat every ~5 min keeps logs from going silent for hours.
wait_until_working_hours() {
    local waited=0 next
    next=$(minutes_until_work_start)
    log_info "⏸️  Off-hours (OFFHOURS_MODE=off): miner paused. Next working window in ~${next} min (WORK_START=$WORK_START, ${SCHEDULE_TZ:-system local time})."
    while [ "$SCHEDULE_ENABLE" = "1" ] && ! in_working_hours; do
        sleep "$SCHEDULE_POLL"
        waited=$(( waited + SCHEDULE_POLL ))
        if [ "$waited" -ge 300 ]; then
            next=$(minutes_until_work_start)
            log_info "… still off-hours; next working window in ~${next} min."
            waited=0
        fi
    done
    log_info "▶️  Entered working hours ($WORK_START–$WORK_END, ${SCHEDULE_TZ:-system local time}) — resuming."
}

# Print full information about 1 file to know exactly what it is / where it's broken
dump_file_info() {
    local p=$1
    hr
    log_warn "DEEP DIAGNOSTIC FILE: $p"
    if [ ! -e "$p" ]; then
        log_warn "  -> File DOES NOT EXIST."
        hr
        return 0
    fi
    log_warn "  -> ls -ld : $(ls -ld "$p" 2>&1)"
    if [ -d "$p" ]; then
        log_warn "  -> This is a DIRECTORY, not a file!"
        hr
        return 0
    fi
    log_warn "  -> Size   : $(stat -c %s "$p" 2>/dev/null || echo '?') bytes"
    log_warn "  -> Magic bytes: '$(magic_of "$p")' (standard Linux ELF = '7f 45 4c 46')"
    log_warn "  -> MD5    : $(md5_of "$p")"
    if command -v file >/dev/null 2>&1; then
        log_warn "  -> file(1)    : $(file -b "$p" 2>&1)"
    fi
    if is_elf "$p"; then
        log_warn "  -> Built for  : $(elf_arch_of "$p") | This machine: $(uname -m)"
        if command -v ldd >/dev/null 2>&1; then
            local missing
            missing=$(ldd "$p" 2>&1 | grep "not found" || true)
            if [ -n "$missing" ]; then
                log_warn "  -> MISSING LIBRARIES (reason cannot run):"
                echo "$missing" | while IFS= read -r line; do log_warn "       $line"; done
            else
                log_warn "  -> Libraries  : complete (ldd OK)"
            fi
        fi
    else
        log_warn "  -> NOT a Linux ELF binary => cannot execute."
        log_warn "  -> File header content: $(head -c 200 "$p" 2>/dev/null | tr -cd '[:print:]' | head -c 150)"
    fi
    if [ ! -x "$p" ]; then
        log_warn "  -> File LACKS execute permission (needs chmod +x)."
    fi
    # Check if mount point has noexec flag
    local mp
    mp=$(df -P "$p" 2>/dev/null | awk 'NR==2{print $6}') || true
    if [ -n "${mp:-}" ] && grep -E "[[:space:]]${mp}[[:space:]]" /proc/mounts 2>/dev/null | grep -q noexec; then
        log_warn "  -> Mount point '$mp' is mounted NOEXEC => cannot execute files!"
    fi
    hr
}

# Explain meaning of exit code + suggest fix
explain_exit_code() {
    local code=$1
    case "$code" in
        0)   log_warn "Code=0: miner exited normally — usually due to config error printed above (bad wallet/pool/args) or pool disconnected." ;;
        1)   log_error "Code=1: general error — usually bad arguments, bad wallet/pool, or pool rejected. Read miner log above." ;;
        2)   log_error "Code=2: bad command-line syntax." ;;
        126) log_error "Code=126: file EXISTS but CANNOT EXECUTE (missing +x permission, noexec mount, or corrupted file)." ;;
        127) log_error "Code=127: file not found, or missing dynamic loader/system libraries (glibc too old?)." ;;
        130) log_warn  "Code=130: stopped by Ctrl+C (SIGINT)." ;;
        132) log_error "Code=132 (SIGILL): CPU does not support binary's instruction set — wrong architecture or CPU too old." ;;
        134) log_error "Code=134 (SIGABRT): miner aborted — usually CUDA runtime/driver incompatibility." ;;
        137) log_error "Code=137 (SIGKILL): killed by system — usually out of RAM (OOM killer) or docker stop."
             log_error "  => Check container RAM limit (docker run -m) and available RAM." ;;
        139) log_error "Code=139 (SIGSEGV): miner crashed — usually NVIDIA driver/CUDA incompatibility with GPU." ;;
        143) log_warn  "Code=143: stopped by SIGTERM (docker stop?)." ;;
        *)   log_error "Code=$code: see miner log above for details." ;;
    esac
}

# ============================================================================
#  STEP 1: ENVIRONMENT INFO & VERSION
# ============================================================================
echo "============================================================="
echo "  💎 Pearl (PRL) Miner Launcher — SRBMiner-Multi + LuckyPool"
echo "  📌 SCRIPT VERSION : v$SCRIPT_VERSION (build $SCRIPT_BUILD_DATE)"
echo "============================================================="

log_step 1 "Environment information"

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_SOURCE="file: ${BASH_SOURCE[0]}"
    log_debug "SHA256 of script: $(sha256_of "${BASH_SOURCE[0]}" | head -c 16)..."
else
    SCRIPT_SOURCE="stdin/pipe (e.g.: curl ... | bash)"
fi
log_info "Script source : $SCRIPT_SOURCE"
log_info "Timestamp     : $(date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)')"
if [ "$SCHEDULE_ENABLE" = "1" ] && [ -n "$SCHEDULE_TZ" ]; then
    log_info "Schedule clock: $(TZ="$SCHEDULE_TZ" date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)') ($SCHEDULE_TZ)"
fi
OS_NAME=$(grep -s PRETTY_NAME /etc/os-release | cut -d'"' -f2) || true
log_info "OS            : ${OS_NAME:-$(uname -s)}"
log_info "Kernel / Arch : $(uname -r) / $(uname -m)"
log_info "User          : $(id -un 2>/dev/null || echo '?') (uid=$(id -u 2>/dev/null || echo '?'))"
if [ -f /.dockerenv ] || grep -qs docker /proc/1/cgroup 2>/dev/null; then
    log_info "Container     : Docker (detected)"
else
    log_info "Container     : not detected (running directly on machine)"
fi
log_debug "Bash version  : $BASH_VERSION"
log_debug "CPU cores     : $(nproc 2>/dev/null || echo '?')"
if command -v free >/dev/null 2>&1; then
    log_debug "RAM           : $(free -h | awk 'NR==2{printf "total %s / available %s", $2, $7}')"
fi
log_debug "Disk space    : /tmp = $(df -h /tmp 2>/dev/null | awk 'NR==2{print $4}') free, $INSTALL_DIR = $(df -h "$INSTALL_DIR" 2>/dev/null | awk 'NR==2{print $4}') free"

# ============================================================================
#  STEP 2: CHECK CONFIGURATION
# ============================================================================
log_step 2 "Check configuration"

# Ensure config variables that should be numeric are valid numbers (avoid arithmetic comparison errors)
ensure_number() {
    local name=$1 def=$2 val
    eval "val=\${$name}"
    case "$val" in
        ''|*[!0-9]*)
            log_warn "$name='$val' is not a valid number — using default: $def"
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
ensure_number GPU_POWER_PERCENT 70
ensure_number GPU_POWER_MINUS_W 100
if [ -n "$GPU_POWER_LIMIT_W" ]; then
    ensure_number GPU_POWER_LIMIT_W 0
fi
ensure_number SCHEDULE_POLL 30
ensure_number OFFHOURS_POWER_PERCENT 40
ensure_number OFFHOURS_POWER_MINUS_W 200
if [ -n "$OFFHOURS_POWER_LIMIT_W" ]; then
    ensure_number OFFHOURS_POWER_LIMIT_W 0
fi
if [ "$SCHEDULE_POLL" -lt 5 ]; then
    log_warn "SCHEDULE_POLL=$SCHEDULE_POLL too small — using 5s minimum."
    SCHEDULE_POLL=5
fi

log_info "WALLET        : $WALLET"
log_info "WORKER        : $WORKER"
log_info "ALGO          : $ALGO"
if [ -n "$POOL" ]; then
    log_info "POOL          : $POOL (hardcoded — skip auto port selection)"
else
    log_info "POOL          : (auto-select) $POOL_HOST + failover: $POOL_FAILOVER_HOSTS"
    log_info "                port will be chosen at STEP 4 based on GPU count × ${GPU_TH_EST} TH/s"
fi
if [ "$GPU_POWER_MODE" = "off" ]; then
    log_info "GPU POWER     : off (stock/default power limit)"
elif [ "$GPU_POWER_MODE" = "percent" ]; then
    log_info "GPU POWER     : percent mode — cap at ${GPU_POWER_PERCENT}% of default/TDP"
elif [ "$GPU_POWER_MODE" = "minus" ]; then
    log_info "GPU POWER     : minus mode — cap at default/TDP minus ${GPU_POWER_MINUS_W}W"
elif [ "$GPU_POWER_MODE" = "fixed" ]; then
    log_info "GPU POWER     : fixed mode — cap at ${GPU_POWER_LIMIT_W:-UNSET}W"
else
    log_warn "GPU_POWER_MODE='$GPU_POWER_MODE' is invalid — valid: off|percent|minus|fixed. Will skip power limiting."
fi

# --- Working-hours schedule: validate, precompute the window, then log it ---
if [ "$SCHEDULE_ENABLE" = "1" ]; then
    SCHED_START_MIN=$(hhmm_to_min "$WORK_START")
    SCHED_END_MIN=$(hhmm_to_min "$WORK_END")
    if [ "$SCHED_START_MIN" -lt 0 ] || [ "$SCHED_END_MIN" -lt 0 ]; then
        log_warn "Invalid WORK_START='$WORK_START' or WORK_END='$WORK_END' (need HH:MM 24h) — DISABLING schedule (will mine 24/7)."
        SCHEDULE_ENABLE=0
    fi
fi
if [ "$SCHEDULE_ENABLE" = "1" ]; then
    case "$OFFHOURS_MODE" in
        off|reduce) ;;
        *)  log_warn "Invalid OFFHOURS_MODE='$OFFHOURS_MODE' (need off|reduce) — defaulting to 'off'."
            OFFHOURS_MODE="off" ;;
    esac
    if [ -n "$SCHEDULE_TZ" ] && [ ! -e "/usr/share/zoneinfo/$SCHEDULE_TZ" ]; then
        log_warn "SCHEDULE_TZ='$SCHEDULE_TZ' not found in /usr/share/zoneinfo — 'date' may silently fall back to UTC."
    fi
    if [ "$OFFHOURS_MODE" = "reduce" ] && ! command -v nvidia-smi >/dev/null 2>&1; then
        log_warn "OFFHOURS_MODE=reduce needs nvidia-smi to lower power, but it is missing — off-hours will run at FULL power."
    fi
    if [ "$SCHED_START_MIN" -eq "$SCHED_END_MIN" ]; then
        log_info "SCHEDULE      : enabled — WORK_START == WORK_END => mining 24/7 (window always open)"
    else
        log_info "SCHEDULE      : enabled — mine $WORK_START–$WORK_END (${SCHEDULE_TZ:-system local time})"
    fi
    if [ "$OFFHOURS_MODE" = "off" ]; then
        log_info "                off-hours => STOP miner and wait until next WORK_START"
    elif [ "$OFFHOURS_POWER_MODE" = "percent" ]; then
        log_info "                off-hours => REDUCE power to ${OFFHOURS_POWER_PERCENT}% of base"
    elif [ "$OFFHOURS_POWER_MODE" = "minus" ]; then
        log_info "                off-hours => REDUCE power by ${OFFHOURS_POWER_MINUS_W}W"
    elif [ "$OFFHOURS_POWER_MODE" = "fixed" ]; then
        log_info "                off-hours => REDUCE power to ${OFFHOURS_POWER_LIMIT_W:-UNSET}W (fixed)"
    else
        log_info "                off-hours => REDUCE power (mode=$OFFHOURS_POWER_MODE)"
    fi
    log_debug "Schedule: start_min=$SCHED_START_MIN end_min=$SCHED_END_MIN poll=${SCHEDULE_POLL}s tz=${SCHEDULE_TZ:-local} offhours_mode=$OFFHOURS_MODE"
else
    log_info "SCHEDULE      : disabled (mining 24/7). Enable with SCHEDULE_ENABLE=1 WORK_START=HH:MM WORK_END=HH:MM"
fi
log_info "EXTRA_ARGS    : ${EXTRA_ARGS:-(none)}"
log_info "SRB_VERSION   : $SRB_VERSION"
log_debug "URL_DOWNLOAD  : $URL_DOWNLOAD"
log_debug "EXPECTED_MD5  : ${EXPECTED_MD5:-(skip check)}"
log_debug "INSTALL_DIR   : $INSTALL_DIR"
log_debug "API_ENABLE=$API_ENABLE API_PORT=$API_PORT GPU_OFF_TEMP=${GPU_OFF_TEMP}°C NO_SHARE_RESTART=${NO_SHARE_RESTART}s"
log_debug "GPU_POWER_MODE=$GPU_POWER_MODE GPU_POWER_PERCENT=$GPU_POWER_PERCENT GPU_POWER_MINUS_W=$GPU_POWER_MINUS_W GPU_POWER_LIMIT_W=${GPU_POWER_LIMIT_W:-unset} GPU_POWER_PERSISTENCE=$GPU_POWER_PERSISTENCE"
log_debug "DEBUG=$DEBUG FORCE_REINSTALL=$FORCE_REINSTALL RESTART_DELAY=${RESTART_DELAY}s MAX_RETRIES=$MAX_RETRIES MIN_UPTIME=${MIN_UPTIME}s"

if [ -z "$WALLET" ]; then
    die "WALLET is empty!"
fi
# LuckyPool supports solo mining via "solo:" prefix before wallet address
WALLET_CHECK=${WALLET#solo:}
case "$WALLET_CHECK" in
    prl*) log_debug "Wallet format: 'prl' prefix valid (length ${#WALLET_CHECK} chars)" ;;
    *)    log_warn "Wallet '$WALLET' does not start with 'prl' — verify Pearl wallet address!" ;;
esac
if [ "$WALLET" != "$WALLET_CHECK" ]; then
    log_warn "Detected 'solo:' prefix — you are SOLO mining (take all risk finding blocks, no PPLNS shares)."
fi

if [ "$ALGO" != "pearlhash" ]; then
    log_warn "ALGO='$ALGO' differs from default 'pearlhash' — ensure SRBMiner supports this algorithm?"
fi

# ============================================================================
#  STEP 3: CHECK SYSTEM TOOLS (DEPENDENCIES)
# ============================================================================
log_step 3 "Check system tools"

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
    log_error "Missing tools:$MISSING"
    die "Install with: apt-get update && apt-get install -y wget tar gzip coreutils ca-certificates"
fi

if [ ! -d /etc/ssl/certs ] || [ -z "$(ls -A /etc/ssl/certs 2>/dev/null)" ]; then
    log_warn "No SSL certificates found (/etc/ssl/certs empty) — HTTPS download may fail. Install: apt-get install -y ca-certificates"
fi
for opt_tool in file timeout getent ldd; do
    command -v "$opt_tool" >/dev/null 2>&1 || log_debug "Missing optional tool '$opt_tool' (not required, reduces diagnostics)"
done
log_info "✅ All required tools present (downloader: $DOWNLOADER)"

# ============================================================================
#  STEP 4: CHECK GPU / NVIDIA DRIVER + SELECT POOL/PORT
# ============================================================================
log_step 4 "Check GPU / NVIDIA driver + select pool/port"

if ! command -v nvidia-smi >/dev/null 2>&1; then
    log_warn "nvidia-smi NOT found! GPU miner will almost certainly fail to run."
    log_warn "  If using Docker, container MUST run with: docker run --gpus all ..."
    log_warn "  and host must have nvidia-container-toolkit + NVIDIA driver installed."
else
    GPU_INFO=$(timeout 15 nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1) || true
    if [ -n "$GPU_INFO" ] && ! echo "$GPU_INFO" | grep -qi "failed\|error"; then
        GPU_COUNT=$(echo "$GPU_INFO" | wc -l)
        log_info "✅ Detected $GPU_COUNT GPU(s):"
        echo "$GPU_INFO" | while IFS= read -r line; do log_info "   -> $line"; done

        DRIVER_VER=$(echo "$GPU_INFO" | head -n1 | awk -F',' '{print $2}' | tr -d ' ')

        # Detect GPU generation via compute capability (RTX 50xx/Blackwell = 12.x)
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

        # Check driver: SRBMiner recommends >= 580 for 'pearlhash';
        # RTX 50xx (Blackwell) minimum requires branch 570 to recognize GPU.
        if [ -n "$DRIVER_VER" ]; then
            if [ "$MAX_CAP_MAJOR" -ge 12 ] && ! version_ge "$DRIVER_VER" "$MIN_BLACKWELL_DRIVER"; then
                log_error "RTX 50xx GPU (Blackwell) but host driver = $DRIVER_VER < $MIN_BLACKWELL_DRIVER —"
                log_error "  this driver CANNOT recognize RTX 50xx, miner will not see GPU."
                log_error "  => Update NVIDIA driver on HOST MACHINE (container uses host driver)."
            elif ! version_ge "$DRIVER_VER" "$RECOMMENDED_DRIVER"; then
                log_warn "Driver $DRIVER_VER < $RECOMMENDED_DRIVER — SRBMiner recommends driver >= $RECOMMENDED_DRIVER"
                log_warn "  for 'pearlhash' (old versions caused rejected shares). Still works but upgrade recommended."
            else
                log_info "✅ Driver $DRIVER_VER >= $RECOMMENDED_DRIVER — meets SRBMiner pearlhash recommendation."
            fi
        fi
    else
        log_warn "nvidia-smi exists but run failed: $GPU_INFO"
        log_warn "  => Driver not loaded in container? Check '--gpus all' again."
    fi
fi

# --- Select LuckyPool port based on estimated total hashrate then build pool list ---
if [ -n "$POOL" ]; then
    POOL_LIST="$POOL"
    log_info "Using hardcoded pool: $POOL_LIST"
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
        log_warn "No GPUs detected yet — temporarily using default port 3360 (vardiff will auto-adjust)."
    else
        log_info "Estimated total hashrate: ${GPU_COUNT} GPU × ${GPU_TH_EST} TH/s = ~${EST_TH} TH/s => select port $LUCKY_PORT"
        log_debug "LuckyPool port thresholds: 3360 (<500 TH/s) | 3361 (500-1000) | 3362 (>1000) — only differ in initial difficulty"
    fi
    POOL_LIST="${POOL_HOST}:${LUCKY_PORT}"
    for fh in $POOL_FAILOVER_HOSTS; do
        POOL_LIST="${POOL_LIST},${fh}:${LUCKY_PORT}"
    done
    log_info "Pool list (primary → failover): $POOL_LIST"
fi


# Apply optional NVIDIA power cap after GPU discovery and before miner startup.
# When scheduling is enabled, the correct profile (working vs reduced off-hours)
# is applied inside the STEP 7 mining loop instead, so skip the baseline here.
if [ "$SCHEDULE_ENABLE" != "1" ]; then
    apply_gpu_power_limit
fi

# ============================================================================
#  STEP 5: INSTALL & VERIFY SRBMINER-MULTI
# ============================================================================
log_step 5 "Install & verify SRBMiner-Multi v$SRB_VERSION"

# Thoroughly validate 1 binary; return 0 if usable
validate_binary() {
    local p=$1 ok=1
    if [ ! -e "$p" ]; then log_debug "Validate: $p does not exist"; return 1; fi
    if [ ! -f "$p" ]; then log_error "Validate FAIL: $p is not a regular file (is directory/broken symlink?)"; return 1; fi
    local size
    size=$(stat -c %s "$p" 2>/dev/null || echo 0)
    if [ "$size" -lt 1000000 ]; then
        log_error "Validate FAIL: file too small ($size bytes) — might be error HTML page instead of binary."
        ok=0
    fi
    if ! is_elf "$p"; then
        log_error "Validate FAIL: magic bytes = '$(magic_of "$p")' — not Linux ELF (standard: '7f 45 4c 46')."
        ok=0
    else
        local barch sarch
        barch=$(elf_arch_of "$p"); sarch=$(uname -m)
        if [ "$barch" != "$sarch" ]; then
            log_error "Validate FAIL: binary built for '$barch' but machine is '$sarch' (=> Exec format error)."
            ok=0
        fi
    fi
    [ "$ok" = "1" ] || return 1
    chmod +x "$p" 2>/dev/null || true
    if [ ! -x "$p" ]; then log_error "Validate FAIL: cannot set execute permission (+x) on $p"; return 1; fi
    log_debug "Validate OK: ELF $(elf_arch_of "$p"), $size bytes, md5=$(md5_of "$p")"
    return 0
}

download_file() {
    local url=$1 out=$2 errlog="$TMP_DIR/download.err" rc=0
    log_info "📥 Downloading: $url"
    if [ "$DOWNLOADER" = "wget" ]; then
        wget --tries=3 --connect-timeout=15 --read-timeout=120 -nv -O "$out" "$url" >"$errlog" 2>&1 || rc=$?
    else
        curl -fSL --retry 3 --connect-timeout 15 -o "$out" "$url" >"$errlog" 2>&1 || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        log_error "Download failed ($DOWNLOADER exit code: $rc). Details:"
        while IFS= read -r line; do log_error "   | $line"; done < <(tail -5 "$errlog")
        if grep -qi "404" "$errlog"; then
            log_error "   => Error 404: wrong URL or release filename changed. Check: https://github.com/doktor83/SRBMiner-Multi/releases"
        elif grep -qi "certificate\|ssl" "$errlog"; then
            log_error "   => SSL error: install ca-certificates (apt-get install -y ca-certificates)"
        elif grep -qi "resolve\|unknown host" "$errlog"; then
            log_error "   => DNS error: container cannot resolve github.com — check Docker network/DNS."
        fi
        return 1
    fi
    log_debug "Downloaded: $(stat -c %s "$out" 2>/dev/null) bytes, md5=$(md5_of "$out")"
    return 0
}

# Find SRBMiner-MULTI binary in install directory (tar package has 1 subdirectory)
locate_installed_binary() {
    BIN_PATH=$(find "$INSTALL_DIR" -maxdepth 2 -type f -name "SRBMiner-MULTI" 2>/dev/null | head -n1)
    if [ -n "$BIN_PATH" ]; then
        BIN_DIR=$(dirname "$BIN_PATH")
        return 0
    fi
    return 1
}

install_miner() {
    TMP_DIR=$(mktemp -d /tmp/srbminer.XXXXXX) || die "Cannot create temp directory in /tmp (disk full?)"
    local pkg="$TMP_DIR/pkg.tar.gz"

    download_file "$URL_DOWNLOAD" "$pkg" || die "Cannot download SRBMiner-Multi. See error details above."

    if [ -n "$EXPECTED_MD5" ]; then
        local actual
        actual=$(md5_of "$pkg")
        if [ "$actual" != "$EXPECTED_MD5" ]; then
            log_error "Actual MD5  : $actual"
            log_error "Expected MD5: $EXPECTED_MD5 (published on official release page)"
            dump_file_info "$pkg"
            die "MD5 checksum MISMATCH — downloaded file is not what was expected!"
        fi
        log_info "✅ MD5 checksum matches official release."
    else
        log_warn "No expected MD5 for version '$SRB_VERSION' — skipping checksum (set EXPECTED_MD5 to verify)."
    fi

    log_info "📂 Extracting tar.gz package..."
    mkdir -p "$TMP_DIR/extract"
    tar -xzf "$pkg" -C "$TMP_DIR/extract" 2>"$TMP_DIR/tar.err" || {
        log_error "Extraction failed: $(cat "$TMP_DIR/tar.err")"
        dump_file_info "$pkg"
        die "Downloaded file is not a valid tar.gz package."
    }
    log_debug "Package contents: $(tar -tzf "$pkg" 2>/dev/null | head -10 | tr '\n' ' ')"

    local src_bin
    src_bin=$(find "$TMP_DIR/extract" -type f -name "SRBMiner-MULTI" 2>/dev/null | head -n1)
    if [ -z "$src_bin" ]; then
        log_error "Cannot find 'SRBMiner-MULTI' binary in package. File list:"
        find "$TMP_DIR/extract" -type f | head -20 | while IFS= read -r f; do log_error "   | $f"; done
        die "Package structure is not as expected."
    fi
    if ! validate_binary "$src_bin"; then
        dump_file_info "$src_bin"
        die "Binary in package is INVALID — see diagnostics above."
    fi

    # Clean old installation then move extracted directory into INSTALL_DIR
    rm -rf "${INSTALL_DIR:?}"/* 2>/dev/null || true
    local src_dir
    src_dir=$(dirname "$src_bin")
    mv -f "$src_dir" "$INSTALL_DIR/" || die "Cannot write to $INSTALL_DIR (permission denied?)"
    echo "$SRB_VERSION" > "$VERSION_FILE" 2>/dev/null || true
    rm -rf "$TMP_DIR"; TMP_DIR=""

    locate_installed_binary || die "Install complete but cannot find binary in $INSTALL_DIR?!"
    chmod +x "$BIN_PATH" 2>/dev/null || true
    log_info "✅ SRBMiner-Multi installed to: $BIN_PATH"
}

mkdir -p "$INSTALL_DIR" 2>/dev/null || true
if [ ! -w "$INSTALL_DIR" ]; then
    die "No write permission to '$INSTALL_DIR'. Run as root, or set INSTALL_DIR=\$HOME/srbminer"
fi

INSTALLED_VERSION=""
if [ -f "$VERSION_FILE" ]; then INSTALLED_VERSION=$(head -n1 "$VERSION_FILE" 2>/dev/null | tr -d ' \r\n'); fi

if [ "$FORCE_REINSTALL" = "1" ]; then
    log_warn "FORCE_REINSTALL=1 — deleting old install in $INSTALL_DIR to re-download."
    rm -rf "${INSTALL_DIR:?}"/* "$VERSION_FILE" 2>/dev/null || true
    INSTALLED_VERSION=""
fi

if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" = "$SRB_VERSION" ] && locate_installed_binary && validate_binary "$BIN_PATH"; then
    log_info "✅ SRBMiner-Multi v$INSTALLED_VERSION already valid: $BIN_PATH (set FORCE_REINSTALL=1 to re-download)"
else
    if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" != "$SRB_VERSION" ]; then
        log_info "Old install is v$INSTALLED_VERSION ≠ v$SRB_VERSION required — re-downloading."
    fi
    install_miner
fi

# Light smoke test: just ensure binary CAN EXECUTE on this machine.
# NOTE: SRBMiner usually outputs NOTHING for algorithm list when stdout is not
# a TTY (running in docker/pipe) — so "no pearlhash in output" is NOT an error.
# Only real errors are: binary won't exec / GLIBC missing.
SMOKE_RUNNER=()
if command -v timeout >/dev/null 2>&1; then SMOKE_RUNNER=(timeout 30); fi

log_info "🔬 Running smoke test ($BIN_PATH --list-algorithms)..."
SMOKE_RC=0
SMOKE_OUT=$(cd "$BIN_DIR" && "${SMOKE_RUNNER[@]}" "$BIN_PATH" --list-algorithms 2>&1) || SMOKE_RC=$?

if echo "$SMOKE_OUT" | grep -qi "$ALGO"; then
    log_info "✅ Binary executes and SUPPORTS algorithm '$ALGO'."
    echo "$SMOKE_OUT" | grep -i "$ALGO" | head -3 | while IFS= read -r line; do log_debug "   | $line"; done
elif [ "$SMOKE_RC" -eq 0 ]; then
    log_info "✅ Binary executes successfully (Code=0)."
    log_warn "Miner did not output algorithm list to cross-check '$ALGO' (normal when no TTY,"
    log_warn "  e.g. in docker) — continuing. If algorithm unsupported, miner will report"
    log_warn "  error clearly at STEP 7."
    if [ "$ALGO" = "pearlhash" ] && version_ge "$SRB_VERSION" "3.3.1"; then
        log_info "Cross-reference: SRBMiner v$SRB_VERSION >= 3.3.1 definitely supports 'pearlhash'."
    fi
elif [ "$SMOKE_RC" -eq 124 ]; then
    log_warn "Smoke test timed out after 30s (unusual but not blocking) — continuing."
elif echo "$SMOKE_OUT" | grep -qi "GLIBC"; then
    log_error "Output: $(echo "$SMOKE_OUT" | head -3)"
    die "GLIBC missing — OS/image is too old for this binary. Use Ubuntu 22.04/24.04 (e.g. nvidia/cuda:12.x-base-ubuntu22.04)."
else
    log_error "Smoke test failed (Code=$SMOKE_RC). Output:"
    echo "$SMOKE_OUT" | head -10 | while IFS= read -r line; do log_error "   | $line"; done
    explain_exit_code "$SMOKE_RC"
    dump_file_info "$BIN_PATH"
    die "Binary SRBMiner-MULTI cannot run on this machine — see diagnostics above."
fi

# ============================================================================
#  STEP 6: CHECK POOL CONNECTIVITY
# ============================================================================
log_step 6 "Check pool connectivity"

POOL_OK=0
POOL_ARR=()
IFS=',' read -r -a POOL_ARR <<< "$POOL_LIST" || true
for pool_entry in "${POOL_ARR[@]}"; do
    p_stripped=${pool_entry#*://}
    p_host=${p_stripped%%:*}
    p_port=${p_stripped##*:}
    if [ "$p_host" = "$p_port" ]; then
        log_warn "Pool '$pool_entry' missing port (correct format: host:port)"
        p_port=""
    fi
    if command -v getent >/dev/null 2>&1; then
        p_ips=$(getent hosts "$p_host" 2>/dev/null | awk '{print $1}' | tr '\n' ' ') || true
        if [ -n "${p_ips:-}" ]; then
            log_debug "DNS OK: $p_host -> $p_ips"
        else
            log_warn "Cannot resolve DNS '$p_host' — check Docker network/DNS."
        fi
    fi
    if [ -n "$p_port" ] && command -v timeout >/dev/null 2>&1; then
        if timeout 7 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$p_host" "$p_port" 2>/dev/null; then
            log_info "✅ TCP connection to $p_host:$p_port successful."
            POOL_OK=1
        else
            log_warn "CANNOT connect to $p_host:$p_port (firewall? pool down? wrong port?)"
        fi
    fi
done
if [ "$POOL_OK" -eq 0 ]; then
    log_warn "Could not connect to any pool in list — miner will still launch and retry,"
    log_warn "  but if miner exits immediately, network/firewall is likely the cause."
fi

# ============================================================================
#  STEP 7: MINING LOOP
# ============================================================================
log_step 7 "Start mining loop (SRBMiner-Multi v$SRB_VERSION)"

EXTRA_ARR=()
if [ -n "$EXTRA_ARGS" ]; then read -r -a EXTRA_ARR <<< "$EXTRA_ARGS" || true; fi

# Mining command: no OC flags here. Optional power cap is applied earlier via nvidia-smi.
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
    log_info "📊 Monitoring API: http://<machine-ip>:$API_PORT/stats (Docker requires -p $API_PORT:$API_PORT)"
fi

launch_miner() {
    log_info "🚀 Command: ${MINER_CMD[*]}"
    # launch_miner is always run in a background subshell so cd here is safe —
    # run in binary directory so miner's Autotune/log files stay in one place.
    # exec makes subshell BECOME the miner process => killing MINER_PID when
    # receiving SIGTERM (docker stop) kills the actual miner cleanly, no orphans.
    cd "$BIN_DIR" 2>/dev/null || true
    exec "${MINER_CMD[@]}"
}

# Launch the miner in the background then supervise it. Running in the background
# (instead of in the foreground) means the script still receives SIGTERM (docker
# stop) IMMEDIATELY and can shut the miner down cleanly instead of waiting for the
# SIGKILL timeout.
#
# When scheduling is enabled we poll every SCHEDULE_POLL seconds to react to the
# WORK_START/WORK_END boundary WITHOUT restarting the miner:
#   - leaving working hours + OFFHOURS_MODE=off    => stop miner (SCHEDULE_STOP=1)
#   - leaving working hours + OFFHOURS_MODE=reduce => lower the power limit live
#   - re-entering working hours                    => restore working power live
# When scheduling is disabled this behaves exactly like a plain 'wait'.
run_supervised() {
    local rc=0
    SCHEDULE_STOP=0
    launch_miner &
    MINER_PID=$!

    if [ "$SCHEDULE_ENABLE" != "1" ]; then
        wait "$MINER_PID" || rc=$?
        MINER_PID=""
        return "$rc"
    fi

    while kill -0 "$MINER_PID" 2>/dev/null; do
        if in_working_hours; then
            if [ "$CURRENT_PROFILE" != "working" ]; then
                log_info "🕑 Entered working hours ($WORK_START–$WORK_END) — restoring working power profile."
                apply_gpu_power_limit
                CURRENT_PROFILE="working"
            fi
        elif [ "$OFFHOURS_MODE" = "off" ]; then
            log_warn "🕑 Left working hours — stopping miner (OFFHOURS_MODE=off) until next WORK_START."
            SCHEDULE_STOP=1
            kill "$MINER_PID" 2>/dev/null || true
            break
        else
            if [ "$CURRENT_PROFILE" != "offhours" ]; then
                log_info "🕑 Left working hours — reducing GPU power (OFFHOURS_MODE=reduce)."
                apply_offhours_power_limit
                CURRENT_PROFILE="offhours"
            fi
        fi
        sleep "$SCHEDULE_POLL"
    done

    wait "$MINER_PID" 2>/dev/null || rc=$?
    MINER_PID=""
    return "$rc"
}

ATTEMPT=0
FAST_FAILS=0
DEEP_DIAG_DONE=0

while :; do
    # Schedule gate: when off-hours with OFFHOURS_MODE=off, pause here (no miner
    # running) until the working window opens again.
    if [ "$SCHEDULE_ENABLE" = "1" ] && [ "$OFFHOURS_MODE" = "off" ] && ! in_working_hours; then
        wait_until_working_hours
    fi

    ATTEMPT=$((ATTEMPT + 1))
    if [ "$MAX_RETRIES" -gt 0 ] && [ "$ATTEMPT" -gt "$MAX_RETRIES" ]; then
        die "Exceeded MAX_RETRIES=$MAX_RETRIES attempts — stopping."
    fi

    # Apply the power profile matching the current window. Skip when unchanged so
    # crash-restarts inside the same window do not re-run nvidia-smi needlessly.
    if [ "$SCHEDULE_ENABLE" = "1" ]; then
        if in_working_hours; then
            if [ "$CURRENT_PROFILE" != "working" ]; then apply_gpu_power_limit; CURRENT_PROFILE="working"; fi
        else
            if [ "$CURRENT_PROFILE" != "offhours" ]; then apply_offhours_power_limit; CURRENT_PROFILE="offhours"; fi
        fi
    fi

    hr
    log_info "▶️  Attempt #$ATTEMPT (script v$SCRIPT_VERSION, miner v$SRB_VERSION, $(date '+%H:%M:%S'))"
    if [ ! -x "$BIN_PATH" ]; then
        dump_file_info "$BIN_PATH"
        die "Binary $BIN_PATH disappeared or lost execute permission!"
    fi

    START_TS=$(date +%s)
    EXIT_CODE=0
    run_supervised || EXIT_CODE=$?

    DURATION=$(( $(date +%s) - START_TS ))

    # A scheduled off-hours stop is NOT a crash — skip backoff/diagnostics and
    # loop back to the gate above, which waits for the next working window.
    if [ "$SCHEDULE_STOP" = "1" ]; then
        log_info "⏸️  Miner stopped for off-hours after running ${DURATION}s — waiting for next working window."
        FAST_FAILS=0
        DEEP_DIAG_DONE=0
        continue
    fi

    log_warn "⚠️  Miner exited: Code=$EXIT_CODE after running ${DURATION}s (attempt #$ATTEMPT)"
    explain_exit_code "$EXIT_CODE"

    DELAY=$RESTART_DELAY
    if [ "$DURATION" -lt "$MIN_UPTIME" ]; then
        FAST_FAILS=$((FAST_FAILS + 1))
        log_warn "Fast crash (ran <${MIN_UPTIME}s) #$FAST_FAILS/$FAST_FAIL_LIMIT consecutive."
        if [ "$FAST_FAILS" -ge "$FAST_FAIL_LIMIT" ]; then
            if [ "$DEEP_DIAG_DONE" -eq 0 ]; then
                log_error "Continuous crashes $FAST_FAILS times — running deep diagnostics:"
                dump_file_info "$BIN_PATH"
                DEEP_DIAG_DONE=1
            fi
            DELAY=$LONG_RESTART_DELAY
            log_error "Error appears PERSISTENT (crashed $FAST_FAILS times consecutive). Increasing wait to ${DELAY}s."
            log_error "Hint: read [ERROR] logs above carefully; try FORCE_REINSTALL=1; verify '--gpus all' and driver >= $RECOMMENDED_DRIVER."
        fi
    else
        FAST_FAILS=0
        DEEP_DIAG_DONE=0
    fi

    log_info "⏳ Restarting in ${DELAY}s... (Ctrl+C to stop)"
    sleep "$DELAY"
done
