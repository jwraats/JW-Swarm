//! Shared application state passed to all handlers.

use std::sync::Arc;

use crate::accounting::Accounting;
use crate::catalog::Catalog;
use crate::db::Db;
use crate::registry::Registry;
use crate::router::Weights;

#[derive(Clone)]
pub struct AppState {
    pub registry: Registry,
    pub catalog: Arc<Catalog>,
    pub weights: Weights,
    pub db: Db,
    pub accounting: Accounting,
}

impl AppState {
    pub fn new(catalog: Catalog, db: Db) -> Self {
        Self {
            registry: Registry::new(),
            catalog: Arc::new(catalog),
            weights: Weights::default(),
            db,
            accounting: Accounting::default(),
        }
    }
}
