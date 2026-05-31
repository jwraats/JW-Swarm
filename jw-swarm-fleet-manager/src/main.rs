//! JW Swarm Fleet Manager — orchestrator binary.

mod accounting;
mod admin;
mod api;
mod catalog;
mod db;
mod proto;
mod registry;
mod router;
mod state;
mod tunnel;

use std::net::SocketAddr;

use axum::Router;
use axum::routing::{get, post};
use tracing::info;
use tracing_subscriber::EnvFilter;

use crate::catalog::Catalog;
use crate::db::Db;
use crate::state::AppState;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let catalog_path =
        std::env::var("JW_CATALOG").unwrap_or_else(|_| "config/models.toml".to_string());
    let catalog = Catalog::load(&catalog_path)?;
    info!(
        "loaded catalog from {catalog_path} ({} models)",
        catalog.len()
    );

    let db_path = std::env::var("JW_DB").unwrap_or_else(|_| "fleet.db".to_string());
    let db = Db::connect(&db_path).await?;
    info!("database connected at {db_path}");

    let state = AppState::new(catalog, db);
    let app = build_router(state);

    let bind = std::env::var("JW_BIND").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    let addr: SocketAddr = bind.parse()?;
    info!("Fleet Manager listening on {addr}");

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/v1/models", get(api::list_models))
        .route("/v1/chat/completions", post(api::chat_completions))
        .route("/node/connect", get(tunnel::node_connect))
        .route("/admin/nodes", get(admin::admin_nodes))
        .route("/admin/nodes/:path", get(admin::admin_node_earnings))
        .route("/admin/leaderboard", get(admin::admin_leaderboard))
        .with_state(state)
}
