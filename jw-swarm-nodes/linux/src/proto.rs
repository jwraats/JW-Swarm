//! Protocol types — node-side mirror of fleet-manager.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ScheduleStateValue {
    Awake,
    Asleep,
    Draining,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GpuVendor {
    Nvidia,
    Amd,
    Apple,
    Intel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OsKind {
    Macos,
    Linux,
    Windows,
}

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

/// A tunnel message envelope.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload")]
pub enum Message {
    /// Node -> Fleet Manager
    Register(Register),
    CatalogRequest,
    Heartbeat(Heartbeat),
    ModelStatus(ModelStatus),
    ScheduleState(ScheduleState),
    TokenChunk(TokenChunk),
    Done(Done),
    Error(ProtoError),
    /// Fleet Manager -> Node
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
