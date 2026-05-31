# JW Swarm Node — Linux Guide

The Linux node is a Rust CLI (`jw-swarm-node`) that runs as a **systemd** service.
It connects outbound to the Fleet Manager over WSS + mTLS, downloads and verifies
catalog models, and serves inference through a stub backend (placeholder for
real vLLM/llama.cpp integration).

## Architecture

```
┌─────────────┐         WSS+mTLS          ┌──────────────────────┐
│  Fleet Mgr  │ ◄───────────────────────► │   jw-swarm-node      │
│  (server)   │    Catalog, prompts       │   (Linux host)       │
│             │    heartbeats, responses  │                      │
│             │                           │  ┌─── config.toml ──┐│
│             │                           │  │ node_id, fleet   ││
└─────────────┘                           │  │ cert, CA, models ││
                                          │  └──────────┬───────┘│
                                          │             │         │
                                          │  ┌──────────▼───────┐│
                                          │  │  model directory  ││
                                          │  │  (downloaded +    ││
                                          │  │   sha256-verified)││
                                          │  └───────────────────┘│
                                          │                       │
                                          │  ┌─── backend stub ─┐ │
                                          │  │ (simulated tokens) │
                                          │  └──────────────────┘ │
                                          └──────────────────────┘
```

## Prerequisites

- **Linux x86_64** with a supported GPU:
  - NVIDIA — CUDA drivers + `nvidia-smi` available on `$PATH`.
  - AMD — ROCm runtime available (detection via `rocminfo`).
- Network egress to the Fleet Manager on port 443 (WSS).
- To build from source: Rust toolchain (<https://rustup.rs>).

## Install

### Option A — Debian package

```sh
sudo apt install ./jw-swarm-node_<version>_amd64.deb
```

Installs to `/usr/bin/jw-swarm-node` and creates a disabled
`jw-swarm-node.service` (see [service file](packaging/debian/jw-swarm-node.service)).

### Option B — Build from source

```sh
cargo build --release
# binary: target/release/jw-swarm-node
```

## Configuration

The node reads its configuration from a TOML file and can override any value
via environment variables.

### File location

| Variable       | Default path                                |
| -------------- | ------------------------------------------- |
| Config file    | `~/.config/jw-swarm-node/config.toml`       |
| Data directory | `~/.local/share/jw-swarm-node/`             |
| Model storage  | `~/.local/share/jw-swarm-node/models/`      |

Override with `JW_CONFIG_DIR` and `JW_DATA_DIR` respectively.

### Auto-generation

On first run, if the config file does not exist, the node generates one with:
- A new random `node_id` (UUID v4)
- Default paths for `node_cert` and `ca_cert`
- `memory_limit_mb = 24000`, `gpu_power_pct = 100`
- Empty `selected_models` (means: download all catalog models for this vendor)

### Config file format

```toml
fleet_url = "wss://swarm.example.com/node/connect"
node_id = "a1b2c3d4-..."
hostname = "gpu-node-01"
node_cert = "/etc/jw-swarm-node/node.pem"
ca_cert = "/etc/jw-swarm-node/ca.crt"

[limits]
gpu_power_pct = 100
memory_limit_mb = 24000

[schedule]
awake_from = ""
awake_until = ""

selected_models = ["qwen3-coder"]
```

### Environment variables

Every config field can be overridden via environment variables:

| Variable        | Config key     | Example                                  |
| --------------- | -------------- | ---------------------------------------- |
| `JW_FLEET_URL`  | `fleet_url`    | `wss://swarm.example.com/node/connect`   |
| `JW_NODE_CERT`  | `node_cert`    | `/etc/jw-swarm-node/node.pem`            |
| `JW_CA_CERT`    | `ca_cert`      | `/etc/jw-swarm-node/ca.crt`              |
| `JW_CONFIG_DIR` | _(path base)_  | `/etc/jw-swarm-node`                     |
| `JW_DATA_DIR`   | _(path base)_  | `/var/lib/jw-swarm-node`                 |
| `JW_FLEET_URL`  | `fleet_url`    | `wss://swarm.example.com/node/connect`   |
| `RUST_LOG`      | _(logging)_    | `debug` or `info`                        |

### mTLS certificates

The `node_cert` file must contain **both** the client certificate and the
private key in PEM format (typically concatenated, cert first, key second).
This is the certificate issued by the Fleet Manager operator — it authenticates
this specific node to the fleet.

```sh
sudo mkdir -p /etc/jw-swarm-node
sudo cp node.pem  /etc/jw-swarm-node/node.pem
sudo cp ca.crt    /etc/jw-swarm-node/ca.crt
sudo chmod 600 /etc/jw-swarm-node/node.pem
```

### Model selection

- `selected_models = ["alias1", "alias2"]` — download only listed catalog aliases.
- `selected_models = []` (empty) — download **all** models the Fleet Manager
  resolves for this GPU vendor.

The node downloads each model's `weights.bin` from the vendor-specific
`download_url`, verifies the `sha256` hash, and stores verified artifacts in
the model directory.

### Schedule (stub)

The `awake_from` / `awake_until` fields are parsed but not yet enforced.
The node currently always reports `schedule_state = awake`. Sleep window
enforcement is future work.

## Running

### As a systemd service

```sh
# Enable and start
sudo systemctl enable --now jw-swarm-node

# Check status
systemctl status jw-swarm-node

# Live logs
journalctl -u jw-swarm-node -f
```

To override the packaged unit defaults, create a drop-in:

```sh
sudo systemctl edit jw-swarm-node
```

Then add under `[Service]`:

```ini
Environment=JW_FLEET_URL=wss://swarm.example.com/node/connect
Environment=JW_NODE_CERT=/etc/jw-swarm-node/node.pem
Environment=JW_CA_CERT=/etc/jw-swarm-node/ca.crt
Environment=RUST_LOG=debug
```

### Standalone (manual run)

```sh
JW_FLEET_URL=wss://swarm.example.com/node/connect \
JW_NODE_CERT=/etc/jw-swarm-node/node.pem \
JW_CA_CERT=/etc/jw-swarm-node/ca.crt \
./jw-swarm-node
```

## Lifecycle

1. **Startup** — load/generate config, detect GPU vendor, build TLS connector.
2. **Connect** — dial WSS to Fleet Manager with mTLS; auto-reconnect on
   failure with exponential backoff (1s → 60s cap).
3. **Register** — send node identity, GPU info, limits, selected models.
4. **Catalog** — request vendor-resolved catalog; download + verify each model.
5. **Heartbeat** — every 30s send GPU metrics (`nvidia-smi` or zeroed) and
   report `awake` schedule state.
6. **Serve** — on `PromptDispatch` from Fleet Manager, the backend stub sends
   ~8 tokens of simulated output followed by a `Done` message with usage stats.
7. **Disconnect** — on close frame or error, the node backs off and reconnects.

## Backend (stub)

The current backend implementation simulates inference:

- **Token streaming** — sends 8 fixed tokens (`Hello`, `,`, ` `, `simulated`, ` `, `response`, `.`, ` `).
- **Usage reporting** — estimates `prompt_tokens` from message content length
  (divided by 4), counts completion tokens from stub output.
- **No real model loading** — model download is verified via sha256, but the
  weights are not loaded into a real inference engine.

Replacing the stub with a real backend (vLLM, llama.cpp) is the next step
(after P4 macOS node). The `BackendManager.dispatch()` method in
[src/backend.rs](src/backend.rs) is the integration point.

## Troubleshooting

| Symptom                      | Check                                                      |
| ---------------------------- | ---------------------------------------------------------- |
| Repeated "connect: ..."      | `JW_FLEET_URL` unreachable? TLS/mTLS cert mismatch?        |
| "connector unavailable"      | `node_cert` or `ca_cert` missing/unreadable?               |
| "no certificates in ..."     | PEM file malformed — must contain cert + key.              |
| Model download fails         | `download_url` unreachable; check DNS/firewall.            |
| sha256 mismatch              | Downloaded artifact corrupted; retry (node re-downloads).  |
| Nothing in logs              | Set `RUST_LOG=debug` in environment.                       |

Run with `RUST_LOG=debug` for verbose output:

```sh
RUST_LOG=debug ./jw-swarm-node
```

## Fleet Manager

The Fleet Manager operator must issue each node a client certificate. See
the Fleet Manager [SETUP](../../jw-swarm-fleet-manager/SETUP.md) for
certificate generation.
