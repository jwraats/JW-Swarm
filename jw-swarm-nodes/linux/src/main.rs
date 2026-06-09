use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use chrono::Timelike;
use tracing::{info, warn};

mod config;
mod proto;
mod tunnel;
mod backend;
mod enroll;
mod models;
mod metrics;

use proto::{Backend, GpuInfo, GpuVendor, Heartbeat, Message, ModelStatus, OsKind, OwnerLimits, Register, ScheduleState, ScheduleStateValue};

struct State {
    config: config::Config,
}

/// Tracks in-flight downloads and failed catalog fingerprints so a model is
/// neither downloaded twice concurrently nor endlessly retried against the
/// same catalog entry — mirrors the macOS coordinator.
#[derive(Default)]
struct DownloadTracker {
    downloading: HashSet<String>,
    /// model id -> (download_url, sha256) of the last failed attempt.
    failed: HashMap<String, (String, String)>,
}

#[tokio::main]
async fn main() -> Result<(), anyhow::Error> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(|v| v.as_str()) == Some("enroll") {
        let enroll_args = enroll::parse_args(&args[2..])?;
        enroll::run(enroll_args).await?;
        return Ok(());
    }

    let config = config::Config::load();
    info!(
        "JW Swarm Node v{} (id={})",
        env!("CARGO_PKG_VERSION"),
        config.node_id
    );

    let state = State { config: config.clone() };
    let bf = Arc::new(backend::BackendManager::new(config.limits.memory_limit_mb));
    run(state, bf).await;
    Ok(())
}

async fn run(state: State, bf: Arc<backend::BackendManager>) {
    let md = state.config.model_dir();
    std::fs::create_dir_all(&md).ok();

    let (handle, mut inb) = tunnel::Tunnel {
        fleet_url: state.config.fleet_url.clone(),
        node_cert: state.config.node_cert.clone(),
        ca_cert: state.config.ca_cert.clone(),
    }
    .run_loop();

    send_reg(&handle, &state);
    let _ = handle.outbound.send(Message::CatalogRequest.to_json().unwrap());

    let tracker = Arc::new(Mutex::new(DownloadTracker::default()));
    let mut catalog: HashMap<String, proto::CatalogModel> = HashMap::new();
    let mut connected_rx = handle.connected.clone();
    let mut awake = is_awake(&state.config.schedule);
    let mut hb = tokio::time::interval(Duration::from_secs(30));
    // Re-request the catalog periodically while no models are ready, mirroring
    // the macOS catalog poll task.
    let mut repoll = tokio::time::interval(Duration::from_secs(60));

    loop {
        tokio::select! {
            _ = hb.tick() => {
                let now_awake = is_awake(&state.config.schedule);
                if now_awake != awake {
                    awake = now_awake;
                    send_schedule_state(&handle, &state.config, awake);
                }
                send_hb(&handle, &state.config, &bf, awake);
            }
            _ = repoll.tick() => {
                if *connected_rx.borrow() && bf.ready().is_empty() {
                    let _ = handle.outbound.send(Message::CatalogRequest.to_json().unwrap());
                    info!("catalog re-poll: no ready models yet");
                }
            }
            changed = connected_rx.changed() => {
                if changed.is_err() {
                    warn!("tunnel gone");
                    break;
                }
                if *connected_rx.borrow() {
                    info!("tunnel connected; re-registering");
                    send_reg(&handle, &state);
                    let _ = handle.outbound.send(Message::CatalogRequest.to_json().unwrap());
                    send_hb(&handle, &state.config, &bf, awake);
                    send_model_status(&handle.outbound, &state.config.node_id, &bf);
                }
            }
            json = inb.recv() => {
                match json {
                    Some(s) => {
                        if let Err(e) = handle_msg(&handle, &state, &bf, &md, &tracker, &mut catalog, &s).await {
                            warn!("msg err: {e}");
                        }
                    }
                    None => {
                        warn!("tunnel gone");
                        break;
                    }
                }
            }
        }
    }
}

/// Whether the configured awake window currently applies. Empty or unparsable
/// bounds mean the node is always awake. Windows may wrap midnight.
fn is_awake(s: &config::Schedule) -> bool {
    let (Some(from), Some(until)) = (parse_hhmm(&s.awake_from), parse_hhmm(&s.awake_until)) else {
        return true;
    };
    if from == until {
        return true;
    }
    let now = chrono::Local::now();
    let cur = now.hour() * 60 + now.minute();
    if from < until {
        cur >= from && cur < until
    } else {
        cur >= from || cur < until
    }
}

fn parse_hhmm(v: &str) -> Option<u32> {
    let (h, m) = v.trim().split_once(':')?;
    let h: u32 = h.parse().ok()?;
    let m: u32 = m.parse().ok()?;
    if h > 23 || m > 59 {
        return None;
    }
    Some(h * 60 + m)
}

fn send_reg(h: &tunnel::TunnelHandle, s: &State) {
    let v = det_vendor();
    let gpu = GpuInfo {
        vendor: v,
        name: gpu_name(v),
        vram_mb: s.config.limits.memory_limit_mb,
    };
    let lim = OwnerLimits {
        gpu_power_pct: s.config.limits.gpu_power_pct,
        memory_limit_mb: s.config.limits.memory_limit_mb,
    };
    let reg = Register {
        node_id: s.config.node_id.clone(),
        hostname: s.config.hostname.clone(),
        os: OsKind::Linux,
        gpu,
        limits: lim,
        selected_models: s.config.selected_models.clone(),
    };
    let _ = h.outbound.send(Message::Register(reg).to_json().unwrap());
    info!("queued Register");
}

fn send_hb(
    h: &tunnel::TunnelHandle,
    c: &config::Config,
    bf: &backend::BackendManager,
    awake: bool,
) {
    let mut m = metrics::collect();
    m.tps = bf.stats().avg_tps;
    m.latency_ms = h.latency_ms().unwrap_or(0.0);
    let _ = h.outbound.send(
        Message::Heartbeat(Heartbeat {
            node_id: c.node_id.clone(),
            metrics: m,
            schedule_state: if awake {
                ScheduleStateValue::Awake
            } else {
                ScheduleStateValue::Asleep
            },
        })
        .to_json()
        .unwrap(),
    );
}

fn send_schedule_state(h: &tunnel::TunnelHandle, c: &config::Config, awake: bool) {
    let st = if awake {
        ScheduleStateValue::Awake
    } else {
        ScheduleStateValue::Asleep
    };
    let _ = h.outbound.send(
        Message::ScheduleState(ScheduleState {
            node_id: c.node_id.clone(),
            state: st,
        })
        .to_json()
        .unwrap(),
    );
    info!("schedule state changed: {:?}", st);
}

fn send_model_status(
    out: &tokio::sync::mpsc::UnboundedSender<String>,
    node_id: &str,
    bf: &backend::BackendManager,
) {
    let ready = bf.ready();
    let _ = out.send(
        Message::ModelStatus(ModelStatus {
            node_id: node_id.to_string(),
            ready_models: ready,
        })
        .to_json()
        .unwrap(),
    );
}

async fn handle_msg(
    h: &tunnel::TunnelHandle,
    s: &State,
    bf: &Arc<backend::BackendManager>,
    md: &std::path::Path,
    tracker: &Arc<Mutex<DownloadTracker>>,
    cat: &mut HashMap<String, proto::CatalogModel>,
    json: &str,
) -> Result<(), anyhow::Error> {
    let msg = Message::from_json(json)?;
    match msg {
        Message::CatalogResponse(cr) => {
            info!("+{} models", cr.models.len());
            cat.clear();
            for m in &cr.models {
                cat.insert(m.id.clone(), m.clone());
            }

            for m in &cr.models {
                let selected = s.config.selected_models.is_empty()
                    || s.config.selected_models.contains(&m.id);
                if !selected {
                    continue;
                }
                if m.backend != Backend::LlamaCpp {
                    warn!(
                        "skipping {}: backend {:?} is not supported by the Linux node",
                        m.id, m.backend
                    );
                    continue;
                }
                if bf.ready().contains(&m.id) {
                    continue;
                }
                {
                    let mut t = tracker.lock().unwrap();
                    if t.downloading.contains(&m.id) {
                        continue;
                    }
                    let fingerprint = (m.download_url.clone(), m.sha256.clone());
                    if t.failed.get(&m.id) == Some(&fingerprint) {
                        continue;
                    }
                    t.downloading.insert(m.id.clone());
                }

                // Download in the background so heartbeats and dispatches keep
                // flowing while large artifacts stream in (macOS parity).
                let m = m.clone();
                let md = md.to_path_buf();
                let bf = bf.clone();
                let tracker = tracker.clone();
                let out = h.outbound.clone();
                let node_id = s.config.node_id.clone();
                tokio::spawn(async move {
                    let mut last_logged: i32 = -10;
                    let result = models::download_model(&m, &md, |fraction| {
                        let pct = (fraction * 100.0) as i32;
                        if pct >= last_logged + 10 {
                            last_logged = pct;
                            info!("download {}: {}%", m.id, pct);
                        }
                    })
                    .await;
                    match result {
                        Ok(dir) => {
                            tracker.lock().unwrap().downloading.remove(&m.id);
                            tracker.lock().unwrap().failed.remove(&m.id);
                            bf.register(m.id.clone(), dir);
                            send_model_status(&out, &node_id, &bf);
                        }
                        Err(e) => {
                            let mut t = tracker.lock().unwrap();
                            t.downloading.remove(&m.id);
                            t.failed
                                .insert(m.id.clone(), (m.download_url.clone(), m.sha256.clone()));
                            drop(t);
                            warn!("dl {} failed for {}: {e}", m.id, m.download_url);
                        }
                    }
                });
            }

            send_model_status(&h.outbound, &s.config.node_id, bf);
        }
        Message::PromptDispatch(ref pd) => {
            info!("dispatch {} (loaded={:?})", pd.request_id, bf.loaded_models());
            bf.dispatch(pd, h.outbound.clone());
        }
        Message::Error(ref e) => warn!("srv err {}: {}", e.request_id, e.message),
        _ => {
            warn!("unexpected msg type");
        }
    }
    Ok(())
}

fn det_vendor() -> GpuVendor {
    if std::process::Command::new("nvidia-smi").output().is_ok() {
        return GpuVendor::Nvidia;
    }
    if std::process::Command::new("rocminfo").output().is_ok() {
        return GpuVendor::Amd;
    }
    GpuVendor::Nvidia
}

fn gpu_name(v: GpuVendor) -> String {
    if v == GpuVendor::Nvidia {
        std::process::Command::new("nvidia-smi")
            .args(["--query-gpu=name", "--format=csv,noheader,nounits"])
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|| "Unknown".into())
    } else {
        "GPU".into()
    }
}
