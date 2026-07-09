# TestHash

This folder contains `run.sh`, a script that automatically provisions a self-hosted **[Hashtopolis](https://github.com/hashtopolis/server)** stack (a distributed hashcat cracking task management platform) using Docker Compose. It is designed to be run on a GPU rental instance (e.g. [Vast.ai](https://vast.ai/)) but works on any Debian/Ubuntu machine with an NVIDIA GPU and root access.

## What `run.sh` does

The script runs through 9 steps:

| Step | Description |
|------|-------------|
| 1/9 | Validates GPU access via `nvidia-smi`. Exits with an error if no GPU is detected. |
| 2/9 | Installs required system packages (`docker` prerequisites, `hashcat`, `python3`, `jq`, `openssl`, `p7zip-full`, OpenCL libs, etc.) via `apt-get`. |
| 3/9 | Installs Docker Engine (`docker-ce`, CLI, `containerd.io`, Buildx and Compose plugins) if not already present. |
| 4/9 | Starts the `dockerd` daemon in the background and waits (up to 90s) for it to become ready. |
| 5/9 | Checks `hashcat --version` and lists available OpenCL/CUDA devices with `hashcat -I`. |
| 6/9 | Creates the Hashtopolis stack in `APP_DIR`: generates `.env`, `docker-compose.yml` (MariaDB + Hashtopolis backend + frontend + nginx reverse proxy), and `nginx.conf`. |
| 7/9 | Pulls the Docker images and starts the stack with `docker compose up -d`. |
| 8/9 | Prints container status (`docker compose ps`). |
| 9/9 | Prints the final connection info: web URL, admin credentials, and API endpoints. |

## Requirements

- Debian/Ubuntu-based Linux
- Root privileges (the script installs system packages and starts `dockerd` directly)
- An NVIDIA GPU with drivers installed on the host (`nvidia-smi` must succeed)
- Outbound internet access (for `apt` repositories, Docker Hub image pulls, and `api.ipify.org` for public IP detection)

## Configuration (environment variables)

All variables are optional — sensible defaults are used, and passwords are randomly generated with `openssl` when not provided.

| Variable | Default | Description |
|----------|---------|--------------|
| `APP_DIR` | `/opt/kiquai-hashtopolis` | Directory where the Docker Compose stack and data volumes are created. |
| `INTERNAL_PORT` | `8080` | Port the nginx reverse proxy listens on inside the container/host. |
| `MYSQL_ROOT_PASS` | random (24 chars) | MariaDB root password. |
| `MYSQL_DATABASE` | `hashtopolis` | MariaDB database name. |
| `MYSQL_USER` | `hashtopolis` | MariaDB application user. |
| `MYSQL_PASSWORD` | random (24 chars) | MariaDB application user password. |
| `HASHTOPOLIS_ADMIN_USER` | `admin` | Hashtopolis web admin username. |
| `HASHTOPOLIS_ADMIN_PASSWORD` | random (24 chars) | Hashtopolis web admin password. |
| `PUBLIC_IPADDR` | auto-detected via `api.ipify.org` | Public IP used to build the displayed access URL. |
| `PUBLIC_URL` | derived from `PUBLIC_IPADDR`/port | Overrides the full public URL shown at the end (and used as the backend API base URL). |

> On Vast.ai instances, the script also auto-detects the externally mapped port using the `VAST_TCP_PORT_<INTERNAL_PORT>` environment variable that Vast.ai injects, so the printed URL reflects the actual reachable port.

## Usage

Make the script executable and run it as root:

```bash
chmod +x run.sh
sudo ./run.sh
```

With custom configuration:

```bash
sudo APP_DIR=/opt/hashtopolis \
     MYSQL_DATABASE=hashtopolis \
     INTERNAL_PORT=8080 \
     ./run.sh
```

## Output

At the end of a successful run, the script prints:

- The Hashtopolis web URL
- The admin username and password
- The backend API v2 URL
- The legacy agent API URL (`/api/server.php`)

**Save this output** — randomly generated passwords are only shown here and stored in `${APP_DIR}/.env`; they are not printed again on subsequent runs.

## Managing the stack afterward

```bash
cd /opt/kiquai-hashtopolis   # or your custom APP_DIR
docker compose ps            # check container status
docker compose logs -f       # follow logs
docker compose down          # stop and remove containers
```

## Notes / Warnings

- The script must be run with root privileges since it installs OS packages and starts `dockerd` directly on the host.
- The nginx proxy exposes the Hashtopolis web UI and API on `INTERNAL_PORT` (default `8080`) — make sure this is only reachable by intended users/networks.
- Re-running the script is idempotent for package/Docker installation, but re-creates `docker-compose.yml`/`nginx.conf` and calls `docker compose up -d` again, which will (re)start the stack using whatever `.env` values already exist unless overridden.
