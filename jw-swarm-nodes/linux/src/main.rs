use std::collections::HashMap;
use std::time::Duration;
use tracing::{info, warn};

mod config;
mod proto;
mod tunnel;
mod backend;
mod enroll;
mod models;
mod metrics;

use proto::{GpuInfo, GpuVendor, Heartbeat, Message, ModelStatus, OsKind, OwnerLimits, Register, ScheduleStateValue};

struct State {
    config: config::Config,
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
    let bf = backend::BackendManager::new();
    run(state, bf).await;
    Ok(())
}

async fn run(state: State, bf: backend::BackendManager) {
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

    let mut catalog: HashMap<String, proto::CatalogModel> = HashMap::new();
    let mut hb = tokio::time::interval(Duration::from_secs(30));

    loop {
        tokio::select! {
            _ = hb.tick() => {
                let m = metrics::collect();
                let _ = send_hb(&handle, &state.config, &m);
            }
            json = inb.recv() => {
                match json {
                    Some(s) => {
                        if let Err(e) = handle_msg(&handle, &state, &bf, &md, &mut catalog, &s).await {
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
    m: &proto::Metrics,
) -> Result<(), anyhow::Error> {
    h.outbound.send(Message::Heartbeat(Heartbeat {
        node_id: c.node_id.clone(),
        metrics: m.clone(),
        schedule_state: ScheduleStateValue::Awake,
    })
    .to_json()?)?;
    Ok(())
}

async fn handle_msg(
    h: &tunnel::TunnelHandle,
    s: &State,
    bf: &backend::BackendManager,
    md: &std::path::Path,
    cat: &mut HashMap<String, proto::CatalogModel>,
    json: &str,
) -> Result<(), anyhow::Error> {
    let msg = Message::from_json(json)?;
    match msg {
        Message::CatalogResponse(cr) => {
            info!("+{} models", cr.models.len());
            for m in &cr.models {
                let sel = s.config.selected_models.is_empty()
                    || s.config.selected_models.contains(&m.id);
                if sel {
                    if let Err(e) = models::download_model(m, md).await {
                        warn!("dl {}: {e}", m.id);
                    } else {
                        bf.register(m.id.clone(), md.join(&m.id));
                    }
                }
            }
            cat.clear();
            for m in &cr.models {
                cat.insert(m.id.clone(), m.clone());
            }
            let ready = bf.ready();
            let _ = h.outbound
                .send(Message::ModelStatus(ModelStatus {
                    node_id: s.config.node_id.clone(),
                    ready_models: ready,
                })
                .to_json()?);
        }
        Message::PromptDispatch(ref pd) => {
            info!("dispatch {}", pd.request_id);
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
