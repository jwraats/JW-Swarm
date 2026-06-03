# JW Swarm Nodes

## Inference Nodes

Each node connects **outbound** to the Fleet Manager over a persistent WSS + mTLS tunnel.
Nodes are **fully independent per-OS codebases** that conform to the shared protocol in [proto/](../proto/):

| Platform | Folder | Form factor | Status | Guide |
| -------- | ------ | ----------- | ------ | ----- |
| Linux | [linux/](linux/) | CLI + systemd service | **done** (P3) | [linux/SETUP.md](linux/SETUP.md) |
| macOS | [macos/](macos/) | Menu-bar app (Swift/SwiftUI) | **in progress** (P4) | [macos/SETUP.md](macos/SETUP.md) |
| Windows | [windows/](windows/) | System-tray app (C#) | Phase 5 | [windows/SETUP.md](windows/SETUP.md) |

## What each node does

1. **Tunnel client** — outbound WSS with client certificate; auto-reconnect with exponential backoff.
2. **Config store** — TOML file (auto-generated on first run) with JW_* environment variable overrides.
3. **Catalog fetch + model download** — pull the vendor-resolved catalog from the Fleet Manager, download each selected model's artifact, verify `sha256`, store locally.
4. **Metrics collector** — sample GPU/VRAM/utilization (`nvidia-smi`, `rocminfo`, etc.) every 30s via `Heartbeat`.
5. **Backend management** — start/stop the inference backend and serve `PromptDispatch` requests.
	- Linux: vLLM / llama.cpp depending on hardware.
	- macOS: currently `llama.swift` (llama.cpp-compatible local model files).
	- Windows: planned vLLM / llama.cpp depending on hardware.
6. **Inference** — for each dispatched prompt, stream tokens back as `TokenChunk` messages, then report usage in `Done`.

### Shared configuration

Every node supports:

- **Fleet URL** — `JW_FLEET_URL` (default: `wss://localhost/node/connect`): WSS endpoint on the HAProxy public endpoint.
- **mTLS certificate** — `JW_NODE_CERT`: path to the PEM file containing both client cert and private key (issued by the Fleet Manager operator).
- **CA certificate** — `JW_CA_CERT`: path to the CA public key used to verify the server.
- **GPU power %** — `limits.gpu_power_pct` (0–100): how much GPU the node commits to the fleet.
- **VRAM reservation** — `limits.memory_limit_mb`: how much video memory the node commits.
- **Schedule** — `schedule.awake_from` / `awake_until`: sleep window in HH:MM format (empty = always awake).
- **Models** — `selected_models`: list of catalog aliases; empty list means "download all for this GPU vendor".

See [DESIGN](../DESIGN.md) for the full protocol specification and [linux/SETUP.md](linux/SETUP.md) for the complete Linux deployment guide. The [sequence diagram](../sequence.puml) shows where each step (enrollment, registration, catalog download, heartbeats, dispatch) fits in the overall flow.

## Registration and readiness

- `GET /admin/nodes` on Fleet Manager shows whether a node has actually registered.
- `GET /v1/models` only lists models that a connected node has reported as ready.
- On macOS, successful bootstrap enrollment and mTLS testing do not imply model readiness; the catalog artifact still has to be compatible with the current backend and pass `sha256` verification.
- The current macOS node does **not** run Hugging Face MLX repos directly. Apple catalog variants must match what `llama.swift` can load today.
