# JW Swarm (Joint Weights)

A distributed LLM inference cluster that combines your personal MacBooks and GPU servers into a single, powerful backend for coding workflows.

Instead of individual agents that perform tasks, JW Swarm provides pure GPU compute capacity. The Fleet Manager orchestrates the fleet and balances load, while you work through [Opencode](https://opencode.ai) or something else as your frontend.

## Why JW Swarm?

- **Pure Power** — No overhead from agent frameworks. Only raw GPU performance is utilized.
- **Smart Routing** — Large context? Route it to an host that can handle it. Fast iteration? Send it to a smaller model.
- **Transparent** — To Opencode it looks like a single, OpenAI-compatible API endpoint.
- **Zero Cloud Costs** — You don't pay per token; you use your own hardware.

## Architecture

JW Swarm is built from four cooperating layers.

### 1. User Client (Opencode)

You use Opencode for your coding workflow. Opencode acts as the interface and sends prompts to the system. It only ever sees a single OpenAI-compatible API endpoint.

### 2. HAProxy

The public entry point. It handles:

- TLS termination
- Routing for HTTP and WebSocket traffic
- Load balancing
- mTLS for inbound node tunnels

### 3. Fleet Manager (Orchestrator)

The central brain that manages all Inference Nodes:

- Maintains a live registry of each node: model size, VRAM usage, TPS (tokens-per-second), and latency.
- Receives requests from Opencode and routes them to the most suitable node.
- Balances load across the fleet for optimal throughput and latency.

### 4. Inference Nodes (The Fleet)

A heterogeneous mix of hosts that connect to the Fleet Manager over a **persistent socket** (WebSocket Secure, mTLS-authenticated). Nodes may live in different locations — they dial in through the **same public HAProxy endpoint** rather than connecting to the Fleet Manager directly. This means:

- A single public entry point (HAProxy) handles both Opencode client traffic and node tunnels.
- Nodes open the connection outbound, so no inbound ports or static IPs are required on the node side.
- The tunnel is bidirectional: the Fleet Manager dispatches prompts down it and receives streamed tokens back up the same connection.
- mTLS ensures only trusted nodes can join the fleet.

Supported node types:

- **MacBook (Apple Silicon)** — runs MLX.
- **Linux Host (NVIDIA)** — runs vLLM on CUDA.
- **Windows Host (NVIDIA)** — runs vLLM on CUDA.
- **Windows Host (AMD)** — runs llama.cpp on ROCm.

Every node:

- Runs an inference backend appropriate to its hardware.
- Registers itself and streams live metrics (model size, VRAM, TPS, latency) over the socket.
- Is **stateless** with respect to the task: it receives a prompt, generates tokens, and sends them back.
- Does no reasoning and no tool use — pure inference speed.

## Request Flow

1. Opencode sends a prompt to the public endpoint.
2. HAProxy terminates TLS and forwards the request to the Fleet Manager.
3. The Fleet Manager inspects its live registry and selects the best-fit node (based on model size, available VRAM, TPS, and latency).
4. The Fleet Manager dispatches the prompt **back down the node's persistent tunnel** (Fleet Manager → HAProxy → node); the node generates tokens and streams them back up the same tunnel.
5. The response flows back through the Fleet Manager and HAProxy to Opencode.

## Smart Routing Examples

| Workload                 | Target Node                  | Reason                            |
| ------------------------ | ---------------------------- | --------------------------------- |
| Large context window     | Linux/Windows NVIDIA host    | High VRAM and throughput          |
| Fast, small iterations   | MacBook (Apple Silicon, MLX) | Low latency, energy efficient     |
| Cost-effective GPU       | Windows AMD host (ROCm)      | Extra capacity on AMD hardware    |
| Heavy batch generation   | Highest-TPS node             | Maximizes tokens-per-second       |

## Architecture Diagram

See [architecture.puml](architecture.puml) for the PlantUML source of the system architecture.

To render it, use any PlantUML-compatible tool, for example:

```sh
plantuml architecture.puml
```

Or use the [PlantUML VS Code extension](https://marketplace.visualstudio.com/items?itemName=jebbs.plantuml) to preview it directly in the editor.

## Repository Layout

This is a **monorepo** with two independently buildable, separately downloadable components plus a shared protocol contract.

```
JW-Swarm/
├── README.md                  ← you are here (architecture overview)
├── DESIGN.md                  ← detailed design & implementation phases
├── architecture.puml          ← PlantUML system diagram
├── proto/                     ← shared wire protocol (schema.json + spec)
├── jw-swarm-fleet-manager/    ← the orchestrator (Rust) — ships as a Debian package
│   └── SETUP.md               ← server hosting guide
└── jw-swarm-nodes/            ← per-OS inference node apps (independent codebases)
    ├── README.md
    ├── linux/                 ← Rust CLI + systemd  (.deb)
    │   └── SETUP.md
    ├── macos/                 ← Swift menu-bar app  (.dmg/.pkg)
    │   └── SETUP.md
    └── windows/               ← C#/WinUI 3 tray app (.msi)
        └── SETUP.md
```

## Getting Started

| I want to…                          | Go to                                                            |
| ----------------------------------- | ---------------------------------------------------------------- |
| Host the orchestrator on a server   | [jw-swarm-fleet-manager/SETUP.md](jw-swarm-fleet-manager/SETUP.md) |
| Join the fleet from a Linux host    | [jw-swarm-nodes/linux/SETUP.md](jw-swarm-nodes/linux/SETUP.md)    |
| Join the fleet from a Mac           | [jw-swarm-nodes/macos/SETUP.md](jw-swarm-nodes/macos/SETUP.md)    |
| Join the fleet from Windows         | [jw-swarm-nodes/windows/SETUP.md](jw-swarm-nodes/windows/SETUP.md) |
| Understand the wire protocol        | [proto/README.md](proto/README.md)                               |
| See the full design & roadmap       | [DESIGN.md](DESIGN.md)                                            |

## Packaging & Releases

Each component is built and released independently by GitHub Actions:

- **Fleet Manager** — [`.github/workflows/fleet-manager.yml`](.github/workflows/fleet-manager.yml) builds, tests, and produces a standalone Debian package. Tag `fleet-manager-v*` to publish a release.
- **Nodes** — [`.github/workflows/nodes.yml`](.github/workflows/nodes.yml) builds the Linux (`.deb`), macOS (`.dmg`/`.pkg`), and Windows (`.msi`) node packages. Tag `nodes-v*` to publish a release.

## Third-party notices

- macOS node third-party license notices: [jw-swarm-nodes/macos/THIRD_PARTY_NOTICES.md](jw-swarm-nodes/macos/THIRD_PARTY_NOTICES.md)

