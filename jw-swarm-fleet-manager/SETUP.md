# Fleet Manager — Server Setup

This guide explains how to host the JW Swarm **Fleet Manager** on a server and put **HAProxy** in front of it for TLS termination, routing, and mTLS authentication of inference nodes.

For the overall architecture see the top-level [README](../README.md) and [DESIGN](../DESIGN.md). For node setup see [jw-swarm-nodes](../jw-swarm-nodes/README.md).

---

## 1. Overview

```
                          :443 (public)
Clients (Opencode) ───┐
                      ├──▶ HAProxy ──▶ Fleet Manager (127.0.0.1:8080)
Inference Nodes ──────┘    (TLS +      - /v1/*        OpenAI API
                            mTLS)      - /node/connect WebSocket tunnel
```

- The **Fleet Manager** listens on a plain HTTP/WebSocket port, bound to localhost.
- **HAProxy** is the only public-facing process. It terminates TLS, enforces **mTLS** for node tunnels, and routes:
  - `/v1/*` → OpenAI-compatible client API
  - `/node/connect` → node WebSocket tunnel
  - `/healthz` → health check

> Security: never expose the Fleet Manager port directly to the internet. Bind it to `127.0.0.1` and let HAProxy be the trust boundary.

## 2. Prerequisites

- A Linux server (Ubuntu/Debian assumed below) with a public DNS name, e.g. `swarm.example.com`.
- Open inbound port **443** (and 80 only if you use ACME HTTP-01 for certs).
- **Rust** toolchain to build, or copy a prebuilt binary. Install via <https://rustup.rs>.
- **HAProxy** ≥ 2.4 (`haproxy -v`).
- A TLS certificate for the public hostname (Let's Encrypt or your own CA).
- A private **CA** for issuing node client certificates (mTLS) — see [§7](#7-mtls-certificates).

## 3. Install

### Option A — Debian package (recommended)

Download the `.deb` from GitHub Releases (built by CI), then:

```sh
sudo apt install ./jw-swarm-fleet-manager_<version>_amd64.deb
```

This installs the binary to `/usr/bin/jw-swarm-fleet-manager`, the catalog to `/etc/jw-swarm/models.toml`, and a systemd unit `jw-swarm-fleet-manager.service` (disabled by default). Skip to [§5](#5-configuration-environment-variables) — the packaged unit already sets sensible defaults; override them with `sudo systemctl edit jw-swarm-fleet-manager`.

### Option B — Build from source

On the server (or build elsewhere and copy the binary):

```sh
git clone <your-repo-url> jw-swarm
cd jw-swarm/jw-swarm-fleet-manager
cargo build --release
# binary at target/release/jw-swarm-fleet-manager
```

## 4. Install files (source build only)

```sh
sudo useradd --system --no-create-home --shell /usr/sbin/nologin jwswarm

sudo mkdir -p /opt/jw-swarm/bin /etc/jw-swarm /var/lib/jw-swarm
sudo cp target/release/jw-swarm-fleet-manager /opt/jw-swarm/bin/
sudo cp config/models.toml /etc/jw-swarm/models.toml

sudo chown -R jwswarm:jwswarm /var/lib/jw-swarm
```

## 5. Configuration (environment variables)

The Fleet Manager is configured entirely via environment variables:

| Variable      | Default              | Purpose                                                        |
| ------------- | -------------------- | -------------------------------------------------------------- |
| `JW_BIND`     | `0.0.0.0:8080`       | Address:port to listen on. **Set to `127.0.0.1:8080`** behind HAProxy. |
| `JW_CATALOG`  | `config/models.toml` | Path to the model catalog (allowlist).                         |
| `JW_DB`       | `fleet.db`           | SQLite path for the persistence/earnings store (P2.5).         |
| `RUST_LOG`    | `info`               | Log level (`error`/`warn`/`info`/`debug`/`trace`).             |

## 6. Run as a systemd service

Create `/etc/systemd/system/jw-fleet-manager.service`:

```ini
[Unit]
Description=JW Swarm Fleet Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=jwswarm
Group=jwswarm
WorkingDirectory=/var/lib/jw-swarm
Environment=JW_BIND=127.0.0.1:8080
Environment=JW_CATALOG=/etc/jw-swarm/models.toml
Environment=JW_DB=/var/lib/jw-swarm/fleet.db
Environment=RUST_LOG=info
ExecStart=/opt/jw-swarm/bin/jw-swarm-fleet-manager
Restart=on-failure
RestartSec=3

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/jw-swarm

[Install]
WantedBy=multi-user.target
```

Enable and start:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now jw-fleet-manager
sudo systemctl status jw-fleet-manager
journalctl -u jw-fleet-manager -f          # follow logs

# verify it is up locally
curl -s http://127.0.0.1:8080/healthz       # -> ok
```

## 7. mTLS certificates

HAProxy verifies that every inference node presents a client certificate signed by your private CA. Generate a CA and per-node client certs (example using OpenSSL):

```sh
mkdir -p /etc/jw-swarm/ca && cd /etc/jw-swarm/ca

# 1) Private CA (once)
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -subj "/CN=JW Swarm Node CA" -out ca.crt

# 2) A client cert for one node (repeat per node, unique CN)
NODE=node-macbook-01
openssl genrsa -out $NODE.key 2048
openssl req -new -key $NODE.key -subj "/CN=$NODE" -out $NODE.csr
openssl x509 -req -in $NODE.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 825 -sha256 -out $NODE.crt

# Bundle the node key+cert for distribution to that node
cat $NODE.crt $NODE.key > $NODE.pem
```

Distribute `ca.crt` + the node's `*.pem` (key+cert) to each node over a secure channel. Keep `ca.key` offline/secret.

The **server** TLS certificate (for `swarm.example.com`) is separate from this CA. With Let's Encrypt, build the PEM HAProxy expects:

```sh
cat /etc/letsencrypt/live/swarm.example.com/fullchain.pem \
    /etc/letsencrypt/live/swarm.example.com/privkey.pem \
    | sudo tee /etc/jw-swarm/server.pem >/dev/null
```

## 8. HAProxy configuration

Create `/etc/haproxy/haproxy.cfg` (or merge the relevant sections):

```haproxy
global
    log /dev/log local0
    maxconn 4096
    tune.ssl.default-dh-param 2048

defaults
    log     global
    mode    http
    option  httplog
    timeout connect 5s
    timeout client  1h      # long-lived: WebSocket tunnels + SSE streaming
    timeout server  1h
    timeout tunnel  1h      # keep node WebSocket tunnels open

frontend jw_swarm
    bind :443 ssl crt /etc/jw-swarm/server.pem ca-file /etc/jw-swarm/ca/ca.crt verify optional
    http-request set-header X-Forwarded-Proto https

    # Identify node tunnel traffic by path.
    acl is_node_path  path_beg /node/
    # mTLS verification result provided by HAProxy.
    acl has_client_cert ssl_c_used
    acl client_cert_ok  ssl_c_verify 0

    # Nodes MUST present a valid client certificate.
    http-request deny status 403 if is_node_path !has_client_cert
    http-request deny status 403 if is_node_path has_client_cert !client_cert_ok

    # Pass the verified client CN to the Fleet Manager for logging/identity.
    http-request set-header X-Node-CN %{+Q}[ssl_c_s_dn(CN)] if is_node_path client_cert_ok

    use_backend fleet_nodes   if is_node_path
    default_backend fleet_api

# Client (Opencode) OpenAI API + health
backend fleet_api
    server fm 127.0.0.1:8080 check

# Inference node WebSocket tunnels
backend fleet_nodes
    server fm 127.0.0.1:8080 check
```

Notes:

- `verify optional` lets normal clients connect without a cert while still capturing one when presented; the `http-request deny` rules then **require** a valid cert for `/node/*` only.
- `timeout tunnel 1h` (and matching client/server timeouts) keep the persistent node WebSocket and SSE streams alive. Increase if you expect longer idle periods.
- WebSocket upgrade works transparently in HAProxy `mode http` for 1.1; no extra config needed for `/node/connect`.

Validate and reload:

```sh
sudo haproxy -c -f /etc/haproxy/haproxy.cfg     # check config
sudo systemctl reload haproxy
```

## 9. Verify end-to-end

```sh
# Health through HAProxy (public)
curl -s https://swarm.example.com/healthz                 # -> ok

# Client API (empty until a node connects)
curl -s https://swarm.example.com/v1/models

# A node tunnel without a client cert must be rejected
curl -s -o /dev/null -w "%{http_code}\n" \
  https://swarm.example.com/node/connect                  # -> 403

# With a node client cert it should upgrade (101) instead of 403
curl -s -o /dev/null -w "%{http_code}\n" \
  --cert /etc/jw-swarm/ca/node-macbook-01.pem \
  https://swarm.example.com/node/connect
```

Point your inference nodes at `wss://swarm.example.com/node/connect` with their client cert, and Opencode at `https://swarm.example.com/v1` as an OpenAI-compatible base URL.

## 10. Operations

- **Logs**: `journalctl -u jw-fleet-manager -f` and HAProxy logs in `/var/log/haproxy.log`.
- **Update the catalog**: edit `/etc/jw-swarm/models.toml`, then `sudo systemctl restart jw-fleet-manager`.
- **Upgrade**: build a new binary, `sudo systemctl stop jw-fleet-manager`, replace `/opt/jw-swarm/bin/jw-swarm-fleet-manager`, `start` again. (With the Debian package: `sudo apt install ./jw-swarm-fleet-manager_<version>_amd64.deb`.)
- **Backup**: persist `/var/lib/jw-swarm/fleet.db` (node identities + earnings ledger).
- **Rotate node certs**: issue a new client cert from the CA and redistribute; revoke by maintaining a CRL referenced in HAProxy (`crl-file`).
