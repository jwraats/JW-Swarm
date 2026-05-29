//! In-memory registry of connected nodes and in-flight requests.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use tokio::sync::mpsc;

use crate::proto::{Message, Metrics, Register, ScheduleStateValue};

/// An event streamed back from a node for an in-flight request.
#[derive(Debug, Clone)]
pub enum RequestEvent {
    Chunk(crate::proto::TokenChunk),
    Done(crate::proto::Done),
    Error(crate::proto::ProtoError),
}

/// Live state for a single connected node.
#[derive(Clone)]
pub struct NodeState {
    pub node_id: String,
    pub register: Register,
    pub metrics: Option<Metrics>,
    pub ready_models: Vec<String>,
    pub schedule_state: ScheduleStateValue,
    /// Outbound channel to the node's tunnel writer task.
    pub tx: mpsc::UnboundedSender<Message>,
}

impl NodeState {
    /// True if this node can currently serve the given model.
    pub fn can_serve(&self, model: &str) -> bool {
        self.schedule_state == ScheduleStateValue::Awake
            && self.ready_models.iter().any(|m| m == model)
    }
}

#[derive(Default)]
struct Inner {
    nodes: HashMap<String, NodeState>,
    pending: HashMap<String, mpsc::UnboundedSender<RequestEvent>>,
}

/// Shared, cloneable registry handle.
#[derive(Clone, Default)]
pub struct Registry {
    inner: Arc<RwLock<Inner>>,
}

impl Registry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register or replace a node, returning its id.
    pub fn upsert_node(&self, register: Register, tx: mpsc::UnboundedSender<Message>) {
        let mut inner = self.inner.write().unwrap();
        let node_id = register.node_id.clone();
        inner.nodes.insert(
            node_id.clone(),
            NodeState {
                node_id,
                register,
                metrics: None,
                ready_models: Vec::new(),
                schedule_state: ScheduleStateValue::Asleep,
                tx,
            },
        );
    }

    pub fn remove_node(&self, node_id: &str) {
        self.inner.write().unwrap().nodes.remove(node_id);
    }

    pub fn update_metrics(&self, node_id: &str, metrics: Metrics, state: ScheduleStateValue) {
        let mut inner = self.inner.write().unwrap();
        if let Some(node) = inner.nodes.get_mut(node_id) {
            node.metrics = Some(metrics);
            node.schedule_state = state;
        }
    }

    pub fn update_ready_models(&self, node_id: &str, ready_models: Vec<String>) {
        let mut inner = self.inner.write().unwrap();
        if let Some(node) = inner.nodes.get_mut(node_id) {
            node.ready_models = ready_models;
        }
    }

    pub fn update_schedule(&self, node_id: &str, state: ScheduleStateValue) {
        let mut inner = self.inner.write().unwrap();
        if let Some(node) = inner.nodes.get_mut(node_id) {
            node.schedule_state = state;
        }
    }

    /// Snapshot of all current nodes.
    pub fn snapshot(&self) -> Vec<NodeState> {
        self.inner.read().unwrap().nodes.values().cloned().collect()
    }

    /// Distinct set of models that have at least one ready, awake node.
    pub fn available_models(&self) -> Vec<String> {
        let inner = self.inner.read().unwrap();
        let mut models: Vec<String> = inner
            .nodes
            .values()
            .filter(|n| n.schedule_state == ScheduleStateValue::Awake)
            .flat_map(|n| n.ready_models.clone())
            .collect();
        models.sort();
        models.dedup();
        models
    }

    /// Get a clone of a node's outbound sender.
    pub fn node_sender(&self, node_id: &str) -> Option<mpsc::UnboundedSender<Message>> {
        self.inner
            .read()
            .unwrap()
            .nodes
            .get(node_id)
            .map(|n| n.tx.clone())
    }

    /// Get a node's GPU vendor (from its registration).
    pub fn node_vendor(&self, node_id: &str) -> Option<crate::proto::GpuVendor> {
        self.inner
            .read()
            .unwrap()
            .nodes
            .get(node_id)
            .map(|n| n.register.gpu.vendor)
    }

    // --- in-flight request correlation ---

    pub fn register_request(&self, request_id: String, tx: mpsc::UnboundedSender<RequestEvent>) {
        self.inner.write().unwrap().pending.insert(request_id, tx);
    }

    pub fn complete_request(&self, request_id: &str) {
        self.inner.write().unwrap().pending.remove(request_id);
    }

    /// Forward a node event to the waiting request handler, if any.
    pub fn dispatch_event(&self, request_id: &str, event: RequestEvent) {
        let inner = self.inner.read().unwrap();
        if let Some(tx) = inner.pending.get(request_id) {
            let _ = tx.send(event);
        }
    }
}
