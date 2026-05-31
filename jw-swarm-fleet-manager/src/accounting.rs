//! Accounting service: converts delivered work and capacity into points.
//!
//! Formula (weights configurable):
//!
//!   delivery_points  = completion_tokens * model_size_factor * w_tokens
//!   capacity_points  = awake_seconds * (gpu_power_pct/100) * (vram_mb/1024) * w_capacity

use crate::proto::Usage;

#[derive(Debug, Clone, Copy)]
pub struct Weights {
    pub tokens: f64,
    pub capacity: f64,
}

impl Default for Weights {
    fn default() -> Self {
        Self {
            tokens: 0.01,
            capacity: 0.001,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Accounting {
    pub weights: Weights,
}

impl Default for Accounting {
    fn default() -> Self {
        Self {
            weights: Weights::default(),
        }
    }
}

impl Accounting {
    /// Points earned for completed token delivery.
    ///
    /// model_size_factor = params_billions / 7.0 (normalized to a 7B baseline).
    pub fn delivery_points(&self, usage: &Usage, params_billions: f64) -> f64 {
        let size_factor = if params_billions > 0.0 {
            params_billions / 7.0
        } else {
            1.0
        };
        usage.completion_tokens as f64 * size_factor * self.weights.tokens
    }

    /// Points earned for keeping hardware available.
    pub fn capacity_points(&self, awake_seconds: f64, gpu_power_pct: f64, vram_mb: f64) -> f64 {
        awake_seconds
            * (gpu_power_pct / 100.0)
            * (vram_mb / 1024.0)
            * self.weights.capacity
    }
}
