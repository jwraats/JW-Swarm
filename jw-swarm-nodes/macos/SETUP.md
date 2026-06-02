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

## Configuration window

Use the menu-bar item `Configuration...` to open a native macOS configuration window.

- Reads detected device unified memory and displays it in MB.
- Reads and displays detected GPU model/kind.
- Shows and allows editing of `node_cert` (PEM) and `ca_cert` paths.
- Lets you set the node memory limit (MB), clamped to the detected memory.
- Persists values to `config.json` and applies them immediately.
- Re-registers the node with Fleet Manager after save.
- Includes `Test Connection (mTLS)` to validate cert files and run an mTLS handshake probe to the Fleet endpoint.

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

Runtime tunnel mTLS now uses these configured cert files directly for websocket connections.
If `JW_NODE_CERT` points to a `.p12` / `.pfx` file, set `JW_NODE_CERT_PASSWORD` as well.

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

The macOS node now uses [llama.swift](https://github.com/mattt/llama.swift), which wraps llama.cpp, to run downloaded models locally.

- Downloaded model files preserve their original names (for example `.gguf`).
- A compatibility symlink to `weights.bin` is still created.
- Requests are executed with a greedy decode path and streamed as token chunks.
- If a model file exceeds the configured memory limit, that model is excluded from `ready_models`.

## Fleet Manager side

The operator must issue this node a client certificate. See the Fleet Manager [SETUP](../../jw-swarm-fleet-manager/SETUP.md).

## CI

The [.github/workflows/nodes.yml](../../.github/workflows/nodes.yml) workflow detects `Package.swift` and builds on `macos-latest`.

## Third-party notices

For llama.swift / llama.cpp license attribution included by the macOS node,
see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
