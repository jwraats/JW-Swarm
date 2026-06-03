//! Minimal secure bootstrap enrollment API.
//!
//! Flow:
//! 1) Admin creates one-time token bound to node_id.
//! 2) Node downloads CA cert and submits CSR + token.
//! 3) Server signs CSR, then consumes token and returns signed client cert.

use std::fmt::Write as _;
use std::path::Path;

use axum::extract::State;
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use time::{Duration, OffsetDateTime};
use tokio::process::Command;
use tracing::warn;
use uuid::Uuid;

use crate::state::AppState;

#[derive(Deserialize)]
pub struct CreateTokenRequest {
    pub node_id: String,
    pub ttl_seconds: Option<i64>,
}

#[derive(Serialize)]
pub struct CreateTokenResponse {
    pub node_id: String,
    pub token: String,
    pub token_hash: String,
    pub expires_at: String,
}

#[derive(Serialize)]
pub struct TokenListItem {
    pub token_hash: String,
    pub node_id: String,
    pub created_at: String,
    pub expires_at: String,
    pub used_at: Option<String>,
    pub created_by: String,
}

#[derive(Deserialize)]
pub struct EnrollRequest {
    pub node_id: String,
    pub token: String,
    pub csr_pem: String,
}

#[derive(Serialize)]
pub struct EnrollResponse {
    pub node_id: String,
    pub node_cert_pem: String,
    pub ca_cert_pem: String,
    pub cert_days: u32,
}

pub async fn download_ca(State(state): State<AppState>) -> Response {
    if !state.enrollment.enabled {
        return json_error(StatusCode::NOT_FOUND, "enrollment disabled");
    }

    match tokio::fs::read_to_string(&state.enrollment.ca_cert_path).await {
        Ok(ca_pem) => {
            let mut headers = HeaderMap::new();
            headers.insert(header::CONTENT_TYPE, "application/x-pem-file".parse().unwrap());
            (headers, ca_pem).into_response()
        }
        Err(e) => {
            warn!("failed to read CA cert: {e}");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "failed to read CA cert")
        }
    }
}

pub async fn create_token(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<CreateTokenRequest>,
) -> Response {
    if !state.enrollment.enabled {
        return json_error(StatusCode::NOT_FOUND, "enrollment disabled");
    }

    if body.node_id.trim().is_empty() {
        return json_error(StatusCode::BAD_REQUEST, "node_id is required");
    }

    if !is_authorized_admin(&headers, state.enrollment.admin_token.as_deref()) {
        return json_error(StatusCode::UNAUTHORIZED, "unauthorized");
    }

    let ttl = body
        .ttl_seconds
        .filter(|v| *v >= 60 && *v <= 86_400)
        .unwrap_or(state.enrollment.default_token_ttl_seconds);

    let now = OffsetDateTime::now_utc();
    let expires_at = now + Duration::seconds(ttl);
    let expires_at_rfc3339 = match expires_at.format(&time::format_description::well_known::Rfc3339) {
        Ok(v) => v,
        Err(_) => return json_error(StatusCode::INTERNAL_SERVER_ERROR, "time formatting error"),
    };

    let node_id = body.node_id.trim().to_string();
    let token = format!("enr_{}_{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
    let token_hash = hash_token(&token);

    let created_by = extract_bearer(&headers)
        .map(|_| "api-admin")
        .unwrap_or("admin");

    if let Err(e) = state
        .db
        .insert_enrollment_token(&token_hash, &node_id, &expires_at_rfc3339, created_by)
        .await
    {
        warn!("failed to insert enrollment token: {e}");
        return json_error(StatusCode::INTERNAL_SERVER_ERROR, "failed to create token");
    }

    Json(CreateTokenResponse {
        node_id,
        token,
        token_hash,
        expires_at: expires_at_rfc3339,
    })
    .into_response()
}

pub async fn admin_list_tokens(State(state): State<AppState>, headers: HeaderMap) -> Response {
    if !state.enrollment.enabled {
        return json_error(StatusCode::NOT_FOUND, "enrollment disabled");
    }
    if !is_authorized_admin(&headers, state.enrollment.admin_token.as_deref()) {
        return json_error(StatusCode::UNAUTHORIZED, "unauthorized");
    }

    let rows = match state.db.list_enrollment_tokens().await {
        Ok(v) => v,
        Err(e) => {
            warn!("failed to list enrollment tokens: {e}");
            return json_error(StatusCode::INTERNAL_SERVER_ERROR, "failed to list tokens");
        }
    };

    let items: Vec<TokenListItem> = rows
        .into_iter()
        .map(|r| TokenListItem {
            token_hash: r.token_hash,
            node_id: r.node_id,
            created_at: r.created_at,
            expires_at: r.expires_at,
            used_at: r.used_at,
            created_by: r.created_by,
        })
        .collect();

    Json(items).into_response()
}

pub async fn admin_revoke_token(
    axum::extract::Path(token_hash): axum::extract::Path<String>,
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Response {
    if !state.enrollment.enabled {
        return json_error(StatusCode::NOT_FOUND, "enrollment disabled");
    }
    if !is_authorized_admin(&headers, state.enrollment.admin_token.as_deref()) {
        return json_error(StatusCode::UNAUTHORIZED, "unauthorized");
    }
    if token_hash.trim().is_empty() {
        return json_error(StatusCode::BAD_REQUEST, "token hash is required");
    }

    match state.db.revoke_enrollment_token(token_hash.trim()).await {
        Ok(true) => Json(json!({ "status": "revoked", "token_hash": token_hash })).into_response(),
        Ok(false) => json_error(StatusCode::NOT_FOUND, "token not found"),
        Err(e) => {
            warn!("failed to revoke token: {e}");
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "failed to revoke token")
        }
    }
}

pub async fn enroll_node(State(state): State<AppState>, Json(body): Json<EnrollRequest>) -> Response {
    if !state.enrollment.enabled {
        return json_error(StatusCode::NOT_FOUND, "enrollment disabled");
    }

    let node_id = body.node_id.trim();
    if node_id.is_empty() {
        return json_error(StatusCode::BAD_REQUEST, "node_id is required");
    }
    if body.token.trim().is_empty() {
        return json_error(StatusCode::BAD_REQUEST, "token is required");
    }
    if !body.csr_pem.contains("BEGIN CERTIFICATE REQUEST") {
        return json_error(StatusCode::BAD_REQUEST, "csr_pem must be a PEM CSR");
    }

    let cert_days = state.enrollment.cert_valid_days;
    let signed_cert = match sign_csr_with_ca(
        &body.csr_pem,
        &state.enrollment.ca_cert_path,
        &state.enrollment.ca_key_path,
        cert_days,
    )
    .await
    {
        Ok(v) => v,
        Err(e) => {
            warn!("CSR signing failed: {e}");
            return json_error(StatusCode::BAD_REQUEST, "CSR signing failed");
        }
    };

    let ca_cert_pem = match tokio::fs::read_to_string(&state.enrollment.ca_cert_path).await {
        Ok(v) => v,
        Err(e) => {
            warn!("failed to read CA cert after signing: {e}");
            return json_error(StatusCode::INTERNAL_SERVER_ERROR, "failed to read CA cert");
        }
    };

    let now_rfc3339 = match OffsetDateTime::now_utc().format(&time::format_description::well_known::Rfc3339) {
        Ok(v) => v,
        Err(_) => return json_error(StatusCode::INTERNAL_SERVER_ERROR, "time formatting error"),
    };

    let token_hash = hash_token(body.token.trim());
    let consumed = match state
        .db
        .consume_enrollment_token(&token_hash, node_id, &now_rfc3339)
        .await
    {
        Ok(v) => v,
        Err(e) => {
            warn!("token consume failed: {e}");
            return json_error(StatusCode::INTERNAL_SERVER_ERROR, "token validation failed");
        }
    };

    if !consumed {
        return json_error(StatusCode::UNAUTHORIZED, "invalid or expired token");
    }

    Json(EnrollResponse {
        node_id: node_id.to_string(),
        node_cert_pem: signed_cert,
        ca_cert_pem,
        cert_days,
    })
    .into_response()
}

fn is_authorized_admin(headers: &HeaderMap, expected_token: Option<&str>) -> bool {
    let Some(expected) = expected_token else {
        return false;
    };
    let Some(actual) = extract_bearer(headers) else {
        return false;
    };
    actual == expected
}

fn extract_bearer(headers: &HeaderMap) -> Option<String> {
    let value = headers.get(header::AUTHORIZATION)?.to_str().ok()?;
    let lower = value.to_ascii_lowercase();
    if !lower.starts_with("bearer ") {
        return None;
    }
    Some(value[7..].trim().to_string())
}

fn hash_token(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    let mut out = String::with_capacity(digest.len() * 2);
    for b in digest {
        let _ = write!(&mut out, "{b:02x}");
    }
    out
}

async fn sign_csr_with_ca(
    csr_pem: &str,
    ca_cert_path: &str,
    ca_key_path: &str,
    cert_days: u32,
) -> anyhow::Result<String> {
    if !Path::new(ca_cert_path).exists() || !Path::new(ca_key_path).exists() {
        anyhow::bail!("CA cert/key paths are missing");
    }

    let dir = std::env::temp_dir().join(format!("jw-enroll-{}", Uuid::new_v4()));
    tokio::fs::create_dir_all(&dir).await?;

    let csr_path = dir.join("node.csr");
    let cert_path = dir.join("node.crt");
    let serial_path = dir.join("ca.srl");
    let ext_path = dir.join("client.ext");

    tokio::fs::write(&csr_path, csr_pem).await?;
    tokio::fs::write(
        &ext_path,
        "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n",
    )
    .await?;

    let verify = Command::new("/usr/bin/openssl")
        .arg("req")
        .arg("-in")
        .arg(&csr_path)
        .arg("-noout")
        .arg("-verify")
        .output()
        .await?;
    if !verify.status.success() {
        anyhow::bail!(
            "invalid CSR: {}",
            String::from_utf8_lossy(&verify.stderr).trim()
        );
    }

    let sign = Command::new("/usr/bin/openssl")
        .arg("x509")
        .arg("-req")
        .arg("-in")
        .arg(&csr_path)
        .arg("-CA")
        .arg(ca_cert_path)
        .arg("-CAkey")
        .arg(ca_key_path)
        .arg("-CAserial")
        .arg(&serial_path)
        .arg("-CAcreateserial")
        .arg("-days")
        .arg(cert_days.to_string())
        .arg("-sha256")
        .arg("-extfile")
        .arg(&ext_path)
        .arg("-out")
        .arg(&cert_path)
        .output()
        .await?;

    if !sign.status.success() {
        anyhow::bail!(
            "signing failed: {}",
            String::from_utf8_lossy(&sign.stderr).trim()
        );
    }

    let signed = tokio::fs::read_to_string(&cert_path).await?;
    let _ = tokio::fs::remove_dir_all(&dir).await;
    Ok(signed)
}

fn json_error(status: StatusCode, message: &str) -> Response {
    (status, Json(json!({ "error": { "message": message } }))).into_response()
}
