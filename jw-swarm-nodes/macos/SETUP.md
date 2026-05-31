# JW Swarm Node — macOS

A menu-bar (status item) app written in Swift/SwiftUI for Apple Silicon. Connects outbound to the Fleet Manager over WSS + mTLS.

## Architecture

```
jw-swarm-nodes/macos/
├── Package.swift
└── Sources/JWSwarmNode/
    ├── Proto/Types.swift          Protocol types (mirrors proto/schema.json)
    ├── Config/ConfigManager.swift  JSON config + env var overrides
    ├── Tunnel/Tunnel.swift         WSS + mTLS client, auto-reconnect
    ├── Models/ModelDownloader.swift Model download + SHA-256 verification
    ├── Metrics/Metrics.swift       sysctl / vm_stats / powermetrics
    ├── Backend/StubBackend.swift   Stub inference (replaced by MLX later)
    └── Views/
        ├── AppEntry.swift           @main, AppDelegate, NodeCoordinator
        └── NodeMenuView.swift       MenuBarExtra popover UI
```

## Prerequisites

- macOS 13+ on **Apple Silicon** (M1 or newer).
- Xcode 15+ with command-line tools (`xcode-select --install`).
- Network egress to the Fleet Manager on port 443.

## Build & Run

```sh
cd jw-swarm-nodes/macos
swift build -c release
```

The binary appears at `.build/release/JWSwarmNode`. Launch it from Finder or the terminal:

```sh
.build/release/JWSwarmNode
```

The app places an icon in the menu bar. Click it for status, awake toggle, and config.

## Configure

### Fleet URL

Via the menu-bar config sheet, or the `JW_FLEET_URL` environment variable:

```sh
export JW_FLEET_URL=wss://swarm.example.com/node/connect
```

### Certificates

The app expects a PEM file containing both the client certificate and private key:

```sh
export JW_NODE_CERT=/path/to/node.pem
export JW_CA_CERT=/path/to/ca.crt
```

Or set the paths from the config sheet. The cert/key are **not** stored in the macOS Keychain — the PEM file is read at runtime.

### Limits

- **GPU power %** — how much GPU the node commits to the fleet (0–100).
- **Memory limit** — unified memory reservation in MB.

### Schedule

Awake window (`awake_from` / `awake_until`, HH:MM format). Empty means always awake.

### Models

- `selected_models` in the config — list of catalog aliases (e.g. `qwen3-coder`).
- Empty list means "download all variants for this GPU vendor".

### Data directory

Config and models are stored in `~/Library/Application Support/JWSwarmNode/`. Override with:

```sh
export JW_CONFIG_DIR=/custom/path
```

## Backend

The current backend is a **stub** that simulates inference with fixed tokens. The MLX backend is planned for a follow-up phase.

## Fleet Manager side

The operator must issue this node a client certificate. See the Fleet Manager [SETUP](../../jw-swarm-fleet-manager/SETUP.md).

## CI

The [.github/workflows/nodes.yml](../../.github/workflows/nodes.yml) workflow detects `Package.swift` and builds on `macos-latest`.
