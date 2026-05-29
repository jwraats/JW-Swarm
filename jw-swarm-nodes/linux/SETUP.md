# JW Swarm Node — Linux Setup

The Linux node is a Rust CLI (`jw-swarm-node`) that runs as a **systemd** service. It connects outbound to the Fleet Manager over WSS + mTLS, hosts the owner-selected models, and serves inference. See the [nodes overview](../README.md) and the top-level [DESIGN](../../DESIGN.md).

> Status: this folder currently contains a buildable scaffold. The full agent is Phase 3 (P3) in [DESIGN.md](../../DESIGN.md#11-implementation-phases).

## Prerequisites

- Linux with a supported GPU:
  - **NVIDIA** — CUDA drivers + `nvidia-smi`; a vLLM install.
  - **AMD** — ROCm; a llama.cpp build with ROCm.
- Rust toolchain (<https://rustup.rs>) to build from source, or install the prebuilt `.deb`.
- Network egress to the Fleet Manager host on port 443.

## Install

### Option A — Debian package (recommended)

Download the `.deb` from the GitHub Releases (built by CI), then:

```sh
sudo apt install ./jw-swarm-node_<version>_amd64.deb
```

This installs the binary to `/usr/bin/jw-swarm-node` and a systemd unit `jw-swarm-node.service` (disabled by default).

### Option B — Build from source

```sh
cd jw-swarm-nodes/linux
cargo build --release      # binary at target/release/jw-swarm-node
```

## Configure

Place your mTLS material (issued by the Fleet Manager operator):

```sh
sudo mkdir -p /etc/jw-swarm-node
sudo cp node.pem /etc/jw-swarm-node/node.pem      # client cert + key
sudo cp ca.crt   /etc/jw-swarm-node/ca.crt        # CA cert
```

Configuration is via environment variables (set in the systemd unit or a drop-in):

| Variable        | Example                                   | Purpose                              |
| --------------- | ----------------------------------------- | ------------------------------------ |
| `JW_FLEET_URL`  | `wss://swarm.example.com/node/connect`    | Fleet Manager tunnel endpoint.       |
| `JW_NODE_CERT`  | `/etc/jw-swarm-node/node.pem`             | Node client certificate + key (mTLS).|
| `JW_CA_CERT`    | `/etc/jw-swarm-node/ca.crt`               | CA certificate to trust the server.  |
| `RUST_LOG`      | `info`                                    | Log level.                           |

To override the packaged unit's values, create a drop-in:

```sh
sudo systemctl edit jw-swarm-node
# add under [Service]:
#   Environment=JW_FLEET_URL=wss://swarm.example.com/node/connect
```

## Run

```sh
sudo systemctl enable --now jw-swarm-node
systemctl status jw-swarm-node
journalctl -u jw-swarm-node -f
```

## Fleet Manager side

The operator must issue this node a client certificate and add it to the fleet. See the Fleet Manager [SETUP](../../jw-swarm-fleet-manager/SETUP.md).
