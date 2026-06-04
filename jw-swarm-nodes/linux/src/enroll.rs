use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{anyhow, Context};
use serde::{Deserialize, Serialize};

use crate::config;

#[derive(Debug)]
pub struct EnrollArgs {
    pub base_url: String,
    pub node_id: String,
    pub token: String,
    pub out_dir: PathBuf,
    pub write_config: bool,
}

#[derive(Debug, Deserialize)]
struct EnrollResponse {
    node_cert_pem: String,
    ca_cert_pem: String,
}

#[derive(Debug, Serialize)]
struct EnrollRequest {
    node_id: String,
    token: String,
    csr_pem: String,
}

pub fn parse_args(args: &[String]) -> anyhow::Result<EnrollArgs> {
    let mut base_url: Option<String> = None;
    let mut node_id: Option<String> = None;
    let mut token: Option<String> = None;
    let mut out_dir = PathBuf::from("/etc/jw-swarm-node");
    let mut write_config = true;

    let mut i = 0usize;
    while i < args.len() {
        match args[i].as_str() {
            "--base-url" => {
                i += 1;
                base_url = args.get(i).cloned();
            }
            "--node-id" => {
                i += 1;
                node_id = args.get(i).cloned();
            }
            "--token" => {
                i += 1;
                token = args.get(i).cloned();
            }
            "--out-dir" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    out_dir = PathBuf::from(v);
                }
            }
            "--no-write-config" => {
                write_config = false;
            }
            "-h" | "--help" => {
                print_help();
                std::process::exit(0);
            }
            other => {
                return Err(anyhow!("unknown argument: {other}"));
            }
        }
        i += 1;
    }

    Ok(EnrollArgs {
        base_url: base_url.context("--base-url is required")?,
        node_id: node_id.context("--node-id is required")?,
        token: token.context("--token is required")?,
        out_dir,
        write_config,
    })
}

pub async fn run(args: EnrollArgs) -> anyhow::Result<()> {
    fs::create_dir_all(&args.out_dir)
        .with_context(|| format!("failed to create {}", args.out_dir.display()))?;

    let key_path = args.out_dir.join(format!("{}.key", args.node_id));
    let csr_path = args.out_dir.join(format!("{}.csr", args.node_id));
    let cert_path = args.out_dir.join(format!("{}.crt", args.node_id));
    let node_pem_path = args.out_dir.join("node.pem");
    let ca_path = args.out_dir.join("ca.crt");

    run_openssl([
        "genrsa",
        "-out",
        key_path.to_str().unwrap_or("node.key"),
        "2048",
    ])?;

    run_openssl([
        "req",
        "-new",
        "-key",
        key_path.to_str().unwrap_or("node.key"),
        "-subj",
        &format!("/CN={}", args.node_id),
        "-out",
        csr_path.to_str().unwrap_or("node.csr"),
    ])?;

    let csr_pem = fs::read_to_string(&csr_path)
        .with_context(|| format!("failed to read {}", csr_path.display()))?;

    let client = reqwest::Client::new();
    let base = args.base_url.trim_end_matches('/').to_string();

    let ca_url = format!("{base}/bootstrap/ca.crt");
    let ca_bytes = client
        .get(&ca_url)
        .send()
        .await
        .context("failed to GET bootstrap CA")?
        .error_for_status()
        .context("CA endpoint returned error")?
        .bytes()
        .await
        .context("failed reading CA body")?;
    fs::write(&ca_path, &ca_bytes)
        .with_context(|| format!("failed to write {}", ca_path.display()))?;

    let enroll_url = format!("{base}/bootstrap/enroll");
    let payload = EnrollRequest {
        node_id: args.node_id.clone(),
        token: args.token.clone(),
        csr_pem,
    };
    let response = client
        .post(&enroll_url)
        .json(&payload)
        .send()
        .await
        .context("failed to POST enroll request")?
        .error_for_status()
        .context("enroll endpoint returned error")?
        .json::<EnrollResponse>()
        .await
        .context("failed to decode enroll response")?;

    fs::write(&cert_path, response.node_cert_pem.as_bytes())
        .with_context(|| format!("failed to write {}", cert_path.display()))?;
    fs::write(&ca_path, response.ca_cert_pem.as_bytes())
        .with_context(|| format!("failed to write {}", ca_path.display()))?;

    let mut pem = fs::read_to_string(&cert_path)?;
    pem.push('\n');
    pem.push_str(&fs::read_to_string(&key_path)?);
    fs::write(&node_pem_path, pem.as_bytes())
        .with_context(|| format!("failed to write {}", node_pem_path.display()))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&key_path, fs::Permissions::from_mode(0o600)).ok();
        fs::set_permissions(&node_pem_path, fs::Permissions::from_mode(0o600)).ok();
        fs::set_permissions(&ca_path, fs::Permissions::from_mode(0o644)).ok();
    }

    if args.write_config {
        let mut cfg = config::Config::load();
        cfg.node_id = args.node_id.clone();
        cfg.node_cert = node_pem_path.display().to_string();
        cfg.ca_cert = ca_path.display().to_string();
        cfg.fleet_url = to_wss_connect_url(&args.base_url);
        cfg.save()?;
        println!("Updated config at {}", config::config_path().display());
    }

    println!("Enrollment complete.");
    println!("Node cert: {}", node_pem_path.display());
    println!("CA cert:   {}", ca_path.display());
    println!("Fleet URL: {}", to_wss_connect_url(&args.base_url));

    Ok(())
}

fn to_wss_connect_url(base_url: &str) -> String {
    let trimmed = base_url.trim().trim_end_matches('/');
    if let Some(rest) = trimmed.strip_prefix("https://") {
        format!("wss://{rest}/node/connect")
    } else if let Some(rest) = trimmed.strip_prefix("http://") {
        format!("ws://{rest}/node/connect")
    } else {
        format!("{trimmed}/node/connect")
    }
}

fn run_openssl<const N: usize>(args: [&str; N]) -> anyhow::Result<()> {
    let output = Command::new("/usr/bin/openssl")
        .args(args)
        .output()
        .context("failed to execute openssl")?;
    if !output.status.success() {
        return Err(anyhow!(
            "openssl failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(())
}

pub fn print_help() {
    println!(
        "jw-swarm-node enroll --base-url <https://swarm.example.com> --node-id <node-id> --token <one-time-token> [--out-dir </etc/jw-swarm-node>] [--no-write-config]"
    );
}

#[allow(dead_code)]
fn ensure_parent_exists(path: &Path) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    Ok(())
}
