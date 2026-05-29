# JW Swarm Node — Windows Setup

The Windows node is a **system-tray app** written in C# / WinUI 3. It runs models with **vLLM (CUDA)** on NVIDIA GPUs or **llama.cpp (ROCm)** on AMD GPUs, connects outbound to the Fleet Manager over WSS + mTLS, and serves inference. See the [nodes overview](../README.md) and the top-level [DESIGN](../../DESIGN.md).

> Status: Phase 5 (P5) in [DESIGN.md](../../DESIGN.md#11-implementation-phases). This folder will hold the .NET/WinUI 3 solution; CI is wired to build and package it once the source lands.

## Prerequisites

- Windows 11.
- A supported GPU:
  - **NVIDIA** — recent driver + CUDA; a vLLM install.
  - **AMD** — ROCm on Windows; a llama.cpp ROCm build.
- .NET 8 SDK + Windows App SDK (WinUI 3) to build from source.
- Network egress to the Fleet Manager host on port 443.

## Install (planned)

Download the `.msi` installer from GitHub Releases (built by CI) and run it. The app starts in the system tray.

## Configure (planned)

From the tray menu:

1. **Fleet URL** — `wss://swarm.example.com/node/connect`.
2. **Certificates** — import the node client cert/key + CA cert issued by the Fleet Manager operator (stored in the Windows certificate store).
3. **Limits** — max GPU usage and VRAM reservation.
4. **Schedule** — awake/asleep windows.
5. **Models** — pick catalog aliases to host (the app downloads the artifact for the detected GPU vendor: `nvidia` → vLLM, `amd` → llama.cpp).

## Build from source (planned)

```powershell
cd jw-swarm-nodes\windows
dotnet build -c Release
```

## Fleet Manager side

The operator must issue this node a client certificate. See the Fleet Manager [SETUP](../../jw-swarm-fleet-manager/SETUP.md).
