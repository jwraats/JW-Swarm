//! Wire protocol types for the JW Swarm node tunnel.
//!
//! These types mirror `proto/schema.json`, the language-neutral source of truth.
//! Messages are exchanged as a tagged envelope: `{ "type": ..., "payload": ... }`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Schedule state reported by a node.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ScheduleStateValue {
    Awake,
    Asleep,
    Draining,
}

/// GPU vendor of a node.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GpuVendor {
    Nvidia,
    Amd,
    Apple,
    Intel,
}

/// Operating system of a node.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OsKind {
    Macos,
    Linux,
    Windows,
}

/// Inference backend hint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Backend {
    #[serde(rename = "vllm")]
    Vllm,
    #[serde(rename = "llama.cpp")]
    LlamaCpp,
    #[serde(rename = "mlx")]
    Mlx,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GpuInfo {
    pub vendor: GpuVendor,
    pub name: String,
    pub vram_mb: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OwnerLimits {
    pub gpu_power_pct: u8,
    pub memory_limit_mb: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Metrics {
    pub vram_used_mb: u64,
    pub vram_total_mb: u64,
    pub gpu_util_pct: f64,
    pub tps: f64,
    pub latency_ms: f64,
    pub in_flight: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CatalogModel {
    pub id: String,
    pub display_name: String,
    pub download_url: String,
    pub sha256: String,
    pub size_bytes: u64,
    pub context_length: u32,
    pub params_billions: f64,
    pub backend: Backend,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Usage {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub total_tokens: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Register {
    pub node_id: String,
    pub hostname: String,
    pub os: OsKind,
    pub gpu: GpuInfo,
    pub limits: OwnerLimits,
    pub selected_models: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CatalogResponse {
    pub models: Vec<CatalogModel>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Heartbeat {
    pub node_id: String,
    pub metrics: Metrics,
    pub schedule_state: ScheduleStateValue,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelStatus {
    pub node_id: String,
    pub ready_models: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScheduleState {
    pub node_id: String,
    pub state: ScheduleStateValue,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PromptDispatch {
    pub request_id: String,
    pub model: String,
    pub payload: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenChunk {
    pub request_id: String,
    pub delta: String,
    pub index: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Done {
    pub request_id: String,
    pub usage: Usage,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProtoError {
    pub request_id: String,
    pub message: String,
}

/// A tunnel message envelope. `type` is the tag and `payload` carries the body.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload")]
pub enum Message {
    // Node -> Fleet Manager
    Register(Register),
    CatalogRequest,
    Heartbeat(Heartbeat),
    ModelStatus(ModelStatus),
    ScheduleState(ScheduleState),
    TokenChunk(TokenChunk),
    Done(Done),
    Error(ProtoError),

    // Fleet Manager -> Node
    CatalogResponse(CatalogResponse),
    PromptDispatch(PromptDispatch),
}

impl Message {
    /// Serialize to a JSON string for the wire.
    pub fn to_json(&self) -> serde_json::Result<String> {
        serde_json::to_string(self)
    }

    /// Parse a JSON string from the wire.
    pub fn from_json(s: &str) -> serde_json::Result<Self> {
        serde_json::from_str(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn envelope_roundtrip_catalog_request() {
        let msg = Message::CatalogRequest;
        let json = msg.to_json().unwrap();
        assert!(json.contains("\"type\":\"CatalogRequest\""));
        let back = Message::from_json(&json).unwrap();
        assert!(matches!(back, Message::CatalogRequest));
    }

    #[test]
    fn envelope_roundtrip_heartbeat() {
        let hb = Heartbeat {
            node_id: "n1".into(),
            metrics: Metrics {
                vram_used_mb: 1000,
                vram_total_mb: 24000,
                gpu_util_pct: 42.0,
                tps: 80.0,
                latency_ms: 120.0,
                in_flight: 1,
            },
            schedule_state: ScheduleStateValue::Awake,
        };
        let json = Message::Heartbeat(hb).to_json().unwrap();
        let back = Message::from_json(&json).unwrap();
        match back {
            Message::Heartbeat(h) => {
                assert_eq!(h.node_id, "n1");
                assert_eq!(h.schedule_state, ScheduleStateValue::Awake);
            }
            _ => panic!("wrong variant"),
        }
    }
}
