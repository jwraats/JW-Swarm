use std::sync::Arc;
use tokio::sync::mpsc;
use tungstenite::protocol::Message as WsMessage;
use tracing::{info, warn};
use futures::{SinkExt, StreamExt};

pub struct TunnelHandle {
    pub outbound: mpsc::UnboundedSender<String>,
    #[allow(dead_code)]
    #[allow(dead_code)]
    #[allow(dead_code)]
    pub shutdown: tokio_util::sync::CancellationToken,
}

pub struct Tunnel {
    pub fleet_url: String,
    pub node_cert: String,
    pub ca_cert: String,
}

impl Tunnel {
    pub fn run_loop(self) -> (TunnelHandle, mpsc::UnboundedReceiver<String>) {
        let (otx, mut orx) = mpsc::unbounded_channel::<String>();
        let (itx, irx) = mpsc::unbounded_channel::<String>();
        let sh = tokio_util::sync::CancellationToken::new();
        let sh_inner = sh.clone();

        let connector = build_connector(&self.node_cert, &self.ca_cert);
        let url = self.fleet_url.clone();

        tokio::spawn(async move {
            let mut backoff = std::time::Duration::from_secs(1);

            loop {
                if sh_inner.is_cancelled() {
                    break;
                }

                let conn = match &connector {
                    Some(c) => c.clone(),
                    None => {
                        warn!("connector unavailable, retry in {:?}", backoff);
                        backoff = std::cmp::min(backoff * 2, std::time::Duration::from_secs(60));
                        tokio::select! {
                            _ = tokio::time::sleep(backoff) => { if sh_inner.is_cancelled() { break; } }
                            _ = sh_inner.cancelled() => break,
                        }
                        continue;
                    }
                };

                let (mut ws, _) = match tokio_tungstenite::connect_async_tls_with_config(
                    &url, None, false, Some(conn.clone()),
                ).await {
                    Ok(s) => s,
                    Err(e) => {
                        warn!("connect: {}", e);
                        backoff = std::cmp::min(backoff * 2, std::time::Duration::from_secs(60));
                        tokio::select! {
                            _ = tokio::time::sleep(backoff) => { if sh_inner.is_cancelled() { break; } }
                            _ = sh_inner.cancelled() => break,
                        }
                        continue;
                    }
                };

                info!("tunnel connected");
                backoff = std::time::Duration::from_secs(1);

                // Drain queued outbound messages
                loop {
                    match orx.try_recv() {
                        Ok(s) => {
                            if ws.send(WsMessage::Text(s.into())).await.is_err() {
                                break;
                            }
                        }
                        Err(_) => break,
                    }
                }

                // Main event loop
                loop {
                    tokio::select! {
                        biased;
                        _ = sh_inner.cancelled() => {
                            info!("shutdown");
                            break;
                        }
                        outgoing = orx.recv() => {
                            match outgoing {
                                Some(s) => {
                                    if ws.send(WsMessage::Text(s.into())).await.is_err() {
                                        break;
                                    }
                                }
                                None => break,
                            }
                        }
                        frame = ws.next() => {
                            match frame {
                                Some(Ok(WsMessage::Text(t))) => {
                                    let _ = itx.send(t.to_string());
                                }
                                Some(Ok(WsMessage::Close(_))) => break,
                                Some(Ok(WsMessage::Ping(p))) => {
                                    let _ = ws.send(WsMessage::Pong(p)).await;
                                }
                                Some(Ok(_)) => {}
                                Some(Err(e)) => {
                                    warn!("read error: {}", e);
                                    break;
                                }
                                None => break,
                            }
                        }
                    }
                }

                warn!("disconnected, retry in {:?}", backoff);
                backoff = std::cmp::min(backoff * 2, std::time::Duration::from_secs(60));
                tokio::select! {
                    _ = tokio::time::sleep(backoff) => { if sh_inner.is_cancelled() { break; } }
                    _ = sh_inner.cancelled() => break,
                }
            }
        });

        (TunnelHandle { outbound: otx, shutdown: sh }, irx)
    }
}

fn build_connector(node_cert: &str, ca_cert: &str) -> Option<tokio_tungstenite::Connector> {
    let root_store = load_root_store(ca_cert)?;

    let verifier = match rustls::client::WebPkiServerVerifier::builder(root_store.clone()).build() {
        Ok(v) => v,
        Err(e) => {
            warn!("verifier build error: {}", e);
            return None;
        }
    };

    let cfg = if !node_cert.is_empty() {
        match std::fs::read(node_cert) {
            Ok(data) => {
                let mut cert_reader = std::io::BufReader::new(&data[..]);
                let chain: Vec<_> = rustls_pemfile::certs(&mut cert_reader)
                    .into_iter()
                    .filter_map(|c| c.ok())
                    .collect();
                if chain.is_empty() {
                    warn!("no certificates in {}", node_cert);
                    return None;
                }

                let mut key_reader = std::io::BufReader::new(&data[..]);
                let key = match rustls_pemfile::private_key(&mut key_reader) {
                    Ok(Some(k)) => k,
                    Ok(None) => {
                        warn!("no private key in {}", node_cert);
                        return None;
                    }
                    Err(e) => {
                        warn!("key parse error: {}", e);
                        return None;
                    }
                };

                match rustls::ClientConfig::builder()
                    .with_webpki_verifier(verifier)
                    .with_client_auth_cert(chain, key)
                {
                    Ok(c) => Some(c),
                    Err(e) => {
                        warn!("client auth cert error: {}", e);
                        None
                    }
                }
            }
            Err(e) => {
                warn!("cannot read node cert ({}): {}", node_cert, e);
                None
            }
        }
    } else {
        Some(rustls::ClientConfig::builder()
            .with_webpki_verifier(verifier)
            .with_no_client_auth())
    };

    cfg.map(|c| tokio_tungstenite::Connector::Rustls(Arc::new(c)))
}

fn load_root_store(ca_cert: &str) -> Option<Arc<rustls::RootCertStore>> {
    let mut store = rustls::RootCertStore::empty();

    if !ca_cert.is_empty() {
        match std::fs::read(ca_cert) {
            Ok(data) => {
                let mut reader = std::io::BufReader::new(&data[..]);
                let certs = rustls_pemfile::certs(&mut reader);
                let mut count = 0u32;
                for c in certs {
                    match c {
                        Ok(cert) => {
                            let _ = store.add(cert);
                            count += 1;
                        }
                        Err(_) => {}
                    }
                }
                if count == 0 {
                    return None;
                }
            }
            Err(e) => {
                warn!("cannot read CA cert ({}): {}", ca_cert, e);
            }
        }
    }

    // Always add native certs as fallback
    for cert in rustls_native_certs::load_native_certs().certs {
        let _ = store.add(cert);
    }

    Some(Arc::new(store))
}
