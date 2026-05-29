//! WebSocket node tunnel endpoint (`/node/connect`).
//!
//! mTLS is terminated at HAProxy; the Fleet Manager trusts the proxied
//! connection. Each node connection runs a writer task (draining an mpsc
//! channel to the socket) and a reader loop (handling inbound messages).

use axum::extract::State;
use axum::extract::ws::{Message as WsMessage, WebSocket, WebSocketUpgrade};
use axum::response::IntoResponse;
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::proto::{CatalogResponse, Message};
use crate::registry::RequestEvent;
use crate::state::AppState;

pub async fn node_connect(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(socket: WebSocket, state: AppState) {
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();

    // Writer task: forward outbound messages to the socket.
    let writer = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            match msg.to_json() {
                Ok(json) => {
                    if sink.send(WsMessage::Text(json)).await.is_err() {
                        break;
                    }
                }
                Err(e) => warn!("failed to serialize outbound message: {e}"),
            }
        }
    });

    let mut node_id: Option<String> = None;

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

        let msg = match Message::from_json(&text) {
            Ok(m) => m,
            Err(e) => {
                warn!("invalid tunnel message: {e}");
                continue;
            }
        };

        handle_message(&state, &tx, &mut node_id, msg);
    }

    // Cleanup on disconnect.
    if let Some(id) = node_id {
        info!("node {id} disconnected");
        state.registry.remove_node(&id);
    }
    drop(tx);
    let _ = writer.await;
}

fn handle_message(
    state: &AppState,
    tx: &mpsc::UnboundedSender<Message>,
    node_id: &mut Option<String>,
    msg: Message,
) {
    match msg {
        Message::Register(reg) => {
            info!("node {} registered ({:?})", reg.node_id, reg.os);
            *node_id = Some(reg.node_id.clone());
            state.registry.upsert_node(reg, tx.clone());
        }
        Message::CatalogRequest => {
            // Resolve the catalog to the variants this node's hardware can host.
            match node_id
                .as_deref()
                .and_then(|id| state.registry.node_vendor(id))
            {
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
            state
                .registry
                .update_metrics(&hb.node_id, hb.metrics, hb.schedule_state);
        }
        Message::ModelStatus(ms) => {
            state
                .registry
                .update_ready_models(&ms.node_id, ms.ready_models);
        }
        Message::ScheduleState(ss) => {
            state.registry.update_schedule(&ss.node_id, ss.state);
        }
        Message::TokenChunk(chunk) => {
            let req = chunk.request_id.clone();
            state
                .registry
                .dispatch_event(&req, RequestEvent::Chunk(chunk));
        }
        Message::Done(done) => {
            let req = done.request_id.clone();
            state
                .registry
                .dispatch_event(&req, RequestEvent::Done(done));
        }
        Message::Error(err) => {
            let req = err.request_id.clone();
            state
                .registry
                .dispatch_event(&req, RequestEvent::Error(err));
        }
        // Server-only messages should never arrive from a node.
        Message::CatalogResponse(_) | Message::PromptDispatch(_) => {
            warn!("ignoring server-only message received from node");
        }
    }
}
