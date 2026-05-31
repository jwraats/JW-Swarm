//! WebSocket node tunnel endpoint (`/node/connect`).
//!
//! mTLS is terminated at HAProxy; the Fleet Manager trusts the proxied
//! connection. Each node connection runs a writer task (draining an mpsc
//! channel to the socket) and a reader loop (handling inbound messages).

use std::time::{SystemTime, UNIX_EPOCH};

use axum::extract::State;
use axum::extract::ws::{Message as WsMessage, WebSocket, WebSocketUpgrade};
use axum::response::IntoResponse;
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::proto::{CatalogResponse, Message};
use crate::registry::RequestEvent;
use crate::state::AppState;

pub(crate) struct Session {
    pub(crate) node_id: String,
    prev_heartbeat_ms: Option<f64>,
    gpu_power_pct: f64,
    vram_mb: f64,
    pub(crate) params_by_model: std::collections::HashMap<String, f64>,
}

pub async fn node_connect(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

fn unix_now_ms() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0)
}

async fn handle_socket(socket: WebSocket, state: AppState) {
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();

    let writer = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            match msg.to_json() {
                Ok(json) => {
                    if sink.send(WsMessage::Text(json.into())).await.is_err() {
                        break;
                    }
                }
                Err(e) => warn!("failed to serialize outbound message: {e}"),
            }
        }
    });

    let mut session: Option<Session> = None;

    while let Some(frame) = stream.next().await {
        let frame = match frame {
            Ok(f) => f,
            Err(e) => {
                warn!("tunnel read error: {e}");
                break;
            }
        };

        let text = match frame {
            WsMessage::Text(t) => t,
            WsMessage::Close(_) => break,
            WsMessage::Ping(_) | WsMessage::Pong(_) | WsMessage::Binary(_) => continue,
        };

        let msg = match Message::from_json(text.as_str()) {
            Ok(m) => m,
            Err(e) => {
                warn!("invalid tunnel message: {e}");
                continue;
            }
        };

        handle_message(&state, &tx, &mut session, msg).await;
    }

    if let Some(ref s) = session {
        info!("node {} disconnected", s.node_id);
        state.registry.remove_node(&s.node_id);
        let node_id = s.node_id.clone();
        let db = state.db.clone();
        tokio::spawn(async move {
            if let Err(e) = db.close_session(&node_id).await {
                warn!("failed to close session for {}: {e}", node_id);
            }
        });
    }

    drop(tx);
    let _ = writer.await;
}

async fn handle_message(
    state: &AppState,
    tx: &mpsc::UnboundedSender<Message>,
    session: &mut Option<Session>,
    msg: Message,
) {
    match msg {
        Message::Register(reg) => {
            info!("node {} registered ({:?}) ({:?})", reg.node_id, reg.os, reg.gpu.vendor);
            state.registry.upsert_node(reg.clone(), tx.clone());

            let catalog = state.catalog.as_ref().clone();
            let node_id = reg.node_id.clone();
            let gpu_vendor = reg.gpu.vendor;

            *session = Some(Session {
                node_id: node_id.clone(),
                prev_heartbeat_ms: None,
                gpu_power_pct: reg.limits.gpu_power_pct as f64,
                vram_mb: reg.limits.memory_limit_mb as f64,
                params_by_model: catalog.resolve_for(gpu_vendor)
                    .into_iter()
                    .map(|m| (m.id, m.params_billions))
                    .collect(),
            });

            let db = state.db.clone();
            let gpu_power = reg.limits.gpu_power_pct as f64;
            let vram = reg.limits.memory_limit_mb as f64;
            tokio::spawn(async move {
                let _ = db.upsert_node(&reg).await;
                let _ = db.open_session(&node_id, gpu_power, vram).await;
            });
        }
        Message::CatalogRequest => {
            match session.as_ref().and_then(|s| state.registry.node_vendor(&s.node_id)) {
                Some(vendor) => {
                    let models = state.catalog.resolve_for(vendor);
                    let _ = tx.send(Message::CatalogResponse(CatalogResponse { models }));
                }
                None => {
                    warn!("CatalogRequest before Register; sending empty catalog");
                    let _ = tx.send(Message::CatalogResponse(CatalogResponse {
                        models: Vec::new(),
                    }));
                }
            }
        }
        Message::Heartbeat(hb) => {
            state.registry.update_metrics(&hb.node_id, hb.metrics.clone(), hb.schedule_state);

            if let Some(ref mut s) = session {
                if s.node_id != hb.node_id {
                    return;
                }
                let now = unix_now_ms();
                let prev = s.prev_heartbeat_ms.unwrap_or(now);
                let delta_sec = (now - prev) / 1000.0;
                s.prev_heartbeat_ms = Some(now);

                if delta_sec > 0.0 && hb.schedule_state == crate::proto::ScheduleStateValue::Awake {
                    let pts = state.accounting.capacity_points(delta_sec, s.gpu_power_pct, s.vram_mb);
                    if pts > 0.0 {
                        if let Err(e) = state.db.touch_session_awake(&s.node_id, delta_sec).await {
                            warn!("failed to touch session awake: {e}");
                        }
                        let node_id = s.node_id.clone();
                        let source = format!("hb_{:.0}", now);
                        if let Err(e) = state.db.credit_points(&node_id, "capacity", pts, &source).await {
                            warn!("failed to credit capacity points: {e}");
                        } else {
                            info!("capacity +{pts:.1}pts for {node_id} ({delta_sec:.1}s awake)");
                        }
                    }
                }
            }
        }
        Message::ModelStatus(ms) => {
            state.registry.update_ready_models(&ms.node_id, ms.ready_models);
        }
        Message::ScheduleState(ss) => {
            state.registry.update_schedule(&ss.node_id, ss.state);
        }
        Message::TokenChunk(chunk) => {
            let req = chunk.request_id.clone();
            state.registry.dispatch_event(&req, RequestEvent::Chunk(chunk));
        }
        Message::Done(done) => {
            let req = done.request_id.clone();

            if let Some(meta) = state.registry.get_pending(&req) {
                let params = session
                    .as_ref()
                    .and_then(|s| s.params_by_model.get(&meta.model))
                    .copied()
                    .unwrap_or(7.0);

                let pts = state.accounting.delivery_points(&done.usage, params);
                info!("delivery +{pts:.1}pts for {} ({} tokens, model={})", meta.node_id, done.usage.completion_tokens, meta.model);

                let db = state.db.clone();
                let node_id = meta.node_id.clone();
                let model = meta.model.clone();
                let usage = done.usage.clone();
                let latency = match state.registry.snapshot().into_iter().find(|n| n.node_id == node_id) {
                    Some(n) => n.metrics.as_ref().map(|m| m.latency_ms).unwrap_or(0.0),
                    None => 0.0,
                };
                let req_delivery = req.clone();
                tokio::spawn(async move {
                    let _ = db.record_delivery(&req_delivery, &node_id, &model, &usage, latency).await;
                    let _ = db.credit_points(&node_id, "delivery", pts, &req_delivery).await;
                });
            }

            state.registry.dispatch_event(&req, RequestEvent::Done(done));
        }
        Message::Error(err) => {
            let rid = err.request_id.clone();
            state.registry.dispatch_event(&rid, RequestEvent::Error(err));
        }
        Message::CatalogResponse(_) | Message::PromptDispatch(_) => {
            warn!("ignoring server-only message received from node");
        }
    }
}
