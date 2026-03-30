use crate::MobileClient;
use crate::discovery_uniffi::{AppDiscoveredServer, AppMdnsSeed, AppProgressiveDiscoveryUpdate};
use crate::ffi::ClientError;
use crate::ffi::shared::{blocking_async, shared_mobile_client, shared_runtime};
use crate::session::connection::{InProcessConfig, ServerConfig};
use std::sync::Arc;

#[derive(uniffi::Object)]
pub struct DiscoveryBridge {
    pub(crate) inner: Arc<MobileClient>,
    pub(crate) rt: Arc<tokio::runtime::Runtime>,
}

#[derive(uniffi::Object)]
pub struct ServerBridge {
    pub(crate) inner: Arc<MobileClient>,
    pub(crate) rt: Arc<tokio::runtime::Runtime>,
}

#[derive(uniffi::Object)]
pub struct DiscoveryScanSubscription {
    pub(crate) rx: std::sync::Mutex<
        Option<tokio::sync::broadcast::Receiver<crate::discovery::ProgressiveDiscoveryUpdate>>,
    >,
}

#[uniffi::export(async_runtime = "tokio")]
impl DiscoveryBridge {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: shared_mobile_client(),
            rt: shared_runtime(),
        }
    }

    pub async fn scan_servers_with_mdns_context(
        &self,
        seeds: Vec<AppMdnsSeed>,
        local_ipv4: Option<String>,
    ) -> Result<Vec<AppDiscoveredServer>, ClientError> {
        let seeds: Vec<_> = seeds.into_iter().map(Into::into).collect();
        blocking_async!(self.rt, self.inner, |c| {
            Ok(c.scan_servers_with_mdns_context(seeds, local_ipv4)
                .await
                .into_iter()
                .map(AppDiscoveredServer::from)
                .collect())
        })
    }

    pub fn scan_servers_with_mdns_context_progressive(
        &self,
        seeds: Vec<AppMdnsSeed>,
        local_ipv4: Option<String>,
    ) -> DiscoveryScanSubscription {
        let seeds: Vec<_> = seeds.into_iter().map(Into::into).collect();
        DiscoveryScanSubscription {
            rx: std::sync::Mutex::new(Some(
                self.inner
                    .subscribe_scan_servers_with_mdns_context(seeds, local_ipv4),
            )),
        }
    }

    pub fn reconcile_servers(
        &self,
        candidates: Vec<AppDiscoveredServer>,
    ) -> Vec<AppDiscoveredServer> {
        crate::discovery::reconcile_discovered_servers(
            candidates.into_iter().map(Into::into).collect(),
        )
        .into_iter()
        .map(AppDiscoveredServer::from)
        .collect()
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl ServerBridge {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: shared_mobile_client(),
            rt: shared_runtime(),
        }
    }

    pub async fn connect_local_server(
        &self,
        server_id: String,
        display_name: String,
        host: String,
        port: u16,
    ) -> Result<String, ClientError> {
        let config = ServerConfig {
            server_id,
            display_name,
            host,
            port,
            websocket_url: None,
            is_local: true,
            tls: false,
        };
        blocking_async!(self.rt, self.inner, |c| {
            c.connect_local(config, InProcessConfig::default())
                .await
                .map_err(|e| ClientError::Transport(e.to_string()))
        })
    }

    pub async fn connect_remote_server(
        &self,
        server_id: String,
        display_name: String,
        host: String,
        port: u16,
    ) -> Result<String, ClientError> {
        let config = ServerConfig {
            server_id,
            display_name,
            host,
            port,
            websocket_url: None,
            is_local: false,
            tls: false,
        };
        blocking_async!(self.rt, self.inner, |c| {
            c.connect_remote(config)
                .await
                .map_err(|e| ClientError::Transport(e.to_string()))
        })
    }

    pub async fn connect_remote_url_server(
        &self,
        server_id: String,
        display_name: String,
        websocket_url: String,
    ) -> Result<String, ClientError> {
        let parsed = url::Url::parse(&websocket_url)
            .map_err(|e| ClientError::InvalidParams(format!("invalid websocket URL: {e}")))?;
        let host = parsed
            .host_str()
            .ok_or_else(|| ClientError::InvalidParams("websocket URL host missing".to_string()))?
            .to_string();
        let port = parsed
            .port_or_known_default()
            .ok_or_else(|| ClientError::InvalidParams("websocket URL port missing".to_string()))?;
        let tls = matches!(parsed.scheme(), "wss" | "https");
        let config = ServerConfig {
            server_id,
            display_name,
            host,
            port,
            websocket_url: Some(websocket_url),
            is_local: false,
            tls,
        };
        blocking_async!(self.rt, self.inner, |c| {
            c.connect_remote(config)
                .await
                .map_err(|e| ClientError::Transport(e.to_string()))
        })
    }

    pub fn disconnect_server(&self, server_id: String) {
        self.inner.disconnect_server(&server_id);
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl DiscoveryScanSubscription {
    pub async fn next_event(&self) -> Result<AppProgressiveDiscoveryUpdate, ClientError> {
        let mut rx = {
            self.rx
                .lock()
                .unwrap()
                .take()
                .ok_or(ClientError::EventClosed(
                    "no discovery subscriber".to_string(),
                ))?
        };
        let result = loop {
            match rx.recv().await {
                Ok(update) => break Ok(update.into()),
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    break Err(ClientError::EventClosed("closed".to_string()));
                }
            }
        };
        *self.rx.lock().unwrap() = Some(rx);
        result
    }
}
