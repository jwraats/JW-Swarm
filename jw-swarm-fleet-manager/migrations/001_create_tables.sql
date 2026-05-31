-- 001_create_tables.sql
-- Core schema for node identity, sessions, deliveries, and earnings ledger.

CREATE TABLE IF NOT EXISTS nodes (
    node_id        TEXT PRIMARY KEY,
    owner          TEXT NOT NULL DEFAULT '',
    hostname       TEXT NOT NULL DEFAULT '',
    os             TEXT NOT NULL DEFAULT '',
    gpu_vendor     TEXT NOT NULL DEFAULT '',
    gpu_name       TEXT NOT NULL DEFAULT '',
    gpu_vram_mb    INTEGER NOT NULL DEFAULT 0,
    cert_fingerprint TEXT NOT NULL DEFAULT '',
    first_seen     TEXT NOT NULL,
    last_seen      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    node_id        TEXT NOT NULL REFERENCES nodes(node_id),
    connected_at   TEXT NOT NULL,
    disconnected_at TEXT,
    awake_seconds  REAL NOT NULL DEFAULT 0,
    gpu_power_pct  REAL NOT NULL DEFAULT 0,
    vram_mb        REAL NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS deliveries (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id     TEXT NOT NULL,
    node_id        TEXT NOT NULL REFERENCES nodes(node_id),
    model_alias    TEXT NOT NULL,
    prompt_tokens  INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    latency_ms     REAL NOT NULL DEFAULT 0,
    delivered_at   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS points_ledger (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    node_id        TEXT NOT NULL REFERENCES nodes(node_id),
    kind           TEXT NOT NULL,
    points         REAL NOT NULL,
    source_ref     TEXT NOT NULL,
    created_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS node_balances (
    node_id        TEXT PRIMARY KEY REFERENCES nodes(node_id),
    total_points   REAL NOT NULL DEFAULT 0
);
