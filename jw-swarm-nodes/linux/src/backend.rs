//! Real llama.cpp inference backend — Linux mirror of the macOS `LlamaBackend`.
//!
//! A dedicated worker thread owns the llama.cpp backend and all resident
//! models; jobs are queued over a channel and token chunks stream back through
//! the tunnel's outbound sender. Resident models are managed LRU-style within
//! the configured memory budget, mirroring the macOS behavior.

use std::collections::HashMap;
use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use llama_cpp_2::context::params::LlamaContextParams;
use llama_cpp_2::llama_backend::LlamaBackend;
use llama_cpp_2::llama_batch::LlamaBatch;
use llama_cpp_2::model::params::LlamaModelParams;
use llama_cpp_2::model::{AddBos, LlamaModel};
use llama_cpp_2::sampling::LlamaSampler;
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::proto::{Done, Message, PromptDispatch, ProtoError, TokenChunk, Usage};

/// Cumulative token accounting for a single model.
#[derive(Debug, Clone, Copy, Default)]
pub struct ModelTokenUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub requests: u64,
}

/// Rolling throughput statistics across all completions.
#[derive(Debug, Clone, Copy, Default)]
pub struct BackendStats {
    pub avg_tps: f64,
    #[allow(dead_code)]
    pub last_tps: f64,
}

#[derive(Default)]
struct SharedState {
    /// Models that are downloaded, verified and within the memory budget.
    ready: HashMap<String, PathBuf>,
    /// Ids of models currently resident in memory (LRU order, oldest first).
    loaded_order: Vec<String>,
    total_completion_tokens: u64,
    total_generation_seconds: f64,
    last_tps: f64,
    token_usage: HashMap<String, ModelTokenUsage>,
}

struct Job {
    pd: PromptDispatch,
    send: mpsc::UnboundedSender<String>,
}

pub struct BackendManager {
    shared: Arc<Mutex<SharedState>>,
    jobs: std::sync::mpsc::Sender<Job>,
    memory_limit_mb: u64,
}

impl BackendManager {
    pub fn new(memory_limit_mb: u64) -> Self {
        let shared = Arc::new(Mutex::new(SharedState::default()));
        let (jobs, rx) = std::sync::mpsc::channel::<Job>();
        let worker_shared = shared.clone();
        std::thread::Builder::new()
            .name("llama-backend".into())
            .spawn(move || worker_loop(rx, worker_shared, memory_limit_mb))
            .expect("spawn llama backend worker");
        Self {
            shared,
            jobs,
            memory_limit_mb,
        }
    }

    /// Register a downloaded model, but only if its on-disk artifact fits within
    /// the configured memory budget. Oversized models are skipped so they are
    /// never advertised as ready, mirroring the macOS backend behavior.
    pub fn register(&self, id: String, dir: PathBuf) {
        match model_file(&dir).and_then(|f| file_size_mb(&f)) {
            Some(size_mb) if size_mb > self.memory_limit_mb => {
                warn!(
                    "skip {}: artifact {}MB exceeds memory limit {}MB",
                    id, size_mb, self.memory_limit_mb
                );
                self.shared.lock().unwrap().ready.remove(&id);
            }
            Some(_) => {
                self.shared.lock().unwrap().ready.insert(id, dir);
            }
            None => {
                warn!("skip {}: no model artifact found in {}", id, dir.display());
                self.shared.lock().unwrap().ready.remove(&id);
            }
        }
    }

    /// Sorted list of ready (registered, fitting) model ids.
    pub fn ready(&self) -> Vec<String> {
        let s = self.shared.lock().unwrap();
        let mut ids: Vec<String> = s.ready.keys().cloned().collect();
        ids.sort();
        ids
    }

    /// Models currently resident in memory (LRU order, oldest first).
    pub fn loaded_models(&self) -> Vec<String> {
        self.shared.lock().unwrap().loaded_order.clone()
    }

    /// Rolling average and most recent tokens/second.
    pub fn stats(&self) -> BackendStats {
        let s = self.shared.lock().unwrap();
        let avg = if s.total_generation_seconds > 0.0 {
            s.total_completion_tokens as f64 / s.total_generation_seconds
        } else {
            0.0
        };
        BackendStats {
            avg_tps: avg,
            last_tps: s.last_tps,
        }
    }

    /// Cumulative input/output token counts per model since the process started.
    #[allow(dead_code)]
    pub fn token_usage(&self) -> HashMap<String, ModelTokenUsage> {
        self.shared.lock().unwrap().token_usage.clone()
    }

    /// Queue a prompt for generation on the backend worker thread. Token
    /// chunks and the final Done/Error message stream through `send`.
    pub fn dispatch(&self, pd: &PromptDispatch, send: mpsc::UnboundedSender<String>) {
        let rid = pd.request_id.clone();
        if !self.shared.lock().unwrap().ready.contains_key(&pd.model) {
            let _ = send.send(
                Message::Error(ProtoError {
                    request_id: rid,
                    message: format!("Model file missing for {}", pd.model),
                })
                .to_json()
                .unwrap(),
            );
            warn!("dispatch rejected for {}: model not ready", pd.model);
            return;
        }
        if self
            .jobs
            .send(Job {
                pd: pd.clone(),
                send: send.clone(),
            })
            .is_err()
        {
            let _ = send.send(
                Message::Error(ProtoError {
                    request_id: rid,
                    message: "backend worker unavailable".into(),
                })
                .to_json()
                .unwrap(),
            );
        }
    }
}

/// Returns the model artifact within `dir`: prefer a `.gguf` file, then the
/// legacy `weights.bin`, then any file that is not the `sha256` marker.
fn model_file(dir: &Path) -> Option<PathBuf> {
    let entries: Vec<PathBuf> = std::fs::read_dir(dir)
        .ok()?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.is_file())
        .collect();
    if let Some(gguf) = entries.iter().find(|p| {
        p.extension()
            .map(|e| e.eq_ignore_ascii_case("gguf"))
            .unwrap_or(false)
    }) {
        return Some(gguf.clone());
    }
    let bin = dir.join("weights.bin");
    if bin.exists() {
        return Some(bin);
    }
    entries
        .into_iter()
        .find(|p| p.file_name().map(|n| n != "sha256").unwrap_or(false))
}

fn file_size_mb(file: &Path) -> Option<u64> {
    std::fs::metadata(file)
        .ok()
        .map(|m| (m.len() + 1024 * 1024 - 1) / (1024 * 1024))
        .map(|mb| mb.max(1))
}

struct LoadedModel {
    model: LlamaModel,
    resident_size_mb: u64,
}

fn worker_loop(
    rx: std::sync::mpsc::Receiver<Job>,
    shared: Arc<Mutex<SharedState>>,
    memory_limit_mb: u64,
) {
    let backend = match LlamaBackend::init() {
        Ok(b) => b,
        Err(e) => {
            warn!("llama backend init failed: {e}");
            return;
        }
    };

    let mut loaded: HashMap<String, LoadedModel> = HashMap::new();

    while let Ok(job) = rx.recv() {
        let rid = job.pd.request_id.clone();
        match generate(
            &backend,
            &mut loaded,
            &shared,
            memory_limit_mb,
            &job.pd,
            &job.send,
        ) {
            Ok(()) => {}
            Err(e) => {
                let msg = e.to_string();
                let _ = job.send.send(
                    Message::Error(ProtoError {
                        request_id: rid.clone(),
                        message: msg.clone(),
                    })
                    .to_json()
                    .unwrap(),
                );
                warn!("dispatch error for {rid}: {msg}");
            }
        }
    }
}

/// Unload least-recently-used models until resident memory (plus an optional
/// reservation) fits the budget. The preferred model is never evicted.
fn trim_loaded_to_budget(
    loaded: &mut HashMap<String, LoadedModel>,
    shared: &Arc<Mutex<SharedState>>,
    memory_limit_mb: u64,
    preferred: Option<&str>,
    reserving_mb: u64,
) {
    loop {
        let resident: u64 = loaded
            .iter()
            .filter(|(id, _)| Some(id.as_str()) != preferred)
            .map(|(_, m)| m.resident_size_mb)
            .sum();
        if resident + reserving_mb <= memory_limit_mb {
            return;
        }
        let candidate = {
            let s = shared.lock().unwrap();
            s.loaded_order
                .iter()
                .find(|id| Some(id.as_str()) != preferred && loaded.contains_key(*id))
                .cloned()
        };
        let Some(id) = candidate else { return };
        loaded.remove(&id);
        shared.lock().unwrap().loaded_order.retain(|x| x != &id);
        info!("unloaded {} due to resident memory budget {}MB", id, memory_limit_mb);
    }
}

fn touch_loaded(shared: &Arc<Mutex<SharedState>>, id: &str) {
    let mut s = shared.lock().unwrap();
    s.loaded_order.retain(|x| x != id);
    s.loaded_order.push(id.to_string());
}

fn generate(
    backend: &LlamaBackend,
    loaded: &mut HashMap<String, LoadedModel>,
    shared: &Arc<Mutex<SharedState>>,
    memory_limit_mb: u64,
    pd: &PromptDispatch,
    send: &mpsc::UnboundedSender<String>,
) -> Result<(), anyhow::Error> {
    let model_id = &pd.model;
    let dir = shared
        .lock()
        .unwrap()
        .ready
        .get(model_id)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("Model file missing for {model_id}"))?;

    // Ensure the model is resident, evicting older models to fit the budget.
    if !loaded.contains_key(model_id) {
        let file = model_file(&dir)
            .ok_or_else(|| anyhow::anyhow!("Model file missing for {model_id}"))?;
        let size_mb = file_size_mb(&file)
            .ok_or_else(|| anyhow::anyhow!("Model file missing for {model_id}"))?;
        if size_mb > memory_limit_mb {
            anyhow::bail!(
                "Model {model_id} is {size_mb}MB, over configured memory limit {memory_limit_mb}MB"
            );
        }
        trim_loaded_to_budget(loaded, shared, memory_limit_mb, None, size_mb);
        info!("loading {} from {}", model_id, file.display());
        let model = LlamaModel::load_from_file(backend, &file, &LlamaModelParams::default())
            .map_err(|e| anyhow::anyhow!("Failed to load model {model_id}: {e}"))?;
        loaded.insert(
            model_id.clone(),
            LoadedModel {
                model,
                resident_size_mb: size_mb,
            },
        );
    }
    touch_loaded(shared, model_id);
    trim_loaded_to_budget(loaded, shared, memory_limit_mb, Some(model_id), 0);

    let prompt = extract_prompt(&pd.payload);
    let max_tokens = extract_max_tokens(&pd.payload);
    let item = loaded.get(model_id).expect("model loaded above");

    let started = Instant::now();

    let tokens = item
        .model
        .str_to_token(&prompt, AddBos::Always)
        .map_err(|e| anyhow::anyhow!("Failed to tokenize input: {e}"))?;
    if tokens.is_empty() {
        anyhow::bail!("Failed to tokenize input");
    }

    let n_batch = tokens.len().max(512);
    let ctx_params = LlamaContextParams::default()
        .with_n_ctx(NonZeroU32::new(4096))
        .with_n_batch(n_batch as u32);
    let mut ctx = item
        .model
        .new_context(backend, ctx_params)
        .map_err(|e| anyhow::anyhow!("Failed to create context for {model_id}: {e}"))?;

    let mut batch = LlamaBatch::new(n_batch, 1);
    let last = tokens.len() - 1;
    for (i, t) in tokens.iter().enumerate() {
        batch.add(*t, i as i32, &[0], i == last)?;
    }
    ctx.decode(&mut batch)
        .map_err(|e| anyhow::anyhow!("Decoding failed: {e}"))?;

    let mut sampler = LlamaSampler::greedy();
    let mut decoder = encoding_rs::UTF_8.new_decoder();
    let mut n_cur = tokens.len() as i32;
    let mut completion_tokens: u32 = 0;

    for index in 0..max_tokens {
        let token = sampler.sample(&ctx, batch.n_tokens() - 1);
        sampler.accept(token);
        if item.model.is_eog_token(token) {
            break;
        }

        if let Ok(piece) = item.model.token_to_piece(token, &mut decoder, false, None) {
            if !piece.is_empty() {
                let _ = send.send(
                    Message::TokenChunk(TokenChunk {
                        request_id: pd.request_id.clone(),
                        delta: piece,
                        index: index as u32,
                    })
                    .to_json()?,
                );
            }
        }
        completion_tokens += 1;

        batch.clear();
        batch.add(token, n_cur, &[0], true)?;
        n_cur += 1;
        ctx.decode(&mut batch)
            .map_err(|e| anyhow::anyhow!("Decoding failed: {e}"))?;
    }

    let elapsed = started.elapsed().as_secs_f64();
    {
        let mut s = shared.lock().unwrap();
        if elapsed > 0.0 && completion_tokens > 0 {
            s.last_tps = completion_tokens as f64 / elapsed;
            s.total_completion_tokens += completion_tokens as u64;
            s.total_generation_seconds += elapsed;
        }
        let usage = s.token_usage.entry(model_id.clone()).or_default();
        usage.input_tokens += tokens.len() as u64;
        usage.output_tokens += completion_tokens as u64;
        usage.requests += 1;
    }

    let _ = send.send(
        Message::Done(Done {
            request_id: pd.request_id.clone(),
            usage: Usage {
                prompt_tokens: tokens.len() as u32,
                completion_tokens,
                total_tokens: tokens.len() as u32 + completion_tokens,
            },
        })
        .to_json()?,
    );
    info!(
        "done {} on {}: {} prompt + {} completion tokens in {:.2}s",
        pd.request_id,
        model_id,
        tokens.len(),
        completion_tokens,
        elapsed
    );
    Ok(())
}

/// Extract the prompt text: the last non-empty chat message content, falling
/// back to a bare `prompt` field — mirrors the macOS extraction logic.
fn extract_prompt(payload: &serde_json::Value) -> String {
    if let Some(messages) = payload.get("messages").and_then(|m| m.as_array()) {
        for msg in messages.iter().rev() {
            if let Some(content) = msg.get("content").and_then(|c| c.as_str()) {
                if !content.is_empty() {
                    return content.to_string();
                }
            }
        }
    }
    payload
        .get("prompt")
        .and_then(|p| p.as_str())
        .unwrap_or("")
        .to_string()
}

fn extract_max_tokens(payload: &serde_json::Value) -> usize {
    payload
        .get("max_tokens")
        .and_then(|v| v.as_u64())
        .map(|v| (v as usize).clamp(1, 512))
        .unwrap_or(128)
}
