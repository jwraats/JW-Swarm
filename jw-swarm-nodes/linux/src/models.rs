use std::io::prelude::*;
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use tracing::info;

use crate::proto::CatalogModel;
use futures::TryStreamExt;

pub async fn download_model(m: &CatalogModel, base: &std::path::Path) -> Result<std::path::PathBuf, anyhow::Error> {
    let dir = base.join(&m.id);
    let sp = dir.join("sha256");
    if sp.exists() {
        if std::fs::read_to_string(&sp).ok() == Some(m.sha256.clone()) {
            info!("{} already verified", m.id);
            return Ok(dir);
        }
    }
    std::fs::create_dir_all(&dir)?;
    ensure_disk_space(&dir, m.size_bytes)?;

    let ap = dir.join("weights.bin");
    let pp = dir.join("weights.bin.partial");
    let _ = std::fs::remove_file(&pp);

    let resp = reqwest::Client::builder()
        .tls_built_in_root_certs(true)
        .build()?
        .get(&m.download_url)
        .send()
        .await?;
    if !resp.status().is_success() {
        return Err(anyhow::anyhow!("HTTP {}", resp.status()));
    }
    info!("dl {} {} bytes", m.id, m.size_bytes);

    let mut f = tokio::io::BufWriter::new(tokio::fs::File::create(&pp).await?);
    let mut st = resp.bytes_stream();
    while let Some(ch) = st.try_next().await? {
        if let Err(e) = f.write_all(&ch).await {
            let _ = std::fs::remove_file(&pp);
            return Err(e.into());
        }
    }
    if let Err(e) = f.flush().await {
        let _ = std::fs::remove_file(&pp);
        return Err(e.into());
    }

    let hash = {
        let mut f = std::fs::File::open(&pp)?;
        let mut h = Sha256::new();
        let mut buf = [0u8; 8192];
        loop {
            let n = f.read(&mut buf)?;
            if n == 0 { break; }
            h.update(&buf[..n]);
        }
        format!("{:x}", h.finalize())
    };

    if hash.to_lowercase() != m.sha256.to_lowercase() {
        std::fs::remove_file(&pp).ok();
        return Err(anyhow::anyhow!("sha256 mismatch"));
    }
    std::fs::remove_file(&ap).ok();
    std::fs::rename(&pp, &ap)?;
    std::fs::write(&sp, &m.sha256)?;
    info!("{} verified", m.id);
    Ok(dir)
}

fn ensure_disk_space(dir: &std::path::Path, required_bytes: u64) -> Result<(), anyhow::Error> {
    let available = fs2::available_space(dir)?;
    let headroom = 64 * 1024 * 1024;
    if available < required_bytes + headroom {
        return Err(anyhow::anyhow!(
            "insufficient disk space: need {} bytes + headroom, have {} bytes",
            required_bytes,
            available
        ));
    }
    Ok(())
}
