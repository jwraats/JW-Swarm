# JW Swarm Node — Windows Setup

The Windows node is a **system-tray app** written in C# / .NET 8. It connects
outbound to the Fleet Manager over **WSS + mTLS**, downloads and verifies model
artifacts, and serves inference. It runs models with **vLLM (CUDA)** on NVIDIA
GPUs or **llama.cpp (ROCm)** on AMD GPUs. See the [nodes overview](../README.md)
and the top-level [DESIGN](../../DESIGN.md).

> Status: Phase 5 (P5) in [DESIGN.md](../../DESIGN.md#11-implementation-phases).
> The cross-platform node logic (`JwSwarmNode.Core`) is implemented and builds on
> any OS; the tray head (`JwSwarmNode.App`) targets `net8.0-windows` and the MSI
> is built on Windows by CI.

## Solution layout

```
jw-swarm-nodes/windows/
  JwSwarmNode.sln
  src/
    JwSwarmNode.Core/        # net8.0 — protocol, tunnel, config, downloader,
                             #          backend, metrics, enrollment, coordinator
    JwSwarmNode.App/         # net8.0-windows — WinForms system-tray head
  packaging/
    Package.wxs              # WiX v5 installer definition
    JwSwarmNode.Installer.wixproj
    build-msi.ps1            # publish + build MSI (run on Windows)
```

The protocol layer in `JwSwarmNode.Core` is wire-compatible with the Fleet
Manager's serde message envelope (`{"type": ..., "payload": ...}`), matching the
Linux and macOS nodes.

## Prerequisites

- Windows 11.
- A supported GPU:
  - **NVIDIA** — recent driver + CUDA; a vLLM install.
  - **AMD** — ROCm on Windows; a llama.cpp ROCm build.
- .NET 8 SDK to build from source.
- WiX Toolset v5 (`dotnet tool install --global wix`) to build the MSI.
- Network egress to the Fleet Manager host on port 443.

## Install

Download the `.msi` installer from GitHub Releases (built by CI) and run it. The
app installs to `Program Files`, registers a per-user logon autostart entry, and
starts in the system tray.

## Enroll

Enrollment performs CSR-based mTLS bootstrap against the Fleet Manager. Run from
a terminal (the same executable handles the `enroll` subcommand):

```powershell
JwSwarmNode.exe enroll --base-url https://swarm.example.com --node-id <id> --token <token>
```

This generates a key + CSR, fetches the CA, posts the CSR with your enrollment
token, and writes `node.pem` + `ca.crt` to `%APPDATA%\JWSwarmNode`, then updates
`config.json` with the issued certificate paths and the `wss://…/node/connect`
fleet URL.

## Configure

Configuration is stored at `%APPDATA%\JWSwarmNode\config.json`:

- `fleet_url` — `wss://swarm.example.com/node/connect`.
- `node_cert` / `ca_cert` — paths to the enrolled `node.pem` and `ca.crt`.
- `limits` — `gpu_power_pct` and `memory_limit_mb` (VRAM/RAM reservation; the
  backend never advertises a model whose artifact exceeds this budget, and only
  one model is active at a time).
- `schedule` — `awake_from` / `awake_until` windows.
- `selected_models` — catalog aliases to host (empty means host the whole
  catalog). The node downloads the artifact for the detected GPU vendor.

The tray menu shows live status, the loaded model, and the ready models, and can
open the config folder.

## Build from source

Build the cross-platform core anywhere:

```powershell
cd jw-swarm-nodes\windows
dotnet build src\JwSwarmNode.Core\JwSwarmNode.Core.csproj -c Release
```

Build the full app + MSI on Windows:

```powershell
cd jw-swarm-nodes\windows
dotnet build -c Release
pwsh packaging\build-msi.ps1
```

## Fleet Manager side

The operator must issue this node a client certificate (or an enrollment token
for self-service bootstrap). See the Fleet Manager
[SETUP](../../jw-swarm-fleet-manager/SETUP.md).
