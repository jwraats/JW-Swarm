use axum::extract::{Path, State};
use axum::Json;
use serde::Serialize;
use serde_json::json;
use sqlx::sqlite::SqliteRow;
use sqlx::Row;

use crate::state::AppState;

// ---------------------------------------------------------------------------
//  Response types
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct AdminNodeInfo {
    pub node_id: String,
    pub hostname: String,
    pub os: String,
    pub gpu_vendor: String,
    pub gpu_name: String,
    pub gpu_vram_mb: i64,
    pub first_seen: String,
    pub last_seen: String,
    pub total_points: Option<f64>,
}

#[derive(Debug, Serialize)]
pub struct LedgerEntry {
    pub id: i64,
    pub kind: String,
    pub points: f64,
    pub source_ref: String,
    pub created_at: String,
}

#[derive(Debug, Serialize)]
pub struct NodeEarnings {
    pub node_id: String,
    pub total_points: f64,
    pub entries: Vec<LedgerEntry>,
}

#[derive(Debug, Serialize)]
pub struct LeaderboardEntry {
    pub rank: u32,
    pub node_id: String,
    pub total_points: f64,
}

// ---------------------------------------------------------------------------
//  Admin endpoints
// ---------------------------------------------------------------------------

pub async fn admin_nodes(
    State(state): State<AppState>,
) -> Result<Json<Vec<AdminNodeInfo>>, (axum::http::StatusCode, Json<serde_json::Value>)> {
    let pool = state.db.get_pool().clone();

    let rows: Vec<SqliteRow> = match sqlx::query(
        r#"
        SELECT n.node_id, n.hostname, n.os, n.gpu_vendor, n.gpu_name, n.gpu_vram_mb,
               n.first_seen, n.last_seen, nb.total_points
        FROM nodes n
        LEFT JOIN node_balances nb ON n.node_id = nb.node_id
        ORDER BY n.last_seen DESC
        "#
    )
    .fetch_all(&*pool)
    .await
    {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("admin_nodes query failed: {e}");
            return Err((
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": "query failed" })),
            ));
        }
    };

    Ok(Json(
        rows
            .into_iter()
            .map(|r| AdminNodeInfo {
                node_id: r.try_get(0).unwrap_or_default(),
                hostname: r.try_get(1).unwrap_or_default(),
                os: r.try_get(2).unwrap_or_default(),
                gpu_vendor: r.try_get(3).unwrap_or_default(),
                gpu_name: r.try_get(4).unwrap_or_default(),
                gpu_vram_mb: r.try_get(5).unwrap_or(0i64),
                first_seen: r.try_get(6).unwrap_or_default(),
                last_seen: r.try_get(7).unwrap_or_default(),
                total_points: r.try_get::<Option<f64>, _>(8).unwrap_or(None),
            })
            .collect::<Vec<_>>(),
    ))
}

pub async fn admin_node_earnings(
    Path(node_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<NodeEarnings>, (axum::http::StatusCode, Json<serde_json::Value>)> {
    let pool = state.db.get_pool().clone();

    // Fetch total balance
    let total: Option<f64> = match sqlx::query_scalar(
        "SELECT total_points FROM node_balances WHERE node_id = ?",
    )
    .bind(&node_id)
    .fetch_optional(&*pool)
    .await
    {
        Ok(row) => row,
        Err(e) => {
            tracing::error!("node balance query failed: {e}");
            return Err((
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": "query failed" })),
            ));
        }
    };

    // Fetch ledger entries
    let entries_raw: Vec<SqliteRow> = match sqlx::query(
        "SELECT id, kind, points, source_ref, created_at
         FROM points_ledger WHERE node_id = ?
         ORDER BY created_at DESC",
    )
    .bind(&node_id)
    .fetch_all(&*pool)
    .await
    {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("ledger query failed: {e}");
            return Err((
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": "query failed" })),
            ));
        }
    };

    let entries: Vec<LedgerEntry> = entries_raw
        .into_iter()
        .filter_map(|row| {
            match (
                row.try_get::<i64, _>(0),
                row.try_get::<String, _>(1),
                row.try_get::<f64, _>(2),
                row.try_get::<String, _>(3),
                row.try_get::<String, _>(4),
            ) {
                (Ok(id), Ok(kind), Ok(points), Ok(source_ref), Ok(created_at)) => {
                    Some(LedgerEntry { id, kind, points, source_ref, created_at })
                }
                _ => None,
            }
        })
        .collect();

    Ok(Json(NodeEarnings {
        node_id,
        total_points: total.unwrap_or(0.0),
        entries,
    }))
}

pub async fn admin_leaderboard(
    State(state): State<AppState>,
) -> Result<Json<Vec<LeaderboardEntry>>, (axum::http::StatusCode, Json<serde_json::Value>)> {
    let pool = state.db.get_pool().clone();

    let rows: Vec<SqliteRow> = match sqlx::query(
        "SELECT node_id, total_points FROM node_balances ORDER BY total_points DESC",
    )
    .fetch_all(&*pool)
    .await
    {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("leaderboard query failed: {e}");
            return Err((
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": "query failed" })),
            ));
        }
    };

    let result: Vec<LeaderboardEntry> = rows
        .into_iter()
        .enumerate()
        .map(|(i, row)| LeaderboardEntry {
            rank: (i + 1) as u32,
            node_id: row.try_get(0).unwrap_or_default(),
            total_points: row.try_get(1).unwrap_or(0.0f64),
        })
        .collect();

    Ok(Json(result))
}