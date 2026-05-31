use std::collections::HashMap;
use std::path::PathBuf;
use tokio::sync::mpsc;
use tracing::info;

use crate::proto::{Done, Message, TokenChunk, Usage};

pub struct BackendManager {
    models: std::sync::RwLock<HashMap<String, PathBuf>>,
}

impl BackendManager {
    pub fn new() -> Self { Self { models: std::sync::RwLock::new(HashMap::new()) } }
    pub fn register(&self, id: String, dir: PathBuf) {
        self.models.write().unwrap().insert(id, dir);
    }
    pub fn ready(&self) -> Vec<String> {
        let m = self.models.read().unwrap();
        m.keys().cloned().collect()
    }
    pub fn dispatch(
        &self,
        pd: &crate::proto::PromptDispatch,
        send: mpsc::UnboundedSender<String>,
    ) {
        let rid = pd.request_id.clone();
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
        info!("stub done for {}", pd.request_id);
    }
}

impl Default for BackendManager { fn default() -> Self { Self::new() } }
