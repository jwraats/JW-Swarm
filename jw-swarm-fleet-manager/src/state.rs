//! Shared application state passed to all handlers.

use std::sync::Arc;

use crate::accounting::Accounting;
use crate::catalog::Catalog;
use crate::db::Db;
use crate::registry::Registry;
use crate::router::Weights;

#[derive(Clone)]
pub struct EnrollmentConfig {
    pub enabled: bool,
    pub ca_cert_path: String,
    pub ca_key_path: String,
    pub admin_token: Option<String>,
    pub default_token_ttl_seconds: i64,
    pub cert_valid_days: u32,
}

impl EnrollmentConfig {
    pub fn from_env() -> Self {
        let enabled = std::env::var("JW_ENROLL_ENABLE")
            .ok()
            .map(|v| matches!(v.to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"))
            .unwrap_or(false);

        let ca_cert_path = std::env::var("JW_ENROLL_CA_CERT")
            .unwrap_or_else(|_| "/etc/jw-swarm/ca/ca.crt".to_string());
        let ca_key_path = std::env::var("JW_ENROLL_CA_KEY")
            .unwrap_or_else(|_| "/etc/jw-swarm/ca/ca.key".to_string());

        let admin_token = std::env::var("JW_ENROLL_ADMIN_TOKEN")
            .ok()
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty());

        let default_token_ttl_seconds = std::env::var("JW_ENROLL_TOKEN_TTL_SECONDS")
            .ok()
            .and_then(|v| v.parse::<i64>().ok())
            .filter(|v| *v >= 60)
            .unwrap_or(600);

        let cert_valid_days = std::env::var("JW_ENROLL_CERT_DAYS")
            .ok()
            .and_then(|v| v.parse::<u32>().ok())
            .filter(|v| *v >= 1)
            .unwrap_or(30);

        Self {
            enabled,
            ca_cert_path,
            ca_key_path,
            admin_token,
            default_token_ttl_seconds,
            cert_valid_days,
        }
    }
}

#[derive(Clone)]
pub struct AppState {
    pub registry: Registry,
    pub catalog: Arc<Catalog>,
    pub weights: Weights,
    pub db: Db,
    pub accounting: Accounting,
    pub enrollment: EnrollmentConfig,
}

impl AppState {
    pub fn new(catalog: Catalog, db: Db) -> Self {
        Self {
            registry: Registry::new(),
            catalog: Arc::new(catalog),
            weights: Weights::default(),
            db,
            accounting: Accounting::default(),
            enrollment: EnrollmentConfig::from_env(),
        }
    }
}
