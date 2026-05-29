# JW Swarm Protocol

This directory is the **language-neutral source of truth** for the JW Swarm tunnel protocol. All node implementations (Rust, Swift, C#) and the Fleet Manager must conform to the JSON schema in [`schema.json`](schema.json).

## Transport

- The node opens an **outbound** WebSocket Secure (WSS) connection to the Fleet Manager (through HAProxy) and authenticates with an **mTLS client certificate**.
- The connection is **bidirectional and persistent**: the node pushes registration/metrics/results up, and the Fleet Manager pushes prompt dispatch down, over the same socket.
- Every frame is a single JSON object using the tagged **envelope**:

  ```json
  { "type": "<MessageType>", "payload": { ... } }
  ```

## Messages

### Node → Fleet Manager

| Type             | Purpose                                                                 |
| ---------------- | ----------------------------------------------------------------------- |
| `Register`       | Sent first. Host info, OS, GPU type, owner limits, selected model ids.  |
| `CatalogRequest` | Ask for the current model allowlist.                                    |
| `Heartbeat`      | Periodic liveness + live metrics.                                       |
| `ModelStatus`    | Which models are downloaded / loaded / ready.                           |
| `ScheduleState`  | Current schedule state: `awake` / `asleep` / `draining`.                |
| `TokenChunk`     | A streamed token delta for an in-flight request.                        |
| `Done`           | A request finished, with usage stats.                                   |
| `Error`          | A request failed.                                                       |

### Fleet Manager → Node

| Type              | Purpose                                                                |
| ----------------- | ---------------------------------------------------------------------- |
| `CatalogResponse` | The model allowlist **resolved for the node's GPU vendor**: per alias, the vendor-specific download URL, hash, size, params, backend. |
| `PromptDispatch`  | A request to generate: request id, target model id, OpenAI payload.    |

## Lifecycle

1. Node connects (mTLS) → sends `Register` (including `selected_models`, a list of aliases the owner chose to host).
2. Node sends `CatalogRequest` → FM replies `CatalogResponse`, resolved for this node's GPU vendor.
3. Node decides **what to download**: for each alias in `selected_models`, it looks up the matching entry (by `id`) in `CatalogResponse` and downloads that entry's `download_url` into its app data dir, verifying `sha256`. Aliases with no variant for this vendor are skipped.
4. Node sends `ModelStatus` (the set of aliases now downloaded/loaded and ready) and `ScheduleState`.
5. Node sends `Heartbeat` periodically (default every 5s).
6. FM routes a client request → sends `PromptDispatch` (targeting an alias the node reported ready).
7. Node streams `TokenChunk` … then `Done` (or `Error`).

## Field reference

See [`schema.json`](schema.json) for the authoritative definitions. Key payloads:

- **Register**: `node_id`, `hostname`, `os` (`macos`|`linux`|`windows`), `gpu` (`{ vendor, name, vram_mb }`), `limits` (`{ gpu_power_pct, memory_limit_mb }`), `selected_models` (string[]).
- **Heartbeat**: `metrics` = `{ vram_used_mb, vram_total_mb, gpu_util_pct, tps, latency_ms, in_flight }`, plus `schedule_state`.
- **CatalogResponse**: `models` = array of `{ id, display_name, download_url, sha256, size_bytes, context_length, params_billions, backend }`. The `id` is the developer-facing **alias**; the remaining fields are the variant resolved for the receiving node's GPU vendor.
- **PromptDispatch**: `request_id`, `model`, `payload` (OpenAI chat completion request object).
- **TokenChunk**: `request_id`, `delta` (string), `index`.
- **Done**: `request_id`, `usage` = `{ prompt_tokens, completion_tokens, total_tokens }`.
- **Error**: `request_id`, `message`.
