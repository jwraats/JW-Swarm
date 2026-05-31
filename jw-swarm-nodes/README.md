# JW Swarm Nodes

Inference node agents for the JW Swarm fleet. Each node connects **outbound** to the Fleet Manager over a persistent WSS + mTLS tunnel, hosts the owner-selected models for its hardware, and serves inference. See the top-level [README](../README.md) and [DESIGN](../DESIGN.md) for the overall architecture.

Nodes are **fully independent per-OS codebases** that conform to the shared protocol in [proto/](../proto/):

| Platform | Folder                 | Form factor                 | Backends                   | Setup                          |
| -------- | ---------------------- | --------------------------- | -------------------------- | ------------------------------ |
| Linux    | [linux/](linux/)       | CLI + systemd service       | vLLM (CUDA), llama.cpp (ROCm) | [linux/SETUP.md](linux/SETUP.md) |
| macOS    | [macos/](macos/)       | Menu-bar (status item) app  | MLX                        | [macos/SETUP.md](macos/SETUP.md) |
| Windows  | [windows/](windows/)   | System-tray app             | vLLM (CUDA), llama.cpp (ROCm) | [windows/SETUP.md](windows/SETUP.md) |

## Configuration common to all nodes

Each node owner configures:

- **Fleet URL** — `wss://<host>/node/connect`
- **mTLS certs** — the node client cert/key + the CA cert (issued by the Fleet Manager operator; see the Fleet Manager [SETUP](../jw-swarm-fleet-manager/SETUP.md#7-mtls-certificates)).
- **Limits** — GPU power %, memory (VRAM) reservation.
- **Schedule** — sleep/awake windows.
- **Models** — which catalog **aliases** to host (the node downloads the artifact matching its GPU vendor).

## Status

- `linux/` — **done** (Phase 3: WSS+mTLS tunnel, config, catalog download, metrics, stub backend).
- `macos/` — Phase 4.
- `windows/` — Phase 5.
