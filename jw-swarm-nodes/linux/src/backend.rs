use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, RwLock};
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::proto::{Done, Message, ProtoError, TokenChunk, Usage};

pub struct BackendManager {
    models: RwLock<HashMap<String, PathBuf>>,
    active_model: Mutex<Option<String>>,
    memory_limit_mb: u64,
}

impl BackendManager {
    pub fn new(memory_limit_mb: u64) -> Self {
        Self {
            models: RwLock::new(HashMap::new()),
            active_model: Mutex::new(None),
            memory_limit_mb,
        }
    }

    /// Register a downloaded model, but only if its on-disk artifact fits within
    /// the configured memory budget. Oversized models are skipped so they are
    /// never advertised as ready, mirroring the macOS backend behavior.
    pub fn register(&self, id: String, dir: PathBuf) {
        match model_size_mb(&dir) {
            Some(size_mb) if size_mb > self.memory_limit_mb => {
                warn!(
                    "skip {}: artifact {}MB exceeds memory limit {}MB",
                    id, size_mb, self.memory_limit_mb
                );
                self.models.write().unwrap().remove(&id);
            }
            _ => {
                self.models.write().unwrap().insert(id, dir);
            }
        }
    }
    pub fn ready(&self) -> Vec<String> {
        let m = self.models.read().unwrap();
        let mut ids: Vec<String> = m.keys().cloned().collect();
        ids.sort();
        ids
    }
    pub fn loaded_model(&self) -> Option<String> {
        self.active_model.lock().unwrap().clone()
    }
    pub fn dispatch(
        &self,
        pd: &crate::proto::PromptDispatch,
        send: mpsc::UnboundedSender<String>,
    ) {
        let rid = pd.request_id.clone();
        if !self.models.read().unwrap().contains_key(&pd.model) {
            let _ = send.send(Message::Error(ProtoError {
                request_id: rid,
                message: format!("Model file missing for {}", pd.model),
            }).to_json().unwrap());
            warn!("dispatch rejected for {}: model not ready", pd.model);
            return;
        }

        {
            let mut active = self.active_model.lock().unwrap();
            if active.as_deref() != Some(&pd.model) {
                if let Some(prev) = active.as_ref() {
                    info!("unloaded {}", prev);
                }
                *active = Some(pd.model.clone());
                info!("loaded {}", pd.model);
            }
        }

        let stub = ["Hello", ",", " ", "simulated", " ", "response", ".", " ", "!"];
        let pt = pd.payload.get("messages").and_then(|m| m.as_array())
            .map(|a| a.iter()
                .filter_map(|v| v.get("content").and_then(|c| c.as_str()))
                .map(|s| s.len() / 4)
                .sum::<usize>())
            .unwrap_or(50) as u32;
        for (i, t) in stub.iter().enumerate() {
            let _ = send.send(Message::TokenChunk(TokenChunk {
                request_id: rid.clone(),
                delta: t.to_string(),
                index: i as u32,
            }).to_json().unwrap());
        }
        let _ = send.send(Message::Done(Done {
            request_id: rid,
            usage: Usage {
                prompt_tokens: pt,
                completion_tokens: stub.len() as u32,
                total_tokens: (pt as u64 + stub.len() as u64) as u32,
            },
        }).to_json().unwrap());
        info!("stub done for {} on {}", pd.request_id, pd.model);
    }
}

/// Returns the size in MB of the model artifact stored under `dir`.
fn model_size_mb(dir: &PathBuf) -> Option<u64> {
    let weights = dir.join("weights.bin");
    std::fs::metadata(&weights)
        .ok()
        .map(|m| m.len() / (1024 * 1024))
}

impl Default for BackendManager {
    fn default() -> Self { Self::new(24_000) }
}
