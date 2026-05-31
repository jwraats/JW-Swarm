//! OpenAI-compatible HTTP API and request dispatcher.

use std::convert::Infallible;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::sse::{Event, Sse};
use axum::response::{IntoResponse, Response};
use futures::StreamExt;
use serde_json::{Value, json};
use tokio_stream::wrappers::UnboundedReceiverStream;
use tracing::warn;
use uuid::Uuid;

use crate::proto::{Message, PromptDispatch};
use crate::registry::RequestEvent;
use crate::router::pick_node;
use crate::state::AppState;

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// `GET /v1/models` — list aliases that have at least one ready, awake node.
pub async fn list_models(State(state): State<AppState>) -> Json<Value> {
    let available = state.registry.available_models();
    let created = unix_now();
    let data: Vec<Value> = state
        .catalog
        .aliases()
        .into_iter()
        .filter(|alias| available.contains(alias))
        .map(|alias| {
            json!({
                "id": alias,
                "object": "model",
                "created": created,
                "owned_by": "jw-swarm",
            })
        })
        .collect();
    Json(json!({ "object": "list", "data": data }))
}

/// `POST /v1/chat/completions` — route to a node and stream/return the result.
pub async fn chat_completions(State(state): State<AppState>, Json(body): Json<Value>) -> Response {
    let model = match body.get("model").and_then(|m| m.as_str()) {
        Some(m) => m.to_string(),
        None => {
            return error_response(StatusCode::BAD_REQUEST, "missing 'model' field");
        }
    };

    let stream = body
        .get("stream")
        .and_then(|s| s.as_bool())
        .unwrap_or(false);

    // Select a node for this model.
    let nodes = state.registry.snapshot();
    let node_id = match pick_node(&nodes, &model, &state.weights) {
        Some(id) => id,
        None => {
            return error_response(
                StatusCode::SERVICE_UNAVAILABLE,
                &format!("no node available for model '{model}'"),
            );
        }
    };

    let sender = match state.registry.node_sender(&node_id) {
        Some(tx) => tx,
        None => {
            return error_response(
                StatusCode::SERVICE_UNAVAILABLE,
                "selected node disconnected",
            );
        }
    };

    // Set up the per-request event channel and dispatch.
    let request_id = Uuid::new_v4().to_string();
    let (event_tx, event_rx) = tokio::sync::mpsc::unbounded_channel::<RequestEvent>();
    state
        .registry
        .register_request(request_id.clone(), model.clone(), node_id.clone(), event_tx);

    let dispatch = Message::PromptDispatch(PromptDispatch {
        request_id: request_id.clone(),
        model: model.clone(),
        payload: body,
    });

    if sender.send(dispatch).is_err() {
        state.registry.complete_request(&request_id);
        return error_response(
            StatusCode::SERVICE_UNAVAILABLE,
            "failed to dispatch to node",
        );
    }

    if stream {
        stream_response(state, request_id, model, event_rx)
    } else {
        buffered_response(state, request_id, model, event_rx).await
    }
}

fn chunk_json(
    request_id: &str,
    model: &str,
    created: u64,
    delta: &str,
    finish: Option<&str>,
) -> Value {
    json!({
        "id": format!("chatcmpl-{request_id}"),
        "object": "chat.completion.chunk",
        "created": created,
        "model": model,
        "choices": [{
            "index": 0,
            "delta": if delta.is_empty() { json!({}) } else { json!({ "content": delta }) },
            "finish_reason": finish,
        }],
    })
}

/// Removes the pending request entry from the registry when the SSE stream is
/// dropped (client disconnect or normal completion).
struct CleanupGuard {
    state: AppState,
    request_id: String,
}

impl Drop for CleanupGuard {
    fn drop(&mut self) {
        self.state.registry.complete_request(&self.request_id);
    }
}

/// Streaming (SSE) response path.
fn stream_response(
    state: AppState,
    request_id: String,
    model: String,
    event_rx: tokio::sync::mpsc::UnboundedReceiver<RequestEvent>,
) -> Response {
    let created = unix_now();
    let rid = request_id.clone();
    let guard = CleanupGuard { state, request_id };

    let sse_stream = UnboundedReceiverStream::new(event_rx)
        .map(move |ev| {
            // Hold the guard alive for the lifetime of the stream.
            let _ = &guard;
            events_for(ev, &rid, &model, created)
        })
        .flat_map(futures::stream::iter);

    Sse::new(sse_stream).into_response()
}

/// Translate a node event into one or more SSE events.
fn events_for(
    ev: RequestEvent,
    rid: &str,
    model: &str,
    created: u64,
) -> Vec<Result<Event, Infallible>> {
    match ev {
        RequestEvent::Chunk(c) => vec![Ok(
            Event::default().data(chunk_json(rid, model, created, &c.delta, None).to_string())
        )],
        RequestEvent::Done(_) => vec![
            Ok(Event::default()
                .data(chunk_json(rid, model, created, "", Some("stop")).to_string())),
            Ok(Event::default().data("[DONE]")),
        ],
        RequestEvent::Error(e) => {
            let err = json!({ "error": { "message": e.message } });
            vec![
                Ok(Event::default().data(err.to_string())),
                Ok(Event::default().data("[DONE]")),
            ]
        }
    }
}

/// Non-streaming path: accumulate tokens, return a single completion object.
async fn buffered_response(
    state: AppState,
    request_id: String,
    model: String,
    mut event_rx: tokio::sync::mpsc::UnboundedReceiver<RequestEvent>,
) -> Response {
    let created = unix_now();
    let mut content = String::new();
    let mut usage = json!({ "prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0 });
    let mut errored: Option<String> = None;

    while let Some(ev) = event_rx.recv().await {
        match ev {
            RequestEvent::Chunk(c) => content.push_str(&c.delta),
            RequestEvent::Done(d) => {
                usage = json!({
                    "prompt_tokens": d.usage.prompt_tokens,
                    "completion_tokens": d.usage.completion_tokens,
                    "total_tokens": d.usage.total_tokens,
                });
                break;
            }
            RequestEvent::Error(e) => {
                errored = Some(e.message);
                break;
            }
        }
    }

    state.registry.complete_request(&request_id);

    if let Some(message) = errored {
        warn!("request {request_id} failed: {message}");
        return error_response(StatusCode::BAD_GATEWAY, &message);
    }

    let body = json!({
        "id": format!("chatcmpl-{request_id}"),
        "object": "chat.completion",
        "created": created,
        "model": model,
        "choices": [{
            "index": 0,
            "message": { "role": "assistant", "content": content },
            "finish_reason": "stop",
        }],
        "usage": usage,
    });
    Json(body).into_response()
}

fn error_response(status: StatusCode, message: &str) -> Response {
    (status, Json(json!({ "error": { "message": message } }))).into_response()
}
