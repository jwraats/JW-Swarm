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

## 1. Install

### Option A — Debian package

Download the `.deb` from the GitHub release (built by CI):

```sh
sudo apt install ./jw-swarm-node_<version>_amd64.deb
```

This installs the binary to `/usr/bin/jw-swarm-node` and creates a disabled
systemd unit `jw-swarm-node.service` (see [service file](packaging/debian/jw-swarm-node.service)).

### Option B — Build from source

```sh
git clone https://github.com/jwraats/JW-Swarm.git
cd JW-Swarm/jw-swarm-nodes/linux
cargo build --release
# binary: target/release/jw-swarm-node
```

## 2. Configure mTLS Certificates

The Fleet Manager operator must issue each node a **client certificate** and a
**CA certificate**. See the [Fleet Manager Setup Guide](../../jw-swarm-fleet-manager/SETUP.md#7-mtls-certificates) for how to generate them.

Place the certificates on the host:

```sh
sudo mkdir -p /etc/jw-swarm-node

# node.pem — the combined client cert + private key (PEM format)
sudo cp node.pem  /etc/jw-swarm-node/node.pem

# ca.crt — the CA public key that signed the cert
sudo cp ca.crt    /etc/jw-swarm-node/ca.crt

# Only the node user (or root) should be able to read the key
sudo chmod 600 /etc/jw-swarm-node/node.pem
sudo chmod 644 /etc/jw-swarm-node/ca.crt
```

## 3. Configure the Node

The node uses a TOML config file with environment variable overrides.

### Configuration file location

| File            | Default path                                  | Override env var    |
| --------------- | --------------------------------------------- | ------------------- |
| Config file     | `~/.config/jw-swarm-node/config.toml`         | `JW_CONFIG_DIR`     |
| Data directory  | `~/.local/share/jw-swarm-node/`               | `JW_DATA_DIR`       |
| Model storage   | `~/.local/share/jw-swarm-node/models/<alias>/` | _(via data dir)_    |

### Auto-generation

On first run, if the config file doesn't exist, the node auto-generates it:

- Unique `node_id` (UUID v4)
- Default `node_cert` / `ca_cert` paths (`/etc/jw-swarm-node/`)
- Default limits: `gpu_power_pct = 100`, `memory_limit_mb = 24000`
- Empty `selected_models` (= download all catalog models for this GPU vendor)
- `fleet_url` from `JW_FLEET_URL` env var (default: `wss://localhost/node/connect`)

### Environment variables

| Variable        | Config key          | Purpose                                                    |
| --------------- | ------------------- | ---------------------------------------------------------- |
| `JW_FLEET_URL`  | `fleet_url`         | WSS endpoint of the HAProxy public entry point             |
| `JW_NODE_CERT`  | `node_cert`         | Path to PEM file with client cert + private key            |
| `JW_CA_CERT`    | `ca_cert`           | Path to CA certificate                                     |
| `JW_CONFIG_DIR` | _(path base)_       | Override the config file parent directory                  |
| `JW_DATA_DIR`   | _(path base)_       | Override the model / data storage parent directory         |
| `RUST_LOG`      | _(logging)_         | Log level (`error`, `warn`, `info`, `debug`)               |

### Model selection

In the config `[selected_models]` list:

- `["qwen3-coder", "llama3-8b"]` → download only these aliases
- `[]` (empty) → download **all** models the Fleet Manager resolves for this GPU vendor
- Aliases must match catalog aliases defined in the Fleet Manager's `models.toml`

Each model is downloaded from the vendor-specific `download_url`, verified by `sha256`, and stored in the model data directory.

### Schedule (stub)

The `schedule.awake_from` / `awake_until` fields (HH:MM format) are parsed but
**not yet enforced**. The node currently always reports `schedule_state = awake`.
Sleep window enforcement is future work.

## 4. Run the Node

### As a systemd service (recommended)

Use the packaged systemd unit with a drop-in to set your environment:

```sh
sudo systemctl edit jw-swarm-node
```

Add under `[Service]`:

```ini
Environment=JW_FLEET_URL=wss://swarm.example.com/node/connect
Environment=JW_NODE_CERT=/etc/jw-swarm-node/node.pem
Environment=JW_CA_CERT=/etc/jw-swarm-node/ca.crt
Environment=RUST_LOG=info
```

Then enable and start:

```sh
sudo systemctl enable --now jw-swarm-node          # start + enable on boot
systemctl status jw-swarm-node                     # check status
journalctl -u jw-swarm-node -f                     # follow live logs
```

### Manual (development)

```sh
JW_FLEET_URL=wss://swarm.example.com/node/connect \
JW_NODE_CERT=/etc/jw-swarm-node/node.pem \
JW_CA_CERT=/etc/jw-swarm-node/ca.crt \
RUST_LOG=debug \
./target/release/jw-swarm-node
```

## 5. Verify

1. **Node starts** — look for "queued Register" in the logs.
2. **mTLS tunnel connects** — look for "tunnel connected".
3. **Catalog received** — look for "+N models" (N catalog entries).
4. **Models downloaded** — look for "dl <alias> <size> bytes" followed by "<alias> verified".
5. **Heartbeats flowing** — periodic nvidia-smi/rocminfo metrics sent every 30s.
6. **Fleet Manager sees you** — in the FM logs, look for "node <id> registered".
7. **Ready models reported** — FM logs show the node's ready model list.

On the server, verify:

```sh
# Does the Fleet Manager see the node?
curl -s http://127.0.0.1:8080/admin/nodes | jq .

# Leaderboard (empty until requests served)
curl -s http://127.0.0.1:8080/admin/leaderboard | jq .
```

## 6. Lifecycle

```
1. Startup    → load/generate config, detect GPU vendor
2. Connect    → WSS + mTLS → auto-reconnect (1s → 60s exponential backoff)
3. Register   → node identity, GPU info, limits, selected_models
4. Catalog    → request vendor-resolved catalog from FM
5. Download   → for each selected model: download → sha256 verify → mark ready
6. Heartbeat  → every 30s: GPU metrics + schedule state
7. Serve      → on PromptDispatch: stream tokens → send Done with usage
8. Reconnect  → on close/error: backoff → reconnect → re-register
```

## 7. Backend (stub)

The current backend implementation **simulates** inference. Replace this with
a real inference engine (vLLM, llama.cpp) to produce real tokens.

**Current behavior:**
- Sends 8 fixed tokens: `Hello`, `,`, ` `, `simulated`, ` `, `response`, `.`, ` `
- Estimates `prompt_tokens` from the dispatched message content (÷4)
- Reports `total_tokens = prompt_tokens + completion_tokens`

**Integration point:** `BackendManager.dispatch()` in
[src/backend.rs](src/backend.rs) — replace this method to spawn a real
inference backend and stream actual tokens.

## 8. Troubleshooting

| Symptom                       | Likely cause                                   | Fix                                      |
| ----------------------------- | ---------------------------------------------- | ---------------------------------------- |
| "connector unavailable"       | cert or CA file missing/unreadable             | Check paths + permissions (`ls -la`)     |
| "no certificates in ..."      | PEM file malformed (no cert or key)            | Ensure cert + key are in the same file   |
| "cannot read node/CA cert"    | Path wrong or permissions block read           | `chmod 600 node.pem`, fix env var path   |
| "connect: ..." loop           | Fleet Manager unreachable / TLS mismatch       | Check `JW_FLEET_URL`, firewall, CA trust |
| "protocol versions error"     | rustls unable to set TLS 1.3                  | Ensure OpenSSL / rustls support TLS 1.3  |
| Model download fails          | `download_url` unreachable or wrong            | Check network + fleet catalog URLs       |
| sha256 mismatch              | Downloaded artifact corrupted                  | Node auto-retries; check network quality |
| "no certs in ca.crt"          | CA file is empty or wrong format               | Re-issue from the Fleet Manager operator |
| Node not seen by FM           | TLS cert mismatch (node cert not trusted)      | Verify node cert was signed by FM's CA   |
| Nothing in logs               | Log level too restrictive                      | Set `RUST_LOG=debug`                     |

```sh
# Debug output
RUST_LOG=debug ./target/release/jw-swarm-node

# Check if nvidia-smi works (for metrics collection)
nvidia-smi

# Check node config
cat ~/.config/jw-swarm-node/config.toml
```

## 9. Uninstall

### Debian package
```sh
sudo systemctl disable --now jw-swarm-node
sudo apt remove jw-swarm-node
# Optionally remove config / data:
sudo rm -rf /etc/jw-swarm-node/
rm -rf ~/.config/jw-swarm-node/ ~/.local/share/jw-swarm-node/
```

### Source build
```sh
rm -f ~/bin/jw-swarm-node
rm -rf ~/.config/jw-swarm-node/ ~/.local/share/jw-swarm-node/
``` [SETUP](../../jw-swarm-fleet-manager/SETUP.md) for
certificate generation.
