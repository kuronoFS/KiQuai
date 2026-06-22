# TestOllama

A minimal Docker entrypoint script that installs and launches an [Ollama](https://ollama.com) server with GPU (NVIDIA CUDA) support, binding on all interfaces so that an upstream proxy (e.g., Nginx Proxy Manager) can forward traffic into the container.

## Directory Structure

```
TestOllama/
├── run.sh      ← Entrypoint script (install + launch Ollama)
└── README.MD   ← This file
```

## Prerequisites

| Requirement | Notes |
|---|---|
| **Docker** | With [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) installed on the **host** |
| **NVIDIA GPU** | Any CUDA-capable card; driver ≥ 520 recommended |
| **Internet access** | Required on first run to download the Ollama installer |

## Quick Start

### Run as a Docker container

```bash
docker run -d \
  --name ollama \
  --gpus all \
  -p 11434:11434 \
  -v ollama_data:/root/.ollama \
  ubuntu:22.04 bash -c "apt-get update -qq && apt-get install -y -qq curl ca-certificates && bash /run.sh"
```

> **Tip:** Mount `run.sh` into the container with `-v $(pwd)/run.sh:/run.sh`.

### Run directly on the host

```bash
chmod +x run.sh
sudo ./run.sh
```

## Configuration

All options are controlled by environment variables:

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_HOST` | `0.0.0.0:11434` | Address and port Ollama listens on |
| `OLLAMA_MODELS` | *(unset)* | Space-separated list of models to pull on first start |
| `OLLAMA_PULL_TIMEOUT` | `300` | Seconds to wait for each model pull |

### Example: pre-pull a model at startup

```bash
OLLAMA_MODELS="qwen2.5:7b" sudo ./run.sh
```

### Example: change the listen port

```bash
OLLAMA_HOST="0.0.0.0:8080" sudo ./run.sh
```

## How It Works

1. **Updates package lists** and installs `curl` and `ca-certificates`.
2. **Detects NVIDIA GPU** via `nvidia-smi` and warns if not found.
3. **Installs Ollama** (skipped if already installed).
4. **Pre-pulls models** listed in `OLLAMA_MODELS` (optional).
5. **Launches `ollama serve`** as PID 1 via `exec`, bound to `OLLAMA_HOST`.

## Accessing the Server

Once running, the Ollama REST API is available at:

```
http://<host-ip>:11434
```

Example — list available models:

```bash
curl http://localhost:11434/api/tags
```

Example — run inference:

```bash
curl http://localhost:11434/api/generate -d '{
  "model": "qwen2.5:7b",
  "prompt": "Hello!"
}'
```

## Notes

- **GPU access in Docker:** The container **must** be started with `--gpus all` (or `--gpus '"device=0"'` for a specific card). Without this flag `nvidia-smi` will not be visible inside the container and Ollama will fall back to CPU-only mode.
- **Binding to `0.0.0.0`:** This is intentional and required for reverse proxies such as Nginx Proxy Manager to route external traffic into the container. Do **not** expose port 11434 directly to the public internet without authentication.
- **Models are persisted** in `/root/.ollama`. Mount a Docker volume there to avoid re-downloading models on every container restart.
