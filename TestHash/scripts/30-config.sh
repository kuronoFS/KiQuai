#!/usr/bin/env bash
# shellcheck shell=bash
# KiQuai module: config
# kiquai-module-api: 1
# kiquai-release: 3.2.5

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

        # The legacy agent API returns extractor/multicast utility URLs below
        # /static (for example /static/7zr.bin).  These files belong to the
        # Hashtopolis server, not the Angular SPA; allowing try_files to handle
        # them returns index.html with HTTP 200 and blocks the agent before its
        # first getTask poll.
        location ^~ /static/ {
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

write_self_test_helper() {
  local target="${CONFIG_DIR}/self-test.py"
  local temp="${target}.tmp.$$"
  cat > "${temp}" <<'PYEOF'
#!/usr/bin/python3
"""Run one isolated KiQuai WPA/PMKID agent integration test via API v2."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import signal
import stat
import sys
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

try:
    import requests
except ImportError:
    print(
        "[self-test] ERROR: /usr/bin/python3 cannot import the requests module.",
        file=sys.stderr,
        flush=True,
    )
    raise SystemExit(70)


API_BASE = "http://127.0.0.1:__INTERNAL_PORT__/api/v2"
PASSWORD = "KiQuai-22000!"
SSID = "KiQuaiSelfTest"
HC22000 = (
    "WPA*01*86bcdc2ba467ec375e3bf879035280c9*020000000001*"
    "020000000002*4b695175616953656c6654657374***"
)
MARKER_PREFIX = "KIQUAI_SELF_TEST_V1:"
MAX_PRIORITY = 2147483647
MAX_SECURE_JSON_BYTES = 65536
RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
HASHLIST_ALIAS_RE = re.compile(r"^#[A-Za-z0-9_.-]{1,30}#$")
VERSION_RE = re.compile(
    r"^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:[-+][0-9A-Za-z.-]+)?$"
)


class SelfTestError(RuntimeError):
    """Expected, safely printable self-test failure."""


class SelfTestInterrupted(BaseException):
    """Signal-induced interruption which still requires exact cleanup."""


def phase(message: str) -> None:
    print(f"[self-test] {message}", flush=True)


def fail(message: str) -> None:
    raise SelfTestError(message)


def positive_int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        fail(f"API returned an invalid {label}.")
    return value


def exact_mode_600(path: Path, descriptor: str) -> os.stat_result:
    try:
        info = path.lstat()
    except OSError:
        fail(f"Unable to inspect the protected {descriptor} file.")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail(f"The protected {descriptor} path must be a regular, non-symlink file.")
    if stat.S_IMODE(info.st_mode) != 0o600:
        fail(f"The protected {descriptor} file must have mode 0600.")
    if info.st_uid != os.geteuid():
        fail(f"The protected {descriptor} file must be owned by the current user.")
    return info


def read_secure_json(path: Path, descriptor: str) -> dict[str, Any]:
    before = exact_mode_600(path, descriptor)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        fail(f"Unable to open the protected {descriptor} file.")
    try:
        current = os.fstat(fd)
        if (
            not stat.S_ISREG(current.st_mode)
            or stat.S_IMODE(current.st_mode) != 0o600
            or current.st_uid != os.geteuid()
            or current.st_dev != before.st_dev
            or current.st_ino != before.st_ino
        ):
            fail(f"The protected {descriptor} file changed while it was opened.")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(fd, min(8192, MAX_SECURE_JSON_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_SECURE_JSON_BYTES:
                fail(f"The protected {descriptor} file is unexpectedly large.")
    finally:
        os.close(fd)
    try:
        value = json.loads(b"".join(chunks).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail(f"The protected {descriptor} file is not valid UTF-8 JSON.")
    if not isinstance(value, dict):
        fail(f"The protected {descriptor} JSON must be an object.")
    return value


def read_credentials(path: Path) -> tuple[str, str]:
    value = read_secure_json(path, "credentials")
    username = value.get("username")
    password = value.get("password")
    if not isinstance(username, str) or not username or "\x00" in username:
        fail("The credentials JSON has no valid username string.")
    if not isinstance(password, str) or not password or "\x00" in password:
        fail("The credentials JSON has no valid password string.")
    return username, password


def ensure_new_state_path(path: Path) -> None:
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    except OSError:
        fail("Unable to prepare the protected state directory.")
    try:
        parent_info = path.parent.stat()
    except OSError:
        fail("Unable to inspect the protected state directory.")
    if not stat.S_ISDIR(parent_info.st_mode):
        fail("The state parent path is not a directory.")
    if path.exists() or path.is_symlink():
        fail("The requested state file already exists; refusing to overwrite recovery state.")


def write_state(path: Path, value: dict[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}.{uuid.uuid4().hex}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
    fd = -1
    try:
        fd = os.open(temporary, flags, 0o600)
        encoded = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        offset = 0
        while offset < len(encoded):
            offset += os.write(fd, encoded[offset:])
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except OSError:
        fail("Unable to persist protected self-test recovery state.")
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass


def checkpoint(path: Path, state_value: dict[str, Any], current_phase: str) -> None:
    state_value["phase"] = current_phase
    write_state(path, state_value)


def remove_completed_state(path: Path, expected: dict[str, Any]) -> None:
    disk_value = read_secure_json(path, "state")
    if disk_value != expected:
        fail("The protected state file changed; refusing to remove recovery state.")
    try:
        path.unlink()
    except OSError:
        fail("Cleanup completed, but the protected recovery state could not be removed.")


def validate_api_base(value: str) -> str:
    candidate = value.rstrip("/")
    parsed = urlparse(candidate)
    if (
        candidate != API_BASE
        or parsed.scheme != "http"
        or parsed.hostname != "127.0.0.1"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        fail("The self-test API base must be the generated loopback API v2 endpoint.")
    return candidate


class ApiClient:
    def __init__(self, base: str) -> None:
        self.base = base
        self.session = requests.Session()
        self.session.trust_env = False
        self.session.headers.update({"Accept": "application/vnd.api+json"})

    def close(self) -> None:
        self.session.headers.pop("Authorization", None)
        self.session.close()

    def authenticate(self, username: str, password: str) -> None:
        raw = f"{username}:{password}".encode("utf-8")
        basic = base64.b64encode(raw).decode("ascii")
        del raw
        try:
            response = self.session.post(
                f"{self.base}/auth/token",
                headers={"Authorization": f"Basic {basic}"},
                data=None,
                timeout=(5, 30),
                allow_redirects=False,
            )
        except requests.RequestException:
            fail("Authentication request to the loopback API failed.")
        finally:
            del basic
        try:
            if response.status_code != 201:
                fail(f"Authentication failed with HTTP {response.status_code}.")
            try:
                body = response.json()
            except ValueError:
                fail("Authentication returned malformed JSON.")
        finally:
            response.close()
        token = body.get("token") if isinstance(body, dict) else None
        if not isinstance(token, str) or not token:
            fail("Authentication returned no bearer token.")
        self.session.headers["Authorization"] = f"Bearer {token}"

    def request(
        self,
        method: str,
        path: str,
        expected_statuses: tuple[int, ...],
        *,
        body: Any = None,
        send_body: bool = False,
        params: dict[str, Any] | None = None,
    ) -> tuple[int, Any]:
        headers: dict[str, str] = {}
        kwargs: dict[str, Any] = {
            "params": params,
            "headers": headers,
            "timeout": (5, 30),
            "allow_redirects": False,
        }
        if send_body:
            headers["Content-Type"] = "application/vnd.api+json"
            kwargs["json"] = body
        try:
            response = self.session.request(method, f"{self.base}{path}", **kwargs)
        except requests.RequestException:
            fail(f"API request failed at {method} {path}.")
        try:
            status_code = response.status_code
            if status_code not in expected_statuses:
                fail(f"API request {method} {path} returned HTTP {status_code}.")
            if status_code == 204:
                return status_code, None
            try:
                value = response.json()
            except ValueError:
                fail(f"API request {method} {path} returned malformed JSON.")
            return status_code, value
        finally:
            response.close()

    def get(self, path: str, *, params: dict[str, Any] | None = None) -> Any:
        return self.request("GET", path, (200,), params=params)[1]

    def get_optional(self, path: str) -> tuple[int, Any]:
        return self.request("GET", path, (200, 404))

    def post(self, path: str, resource_type: str, attributes: dict[str, Any]) -> Any:
        body = {"data": {"type": resource_type, "attributes": attributes}}
        return self.request("POST", path, (201,), body=body, send_body=True)[1]

    def patch(
        self,
        path: str,
        resource_type: str,
        resource_id: int,
        attributes: dict[str, Any],
    ) -> Any:
        body = {
            "data": {
                "type": resource_type,
                "id": resource_id,
                "attributes": attributes,
            }
        }
        return self.request("PATCH", path, (200,), body=body, send_body=True)[1]

    def delete(self, path: str) -> None:
        self.request("DELETE", path, (204,), body={}, send_body=True)


def resource_from_document(document: Any, expected_type: str, descriptor: str) -> dict[str, Any]:
    resource = document.get("data") if isinstance(document, dict) else None
    if not isinstance(resource, dict) or resource.get("type") != expected_type:
        fail(f"API returned no valid {descriptor} resource.")
    positive_int(resource.get("id"), f"{descriptor} ID")
    if not isinstance(resource.get("attributes"), dict):
        fail(f"API returned invalid {descriptor} attributes.")
    return resource


def resource_list(document: Any, descriptor: str) -> list[dict[str, Any]]:
    data = document.get("data") if isinstance(document, dict) else None
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        fail(f"API returned an invalid {descriptor} list.")
    return data


def agent_assignments(api: ApiClient, agent_id: int) -> list[dict[str, Any]]:
    return resource_list(api.get(f"/ui/agents/{agent_id}/assignments"), "agent assignment")


def require_agent_idle(api: ApiClient, agent_id: int, stage: str) -> None:
    if agent_assignments(api, agent_id):
        fail(f"Agent {agent_id} has an assignment {stage}; no self-test resources were assigned.")


def select_access_group(api: ApiClient, agent_id: int) -> int:
    items = resource_list(api.get(f"/ui/agents/{agent_id}/accessGroups"), "agent access group")
    ids: list[int] = []
    for item in items:
        if item.get("type") != "accessGroup":
            fail("Agent access-group relation returned an unexpected resource type.")
        ids.append(positive_int(item.get("id"), "access-group ID"))
    if not ids:
        fail(f"Agent {agent_id} has no accessible access group.")
    return min(ids)


def select_hashcat(api: ApiClient) -> int:
    items = resource_list(
        api.get("/ui/crackers", params={"page[size]": 500}),
        "cracker binary",
    )
    candidates: list[tuple[tuple[int, int, int], int]] = []
    for item in items:
        attributes = item.get("attributes")
        if (
            item.get("type") == "crackerBinary"
            and isinstance(attributes, dict)
            and attributes.get("binaryName") == "hashcat"
        ):
            version = attributes.get("version")
            download_url = attributes.get("downloadUrl")
            version_match = VERSION_RE.fullmatch(version) if isinstance(version, str) else None
            parsed_url = urlparse(download_url) if isinstance(download_url, str) else None
            if (
                version_match is None
                or int(version_match.group(1)) < 6
                or parsed_url is None
                or parsed_url.scheme not in ("http", "https")
                or not parsed_url.hostname
                or parsed_url.username is not None
                or parsed_url.password is not None
            ):
                continue
            version_key = tuple(
                int(version_match.group(index) or 0) for index in (1, 2, 3)
            )
            candidates.append(
                (version_key, positive_int(item.get("id"), "cracker-binary ID"))
            )
    if not candidates:
        fail(
            "No accessible hashcat cracker with major version >=6 and an HTTP(S) download URL exists."
        )
    return max(candidates)[1]


def select_hashlist_alias(api: ApiClient) -> str:
    items = resource_list(
        api.get("/ui/configs", params={"page[size]": 500}),
        "server configuration",
    )
    aliases: list[str] = []
    for item in items:
        attributes = item.get("attributes")
        if (
            item.get("type") == "config"
            and isinstance(attributes, dict)
            and attributes.get("item") == "hashlistAlias"
            and isinstance(attributes.get("value"), str)
            and attributes["value"]
        ):
            aliases.append(attributes["value"])
    if len(aliases) != 1:
        fail("The API did not return exactly one configured hashlistAlias.")
    if not HASHLIST_ALIAS_RE.fullmatch(aliases[0]):
        fail("The configured hashlistAlias is not a conservative single marker token.")
    return aliases[0]


def verify_created_resource(
    resource: dict[str, Any], expected_type: str, expected_attributes: dict[str, Any], descriptor: str
) -> None:
    if resource.get("type") != expected_type:
        fail(f"Created {descriptor} has an unexpected resource type.")
    attributes = resource.get("attributes")
    if not isinstance(attributes, dict):
        fail(f"Created {descriptor} has invalid attributes.")
    for key, expected in expected_attributes.items():
        if attributes.get(key) != expected:
            fail(f"Created {descriptor} failed exact {key} verification.")


def prepare_resources(
    api: ApiClient,
    agent_id: int,
    run_id: str,
    state_path: Path,
    state_value: dict[str, Any],
) -> int:
    phase("phase 1/8: validating target agent and idle assignment state")
    agent = resource_from_document(api.get(f"/ui/agents/{agent_id}"), "agent", "agent")
    if positive_int(agent.get("id"), "agent ID") != agent_id:
        fail("The API returned a different target agent.")
    agent_attributes = agent["attributes"]
    if agent_attributes.get("isActive") is not True:
        fail(f"Agent {agent_id} is inactive.")
    last_action = agent_attributes.get("lastAct")
    last_time = agent_attributes.get("lastTime")
    if isinstance(last_time, bool) or not isinstance(last_time, int):
        fail(f"Agent {agent_id} has no valid polling heartbeat timestamp.")
    heartbeat_age = int(time.time()) - last_time
    if last_action != "getTask" or heartbeat_age < -5 or heartbeat_age > 30:
        fail(f"Agent {agent_id} does not have a fresh idle getTask poll.")
    cpu_only = agent_attributes.get("cpuOnly")
    if not isinstance(cpu_only, bool):
        fail("The target agent has no valid cpuOnly value.")
    require_agent_idle(api, agent_id, "before preparation")
    access_group_id = select_access_group(api, agent_id)
    cracker_id = select_hashcat(api)
    hashlist_alias = select_hashlist_alias(api)

    marker = f"{MARKER_PREFIX}{run_id}"
    filename = f"kiquai-self-test-{run_id}.txt"
    hashlist_name = f"KiQuai WPA self-test hashes {run_id}"
    task_name = f"KiQuai WPA self-test {run_id}"
    state_value.update({
        "schema": 1,
        "run_id": run_id,
        "marker": marker,
        "agent_id": agent_id,
        "access_group_id": access_group_id,
        "cracker_binary_id": cracker_id,
        "hashlist_alias": hashlist_alias,
        "file": None,
        "hashlist": None,
        "task": None,
        "assignment": None,
        "phase": "preflight",
    })
    checkpoint(state_path, state_value, "preflight-complete")

    phase("phase 2/8: creating isolated inline wordlist")
    file_document = api.post(
        "/ui/files",
        "file",
        {
            "sourceType": "inline",
            "sourceData": base64.b64encode(f"{PASSWORD}\n".encode("utf-8")).decode("ascii"),
            "filename": filename,
            "isSecret": False,
            "fileType": 0,
            "accessGroupId": access_group_id,
        },
    )
    file_resource = resource_from_document(file_document, "file", "file")
    state_value["file"] = {
        "id": positive_int(file_resource.get("id"), "file ID"),
        "filename": filename,
        "access_group_id": access_group_id,
        "deleted": False,
    }
    checkpoint(state_path, state_value, "file-returned")
    verify_created_resource(
        file_resource,
        "file",
        {"filename": filename, "isSecret": False, "fileType": 0, "accessGroupId": access_group_id},
        "wordlist",
    )
    checkpoint(state_path, state_value, "file-created")

    phase("phase 3/8: creating isolated mode-22000 PLAIN hashlist")
    hashlist_document = api.post(
        "/ui/hashlists",
        "hashlist",
        {
            "hashlistSeperator": None,
            "sourceType": "paste",
            "sourceData": base64.b64encode(f"{HC22000}\n".encode("ascii")).decode("ascii"),
            "name": hashlist_name,
            "format": 0,
            "hashTypeId": 22000,
            "hashCount": 0,
            "separator": None,
            "isSecret": False,
            "isHexSalt": False,
            "isSalted": False,
            "accessGroupId": access_group_id,
            "notes": marker,
            "useBrain": False,
            "brainFeatures": 0,
            "isArchived": False,
        },
    )
    hashlist_resource = resource_from_document(hashlist_document, "hashlist", "hashlist")
    state_value["hashlist"] = {
        "id": positive_int(hashlist_resource.get("id"), "hashlist ID"),
        "name": hashlist_name,
        "notes": marker,
        "access_group_id": access_group_id,
        "deleted": False,
    }
    checkpoint(state_path, state_value, "hashlist-returned")
    verify_created_resource(
        hashlist_resource,
        "hashlist",
        {
            "name": hashlist_name,
            "format": 0,
            "hashTypeId": 22000,
            "isSecret": False,
            "accessGroupId": access_group_id,
            "notes": marker,
        },
        "hashlist",
    )
    checkpoint(state_path, state_value, "hashlist-created")

    phase("phase 4/8: creating archived task guard")
    file_id = state_value["file"]["id"]
    hashlist_id = state_value["hashlist"]["id"]
    task_document = api.post(
        "/ui/tasks",
        "task",
        {
            "hashlistId": hashlist_id,
            "files": [file_id],
            "taskName": task_name,
            "attackCmd": f"-a 0 {hashlist_alias} {filename}",
            "chunkTime": 30,
            "statusTimer": 5,
            "priority": 0,
            "maxAgents": 1,
            "color": "",
            "isSmall": True,
            "isCpuTask": cpu_only,
            "useNewBench": True,
            "skipKeyspace": 0,
            "crackerBinaryId": cracker_id,
            "crackerBinaryTypeId": None,
            "isArchived": True,
            "notes": marker,
            "staticChunks": 0,
            "chunkSize": 0,
            "forcePipe": False,
            "preprocessorId": 0,
            "preprocessorCommand": "",
        },
    )
    task_resource = resource_from_document(task_document, "task", "task")
    state_value["task"] = {
        "id": positive_int(task_resource.get("id"), "task ID"),
        "name": task_name,
        "notes": marker,
        "deleted": False,
    }
    checkpoint(state_path, state_value, "guarded-task-returned")
    verify_created_resource(
        task_resource,
        "task",
        {
            "taskName": task_name,
            "priority": 0,
            "maxAgents": 1,
            "isSmall": True,
            "isCpuTask": cpu_only,
            "crackerBinaryId": cracker_id,
            "isArchived": True,
            "notes": marker,
        },
        "guarded task",
    )
    checkpoint(state_path, state_value, "guarded-task-created")

    phase("phase 5/8: assigning the guarded task")
    phase(
        "WARNING: API assignment is not compare-and-swap; a concurrent WebUI assignment can race the final check."
    )
    require_agent_idle(api, agent_id, "immediately before assignment")
    task_id = state_value["task"]["id"]
    assignment_document = api.post(
        "/ui/agentassignments",
        "agentAssignment",
        {"taskId": task_id, "agentId": agent_id, "benchmark": ""},
    )
    assignment_resource = resource_from_document(
        assignment_document, "agentAssignment", "agent assignment"
    )
    state_value["assignment"] = {
        "id": positive_int(assignment_resource.get("id"), "assignment ID"),
        "task_id": task_id,
        "agent_id": agent_id,
    }
    checkpoint(state_path, state_value, "guarded-assignment-returned")
    verify_created_resource(
        assignment_resource,
        "agentAssignment",
        {"taskId": task_id, "agentId": agent_id},
        "agent assignment",
    )
    checkpoint(state_path, state_value, "guarded-task-assigned")

    phase("phase 6/8: atomically releasing the assigned task")
    released_document = api.patch(
        f"/ui/tasks/{task_id}",
        "task",
        task_id,
        {"isArchived": False, "priority": MAX_PRIORITY},
    )
    released_resource = resource_from_document(released_document, "task", "released task")
    verify_created_resource(
        released_resource,
        "task",
        {
            "taskName": task_name,
            "isArchived": False,
            "priority": MAX_PRIORITY,
            "notes": marker,
        },
        "released task",
    )
    assignments = agent_assignments(api, agent_id)
    if not assignments:
        # The legacy getTask poll can discard an assignment while its task is
        # archived. Recheck immediately, then recreate our exact assignment at
        # most once now that the task is released.
        require_agent_idle(api, agent_id, "before the one-time released-task reassignment")
        reassignment_document = api.post(
            "/ui/agentassignments",
            "agentAssignment",
            {"taskId": task_id, "agentId": agent_id, "benchmark": ""},
        )
        reassignment_resource = resource_from_document(
            reassignment_document, "agentAssignment", "released-task reassignment"
        )
        state_value["assignment"] = {
            "id": positive_int(reassignment_resource.get("id"), "reassignment ID"),
            "task_id": task_id,
            "agent_id": agent_id,
        }
        checkpoint(state_path, state_value, "released-reassignment-returned")
        verify_created_resource(
            reassignment_resource,
            "agentAssignment",
            {"taskId": task_id, "agentId": agent_id},
            "released-task reassignment",
        )
        checkpoint(state_path, state_value, "released-task-reassigned-once")
        assignments = agent_assignments(api, agent_id)
    if len(assignments) != 1:
        fail("The target agent does not have exactly one assignment after task release.")
    exact_assignment = assignments[0]
    exact_attributes = exact_assignment.get("attributes")
    if (
        exact_assignment.get("type") != "agentAssignment"
        or positive_int(exact_assignment.get("id"), "assignment ID")
        != state_value["assignment"]["id"]
        or not isinstance(exact_attributes, dict)
        or exact_attributes.get("taskId") != task_id
        or exact_attributes.get("agentId") != agent_id
    ):
        fail("The exact self-test assignment was replaced during the WebUI race window.")
    checkpoint(state_path, state_value, "task-released-and-assignment-verified")
    return task_id


def poll_for_exact_crack(
    api: ApiClient, agent_id: int, task_id: int, timeout: int, interval: float
) -> None:
    phase("phase 7/8: polling for exact crack submission")
    started = time.monotonic()
    deadline = started + timeout
    next_progress = started + 15
    while True:
        document = api.get("/helper/getCracksOfTask", params={"task": task_id})
        cracks = resource_list(document, "task crack")
        plaintexts: list[str] = []
        for item in cracks:
            attributes = item.get("attributes")
            if isinstance(attributes, dict) and isinstance(attributes.get("plaintext"), str):
                plaintexts.append(attributes["plaintext"])
                if attributes["plaintext"] == PASSWORD:
                    if item.get("type") != "hash":
                        fail("The exact plaintext was returned as an unexpected hash resource type.")
                    if attributes.get("hash") != HC22000:
                        fail("The exact plaintext was returned for a different hash value.")
                    chunk_id = positive_int(attributes.get("chunkId"), "crack chunk ID")
                    chunk = resource_from_document(
                        api.get(f"/ui/chunks/{chunk_id}"), "chunk", "crack chunk"
                    )
                    chunk_attributes = chunk["attributes"]
                    if (
                        positive_int(chunk.get("id"), "crack chunk ID") != chunk_id
                        or chunk_attributes.get("taskId") != task_id
                        or chunk_attributes.get("agentId") != agent_id
                    ):
                        fail(
                            "The exact plaintext did not originate from the target agent/task chunk."
                        )
                    phase(
                        "exact fixture plaintext and target agent/task chunk ownership were verified"
                    )
                    phase(
                        f"RESULT plaintext={PASSWORD} hash={HC22000} mode=22000 "
                        f"chunkId={chunk_id} taskId={task_id} agentId={agent_id}"
                    )
                    return
        if plaintexts:
            fail("The self-test task returned a plaintext which did not match the exact fixture.")
        now = time.monotonic()
        if now >= deadline:
            fail(f"Timed out after {timeout}s waiting for the exact self-test crack.")
        if now >= next_progress:
            phase(f"waiting for agent polling/cracking ({int(now - started)}s elapsed)")
            next_progress = now + 15
        time.sleep(min(interval, max(0.0, deadline - now)))


def validate_cleanup_task(resource: dict[str, Any], record: dict[str, Any]) -> None:
    verify_created_resource(
        resource,
        "task",
        {"taskName": record["name"], "notes": record["notes"]},
        "cleanup task",
    )


def validate_cleanup_file(resource: dict[str, Any], record: dict[str, Any]) -> None:
    verify_created_resource(
        resource,
        "file",
        {
            "filename": record["filename"],
            "fileType": 0,
            "isSecret": False,
            "accessGroupId": record["access_group_id"],
        },
        "cleanup file",
    )


def validate_cleanup_hashlist(resource: dict[str, Any], record: dict[str, Any]) -> None:
    verify_created_resource(
        resource,
        "hashlist",
        {
            "name": record["name"],
            "notes": record["notes"],
            "format": 0,
            "hashTypeId": 22000,
            "accessGroupId": record["access_group_id"],
        },
        "cleanup hashlist",
    )


def delete_exact_resource(
    api: ApiClient,
    state_path: Path,
    state_value: dict[str, Any],
    key: str,
    endpoint: str,
    expected_type: str,
    validator: Any,
    require_empty_relation: str | None = None,
) -> None:
    record = state_value.get(key)
    if record is None:
        return
    if not isinstance(record, dict):
        fail(f"Recovery state contains invalid {key} metadata.")
    if record.get("deleted") is True:
        return
    resource_id = positive_int(record.get("id"), f"cleanup {key} ID")
    status_code, document = api.get_optional(f"{endpoint}/{resource_id}")
    if status_code == 200:
        resource = resource_from_document(document, expected_type, f"cleanup {key}")
        if positive_int(resource.get("id"), f"cleanup {key} ID") != resource_id:
            fail(f"Cleanup {key} lookup returned a different ID.")
        validator(resource, record)
        if require_empty_relation is not None:
            related = resource_list(
                api.get(f"{endpoint}/{resource_id}/{require_empty_relation}"),
                f"cleanup {key} {require_empty_relation} relation",
            )
            if related:
                fail(
                    f"Cleanup refused: exact {key} ID {resource_id} acquired a related "
                    f"{require_empty_relation} resource. Recovery state was retained."
                )
        api.delete(f"{endpoint}/{resource_id}")
        confirmation, _ = api.get_optional(f"{endpoint}/{resource_id}")
        if confirmation != 404:
            fail(f"Cleanup could not confirm deletion of exact {key} ID {resource_id}.")
    record["deleted"] = True
    checkpoint(state_path, state_value, f"{key}-deleted")


def cleanup_resources(api: ApiClient, state_path: Path, state_value: dict[str, Any]) -> None:
    phase("phase 8/8: cleaning exact self-test resources")
    # Never DELETE an assignment: RC2 deletion unassigns the whole agent. Deleting
    # the exact marked task first lets TaskUtils remove only that task's assignment.
    delete_exact_resource(
        api, state_path, state_value, "task", "/ui/tasks", "task", validate_cleanup_task
    )
    delete_exact_resource(
        api, state_path, state_value, "file", "/ui/files", "file", validate_cleanup_file
    )
    delete_exact_resource(
        api,
        state_path,
        state_value,
        "hashlist",
        "/ui/hashlists",
        "hashlist",
        validate_cleanup_hashlist,
        "tasks",
    )
    checkpoint(state_path, state_value, "cleanup-complete")
    remove_completed_state(state_path, state_value)
    phase("cleanup completed; protected recovery state removed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the KiQuai WPA mode-22000 agent self-test.")
    parser.add_argument("--api-base", required=True)
    parser.add_argument("--agent-id", required=True, type=int)
    parser.add_argument("--timeout", required=True, type=int)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--credentials-file", required=True, type=Path)
    parser.add_argument("--state-file", required=True, type=Path)
    parser.add_argument("--poll-interval", type=float, default=3.0, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.agent_id <= 0:
        parser.error("--agent-id must be positive")
    if args.timeout < 30 or args.timeout > 1800:
        parser.error("--timeout must be from 30 to 1800 seconds")
    if not RUN_ID_RE.fullmatch(args.run_id):
        parser.error("--run-id contains unsupported characters or is too long")
    if args.poll_interval < 0.1 or args.poll_interval > 30:
        parser.error("--poll-interval must be from 0.1 to 30 seconds")
    return args


def install_signal_handlers() -> None:
    def interrupted(signum: int, _frame: Any) -> None:
        raise SelfTestInterrupted(signum)

    signal.signal(signal.SIGTERM, interrupted)
    if hasattr(signal, "SIGHUP"):
        signal.signal(signal.SIGHUP, interrupted)


def ignore_cleanup_interrupts() -> None:
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if hasattr(signal, "SIGHUP"):
        signal.signal(signal.SIGHUP, signal.SIG_IGN)


def main() -> int:
    args = parse_args()
    install_signal_handlers()
    state_value: dict[str, Any] | None = None
    state_path = args.state_file
    api: ApiClient | None = None
    exit_code = 1
    interrupted = False
    try:
        api_base = validate_api_base(args.api_base)
        ensure_new_state_path(state_path)
        if args.credentials_file.resolve() == state_path.resolve():
            fail("Credentials and recovery state must use different files.")
        phase("authenticating to loopback API v2")
        username, password = read_credentials(args.credentials_file)
        api = ApiClient(api_base)
        api.authenticate(username, password)
        del username, password
        state_value = {}
        task_id = prepare_resources(
            api, args.agent_id, args.run_id, state_path, state_value
        )
        poll_for_exact_crack(api, args.agent_id, task_id, args.timeout, args.poll_interval)
        exit_code = 0
    except KeyboardInterrupt:
        interrupted = True
        exit_code = 130
        phase("interrupted; exact cleanup will be attempted")
    except SelfTestInterrupted:
        interrupted = True
        exit_code = 143
        phase("termination signal received; exact cleanup will be attempted")
    except SelfTestError as exc:
        phase(f"ERROR: {exc}")
        exit_code = 1
    except Exception as exc:
        phase(f"ERROR: unexpected {type(exc).__name__}; exact cleanup will be attempted")
        exit_code = 1
    finally:
        if api is not None and state_value is not None and state_path.exists():
            ignore_cleanup_interrupts()
            try:
                cleanup_resources(api, state_path, state_value)
            except SelfTestError as exc:
                phase(f"ERROR: cleanup failed: {exc}")
                exit_code = 1
            except Exception as exc:
                phase(f"ERROR: cleanup failed with unexpected {type(exc).__name__}")
                exit_code = 1
        if api is not None:
            api.close()
    if exit_code == 0:
        phase("PASS: exact mode-22000 fixture cracked and all resources cleaned")
    elif interrupted and exit_code not in (130, 143):
        phase("interrupted and cleanup did not complete; recovery state was retained")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
PYEOF
  sed -i "s|__INTERNAL_PORT__|${INTERNAL_PORT}|g" "${temp}"
  chmod 700 "${temp}"
  mv -f "${temp}" "${target}"
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
    # BinaryDownload.run() is executed before the upstream getTask loop.  An
    # extractor download must therefore not gate the first heartbeat/poll:
    # task preparation below re-validates 7zr before any archive can be used.
    seven_zip = utility_path("7zr")
    if not valid_utility(seven_zip, seven_zip=True):
        logging.info("Deferring 7zr preparation until the first assigned task")
    if self.config.get_value("multicast"):
        # uftpd is different: upstream starts it immediately after run().
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
        # This is the first task-dependent preparation step.  Requiring the
        # extractor here lets the idle agent poll/claim an assignment first,
        # while still preventing cracker or task-file extraction without a
        # validated 7zr binary.
        if not ensure_utility(self, "7zr", "7zr"):
            return False
        if cache_executable(target, names, verify_version) is not None:
            retry_success(key)
            return True
        if os.path.lexists(target):
            quarantine_cache(target, root, f"cracker-{identifier}")
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
  write_self_test_helper
  write_agent_launcher
  write_supervisor_config
}
