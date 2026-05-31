use crate::proto::Metrics;

pub fn collect() -> Metrics {
    nvidia().unwrap_or(zero())
}

fn nvidia() -> Option<Metrics> {
    let o = std::process::Command::new("nvidia-smi")
        .args(["--query-gpu=memory.used,memory.total,utilization.gpu", "--format=csv,noheader,nounits"])
        .output().ok()?;
    if !o.status.success() { return None; }
    let s = String::from_utf8_lossy(&o.stdout);
    let parts: Vec<&str> = s.split(',').map(|x| x.trim()).collect();
    if parts.len() < 3 { return None; }
    Some(Metrics {
        vram_used_mb: parts[0].parse().ok()?,
        vram_total_mb: parts[1].parse().ok()?,
        gpu_util_pct: parts[2].parse().ok()?,
        tps: 0.0, latency_ms: 0.0, in_flight: 0,
    })
}

fn zero() -> Metrics {
    Metrics { vram_used_mb: 0, vram_total_mb: 0, gpu_util_pct: 0.0, tps: 0.0, latency_ms: 0.0, in_flight: 0 }
}
