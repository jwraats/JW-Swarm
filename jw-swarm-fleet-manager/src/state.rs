//! Shared application state passed to all handlers.

use std::sync::Arc;

use crate::catalog::Catalog;
use crate::registry::Registry;
use crate::router::Weights;

#[derive(Clone)]
pub struct AppState {
    pub registry: Registry,
    pub catalog: Arc<Catalog>,
    pub weights: Weights,
}

impl AppState {
    pub fn new(catalog: Catalog) -> Self {
        Self {
            registry: Registry::new(),
            catalog: Arc::new(catalog),
            weights: Weights::default(),
        }
    }
}
