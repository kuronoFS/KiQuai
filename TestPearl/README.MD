# Pearl (PRL) Modular Mining Script

An all-in-one Pearl (PRL) mining script — easy to configure, supports GPU, CPU, or both simultaneously.

## Structure

```
├── run.sh       ← Main script (configuration at the top of the file)
└── README.MD    ← Documentation
```

## Quick Start

### 1. Configure
Open `run.sh` and edit the **⚙️ CONFIGURATION** section at the top of the file:

```bash
# Select mining mode
MINING_MODE="gpu"          # gpu | cpu | dual

# PRL wallet address
WALLET="prl1..."

# Worker name
WORKER_NAME="rig01"
```

### 2. Run

```bash
chmod +x run.sh
sudo ./run.sh
```

## Mining Modes

| Mode   | Description                          | Miner used              |
|--------|--------------------------------------|-------------------------|
| `gpu`  | GPU-only mining (NVIDIA CUDA)        | SRBMiner-Multi          |
| `cpu`  | CPU-only mining                      | SRBMiner-Multi (beta)   |
| `dual` | Simultaneous GPU + CPU mining        | SRBMiner-Multi (both)   |

## Detailed Configuration (inside `run.sh`)

### GPU (SRBMiner-Multi)
| Parameter | Description | Default |
|---|---|---|
| `GPU_ALGO` | Algorithm | `pearlhash` |
| `GPU_POOL` | Pool address | `pearl-sg1.luckypool.io:3360` |
| `GPU_TH_EST` | Estimated TH/s per GPU (used to auto-select port) | `350` |

### CPU (SRBMiner-Multi)
| Parameter | Description | Default |
|---|---|---|
| `CPU_ALGO` | Algorithm | `pearlhash` |
| `CPU_POOL` | Pool address | `pearl-sg1.luckypool.io:3360` |
| `CPU_THREADS` | Thread count (`"auto"` = auto-detect) | `"auto"` |

### Restart Behavior
| Parameter | Description | Default |
|---|---|---|
| `RESTART_DELAY` | Seconds to wait before restarting | `5` |
| `MAX_RETRIES` | Maximum number of attempts (0 = unlimited) | `0` |
| `LONG_RESTART_DELAY` | Wait time after repeated fast crashes | `60` |

## Important Notes

- **GPU mining (SRBMiner-Multi):** Requires an NVIDIA GPU with CUDA. RTX 30/40/50 series work best. Driver ≥ 580 is recommended for `pearlhash`; RTX 50xx (Blackwell) requires at least driver branch 570.
- **CPU mining:** Currently in beta. Performance is significantly lower than GPU mining.
- **Dual mode:** Runs GPU and CPU mining simultaneously as separate processes. Press `Ctrl+C` to stop both.
- The script automatically downloads the latest supported miner version from GitHub on each run unless already installed.
- GPUs run at **stock clocks** — the script does not apply any overclocking or power limits.

## Suggested Pools

| Pool | Address | Notes |
|---|---|---|
| LuckyPool (Singapore) | `pearl-sg1.luckypool.io:3360` | Primary (GPU + CPU) |
| LuckyPool (Singapore 2) | `pearl-sg2.luckypool.io:3360` | Failover |
| LuckyPool (Europe) | `pearl-eu2.luckypool.io:3360` | Failover |
| rplant (Asia) | `asia.rplant.xyz:17168` | GPU |
| AkoyaPool | `pool.akoyapool.com:3333` | GPU |
| AlphaPool | `pearl.alphapool.tech` | GPU + AMD |
