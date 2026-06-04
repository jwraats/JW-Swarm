CREATE TABLE IF NOT EXISTS enrollment_tokens (
    token_hash   TEXT PRIMARY KEY,
    node_id      TEXT NOT NULL,
    created_at   TEXT NOT NULL,
    expires_at   TEXT NOT NULL,
    used_at      TEXT,
    created_by   TEXT NOT NULL DEFAULT 'admin'
);

CREATE INDEX IF NOT EXISTS idx_enrollment_tokens_node_id
    ON enrollment_tokens(node_id);

CREATE INDEX IF NOT EXISTS idx_enrollment_tokens_expires_at
    ON enrollment_tokens(expires_at);