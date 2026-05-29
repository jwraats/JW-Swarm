//! Node selection (routing/scheduling) logic.

use crate::registry::NodeState;
use crate::proto::ScheduleStateValue;

/// Tunable scoring weights for node selection.
#[derive(Debug, Clone, Copy)]
pub struct Weights {
    pub vram: f64,
    pub tps: f64,
    pub latency: f64,
    pub load: f64,
}

impl Default for Weights {
    fn default() -> Self {
        Self {
            vram: 1.0,
            tps: 1.0,
            latency: 1.0,
            load: 1.0,
        }
    }
}

/// Compute a routing score for a candidate node. Higher is better.
fn score(node: &NodeState, w: &Weights) -> f64 {
    let m = match &node.metrics {
        Some(m) => m,
        None => return f64::NEG_INFINITY,
    };

    let free_vram = m.vram_total_mb.saturating_sub(m.vram_used_mb) as f64;
    let free_vram_norm = if m.vram_total_mb > 0 {
        free_vram / m.vram_total_mb as f64
    } else {
        0.0
    };
    // Normalize TPS against a reference ceiling so weights stay comparable.
    let tps_norm = (m.tps / 200.0).min(1.0);
    let latency_norm = (m.latency_ms / 1000.0).min(1.0);
    let load_norm = (m.in_flight as f64 / 8.0).min(1.0);

    w.vram * free_vram_norm + w.tps * tps_norm - w.latency * latency_norm - w.load * load_norm
}

/// Pick the best node for a model from a set of candidates.
///
/// Returns the `node_id` of the chosen node, or `None` if no node can serve the model.
pub fn pick_node(nodes: &[NodeState], model: &str, weights: &Weights) -> Option<String> {
    nodes
        .iter()
        .filter(|n| n.schedule_state == ScheduleStateValue::Awake && n.can_serve(model))
        .max_by(|a, b| {
            score(a, weights)
                .partial_cmp(&score(b, weights))
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(|n| n.node_id.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::{GpuInfo, GpuVendor, Metrics, OsKind, OwnerLimits, Register};
    use tokio::sync::mpsc;

    fn make_node(
        id: &str,
        ready: &[&str],
        state: ScheduleStateValue,
        metrics: Option<Metrics>,
    ) -> NodeState {
        let (tx, _rx) = mpsc::unbounded_channel();
        NodeState {
            node_id: id.into(),
            register: Register {
                node_id: id.into(),
                hostname: id.into(),
                os: OsKind::Linux,
                gpu: GpuInfo {
                    vendor: GpuVendor::Nvidia,
                    name: "RTX".into(),
                    vram_mb: 24000,
                },
                limits: OwnerLimits {
                    gpu_power_pct: 100,
                    memory_limit_mb: 24000,
                },
                selected_models: ready.iter().map(|s| s.to_string()).collect(),
            },
            metrics,
            ready_models: ready.iter().map(|s| s.to_string()).collect(),
            schedule_state: state,
            tx,
        }
    }

    fn metrics(free_mb: u64, total_mb: u64, tps: f64, latency: f64, in_flight: u32) -> Metrics {
        Metrics {
            vram_used_mb: total_mb - free_mb,
            vram_total_mb: total_mb,
            gpu_util_pct: 50.0,
            tps,
            latency_ms: latency,
            in_flight,
        }
    }

    #[test]
    fn returns_none_when_no_ready_node() {
        let nodes = vec![make_node("a", &[], ScheduleStateValue::Awake, None)];
        assert_eq!(pick_node(&nodes, "m1", &Weights::default()), None);
    }

    #[test]
    fn skips_asleep_nodes() {
        let nodes = vec![make_node(
            "a",
            &["m1"],
            ScheduleStateValue::Asleep,
            Some(metrics(20000, 24000, 100.0, 100.0, 0)),
        )];
        assert_eq!(pick_node(&nodes, "m1", &Weights::default()), None);
    }

    #[test]
    fn prefers_node_with_more_free_vram_and_higher_tps() {
        let nodes = vec![
            make_node(
                "small",
                &["m1"],
                ScheduleStateValue::Awake,
                Some(metrics(2000, 24000, 40.0, 300.0, 4)),
            ),
            make_node(
                "big",
                &["m1"],
                ScheduleStateValue::Awake,
                Some(metrics(22000, 24000, 150.0, 80.0, 0)),
            ),
        ];
        assert_eq!(
            pick_node(&nodes, "m1", &Weights::default()),
            Some("big".to_string())
        );
    }

    #[test]
    fn only_considers_nodes_with_the_model() {
        let nodes = vec![
            make_node(
                "has-other",
                &["other"],
                ScheduleStateValue::Awake,
                Some(metrics(22000, 24000, 150.0, 80.0, 0)),
            ),
            make_node(
                "has-target",
                &["m1"],
                ScheduleStateValue::Awake,
                Some(metrics(8000, 24000, 60.0, 200.0, 2)),
            ),
        ];
        assert_eq!(
            pick_node(&nodes, "m1", &Weights::default()),
            Some("has-target".to_string())
        );
    }
}
