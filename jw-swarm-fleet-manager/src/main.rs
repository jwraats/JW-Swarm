//! JW Swarm Fleet Manager — orchestrator binary.

mod api;
mod catalog;
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

    let state = AppState::new(catalog);
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
        .with_state(state)
}
