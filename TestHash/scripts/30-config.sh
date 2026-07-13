#!/usr/bin/env bash
# shellcheck shell=bash
# KiQuai module: config
# kiquai-module-api: 1
# kiquai-release: 3.2.4

if [[ "${KIQUAI_MODULE_CONTEXT:-0}" != "1" ]]; then
  printf 'This file is a KiQuai module; run ../run.sh instead.\n' >&2
  return 64 2>/dev/null || exit 64
fi

write_mysql_config() {
  local temp="${MYSQL_CONFIG}.tmp.$$"
  touch "${LOG_DIR}/mysql.log"
  chown mysql:mysql "${LOG_DIR}/mysql.log"
  chmod 640 "${LOG_DIR}/mysql.log"
  cat > "${temp}" <<EOF
[mysqld]
user=mysql
datadir=${MYSQL_DATA_DIR}
socket=${MYSQL_RUN_DIR}/mysqld.sock
pid-file=${MYSQL_RUN_DIR}/mysqld.pid
port=${DB_PORT}
bind-address=127.0.0.1
mysqlx=0
skip-name-resolve
skip-log-bin
max_allowed_packet=1G
log-error=${LOG_DIR}/mysql.log

[client]
socket=${MYSQL_RUN_DIR}/mysqld.sock
port=${DB_PORT}
host=127.0.0.1
EOF
  chown mysql:mysql "${temp}"
  chmod 600 "${temp}"
  mv -f "${temp}" "${MYSQL_CONFIG}"
}

write_php_config() {
  local directory
  for directory in /etc/php/*/apache2/conf.d; do
    [[ -d "${directory}" ]] || continue
    cat > "${directory}/99-kiquai-hashtopolis.ini" <<'EOF'
memory_limit = 512M
upload_max_filesize = 20G
post_max_size = 20G
max_execution_time = 3600
max_input_time = 3600
display_errors = Off
log_errors = On
expose_php = Off
EOF
  done
}

write_apache_config() {
  cat > /etc/apache2/ports.conf <<EOF
Listen 127.0.0.1:${BACKEND_PORT}
EOF
  cat > /etc/apache2/conf-available/kiquai-servername.conf <<'EOF'
ServerName 127.0.0.1
EOF
  a2enconf kiquai-servername >/dev/null
  a2dissite 000-default.conf >/dev/null 2>&1 || true
  cat > /etc/apache2/sites-available/kiquai-hashtopolis.conf <<EOF
<VirtualHost 127.0.0.1:${BACKEND_PORT}>
    ServerName 127.0.0.1
    DocumentRoot "${SERVER_CURRENT}/src"
    ErrorLog "${LOG_DIR}/apache-error.log"
    CustomLog "${LOG_DIR}/apache-access.log" combined

    <Directory "${SERVER_CURRENT}/src">
        Options FollowSymLinks
        AllowOverride None
        Require all granted
        LimitRequestBody 0
    </Directory>

    <Directory "${SERVER_CURRENT}/src/api/v2">
        AllowOverride All
        Require all granted
    </Directory>

    <Directory "${SERVER_CURRENT}/src/install">
        Require all denied
    </Directory>

    Alias /binaries "${HASHTOPOLIS_DATA_DIR}/binaries"
    <Directory "${HASHTOPOLIS_DATA_DIR}/binaries">
        Options FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    Header always set Referrer-Policy "same-origin"
    Header always set X-Frame-Options "DENY"
    Header always set X-Content-Type-Options "nosniff"
    Header unset X-Powered-By
</VirtualHost>
EOF
  a2ensite kiquai-hashtopolis.conf >/dev/null
  write_php_config
  apache2ctl configtest
}

write_frontend_config() {
  local example="${FRONTEND_CURRENT}/dist/assets/config.json.example"
  local target="${FRONTEND_CURRENT}/dist/assets/config.json"
  local temp="${target}.tmp.$$"
  local themes_target="${FRONTEND_CURRENT}/dist/assets/themes/custom-themes.json"
  local themes_temp="${themes_target}.tmp.$$"
  [[ -f "${example}" ]] || die "Frontend config template is missing: ${example}"
  mkdir -p "${FRONTEND_CURRENT}/dist/assets/themes"
  jq --arg backend_url "${HASHTOPOLIS_BACKEND_URL}" \
    '.hashtopolis_backend_url = $backend_url' "${example}" > "${temp}"
  jq -e '.hashtopolis_backend_url | type == "string" and endswith("/api/v2")' \
    "${temp}" >/dev/null || die "Generated frontend config is invalid."
  printf '%s\n' '[]' > "${themes_temp}"
  chown root:www-data "${temp}" "${themes_temp}"
  chmod 640 "${temp}" "${themes_temp}"
  mv -f "${temp}" "${target}"
  mv -f "${themes_temp}" "${themes_target}"
}

write_nginx_config() {
  local temp="${NGINX_CONFIG}.tmp.$$"
  cat > "${temp}" <<EOF
user www-data;
worker_processes auto;
pid ${RUN_DIR}/nginx.pid;
error_log ${LOG_DIR}/nginx-error.log notice;

events {
    worker_connections 2048;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log ${LOG_DIR}/nginx-access.log;
    server_tokens off;
    sendfile on;

    client_max_body_size 20G;
    client_body_timeout 3600s;
    proxy_connect_timeout 30s;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    server {
        listen 0.0.0.0:${INTERNAL_PORT};
        server_name _;
        root ${FRONTEND_CURRENT}/dist;
        index index.html;

        location = /healthz {
            access_log off;
            add_header Content-Type text/plain;
            return 200 "ok\n";
        }

        location ^~ /api/ {
            proxy_pass http://127.0.0.1:${BACKEND_PORT};
            proxy_request_buffering off;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host \$http_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location ^~ /binaries/ {
            proxy_pass http://127.0.0.1:${BACKEND_PORT};
            proxy_request_buffering off;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host \$http_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location ~ \.php\$ {
            proxy_pass http://127.0.0.1:${BACKEND_PORT};
            proxy_request_buffering off;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host \$http_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF
  chmod 640 "${temp}"
  nginx -t -c "${temp}"
  mv -f "${temp}" "${NGINX_CONFIG}"
}

write_runtime_environment() {
  cat > "${RUNTIME_ENV_FILE}" <<'EOF'
#!/usr/bin/env bash
if [[ "${KIQUAI_RUNTIME_CONFIG_LOADED:-0}" != "1" ]]; then
  set -a
  source "__ENV_FILE__"
  set +a
fi

SERVER_CURRENT="${APP_DIR}/current/server"
HASHTOPOLIS_DATA_DIR="${APP_DIR}/data/hashtopolis"
CONFIG_DIR="${APP_DIR}/config"
RUN_DIR="${APP_DIR}/run"
BACKEND_READY_FILE="${RUN_DIR}/backend-ready"
KIQUAI_RUN_ID="$(cat "${RUN_DIR}/current-run-id" 2>/dev/null || printf 'service-restart')"
export PATH="${APP_DIR}/tools/bin:/usr/local/nvidia/bin:${PATH}"
export LD_LIBRARY_PATH="/usr/local/nvidia/lib:/usr/local/nvidia/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export HASHTOPOLIS_DOCUMENT_ROOT="${SERVER_CURRENT}/src"
export HASHTOPOLIS_PATH="${HASHTOPOLIS_DATA_DIR}"
export HASHTOPOLIS_FILES_PATH="${HASHTOPOLIS_DATA_DIR}/files"
export HASHTOPOLIS_IMPORT_PATH="${HASHTOPOLIS_DATA_DIR}/import"
export HASHTOPOLIS_LOG_PATH="${HASHTOPOLIS_DATA_DIR}/log"
export HASHTOPOLIS_CONFIG_PATH="${HASHTOPOLIS_DATA_DIR}/config"
export HASHTOPOLIS_BINARIES_PATH="${HASHTOPOLIS_DATA_DIR}/binaries"
export HASHTOPOLIS_TUS_PATH="${HASHTOPOLIS_DATA_DIR}/tus"
export HASHTOPOLIS_TEMP_UPLOADS_PATH="${HASHTOPOLIS_DATA_DIR}/tus/uploads"
export HASHTOPOLIS_TEMP_META_PATH="${HASHTOPOLIS_DATA_DIR}/tus/meta"
export HASHTOPOLIS_DB_TYPE="mysql"
export HASHTOPOLIS_DB_HOST="127.0.0.1"
export HASHTOPOLIS_DB_PORT="${DB_PORT}"
export HASHTOPOLIS_DB_USER="${MYSQL_USER}"
export HASHTOPOLIS_DB_PASS="${MYSQL_PASSWORD}"
export HASHTOPOLIS_DB_DATABASE="${MYSQL_DATABASE}"
export HASHTOPOLIS_APIV2_ENABLE="1"
export HASHTOPOLIS_ADMIN_USER HASHTOPOLIS_ADMIN_PASSWORD
export HASHTOPOLIS_BACKEND_URL HASHTOPOLIS_FRONTEND_PORT

runtime_log() {
  local level="$1"
  shift
  printf '[%s] %-5s [run=%s] [component=%s] %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S%z')" "${level}" "${KIQUAI_RUN_ID}" \
    "${KIQUAI_COMPONENT:-runtime}" "$*"
}
EOF
  sed -i "s|__ENV_FILE__|${ENV_FILE}|g" "${RUNTIME_ENV_FILE}"
  chmod 700 "${RUNTIME_ENV_FILE}"
}

write_backend_launcher() {
  cat > "${CONFIG_DIR}/start-backend.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source "__RUNTIME_ENV_FILE__"
KIQUAI_COMPONENT="backend"

expected_ready="${HASHTOPOLIS_VERSION}|$(readlink -f "${SERVER_CURRENT}")"
actual_ready="$(cat "${BACKEND_READY_FILE}" 2>/dev/null || true)"
if [[ "${actual_ready}" != "${expected_ready}" ]]; then
  runtime_log ERROR "Backend start refused: the synchronous migration gate is not complete for the active release."
  runtime_log ERROR "Expected marker '${expected_ready}', found '${actual_ready:-missing}'. Run './run.sh deploy'."
  exit 1
fi
if ! runuser -u www-data -- test -w "${SERVER_CURRENT}/src/inc/utils/locks"; then
  runtime_log ERROR "Hashtopolis lock directory is not writable by www-data: ${SERVER_CURRENT}/src/inc/utils/locks"
  exit 1
fi

runtime_log INFO "Starting Apache for Hashtopolis ${HASHTOPOLIS_VERSION}; migrations already completed."
exec /usr/sbin/apache2ctl -DFOREGROUND
EOF
  sed -i "s|__RUNTIME_ENV_FILE__|${RUNTIME_ENV_FILE}|g" "${CONFIG_DIR}/start-backend.sh"
  chmod 700 "${CONFIG_DIR}/start-backend.sh"
}

write_agent_compatibility_wrapper() {
  cat > "${CONFIG_DIR}/agent-wrapper.py" <<'PYEOF'
#!/usr/bin/python3
"""KiQuai compatibility wrapper for the pinned Hashtopolis Python agent."""

from __future__ import annotations

import hashlib
import logging
import os
import platform
import re
import runpy
import shlex
import shutil
import stat
import subprocess
import sys
import time
import uuid
import zipfile
from pathlib import Path
from urllib.parse import urlparse


EXPECTED_AGENT_SHA256 = "7f6f00a9f1983e3d0f2db5f76f3bd8f0ffb20327ed77bb11659bb7740bff4da2"
REQUIRED_AGENT_MEMBERS = {
    "__main__.py",
    "htpclient/binarydownload.py",
    "htpclient/download.py",
    "htpclient/initialize.py",
}
MAX_QUARANTINES = 3
_retry_state: dict[str, tuple[int, float]] = {}


def fail(message: str) -> "NoReturn":
    print(f"KiQuai agent wrapper: {message}", file=sys.stderr)
    raise SystemExit(78)


def validate_archive(archive: Path) -> None:
    try:
        mode = archive.lstat().st_mode
    except OSError as exc:
        fail(f"cannot stat agent archive {archive}: {exc}")
    if not stat.S_ISREG(mode):
        fail(f"agent archive must be a regular, non-symlink file: {archive}")

    digest = hashlib.sha256()
    try:
        with archive.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as exc:
        fail(f"cannot read agent archive {archive}: {exc}")
    actual = digest.hexdigest()
    if actual != EXPECTED_AGENT_SHA256:
        fail(
            "unsupported Hashtopolis agent archive; expected the immutable RC2 "
            f"0.7.4 payload sha256={EXPECTED_AGENT_SHA256}, got sha256={actual}"
        )

    try:
        with zipfile.ZipFile(archive) as package:
            names = set(package.namelist())
            missing = sorted(REQUIRED_AGENT_MEMBERS - names)
            if missing:
                fail("pinned archive is missing required members: " + ", ".join(missing))
            corrupt_member = package.testzip()
            if corrupt_member is not None:
                fail(f"pinned archive failed ZIP integrity at {corrupt_member}")
    except (OSError, zipfile.BadZipFile) as exc:
        fail(f"pinned agent archive is not a valid ZIP application: {exc}")


def parse_wrapper_arguments() -> tuple[Path, bool]:
    if len(sys.argv) >= 2 and sys.argv[1] == "--validate-only":
        if len(sys.argv) != 3:
            fail("usage: agent-wrapper.py --validate-only /path/to/hashtopolis.zip")
        return Path(sys.argv[2]).resolve(), True
    if len(sys.argv) < 2:
        fail("the pinned agent archive path is required")
    return Path(sys.argv[1]).resolve(), False


archive_path, validate_only = parse_wrapper_arguments()
validate_archive(archive_path)

try:
    import psutil  # noqa: F401
    import requests
except ModuleNotFoundError as exc:
    fail(
        f"required Python module {exc.name!r} is unavailable to /usr/bin/python3; "
        "install requests and psutil before starting the agent"
    )

sys.path.insert(0, str(archive_path))
try:
    from htpclient.binarydownload import BinaryDownload
    from htpclient.dicts import (
        copy_and_set_token,
        dict_downloadBinary,
        dict_login,
        dict_register,
        dict_updateInformation,
    )
    from htpclient.download import Download
    from htpclient.hashcat_cracker import HashcatCracker
    from htpclient.helpers import send_error, update_files
    from htpclient.initialize import Initialize
    from htpclient.jsonRequest import JsonRequest
    from htpclient.session import Session
except (ImportError, SyntaxError) as exc:
    fail(f"pinned agent imports failed: {exc}")

if validate_only:
    print(
        "KiQuai agent wrapper validation OK: "
        f"sha256={EXPECTED_AGENT_SHA256}, requests={requests.__version__}"
    )
    raise SystemExit(0)


def redacted_json_execute(self: JsonRequest) -> object:
    """Execute an upstream request without ever logging credentials or responses."""
    action = self.data.get("action", "unknown") if isinstance(self.data, dict) else "unknown"
    try:
        logging.debug("Hashtopolis API request action=%s (payload redacted)", action)
        response = self.session.post(
            self.config.get_value("url"), json=self.data, timeout=30
        )
        if response.status_code != 200:
            logging.error(
                "Hashtopolis API action=%s returned HTTP %s",
                action,
                response.status_code,
            )
            return None
        # Registration responses contain a new token and every response is
        # untrusted server data, so never log the body (including in debug).
        return response.json()
    except Exception as exc:
        # Exception strings may embed a prepared request/body.  Reporting only
        # the type keeps token and voucher values (and encodings) out of logs.
        logging.error(
            "Hashtopolis API action=%s failed (%s)", action, type(exc).__name__
        )
        return None


JsonRequest.execute = redacted_json_execute


def atomic_download(url: str, output: str | os.PathLike[str], no_header: bool = False) -> bool:
    target = Path(output)
    temporary = target.with_name(f".{target.name}.download-{os.getpid()}-{uuid.uuid4().hex}.tmp")
    parsed = urlparse(str(url))
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        logging.error("Refusing binary download from a non-HTTP(S) URL")
        return False

    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        session = Session().s
        if not no_header:
            head = session.head(url, allow_redirects=True, timeout=(10, 30))
            if not head.ok:
                logging.error("File download header returned HTTP %s", head.status_code)
                return False

        with session.get(url, stream=True, allow_redirects=True, timeout=(15, 180)) as response:
            response.raise_for_status()
            expected_length = response.headers.get("Content-Length")
            expected = int(expected_length) if expected_length is not None else None
            written = 0
            with temporary.open("xb") as destination:
                for chunk in response.iter_content(chunk_size=1024 * 1024):
                    if not chunk:
                        continue
                    destination.write(chunk)
                    written += len(chunk)
                destination.flush()
                os.fsync(destination.fileno())
        if written == 0:
            raise OSError("server returned an empty download")
        if expected is not None and written != expected:
            raise OSError(f"download length mismatch (expected {expected}, received {written})")
        os.replace(temporary, target)
        return True
    except (OSError, ValueError, requests.RequestException) as exc:
        # Request exceptions may include a signed URL.  Keep diagnostics useful
        # without copying credentials or query strings into client.log.
        logging.error(
            "Binary download failed without replacing the installed file (%s)",
            type(exc).__name__,
        )
        return False
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            logging.warning("Unable to remove failed download staging file %s: %s", temporary, exc)


Download.download = staticmethod(atomic_download)


def collect_linux_devices(cpu_only: bool) -> list[str]:
    devices: list[str] = []
    packages: dict[tuple[str, str], str] = {}
    try:
        cpuinfo = Path("/proc/cpuinfo").read_text(encoding="utf-8", errors="replace")
        for index, record in enumerate(re.split(r"\n\s*\n", cpuinfo)):
            fields: dict[str, str] = {}
            for line in record.splitlines():
                if ":" not in line:
                    continue
                key, value = line.split(":", 1)
                fields.setdefault(key.strip().lower(), " ".join(value.split()))
            model = fields.get("model name") or fields.get("hardware")
            if not model:
                continue
            package_id = fields.get("physical id") or fields.get("package id") or "0"
            packages.setdefault((package_id, model), model)
        devices.extend(packages.values())
    except OSError as exc:
        logging.warning("Unable to read /proc/cpuinfo; using a platform fallback: %s", exc)

    if not devices:
        fallback = platform.processor().strip() or platform.machine().strip() or "unknown CPU"
        devices.append(fallback)

    if not cpu_only:
        pci_devices: list[str] = []
        lspci = shutil.which("lspci")
        if lspci:
            try:
                result = subprocess.run(
                    [lspci], capture_output=True, text=True, timeout=10, check=False
                )
                for line in result.stdout.splitlines():
                    if "VGA compatible controller" not in line and "3D controller" not in line:
                        continue
                    pci_devices.append(line.split(": ", 1)[-1].strip())
            except (OSError, subprocess.SubprocessError) as exc:
                logging.warning("PCI GPU discovery failed: %s", exc)
        devices.extend(pci_devices)

        # Some containers expose an unrelated virtual VGA device through PCI
        # while hiding the NVIDIA adapter.  Fall back unless PCI itself found
        # NVIDIA, not merely whenever the PCI result is empty.
        if not any("nvidia" in device.lower() for device in pci_devices):
            nvidia_smi = shutil.which("nvidia-smi")
            if nvidia_smi:
                try:
                    result = subprocess.run(
                        [nvidia_smi, "--query-gpu=name", "--format=csv,noheader"],
                        capture_output=True,
                        text=True,
                        timeout=15,
                        check=False,
                    )
                    if result.returncode == 0:
                        devices.extend(line.strip() for line in result.stdout.splitlines() if line.strip())
                    else:
                        logging.warning("nvidia-smi GPU discovery exited with status %s", result.returncode)
                except (OSError, subprocess.SubprocessError) as exc:
                    logging.warning("nvidia-smi GPU discovery failed: %s", exc)

    return list(dict.fromkeys(device for device in devices if device))


def managed_check_token(self: Initialize, args: object) -> None:
    if self.config.get_value("token"):
        return
    delay = 5
    while not self.config.get_value("token"):
        voucher = self.config.get_value("voucher") or getattr(args, "voucher", None)
        if not voucher:
            logging.error(
                "Agent registration is pending but no managed voucher is available"
            )
            time.sleep(delay)
            delay = min(delay * 2, 20)
            continue
        query = dict_register.copy()
        query["voucher"] = voucher
        query["name"] = platform.node()
        if self.config.get_value("cpu-only"):
            query["cpu-only"] = True
        answer = JsonRequest(query).execute()
        if (
            isinstance(answer, dict)
            and answer.get("response") == "SUCCESS"
            and isinstance(answer.get("token"), str)
            and answer["token"]
        ):
            # Persist the identity first.  Never put the voucher, token, or a
            # representation of either into logs.
            self.config.set_value("token", answer["token"])
            self.config.set_value("voucher", "")
            logging.info("Agent registration completed successfully")
            return
        message = answer.get("message", "") if isinstance(answer, dict) else ""
        if "voucher" in str(message).lower():
            logging.error("Agent registration voucher was rejected or expired")
        else:
            logging.error("Agent registration request failed safely")
        time.sleep(delay)
        delay = min(delay * 2, 20)


def managed_login(self: Initialize) -> None:
    delay = 5
    while True:
        token = self.config.get_value("token")
        if not token:
            logging.error("Agent login is waiting for a repaired registration identity")
            time.sleep(delay)
            delay = min(delay * 2, 20)
            continue
        query = copy_and_set_token(dict_login, token)
        query["clientSignature"] = self.get_version()
        answer = JsonRequest(query).execute()
        if isinstance(answer, dict) and answer.get("response") == "SUCCESS":
            logging.info("Login successful")
            version = answer.get("server-version")
            if isinstance(version, str):
                safe_version = re.sub(r"[^A-Za-z0-9._+ -]", "?", version)[:80]
                logging.info("Hashtopolis Server version: %s", safe_version)
            if answer.get("multicastEnabled") and self.get_os() == 0:
                logging.info("Multicast enabled")
                self.config.set_value("multicast", True)
                Path("multicast").mkdir(exist_ok=True)
            return
        message = answer.get("message", "") if isinstance(answer, dict) else ""
        lowered = str(message).lower()
        if "invalid token" in lowered or "token" in lowered and "invalid" in lowered:
            logging.error("Agent login rejected: registration identity is invalid")
        elif "inactive" in lowered or "not active" in lowered:
            logging.error("Agent login rejected: server reports the agent inactive")
        else:
            logging.error("Agent login failed safely; registration identity was preserved")
        time.sleep(delay)
        delay = min(delay * 2, 20)


Initialize._Initialize__check_token = managed_check_token
Initialize._Initialize__login = managed_login


def safe_update_information(self: Initialize) -> None:
    if not self.config.get_value("uuid"):
        self.config.set_value("uuid", str(uuid.uuid4()))
    logging.info("Collecting agent data through the KiQuai compatibility wrapper...")
    devices = collect_linux_devices(bool(self.config.get_value("cpu-only")))
    delay = 5
    while True:
        try:
            query = copy_and_set_token(dict_updateInformation, self.config.get_value("token"))
            query["uid"] = self.config.get_value("uuid")
            query["os"] = self.get_os()
            query["devices"] = devices
            answer = JsonRequest(query).execute()
            if isinstance(answer, dict) and answer.get("response") == "SUCCESS":
                return
            message = answer.get("message", "no response") if isinstance(answer, dict) else "no response"
            if "invalid token" in str(message).lower():
                logging.error("Agent information update rejected: registration identity is invalid")
            else:
                logging.error("Agent information update was rejected safely")
        except Exception as exc:  # upstream network/JSON failures must not crash Supervisor
            logging.error(
                "Agent information update failed transiently (%s)", type(exc).__name__
            )
        logging.info("Retrying agent information update in %s seconds", delay)
        time.sleep(delay)
        # Keep retries below the default 30-second server agent timeout so a
        # live recovering process is not misclassified as dead by status/UI.
        delay = min(delay * 2, 20)


Initialize._Initialize__update_information = safe_update_information


def retry_ready(key: str) -> bool:
    state = _retry_state.get(key)
    if state is None:
        return True
    remaining = state[1] - time.monotonic()
    if remaining > 0:
        time.sleep(min(remaining, 20))
    return time.monotonic() >= state[1]


def retry_failure(key: str, message: str) -> bool:
    failures = _retry_state.get(key, (0, 0.0))[0] + 1
    # Stay below the default server agent timeout while preventing the
    # upstream task loop from hammering getTask during a download outage.
    delay = min(5 * (2 ** min(failures - 1, 2)), 20)
    _retry_state[key] = (failures, time.monotonic() + delay)
    logging.error("%s; retrying in %s seconds", message, delay)
    time.sleep(delay)
    return False


def retry_success(key: str) -> None:
    _retry_state.pop(key, None)


def safe_executable_names(value: object) -> list[str]:
    executable = str(value or "")
    if not re.fullmatch(r"[A-Za-z0-9_.+-]+", executable):
        raise ValueError("server returned an unsafe cracker executable name")
    names = [executable]
    suffix = Path(executable).suffix
    if suffix:
        names.append(f"{Path(executable).stem}64{suffix}")
    else:
        # The RC2 database seeds Prince as `pp`, while the official Linux
        # archive contains pp64.bin.  Keep the declared name first, then the
        # exact variants understood by the 0.7.4 agent.
        names.extend((f"{executable}64", f"{executable}.bin", f"{executable}64.bin"))
    return list(dict.fromkeys(names))


def cache_executable(path: Path, names: list[str], verify_version: bool) -> Path | None:
    if path.is_symlink() or not path.is_dir():
        return None
    try:
        if any(item.is_symlink() for item in path.rglob("*")):
            return None
    except OSError:
        return None
    for name in names:
        executable = path / name
        if not executable.is_file() or executable.stat().st_size == 0 or not os.access(executable, os.X_OK):
            continue
        if verify_version:
            try:
                result = subprocess.run(
                    [str(executable), "--version"],
                    cwd=path,
                    capture_output=True,
                    timeout=30,
                    check=False,
                )
            except (OSError, subprocess.SubprocessError):
                continue
            if result.returncode != 0 or not (result.stdout or result.stderr):
                continue
        return executable
    return None


def remove_path(path: Path) -> None:
    if path.is_symlink() or not path.is_dir():
        path.unlink(missing_ok=True)
    else:
        shutil.rmtree(path)


def ensure_cache_root(root: Path) -> None:
    if os.path.lexists(root):
        if root.is_symlink() or not root.is_dir():
            raise OSError(f"cache root is not a real directory: {root}")
        return
    root.mkdir(parents=True, mode=0o700)


def quarantine_cache(path: Path, root: Path, label: str) -> None:
    quarantine = root / ".kiquai-quarantine"
    if quarantine.is_symlink():
        raise OSError(f"quarantine path is a symlink: {quarantine}")
    quarantine.mkdir(mode=0o700, exist_ok=True)
    destination = quarantine / f"{label}-{int(time.time())}-{uuid.uuid4().hex[:8]}"
    os.replace(path, destination)
    logging.warning("Quarantined incomplete cracker cache %s as %s", path, destination)
    entries = sorted(quarantine.iterdir(), key=lambda item: item.stat().st_mtime, reverse=True)
    for stale in entries[MAX_QUARANTINES:]:
        try:
            remove_path(stale)
        except OSError as exc:
            logging.warning("Unable to prune stale quarantine %s: %s", stale, exc)


def utility_path(name: str) -> Path:
    return Path.cwd() / f"{name}{Initialize.get_os_extension()}"


def valid_utility(path: Path, seven_zip: bool = False) -> bool:
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            return False
        if not os.access(path, os.X_OK):
            return False
        if seven_zip:
            result = subprocess.run(
                [str(path), "i"],
                cwd=path.parent,
                capture_output=True,
                timeout=30,
                check=False,
            )
            if result.returncode != 0 or not (result.stdout or result.stderr):
                return False
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def ensure_utility(self: BinaryDownload, binary_type: str, name: str) -> bool:
    key = f"utility:{binary_type}"
    target = utility_path(name)
    try:
        if valid_utility(target, seven_zip=(binary_type == "7zr")):
            retry_success(key)
            return True
        if os.path.lexists(target):
            quarantine_cache(target, target.parent, f"utility-{binary_type}")
        if not retry_ready(key):
            return False

        query = copy_and_set_token(dict_downloadBinary, self.config.get_value("token"))
        query["type"] = binary_type
        answer = JsonRequest(query).execute()
        if not isinstance(answer, dict) or answer.get("response") != "SUCCESS":
            message = answer.get("message", "no response") if isinstance(answer, dict) else "no response"
            return retry_failure(key, f"Unable to load {binary_type} metadata: {message}")
        url = str(answer.get("executable") or "")
        parsed = urlparse(url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            return retry_failure(key, f"Server returned an invalid {binary_type} download URL")
        if not Download.download(url, target):
            return retry_failure(key, f"Download of {binary_type} did not complete")
        target.chmod(target.stat().st_mode | stat.S_IXUSR)
        if not valid_utility(target, seven_zip=(binary_type == "7zr")):
            if os.path.lexists(target):
                quarantine_cache(target, target.parent, f"utility-{binary_type}")
            return retry_failure(key, f"Downloaded {binary_type} failed executable validation")
        retry_success(key)
        logging.info("Installed and validated utility %s", binary_type)
        return True
    except Exception as exc:
        return retry_failure(
            key, f"Utility {binary_type} preparation failed safely: {type(exc).__name__}"
        )


def hardened_check_utils(self: BinaryDownload) -> bool:
    # BinaryDownload.run() invokes this method only once.  Keep retrying in
    # this live process so a temporary API/CDN outage cannot terminate the
    # agent or let task handling continue without the extractor.
    while not ensure_utility(self, "7zr", "7zr"):
        pass
    if self.config.get_value("multicast"):
        while not ensure_utility(self, "uftpd", "uftpd"):
            pass
    return True


BinaryDownload._BinaryDownload__check_utils = hardened_check_utils


def select_payload_root(extract_root: Path, names: list[str]) -> Path:
    if any(item.is_symlink() for item in extract_root.rglob("*")):
        raise ValueError("cracker archive contains symbolic links")
    if any((extract_root / name).is_file() for name in names):
        return extract_root
    entries = [item for item in extract_root.iterdir() if item.name != "__MACOSX"]
    if len(entries) == 1 and entries[0].is_dir() \
            and any((entries[0] / name).is_file() for name in names):
        return entries[0]
    raise ValueError("archive has an unsupported layout or no declared executable")


def install_archive_payload(
    root: Path,
    target: Path,
    url: str,
    names: list[str],
    verify_version: bool = True,
) -> Path:
    staging = root / f".kiquai-stage-{target.name}-{os.getpid()}-{uuid.uuid4().hex}"
    archive = staging / "payload.7z"
    extracted = staging / "extract"
    try:
        staging.mkdir(mode=0o700)
        extracted.mkdir(mode=0o700)
        if not Download.download(url, archive):
            raise OSError("archive download did not complete")
        seven_zip = utility_path("7zr")
        if not valid_utility(seven_zip, seven_zip=True):
            raise OSError("7zr is missing or failed validation")
        tested = subprocess.run(
            [str(seven_zip), "t", str(archive)],
            capture_output=True,
            timeout=600,
            check=False,
        )
        if tested.returncode != 0:
            raise ValueError(f"7zr archive test failed with status {tested.returncode}")
        unpacked = subprocess.run(
            [str(seven_zip), "x", "-y", f"-o{extracted}", str(archive)],
            capture_output=True,
            timeout=600,
            check=False,
        )
        if unpacked.returncode != 0:
            raise ValueError(f"7zr extraction failed with status {unpacked.returncode}")
        payload = select_payload_root(extracted, names)
        for name in names:
            executable = payload / name
            if executable.is_file():
                executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
        selected = cache_executable(payload, names, verify_version)
        if selected is None:
            raise ValueError("declared executable failed validation or --version")
        selected_name = selected.name
        os.replace(payload, target)
        return target / selected_name
    finally:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)


def hardened_check_version(self: BinaryDownload, cracker_id: object) -> bool:
    identifier = str(cracker_id)
    key = f"cracker:{identifier}"
    if not re.fullmatch(r"[0-9]+", identifier):
        return retry_failure(key, "Server returned an invalid cracker identifier")
    if not retry_ready(key):
        return False

    try:
        query = copy_and_set_token(dict_downloadBinary, self.config.get_value("token"))
        query["type"] = "cracker"
        query["binaryVersionId"] = cracker_id
        answer = JsonRequest(query).execute()
        if not isinstance(answer, dict) or answer.get("response") != "SUCCESS":
            message = answer.get("message", "no response") if isinstance(answer, dict) else "no response"
            return retry_failure(key, f"Unable to load cracker metadata: {message}")
        parsed = urlparse(str(answer.get("url") or ""))
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            return retry_failure(key, "Server returned an invalid cracker download URL")
        names = safe_executable_names(answer.get("executable"))
        self.last_version = answer

        root = Path(self.config.get_value("crackers-path"))
        ensure_cache_root(root)
        target = root / identifier
        verify_version = str(answer.get("name") or "").strip().lower() == "hashcat"
        if cache_executable(target, names, verify_version) is not None:
            retry_success(key)
            return True
        if os.path.lexists(target):
            quarantine_cache(target, root, f"cracker-{identifier}")
        if not ensure_utility(self, "7zr", "7zr"):
            return False
        install_archive_payload(root, target, str(answer["url"]), names, verify_version)
        if cache_executable(target, names, verify_version) is None:
            if os.path.lexists(target):
                quarantine_cache(target, root, f"cracker-{identifier}")
            raise ValueError("atomically installed cracker failed final validation")
        retry_success(key)
        logging.info("Installed and validated cracker binary %s", identifier)
        return True
    except Exception as exc:
        return retry_failure(key, f"Cracker {identifier} preparation failed safely: {exc}")


BinaryDownload.check_version = hardened_check_version


def payload_metadata(
    self: BinaryDownload,
    binary_type: str,
    identifier_field: str,
    identifier: object,
) -> dict[str, object]:
    query = copy_and_set_token(dict_downloadBinary, self.config.get_value("token"))
    query["type"] = binary_type
    query[identifier_field] = identifier
    answer = JsonRequest(query).execute()
    if not isinstance(answer, dict) or answer.get("response") != "SUCCESS":
        message = answer.get("message", "no response") if isinstance(answer, dict) else "no response"
        raise OSError(f"metadata request failed: {message}")
    parsed = urlparse(str(answer.get("url") or ""))
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("server returned an invalid payload download URL")
    # Validate this before any filesystem work.  Architecture variants are
    # accepted only when derived from this safe basename.
    safe_executable_names(answer.get("executable"))
    return answer


def hardened_check_prince(self: BinaryDownload) -> bool:
    # RC2 routes both `prince` and `preprocessor` through Preprocessor id 1;
    # omitting preprocessorId makes the legacy 0.7.4 request fail server-side.
    key = "prince:1"
    if not retry_ready(key):
        return False
    try:
        answer = payload_metadata(self, "prince", "preprocessorId", 1)
        declared = safe_executable_names(answer.get("executable"))
        names = list(dict.fromkeys(["pp64.bin", "pp.bin", *declared]))
        root = Path.cwd()
        ensure_cache_root(root)
        target = root / "prince"
        if cache_executable(target, names, True) is not None:
            retry_success(key)
            return True
        if os.path.lexists(target):
            quarantine_cache(target, root, "prince-1")
        if not ensure_utility(self, "7zr", "7zr"):
            return False
        install_archive_payload(root, target, str(answer["url"]), names, True)
        if cache_executable(target, names, True) is None:
            if os.path.lexists(target):
                quarantine_cache(target, root, "prince-1")
            raise ValueError("atomically installed Prince executable failed final validation")
        retry_success(key)
        logging.info("Installed and validated legacy Prince preprocessor")
        return True
    except Exception as exc:
        return retry_failure(
            key, f"Prince preparation failed safely: {type(exc).__name__}"
        )


def hardened_check_preprocessor(self: BinaryDownload, task: object) -> bool:
    task_data = task.get_task()
    identifier = str(task_data.get("preprocessor", "")) if isinstance(task_data, dict) else ""
    key = f"preprocessor:{identifier or 'invalid'}"
    if not re.fullmatch(r"[0-9]+", identifier):
        return retry_failure(key, "Task returned an invalid preprocessor identifier")
    if not retry_ready(key):
        return False
    try:
        answer = payload_metadata(self, "preprocessor", "preprocessorId", identifier)
        # Preserve upstream semantics: a successful metadata response is made
        # available to Task even when a later transient download fails.
        task.set_preprocessor(answer)
        names = safe_executable_names(answer.get("executable"))
        root = Path(self.config.get_value("preprocessors-path"))
        ensure_cache_root(root)
        target = root / identifier
        selected = cache_executable(target, names, True)
        if selected is None:
            if os.path.lexists(target):
                quarantine_cache(target, root, f"preprocessor-{identifier}")
            if not ensure_utility(self, "7zr", "7zr"):
                return False
            selected = install_archive_payload(root, target, str(answer["url"]), names, True)
        selected = cache_executable(target, names, True)
        if selected is None:
            if os.path.lexists(target):
                quarantine_cache(target, root, f"preprocessor-{identifier}")
            raise ValueError("atomically installed preprocessor failed final validation")

        # The 0.7.4 command builder can derive the wrong architecture name
        # from extensionless RC2 metadata (`pp` -> `64.pp`).  Report the exact
        # validated basename while retaining every other metadata field.
        normalized = dict(answer)
        normalized["executable"] = selected.name
        task.set_preprocessor(normalized)
        retry_success(key)
        logging.info("Installed and validated preprocessor %s", identifier)
        return True
    except Exception as exc:
        return retry_failure(
            key,
            f"Preprocessor {identifier} preparation failed safely: {type(exc).__name__}",
        )


BinaryDownload.check_prince = hardened_check_prince
BinaryDownload.check_preprocessor = hardened_check_preprocessor


def hardened_preprocessor_keyspace(
    self: HashcatCracker, task: object, chunk: object
) -> object:
    preprocessor = task.get_preprocessor()
    task_data = task.get_task()
    if not isinstance(preprocessor, dict) or not isinstance(task_data, dict):
        logging.error("Preprocessor keyspace metadata is unavailable")
        return False
    if preprocessor.get("keyspaceCommand") is None:
        return chunk.send_keyspace(-1, task_data["taskId"])

    identifier = str(task_data.get("preprocessor", ""))
    executable_name = str(preprocessor.get("executable", ""))
    if not re.fullmatch(r"[0-9]+", identifier) or not re.fullmatch(
        r"[A-Za-z0-9_.+-]+", executable_name
    ):
        logging.error("Preprocessor keyspace metadata contains an unsafe identifier")
        send_error(
            "Preprocessor keyspace measure failed!",
            self.config.get_value("token"),
            task_data["taskId"],
            None,
        )
        time.sleep(5)
        return False

    workdir = Path(self.config.get_value("preprocessors-path"), identifier)
    executable = cache_executable(workdir, [executable_name], True)
    if executable is None:
        logging.error("Validated preprocessor executable is no longer available")
        send_error(
            "Preprocessor keyspace measure failed!",
            self.config.get_value("token"),
            task_data["taskId"],
            None,
        )
        time.sleep(5)
        return False

    try:
        keyspace_args = shlex.split(str(preprocessor["keyspaceCommand"]))
        command_args = shlex.split(
            update_files(str(task_data.get("preprocessorCommand", "")))
        )
        result = subprocess.run(
            [str(executable), *keyspace_args, *command_args],
            cwd=workdir,
            capture_output=True,
            timeout=300,
            check=False,
        )
        if result.returncode != 0:
            raise subprocess.CalledProcessError(result.returncode, executable_name)
        lines = result.stdout.decode(encoding="utf-8", errors="replace").splitlines()
        values = [line.strip() for line in lines if line.strip()]
        keyspace = int(values[-1] if values else "0")
    except (OSError, ValueError, subprocess.SubprocessError):
        logging.error("Error during preprocessor keyspace measure")
        send_error(
            "Preprocessor keyspace measure failed!",
            self.config.get_value("token"),
            task_data["taskId"],
            None,
        )
        time.sleep(5)
        return False
    if keyspace > 9000000000000000000:
        return chunk.send_keyspace(-1, task_data["taskId"])
    return chunk.send_keyspace(keyspace, task_data["taskId"])


HashcatCracker.preprocessor_keyspace = hardened_preprocessor_keyspace

# The archive path is removed before upstream argparse sees the managed options.
sys.argv = [str(archive_path), *sys.argv[2:]]
runpy.run_path(str(archive_path), run_name="__main__")
PYEOF
  chmod 700 "${CONFIG_DIR}/agent-wrapper.py"
}

write_agent_launcher() {
  # agent-start can reconcile this launcher without regenerating every other
  # runtime config, so keep its compatibility wrapper in the same operation.
  write_agent_compatibility_wrapper
  cat > "${CONFIG_DIR}/start-agent.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source "__RUNTIME_ENV_FILE__"
KIQUAI_COMPONENT="agent"
# Re-derive this deployment-owned path locally as well as in runtime-env.sh.
# This keeps a newly reconciled launcher compatible with an older persisted
# runtime environment which did not export CONFIG_DIR.
CONFIG_DIR="${APP_DIR}/config"
AGENT_DIR="${APP_DIR}/agent"
AGENT_PROCESS_LOCK="${RUN_DIR}/agent-runtime.lock"
cd "${AGENT_DIR}"

# The upstream Python agent's lock.pid check only verifies that the recorded
# PID belongs to any Python process. A PID reused by Jupyter therefore blocks
# every Supervisor retry. This deployment-owned flock is authoritative and is
# held across exec/agent self-update, while the upstream lock is reconciled
# conservatively before Python starts.
exec 6>"${AGENT_PROCESS_LOCK}"
if ! flock -n 6; then
  runtime_log ERROR "Another KiQuai-managed agent process holds ${AGENT_PROCESS_LOCK}."
  exit 1
fi

reconcile_upstream_agent_lock() {
  local lock_file="${AGENT_DIR}/lock.pid"
  local lock_pid=""
  local process_cwd=""
  local agent_cwd=""
  local process_arg=""
  local has_agent_archive=0

  [[ -e "${lock_file}" ]] || return 0
  if [[ ! -f "${lock_file}" || ! -r "${lock_file}" ]]; then
    runtime_log ERROR "Agent lock exists but is not a readable regular file: ${lock_file}."
    return 1
  fi
  lock_pid="$(tr -d '\r\n' < "${lock_file}")"
  if [[ ! "${lock_pid}" =~ ^[1-9][0-9]*$ ]]; then
    runtime_log WARN "Removing malformed upstream agent lock.pid."
    rm -f -- "${lock_file}"
    return 0
  fi
  if [[ ! -d "/proc/${lock_pid}" ]] || ! kill -0 "${lock_pid}" 2>/dev/null; then
    runtime_log WARN "Removing stale upstream agent lock.pid for exited PID ${lock_pid}."
    rm -f -- "${lock_file}"
    return 0
  fi
  if ! process_cwd="$(readlink -f "/proc/${lock_pid}/cwd" 2>/dev/null)" \
      || [[ -z "${process_cwd}" ]]; then
    runtime_log ERROR "PID ${lock_pid} is alive but its working directory cannot be verified; refusing to remove lock.pid."
    return 1
  fi
  [[ -r "/proc/${lock_pid}/cmdline" ]] || {
    runtime_log ERROR "PID ${lock_pid} is alive but its command line cannot be verified; refusing to remove lock.pid."
    return 1
  }
  while IFS= read -r -d '' process_arg; do
    case "${process_arg}" in
      hashtopolis.zip|"${AGENT_DIR}/hashtopolis.zip")
        has_agent_archive=1
        ;;
    esac
  done < "/proc/${lock_pid}/cmdline"
  agent_cwd="$(readlink -f "${AGENT_DIR}")"
  if [[ "${process_cwd}" == "${agent_cwd}" && "${has_agent_archive}" == "1" ]]; then
    runtime_log ERROR "A live Hashtopolis agent already owns lock.pid (pid=${lock_pid}); refusing to create a duplicate."
    return 1
  fi
  runtime_log WARN "Removing lock.pid whose live PID ${lock_pid} belongs to an unrelated process."
  rm -f -- "${lock_file}"
}

managed_agent_cracker_groups() {
  local own_pgid=""
  local proc_dir=""
  local process_cwd=""
  local process_arg=""
  local process_pgid=""
  local has_hashcat=0
  declare -A seen_groups=()

  own_pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]')"
  for proc_dir in /proc/[0-9]*; do
    [[ -d "${proc_dir}" ]] || continue
    process_cwd="$(readlink -f "${proc_dir}/cwd" 2>/dev/null || true)"
    case "${process_cwd}" in
      "${AGENT_DIR}/crackers"|"${AGENT_DIR}/crackers/"*) ;;
      *) continue ;;
    esac
    [[ -r "${proc_dir}/cmdline" ]] || continue
    has_hashcat=0
    while IFS= read -r -d '' process_arg; do
      [[ "${process_arg}" == *hashcat* ]] && has_hashcat=1
    done < "${proc_dir}/cmdline"
    [[ "${has_hashcat}" == "1" ]] || continue
    process_pgid="$(ps -o pgid= -p "${proc_dir##*/}" 2>/dev/null | tr -d '[:space:]')"
    [[ "${process_pgid}" =~ ^[1-9][0-9]*$ && "${process_pgid}" != "${own_pgid}" ]] \
      || continue
    if [[ -z "${seen_groups[${process_pgid}]:-}" ]]; then
      seen_groups["${process_pgid}"]=1
      printf '%s\n' "${process_pgid}"
    fi
  done
}

cleanup_orphan_agent_crackers() {
  local deadline=0
  local process_pgid=""
  local any_live=0
  local -a groups=()

  mapfile -t groups < <(managed_agent_cracker_groups)
  (( ${#groups[@]} > 0 )) || return 0
  runtime_log WARN "Found ${#groups[@]} orphan Hashcat process group(s) in the managed agent cracker directory; requesting TERM before agent start."
  for process_pgid in "${groups[@]}"; do
    kill -TERM -- "-${process_pgid}" 2>/dev/null || true
  done
  deadline=$((SECONDS + 15))
  while (( SECONDS < deadline )); do
    mapfile -t groups < <(managed_agent_cracker_groups)
    (( ${#groups[@]} == 0 )) && return 0
    sleep 1
  done
  mapfile -t groups < <(managed_agent_cracker_groups)
  for process_pgid in "${groups[@]}"; do
    runtime_log WARN "Hashcat process group ${process_pgid} ignored TERM; sending KILL."
    kill -KILL -- "-${process_pgid}" 2>/dev/null || true
  done
  sleep 1
  mapfile -t groups < <(managed_agent_cracker_groups)
  any_live=${#groups[@]}
  (( any_live == 0 )) || {
    runtime_log ERROR "Unable to terminate ${any_live} orphan managed Hashcat process group(s)."
    return 1
  }
}

for _attempt in $(seq 1 150); do
  [[ -f "${AGENT_DIR}/hashtopolis.zip" ]] && break
  if [[ "${_attempt}" == "150" ]]; then
    runtime_log ERROR "Agent package did not become available."
    exit 1
  fi
  sleep 2
done

reconcile_upstream_agent_lock
cleanup_orphan_agent_crackers

if ! /usr/bin/python3 "${CONFIG_DIR}/agent-wrapper.py" --validate-only \
    "${AGENT_DIR}/hashtopolis.zip"; then
  runtime_log ERROR "The pinned Hashtopolis agent archive or its Python prerequisites failed compatibility validation."
  exit 1
fi

args=(
  /usr/bin/python3 "${CONFIG_DIR}/agent-wrapper.py" "${AGENT_DIR}/hashtopolis.zip"
  --disable-update
  --url "http://127.0.0.1:${INTERNAL_PORT}/api/server.php"
  --files-path "${AGENT_DIR}/files"
  --crackers-path "${AGENT_DIR}/crackers"
  --hashlists-path "${AGENT_DIR}/hashlists"
  --preprocessors-path "${AGENT_DIR}/preprocessors"
  --zaps-path "${AGENT_DIR}/zaps"
)
if [[ -e "${AGENT_DIR}/config.json" ]] \
    && ! jq -e 'type == "object"' "${AGENT_DIR}/config.json" >/dev/null 2>&1; then
  runtime_log ERROR "Agent config.json is not valid JSON; preserve it for inspection, then repair or remove it before re-registration."
  exit 1
fi
if ! jq -e '(.token? | type == "string" and length > 0)' \
    "${AGENT_DIR}/config.json" >/dev/null 2>&1; then
  [[ -n "${AGENT_VOUCHER}" ]] || {
    runtime_log ERROR "No completed agent registration token or AGENT_VOUCHER is available."
    exit 1
  }
  args+=(--voucher "${AGENT_VOUCHER}")
fi
runtime_log INFO "Starting the Hashtopolis Python agent."
exec "${args[@]}"
EOF
  sed -i "s|__RUNTIME_ENV_FILE__|${RUNTIME_ENV_FILE}|g" "${CONFIG_DIR}/start-agent.sh"
  chmod 700 "${CONFIG_DIR}/start-agent.sh"
}

write_supervisor_config() {
  local temp="${SUPERVISOR_CONFIG}.tmp.$$"
  cat > "${temp}" <<EOF
[unix_http_server]
file=${SUPERVISOR_SOCKET}
chmod=0700

[supervisord]
logfile=${LOG_DIR}/supervisord.log
logfile_maxbytes=20MB
logfile_backups=3
pidfile=${SUPERVISOR_PID}
childlogdir=${LOG_DIR}
nodaemon=false
minfds=4096
user=root

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://${SUPERVISOR_SOCKET}

[program:mysql]
command=/usr/sbin/mysqld --defaults-file=${MYSQL_CONFIG}
user=mysql
priority=10
autostart=true
autorestart=true
startsecs=5
startretries=20
stopasgroup=true
killasgroup=true
stopsignal=TERM
stopwaitsecs=60
redirect_stderr=true
stdout_logfile=${LOG_DIR}/mysql-supervisor.log
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=3

[program:backend]
command=/bin/bash ${CONFIG_DIR}/start-backend.sh
user=root
priority=20
autostart=false
autorestart=true
startsecs=5
startretries=3
stopasgroup=true
killasgroup=true
stopsignal=TERM
stopwaitsecs=30
redirect_stderr=true
stdout_logfile=${LOG_DIR}/backend.log
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=3

[program:nginx]
command=/usr/sbin/nginx -c ${NGINX_CONFIG} -g "daemon off;"
user=root
priority=30
autostart=false
autorestart=true
startsecs=5
startretries=20
stopasgroup=true
killasgroup=true
stopsignal=QUIT
stopwaitsecs=20
redirect_stderr=true
stdout_logfile=${LOG_DIR}/nginx-supervisor.log
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=3

[program:agent]
command=/bin/bash ${CONFIG_DIR}/start-agent.sh
directory=${AGENT_DIR}
user=root
environment=PYTHONUNBUFFERED="1"
priority=40
autostart=false
autorestart=unexpected
startsecs=10
startretries=3
stopasgroup=true
killasgroup=true
stopsignal=INT
stopwaitsecs=30
redirect_stderr=true
stdout_logfile=${LOG_DIR}/agent.log
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=3
EOF
  chmod 600 "${temp}"
  mv -f "${temp}" "${SUPERVISOR_CONFIG}"
}

write_runtime_configs() {
  write_mysql_config
  write_apache_config
  write_frontend_config
  write_nginx_config
  write_runtime_environment
  write_backend_launcher
  write_agent_launcher
  write_supervisor_config
}
