//! SQLite persistence layer.

use std::sync::Arc;

use ::time::OffsetDateTime;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqliteSynchronous};
use sqlx::SqlitePool;

use crate::proto::{GpuVendor, OsKind, Register, Usage};

#[derive(Clone)]
pub struct Db {
    pool: Arc<SqlitePool>,
}

impl Db {
    pub async fn connect(path: &str) -> anyhow::Result<Self> {
        let url = format!("sqlite://{path}");
        let options = url
            .parse::<SqliteConnectOptions>()?
            .create_if_missing(true)
            .journal_mode(SqliteJournalMode::Wal)
            .synchronous(SqliteSynchronous::Normal);
        let pool = SqlitePool::connect_with(options).await?;

        sqlx::migrate!().run(&pool).await?;

        Ok(Self {
            pool: Arc::new(pool),
        })
    }

    // ------------------------------------------------------------------
    //  nodes
    // ------------------------------------------------------------------

    pub async fn upsert_node(&self, reg: &Register) -> anyhow::Result<()> {
        let os_str = match reg.os {
            OsKind::Macos => "macos",
            OsKind::Linux => "linux",
            OsKind::Windows => "windows",
        };
        let vendor_str = match reg.gpu.vendor {
            GpuVendor::Apple => "apple",
            GpuVendor::Nvidia => "nvidia",
            GpuVendor::Amd => "amd",
            GpuVendor::Intel => "intel",
        };
        let now = OffsetDateTime::now_utc();

        sqlx::query(
            "INSERT INTO nodes (node_id, hostname, os, gpu_vendor, gpu_name, gpu_vram_mb, first_seen, last_seen)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(node_id) DO UPDATE SET
                 hostname = excluded.hostname,
                 os = excluded.os,
                 gpu_vendor = excluded.gpu_vendor,
                 gpu_name = excluded.gpu_name,
                 gpu_vram_mb = excluded.gpu_vram_mb,
                 last_seen = excluded.last_seen"
        )
        .bind(&reg.node_id)
        .bind(&reg.hostname)
        .bind(os_str)
        .bind(vendor_str)
        .bind(&reg.gpu.name)
        .bind(reg.gpu.vram_mb as i64)
        .bind(now.format(&::time::format_description::well_known::Rfc3339)?)
        .bind(now.format(&::time::format_description::well_known::Rfc3339)?)
        .execute(&*self.pool)
        .await?;

        Ok(())
    }

    // ------------------------------------------------------------------
    //  sessions
    // ------------------------------------------------------------------

    pub async fn open_session(
        &self,
        node_id: &str,
        gpu_power_pct: f64,
        vram_mb: f64,
    ) -> anyhow::Result<()> {
        let now =
            OffsetDateTime::now_utc().format(&::time::format_description::well_known::Rfc3339)?;

        sqlx::query(
            "INSERT INTO sessions (node_id, connected_at, gpu_power_pct, vram_mb)
             VALUES (?, ?, ?, ?)",
        )
        .bind(node_id)
        .bind(&now)
        .bind(gpu_power_pct)
        .bind(vram_mb)
        .execute(&*self.pool)
        .await?;

        Ok(())
    }

    pub async fn close_session(&self, node_id: &str) -> anyhow::Result<()> {
        let now =
            OffsetDateTime::now_utc().format(&::time::format_description::well_known::Rfc3339)?;

        sqlx::query(
            "UPDATE sessions
             SET disconnected_at = ?
             WHERE node_id = ?
               AND disconnected_at IS NULL
             ORDER BY connected_at DESC
             LIMIT 1",
        )
        .bind(&now)
        .bind(node_id)
        .execute(&*self.pool)
        .await?;

        Ok(())
    }

    pub async fn touch_session_awake(
        &self,
        node_id: &str,
        awake_seconds_delta: f64,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "UPDATE sessions
             SET awake_seconds = awake_seconds + ?
             WHERE node_id = ?
               AND disconnected_at IS NULL
             ORDER BY connected_at DESC
             LIMIT 1",
        )
        .bind(awake_seconds_delta)
        .bind(node_id)
        .execute(&*self.pool)
        .await?;

        Ok(())
    }

    // ------------------------------------------------------------------
    //  deliveries
    // ------------------------------------------------------------------

    pub async fn record_delivery(
        &self,
        request_id: &str,
        node_id: &str,
        model: &str,
        usage: &Usage,
        latency_ms: f64,
    ) -> anyhow::Result<()> {
        let now =
            OffsetDateTime::now_utc().format(&::time::format_description::well_known::Rfc3339)?;

        sqlx::query(
            "INSERT INTO deliveries (request_id, node_id, model_alias, prompt_tokens, completion_tokens, latency_ms, delivered_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)"
        )
        .bind(request_id)
        .bind(node_id)
        .bind(model)
        .bind(usage.prompt_tokens as i64)
        .bind(usage.completion_tokens as i64)
        .bind(latency_ms)
        .bind(&now)
        .execute(&*self.pool)
        .await?;

        Ok(())
    }

    // ------------------------------------------------------------------
    //  points
    // ------------------------------------------------------------------

    pub async fn credit_points(
        &self,
        node_id: &str,
        kind: &str,
        points: f64,
        source_ref: &str,
    ) -> anyhow::Result<()> {
        let now =
            OffsetDateTime::now_utc().format(&::time::format_description::well_known::Rfc3339)?;

        let mut tx = self.pool.begin().await?;

        sqlx::query(
            "INSERT INTO points_ledger (node_id, kind, points, source_ref, created_at)
             VALUES (?, ?, ?, ?, ?)",
        )
        .bind(node_id)
        .bind(kind)
        .bind(points)
        .bind(source_ref)
        .bind(&now)
        .execute(&mut *tx)
        .await?;

        sqlx::query(
            "INSERT INTO node_balances (node_id, total_points)
             VALUES (?, ?)
             ON CONFLICT(node_id) DO UPDATE SET
                 total_points = total_points + excluded.total_points",
        )
        .bind(node_id)
        .bind(points)
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;

        Ok(())
    }

    // ------------------------------------------------------------------
    //  pool access
    // ------------------------------------------------------------------

    pub fn get_pool(&self) -> Arc<SqlitePool> {
        self.pool.clone()
    }
}
