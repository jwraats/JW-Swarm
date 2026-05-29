# JW Swarm Node — macOS Setup

The macOS node is a **menu-bar (status item) app** written in Swift/SwiftUI. It uses **MLX** to run models on Apple Silicon, connects outbound to the Fleet Manager over WSS + mTLS, and serves inference. See the [nodes overview](../README.md) and the top-level [DESIGN](../../DESIGN.md).

> Status: Phase 4 (P4) in [DESIGN.md](../../DESIGN.md#11-implementation-phases). This folder will hold the Xcode/Swift Package project; CI is wired to build and package it once the source lands.

## Prerequisites

- macOS on **Apple Silicon** (M1 or newer).
- Xcode 16+ with the command-line tools.
- [MLX](https://github.com/ml-explore/mlx) (bundled via Swift Package Manager).
- Network egress to the Fleet Manager host on port 443.

## Install (planned)

Download the signed `.dmg` from GitHub Releases (built by CI), drag **JW Swarm Node** to Applications, and launch it. The app appears in the menu bar.

## Configure (planned)

From the menu-bar popover:

1. **Fleet URL** — `wss://swarm.example.com/node/connect`.
2. **Certificates** — import the node client cert/key + CA cert issued by the Fleet Manager operator (stored in the macOS Keychain).
3. **Limits** — max GPU/CPU usage and unified-memory reservation.
4. **Schedule** — awake/asleep windows.
5. **Models** — pick catalog aliases to host (the app downloads the MLX (`apple`) artifact).

## Build from source (planned)

```sh
cd jw-swarm-nodes/macos
xcodebuild -scheme JWSwarmNode -configuration Release
```

## Fleet Manager side

The operator must issue this node a client certificate. See the Fleet Manager [SETUP](../../jw-swarm-fleet-manager/SETUP.md).
