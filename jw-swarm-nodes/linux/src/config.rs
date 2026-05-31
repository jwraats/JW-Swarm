use serde::{Deserialize, Serialize};
use tracing::info;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default = "df_f")]
    pub fleet_url: String,
    #[serde(default)]
    pub node_id: String,
    #[serde(default)]
    pub hostname: String,
    #[serde(default)]
    pub node_cert: String,
    #[serde(default)]
    pub ca_cert: String,
    pub limits: Limits,
    #[serde(default)]
    pub schedule: Schedule,
    #[serde(default)]
    pub selected_models: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Limits {
    #[serde(default = "default_power")]
    pub gpu_power_pct: u8,
    #[serde(default = "default_mem")]
    pub memory_limit_mb: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Schedule {
    pub awake_from: String,
    pub awake_until: String,
}

fn df_f() -> String {
    std::env::var("JW_FLEET_URL")
        .unwrap_or_else(|_| "wss://localhost/node/connect".into())
}
fn default_power() -> u8 { 100 }
fn default_mem() -> u64 { 24000 }

impl Config {
    pub fn load() -> Self {
        let path = config_path();
        if path.exists() {
            info!("config: {}", path.display());
            let t = std::fs::read_to_string(&path).expect("read config");
            toml::from_str(&t).unwrap_or_else(|e| {
                eprintln!("bad config: {e}");
                Self::generate()
            })
        } else {
            info!("generating config");
            Self::generate()
        }
    }

    pub fn generate() -> Self {
        let nid = uuid::Uuid::new_v4().to_string();
        let hn = std::env::var("HOSTNAME")
            .ok()
            .or_else(|| {
                std::process::Command::new("hostname")
                    .output()
                    .ok()
                    .and_then(|o| String::from_utf8(o.stdout).ok())
            })
            .unwrap_or_else(|| "jw-node".into());
        let nc = std::env::var("JW_NODE_CERT")
            .unwrap_or_else(|_| "/etc/jw-swarm-node/node.pem".into());
        let ca = std::env::var("JW_CA_CERT")
            .unwrap_or_else(|_| "/etc/jw-swarm-node/ca.crt".into());
        let s = Self {
            fleet_url: df_f(),
            node_id: nid,
            hostname: hn.trim().into(),
            node_cert: nc,
            ca_cert: ca,
            limits: Limits {
                gpu_power_pct: 100,
                memory_limit_mb: 24000,
            },
            schedule: Schedule {
                awake_from: String::new(),
                awake_until: String::new(),
            },
            selected_models: Vec::new(),
        };
        let p = config_path();
        if let Some(parent) = p.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let txt = "# JW Swarm Node\n#".to_owned()
            + "\n"
            + &toml::to_string_pretty(&s).unwrap();
        std::fs::write(&p, txt).ok();
        info!("written {}", p.display());
        s
    }

    pub fn data_dir(&self) -> std::path::PathBuf {
        std::env::var("JW_DATA_DIR")
            .ok()
            .map(std::path::PathBuf::from)
            .or_else(|| dirs::data_local_dir())
            .unwrap_or_else(|| "/tmp/jw-swarm-node".into())
            .join("jw-swarm-node")
    }

    pub fn model_dir(&self) -> std::path::PathBuf {
        self.data_dir().join("models")
    }
}

fn config_path() -> std::path::PathBuf {
    std::env::var("JW_CONFIG_DIR")
        .ok()
        .map(std::path::PathBuf::from)
        .or_else(|| dirs::config_dir())
        .unwrap_or_else(|| "/tmp/jw-swarm-node".into())
        .join("jw-swarm-node/config.toml")
}
