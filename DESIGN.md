# JW Swarm — Design Document

This document describes the architecture and implementation plan for **JW Swarm (Joint Weights)**, a distributed LLM inference cluster that combines personal MacBooks and GPU servers into a single OpenAI-compatible backend.

For the high-level concept and architecture diagram, see [README.md](README.md) and [architecture.puml](architecture.puml). For the end-to-end runtime flow (enrollment, registration, dispatch, earnings) see [sequence.puml](sequence.puml).

---

## 1. Goals

- Combine heterogeneous hardware (Apple Silicon, NVIDIA, AMD) into one inference fleet.
- Expose a single **OpenAI-compatible** endpoint to clients (Opencode).
- Let each node **owner** control GPU/memory limits, sleep schedules, and which models to host.
- Route each request to the **best-fit** node based on live metrics.
- Use the owner's own hardware — **zero cloud costs**, no per-token billing.

## 2. High-Level Architecture

```
Developer → Opencode → HAProxy → Fleet Manager → (tunnel) → Inference Nodes
                         (TLS)      (Rust)         (WSS+mTLS)   (native apps)
```

- **HAProxy** — public entry point. TLS termination, HTTP + WebSocket routing, load balancing, and mTLS for inbound node tunnels.
- **Fleet Manager** — Rust orchestrator. OpenAI HTTP API + node WebSocket endpoint + live registry + router + model catalog.
- **Inference Nodes** — fully independent native apps that dial in outbound over a persistent WSS + mTLS tunnel. The same tunnel carries registration, metrics, prompt dispatch, and token streaming.

## 3. Technology Decisions

| Component       | Stack                                  | Notes                                            |
| --------------- | -------------------------------------- | ------------------------------------------------ |
| Fleet Manager   | Rust                                   | High-concurrency WebSocket fan-out, single binary |
| macOS node      | Swift / SwiftUI menu-bar app           | `llama.swift` backend today; MLX remains future work |
| Windows node    | C# / WinUI 3 system-tray app           | vLLM (CUDA) / llama.cpp (ROCm)                   |
| Linux node      | Rust CLI `jw-swarm-node` + systemd     | vLLM (CUDA) / llama.cpp (ROCm)                   |
| Transport       | WebSocket Secure (WSS) + mTLS          | Outbound from node, bidirectional                |
| Client API      | OpenAI-compatible (HTTP + SSE)         | `/v1/models`, `/v1/chat/completions`            |
| Model catalog   | Static TOML on Fleet Manager           | Fetched by nodes on connect                      |

**Node apps are fully independent codebases.** There is no shared binary core; each platform reimplements the protocol client and backend manager against the language-neutral spec in `proto/`. The JSON schema is the single source of truth.

## 4. Repository Layout

```
proto/                  Protocol spec (markdown) + JSON schema — source of truth
config/models.toml      Static model catalog (allowlist + download URLs + hashes)
fleet-manager/          Rust: HTTP OpenAI API + WS node endpoint + registry + router + catalog
nodes/linux/            Rust CLI "jw-swarm-node" + systemd unit
nodes/macos/            Swift/SwiftUI menu-bar app
nodes/windows/          C#/WinUI 3 tray app
deploy/haproxy/         haproxy.cfg
deploy/certs/           CA + cert generation scripts (mTLS)
docs/                   architecture.puml, README
```

## 5. Protocol

All messages are JSON, exchanged over the WSS tunnel. A node opens the connection outbound; the Fleet Manager then both pushes work down and receives results up the same socket. The wire format is defined by the JSON schema in [proto/](proto/) and is consumed by Rust (serde), Swift (Codable), and C# (System.Text.Json).

### Message types

| Message            | Direction      | Purpose                                                              |
| ------------------ | -------------- | ------------------------------------------------------------------- |
| `Register`         | Node → FM      | Announce host info, OS, GPU type, owner limits, selected models.    |
| `CatalogRequest`   | Node → FM      | Ask for the current model allowlist.                                |
| `CatalogResponse`  | FM → Node      | Allowlist resolved for the node's GPU vendor: per alias `id`, vendor-specific download URL, sha256, size, params, backend, ctx. |
| `Heartbeat`        | Node → FM      | Periodic liveness + live metrics (VRAM, util %, TPS, latency, load).|
| `ModelStatus`      | Node → FM      | Which models are downloaded / loaded / ready.                       |
| `ScheduleState`    | Node → FM      | `awake` / `asleep` / `draining`.                                    |
| `PromptDispatch`   | FM → Node      | Request id, target model, OpenAI chat payload.                      |
| `TokenChunk`       | Node → FM      | Streamed token delta for a request id.                              |
| `Done`             | Node → FM      | Request finished (usage stats).                                     |
| `Error`            | Node → FM      | Request failed (request id, message).                               |

### Envelope

Every message is wrapped in a tagged envelope:

```json
{ "type": "Heartbeat", "payload": { ... } }
```

## 6. Model Catalog

A static TOML file (`config/models.toml`) on the Fleet Manager is the allowlist source of truth.

Each model has a **developer-facing alias** (e.g. `qwen3-coder`) that stays the same regardless of which hardware ultimately serves the request. Under each alias are one or more **hardware-specific variants**, keyed by GPU vendor and inference backend:

| Vendor        | Backend          | Artifact kind            |
| ------------- | ---------------- | ------------------------ |
| Apple Silicon | `llama.swift` today (`mlx` future) | single-file llama.cpp-compatible artifact |
| NVIDIA        | vLLM (CUDA)      | safetensors / HF repo    |
| AMD           | llama.cpp (ROCm) | GGUF                     |
| Intel         | llama.cpp (SYCL/Vulkan) | GGUF              |

When a node connects, the Fleet Manager **resolves the catalog to that node's GPU vendor** and sends only the variants that node can host (each with its own download URL + sha256). The developer always references the alias; the Fleet Manager and node transparently use the correct artifact. Every node of a given vendor runs the identical artifact, verified by sha256 before serving.

```toml
[[model]]
alias = "qwen3-coder"
display_name = "Qwen3 Coder"

[[model.variant]]
vendor = "apple"            # nvidia | amd | apple | intel
   backend = "llama.cpp"       # vllm | llama.cpp | mlx
   download_url = "https://example.com/qwen3-coder-apple.gguf"
sha256 = "..."
size_bytes = 4200000000
context_length = 32768
params_billions = 7.6

[[model.variant]]
vendor = "nvidia"
backend = "vllm"
download_url = "https://example.com/qwen3-coder-cuda"
sha256 = "..."
size_bytes = 15200000000
context_length = 32768
params_billions = 7.6
```

## 7. Fleet Manager Design

### Components

- **HTTP API (`/v1/*`)** — OpenAI-compatible. `/v1/models` lists catalog models that have at least one ready node; `/v1/chat/completions` accepts chat requests and streams responses via SSE.
- **Node WebSocket endpoint (`/node/connect`)** — accepts node tunnels, authenticated by mTLS client certificate. Each connection gets a tunnel actor task.
- **Registry** — in-memory map of connected nodes and their live state (metrics, ready models, schedule state). Updated from `Register`, `Heartbeat`, `ModelStatus`, `ScheduleState`.
- **Catalog service** — loads `models.toml`, answers `CatalogRequest`.
- **Router/Scheduler** — given a requested model, selects the best node: must have the model ready, be `awake`, and is scored by free VRAM, GPU utilization, TPS, and latency.
- **Dispatcher** — correlates a client HTTP request with a node tunnel: sends `PromptDispatch`, relays `TokenChunk`s back to the SSE response, completes on `Done`/`Error`.
- **Persistence (DB)** — durable store (SQLite via `sqlx`) for node identities, connection/uptime sessions, per-request delivery records, and the accrued points ledger. Survives restarts; the in-memory `Registry` is rebuilt/augmented from it on boot. See [§7.1](#71-persistence--earnings-points-system).
- **Accounting/Earnings service** — converts delivered work and reserved capacity into points and writes them to the ledger.

### Concurrency model

- One Tokio task per node tunnel (read loop) plus an mpsc sender for outbound frames.
- A shared `Registry` behind `RwLock`/`DashMap`.
- Per-request oneshot/mpsc channels keyed by request id to route `TokenChunk`s back to the waiting HTTP handler.

### Routing algorithm (initial)

```
candidates = nodes where model is ready AND schedule == awake AND not draining
if candidates empty → 503 model unavailable
score(node) = w_vram * free_vram_norm
            + w_tps  * tps_norm
            - w_lat  * latency_norm
            - w_load * in_flight_norm
pick argmax(score)
```

Weights are configurable; the initial implementation uses sensible defaults and is unit-tested with synthetic node states.

### 7.1 Persistence & Earnings (Points) System

The Fleet Manager keeps a durable database so that node participation and contribution are tracked across restarts and can be rewarded. The store is **SQLite** (via `sqlx`, async, compile-time-checked queries); the path is configurable (`JW_DB`, default `fleet.db`). The live in-memory `Registry` remains the source of truth for routing; the DB is the source of truth for identity and earnings.

#### Why

- **Know the clients** — persist each node (owner, hardware, certificate fingerprint) so a returning node is recognised, not treated as brand new.
- **Reward contribution** — give each node owner **points** for the work their hardware delivers, so usage of shared hardware is measurable and fair.

#### What is rewarded

Points accrue from two sources:

1. **Token delivery** — completed generation work. Points scale with `completion_tokens` (and optionally `prompt_tokens`), weighted by model size so larger models earn more per token.
2. **Reserved capacity / availability** — keeping hardware online and reserved for the fleet. Points scale with **uptime** while `awake`, multiplied by the reserved **GPU power %** and **VRAM (memory) reservation** the owner committed.

Indicative formula (tunable weights, computed by the accounting service):

```
delivery_points  = Σ over requests( completion_tokens * model_size_factor * w_tokens )
capacity_points  = Σ over awake_seconds( (gpu_power_pct/100) * (reserved_vram_mb/1024) * w_capacity )
total_points     = delivery_points + capacity_points
```

#### Data model

| Table              | Purpose                                                                                  |
| ------------------ | ---------------------------------------------------------------------------------------- |
| `nodes`            | Stable node identity: `node_id`, owner, hostname, OS, GPU vendor/name/VRAM, cert fingerprint, first/last seen. |
| `sessions`         | One row per tunnel connection: `node_id`, `connected_at`, `disconnected_at`, awake seconds, reserved `gpu_power_pct` and `vram_mb` for the session. |
| `deliveries`       | One row per completed request: `request_id`, `node_id`, model alias, prompt/completion tokens, latency, `delivered_at`. |
| `points_ledger`    | Append-only entries: `node_id`, `kind` (`delivery`|`capacity`), `points`, `source_ref` (session/request id), `created_at`. |
| `node_balances`    | Materialised view / cached sum of points per node (for fast lookup).                     |

#### Lifecycle hooks

- **On `Register`** — upsert into `nodes`; open a new `sessions` row (record reserved GPU %/VRAM from `limits`).
- **On `Heartbeat`** — accrue `capacity_points` for the elapsed awake interval; refresh `last_seen`.
- **On `Done`** — write a `deliveries` row and a `delivery` ledger entry from the reported `usage`.
- **On disconnect** — close the `sessions` row (`disconnected_at`, final awake seconds).

#### Earnings API (read-only, initial)

- `GET /admin/nodes` — registered nodes with last-seen and current points balance.
- `GET /admin/nodes/{node_id}/earnings` — ledger entries and totals for a node.
- `GET /admin/leaderboard` — nodes ranked by total points.

These endpoints sit behind the same trust boundary as the rest of the Fleet Manager (HAProxy / mTLS); fine-grained admin auth is future work.

## 8. Inference Node Design (per platform)

Each node app implements the same responsibilities:

1. **Tunnel client** — outbound WSS with client certificate; auto-reconnect with backoff.
2. **Catalog fetch + model download** — pull the vendor-resolved catalog, then for each alias in the owner's `selected_models`, match it (by `id`) to a `CatalogResponse` entry and download that entry's vendor-specific `download_url` into the app data dir, verifying `sha256`. Aliases with no variant for this node's vendor are skipped and reported as not ready.
3. **Config store** — owner settings persisted locally: GPU power %, memory limit, schedule/sleep windows, selected models.
4. **Backend manager** — start/stop the inference backend with best-effort limit flags. The backend and artifact are chosen from the alias variant the Fleet Manager resolved for this node's GPU vendor:
   - Apple Silicon → currently `llama.swift` / llama.cpp-compatible artifact loading on-device. Direct Hugging Face MLX repo execution is not implemented yet.
   - NVIDIA → vLLM (CUDA), `--gpu-memory-utilization`
   - AMD → llama.cpp (ROCm)
   - Intel → llama.cpp (SYCL/Vulkan)
5. **Scheduler** — enforce sleep windows: drain in-flight requests, then stop accepting and report `asleep`.
6. **Metrics collector** — sample GPU/VRAM/util/TPS/latency (`nvidia-smi`, macOS tooling, ROCm SMI) and send via `Heartbeat`.

## 9. Security

- **mTLS** for every node tunnel: a private CA issues the Fleet Manager server cert and one client cert per node. HAProxy/Fleet Manager reject connections without a valid client cert.
- Nodes initiate **outbound** connections only — no inbound ports or static IPs required on the node side.
- Model artifacts are verified by **sha256** against the catalog before use.

### 9.1 Bootstrap Enrollment

Issuing and distributing per-node client certificates by hand is error-prone and risks copying private keys between machines. The Fleet Manager therefore exposes an optional **bootstrap enrollment API** (HTTP, served alongside `/v1/*`, in front of HAProxy) so a node can self-provision a certificate while its private key never leaves the node.

#### Flow

1. **Admin issues a token** — `POST /bootstrap/tokens` (Bearer admin token) creates a one-time token bound to a specific `node_id`, with a TTL. The token is stored **hashed** (SHA-256) in the DB; only the hash is persisted.
2. **Node fetches the CA** — `GET /bootstrap/ca.crt` returns the trust CA certificate.
3. **Node generates a key + CSR** locally (CN = `node_id`) and submits `POST /bootstrap/enroll` with `node_id`, `token`, and `csr_pem`.
4. **Fleet Manager signs** the CSR with the private CA, **consumes** the one-time token (marking `used_at`), and returns the signed client cert plus the CA cert.
5. The node stores `node.pem` (key + cert) and `ca.crt`, then opens the WSS + mTLS tunnel.

#### Endpoints

| Endpoint                                   | Method   | Auth         | Purpose                                        |
| ------------------------------------------ | -------- | ------------ | ---------------------------------------------- |
| `/bootstrap/ca.crt`                        | `GET`    | none         | Download the trust CA certificate.             |
| `/bootstrap/tokens`                        | `POST`   | admin Bearer | Create a one-time `node_id`-bound token.       |
| `/bootstrap/enroll`                        | `POST`   | one-time token | Submit CSR + token, receive signed cert.     |
| `/admin/enrollment/tokens`                 | `GET`/`POST` | admin Bearer | List or create enrollment tokens.          |
| `/admin/enrollment/tokens/{token_hash}`    | `DELETE` | admin Bearer | Revoke a token immediately.                    |

#### Configuration (environment variables)

| Variable                      | Default                      | Purpose                                          |
| ----------------------------- | ---------------------------- | ------------------------------------------------ |
| `JW_ENROLL_ENABLE`            | `false`                      | Enable the enrollment API.                       |
| `JW_ENROLL_CA_CERT`           | `/etc/jw-swarm/ca/ca.crt`    | CA certificate used to sign node CSRs.           |
| `JW_ENROLL_CA_KEY`            | `/etc/jw-swarm/ca/ca.key`    | CA private key used to sign node CSRs.            |
| `JW_ENROLL_ADMIN_TOKEN`       | _(unset)_                    | Bearer token guarding token-management routes.   |
| `JW_ENROLL_TOKEN_TTL_SECONDS` | `600`                        | Default token lifetime (clamped 60–86400).        |
| `JW_ENROLL_CERT_DAYS`         | `30`                         | Validity of issued client certificates.          |

When enrollment is disabled, every bootstrap/enrollment route returns `404`, and operators provision certs manually (see [jw-swarm-fleet-manager/SETUP.md](jw-swarm-fleet-manager/SETUP.md) §7).

## 10. Limits Enforcement

Best-effort, via backend launch flags (e.g. vLLM `--gpu-memory-utilization`, llama.cpp layer/mem flags). Hard OS-level isolation (cgroups, MPS, job objects) is out of scope for the first iteration.

## 11. Implementation Phases

- **P1 — Protocol & catalog** *(this iteration)*: JSON schema in `proto/`, message spec, `config/models.toml` format.
- **P2 — Fleet Manager** *(this iteration)*: registry, WS endpoint, catalog service, router, OpenAI HTTP API + dispatcher.
- **P2.5 — Persistence & earnings**: SQLite (`sqlx`) schema + migrations, node/session/delivery recording, points accounting service, read-only earnings/admin API.
- **P2.6 — Bootstrap enrollment**: one-time token issuance, CA download, CSR signing API; self-service node certificate provisioning (see [§9.1](#91-bootstrap-enrollment)).
- **P3 — Linux node** (Rust `jw-swarm-node` + systemd) — reference node implementation.
- **P4 — macOS node** (Swift/SwiftUI menu-bar app).
- **P5 — Windows node** (C#/WinUI 3 tray app).
- **P6 — Deploy & end-to-end**: mTLS cert scripts, HAProxy config, full run-through.

## 12. Out of Scope (first iteration)

- Hard OS-level resource isolation.
- Billing / quotas / multi-tenant auth beyond mTLS.
- Web admin dashboard (earnings exposed via read-only API only; points are tracked but not yet redeemable).
- Runtime catalog editing API (catalog is static TOML for now).
