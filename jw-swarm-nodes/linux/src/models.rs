use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use tracing::info;

use crate::proto::CatalogModel;
use futures::TryStreamExt;

/// Download and verify a model artifact, mirroring the macOS downloader:
/// the artifact keeps its remote filename (so `.gguf` files stay `.gguf`),
/// `weights.bin` is maintained as a legacy symlink, the SHA256 is computed
/// while streaming, and `progress` is invoked with a 0..=1 fraction.
pub async fn download_model(
    m: &CatalogModel,
    base: &std::path::Path,
    mut progress: impl FnMut(f64),
) -> Result<std::path::PathBuf, anyhow::Error> {
    let dir = base.join(&m.id);
    let sp = dir.join("sha256");
    if sp.exists() {
        if std::fs::read_to_string(&sp).ok().map(|s| s.trim().to_string()) == Some(m.sha256.clone()) {
            info!("{} already verified", m.id);
            progress(1.0);
            return Ok(dir);
        }
    }
    std::fs::create_dir_all(&dir)?;
    ensure_disk_space(&dir, m.size_bytes)?;

    let filename = remote_filename(&m.download_url);
    let ap = dir.join(&filename);
    let pp = dir.join(format!("{filename}.partial"));
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
    let mut hasher = Sha256::new();
    let mut written: u64 = 0;
    loop {
        let ch = match st.try_next().await {
            Ok(Some(ch)) => ch,
            Ok(None) => break,
            Err(e) => {
                let _ = std::fs::remove_file(&pp);
                return Err(e.into());
            }
        };
        if let Err(e) = f.write_all(&ch).await {
            let _ = std::fs::remove_file(&pp);
            return Err(e.into());
        }
        hasher.update(&ch);
        written += ch.len() as u64;
        if m.size_bytes > 0 {
            progress((written as f64 / m.size_bytes as f64).min(1.0));
        }
    }
    if let Err(e) = f.flush().await {
        let _ = std::fs::remove_file(&pp);
        return Err(e.into());
    }

    let hash = format!("{:x}", hasher.finalize());
    if hash.to_lowercase() != m.sha256.to_lowercase() {
        std::fs::remove_file(&pp).ok();
        return Err(anyhow::anyhow!(
            "sha256 mismatch {} != {}",
            m.sha256,
            hash
        ));
    }
    std::fs::remove_file(&ap).ok();
    std::fs::rename(&pp, &ap)?;
    if filename != "weights.bin" {
        let legacy = dir.join("weights.bin");
        let _ = std::fs::remove_file(&legacy);
        let _ = std::os::unix::fs::symlink(&ap, &legacy);
    }
    std::fs::write(&sp, &m.sha256)?;
    progress(1.0);
    info!("{} verified", m.id);
    Ok(dir)
}

/// The artifact filename derived from the download URL, defaulting to the
/// legacy `weights.bin` when the URL has no usable last path component.
fn remote_filename(url: &str) -> String {
    url::Url::parse(url)
        .ok()
        .and_then(|u| {
            u.path_segments()
                .and_then(|s| s.last().map(|v| v.to_string()))
        })
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "weights.bin".into())
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

