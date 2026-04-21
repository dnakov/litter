use crate::discovery::{
    DiscoveredServer, DiscoverySource, MdnsSeed, ProgressiveDiscoveryUpdate,
    ProgressiveDiscoveryUpdateKind,
};
use crate::session::connection::{AppServerConnectionPath, AppServerTransportKind};
use std::collections::HashMap;
use std::time::Instant;

const METADATA_BACKEND_KIND: &str = "backend_kind";
const METADATA_OPENCODE_BASE_URL: &str = "opencode_base_url";
const METADATA_OPENCODE_REQUIRES_AUTH: &str = "opencode_requires_auth";
const BACKEND_KIND_OPEN_CODE: &str = "openCode";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AppDiscoverySource {
    Bonjour,
    Tailscale,
    LanProbe,
    ArpScan,
    Manual,
    Local,
}

impl From<DiscoverySource> for AppDiscoverySource {
    fn from(value: DiscoverySource) -> Self {
        match value {
            DiscoverySource::Bonjour => Self::Bonjour,
            DiscoverySource::Tailscale => Self::Tailscale,
            DiscoverySource::LanProbe => Self::LanProbe,
            DiscoverySource::ArpScan => Self::ArpScan,
            DiscoverySource::Manual => Self::Manual,
            DiscoverySource::Bundled => Self::Local,
        }
    }
}

impl From<AppDiscoverySource> for DiscoverySource {
    fn from(value: AppDiscoverySource) -> Self {
        match value {
            AppDiscoverySource::Bonjour => Self::Bonjour,
            AppDiscoverySource::Tailscale => Self::Tailscale,
            AppDiscoverySource::LanProbe => Self::LanProbe,
            AppDiscoverySource::ArpScan => Self::ArpScan,
            AppDiscoverySource::Manual => Self::Manual,
            AppDiscoverySource::Local => Self::Bundled,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum AppDiscoveredBackendKind {
    Codex,
    OpenCode,
}

#[derive(uniffi::Record)]
pub struct AppMdnsSeed {
    pub name: String,
    pub host: String,
    pub port: Option<u16>,
    pub service_type: String,
    pub txt: HashMap<String, String>,
}

impl From<AppMdnsSeed> for MdnsSeed {
    fn from(value: AppMdnsSeed) -> Self {
        Self {
            name: value.name,
            host: value.host,
            port: value.port,
            service_type: value.service_type,
            txt: value.txt,
        }
    }
}

#[derive(uniffi::Record)]
pub struct AppDiscoveredServer {
    pub id: String,
    pub display_name: String,
    pub host: String,
    pub port: u16,
    pub backend_kind: AppDiscoveredBackendKind,
    pub transport_kind: AppServerTransportKind,
    pub connection_path: AppServerConnectionPath,
    pub codex_port: Option<u16>,
    pub codex_ports: Vec<u16>,
    pub ssh_port: Option<u16>,
    pub source: AppDiscoverySource,
    pub reachable: bool,
    pub os: Option<String>,
    pub ssh_banner: Option<String>,
    pub requires_auth: bool,
    pub opencode_base_url: Option<String>,
    pub opencode_requires_auth: bool,
}

impl From<DiscoveredServer> for AppDiscoveredServer {
    fn from(value: DiscoveredServer) -> Self {
        let os = value.metadata.get("os").cloned();
        let ssh_banner = value.metadata.get("ssh_banner").cloned();
        let backend_kind = match value
            .metadata
            .get(METADATA_BACKEND_KIND)
            .map(String::as_str)
        {
            Some(BACKEND_KIND_OPEN_CODE) => AppDiscoveredBackendKind::OpenCode,
            _ => AppDiscoveredBackendKind::Codex,
        };
        let opencode_base_url = value.metadata.get(METADATA_OPENCODE_BASE_URL).cloned();
        let opencode_requires_auth = value
            .metadata
            .get(METADATA_OPENCODE_REQUIRES_AUTH)
            .map(|value| value == "true")
            .unwrap_or(false);
        let connection_path = discovered_connection_path(&value, backend_kind);
        let transport_kind =
            discovered_transport_kind(&value, backend_kind, connection_path, opencode_base_url.as_deref());
        let requires_auth = match backend_kind {
            AppDiscoveredBackendKind::OpenCode => opencode_requires_auth,
            AppDiscoveredBackendKind::Codex => {
                value.codex_port.is_none() && value.codex_ports.is_empty() && value.ssh_port.is_some()
            }
        };
        Self {
            id: value.id,
            display_name: value.display_name,
            host: value.host,
            port: value.port,
            backend_kind,
            transport_kind,
            connection_path,
            codex_port: value.codex_port,
            codex_ports: value.codex_ports,
            ssh_port: value.ssh_port,
            source: value.source.into(),
            reachable: value.reachable,
            os,
            ssh_banner,
            requires_auth,
            opencode_base_url,
            opencode_requires_auth,
        }
    }
}

impl From<AppDiscoveredServer> for DiscoveredServer {
    fn from(value: AppDiscoveredServer) -> Self {
        let mut metadata = HashMap::new();
        if let Some(os) = value.os {
            metadata.insert("os".to_string(), os);
        }
        if let Some(banner) = value.ssh_banner {
            metadata.insert("ssh_banner".to_string(), banner);
        }
        if value.backend_kind == AppDiscoveredBackendKind::OpenCode {
            metadata.insert(
                METADATA_BACKEND_KIND.to_string(),
                BACKEND_KIND_OPEN_CODE.to_string(),
            );
        }
        if let Some(base_url) = value.opencode_base_url {
            metadata.insert(METADATA_OPENCODE_BASE_URL.to_string(), base_url);
        }
        if value.opencode_requires_auth {
            metadata.insert(
                METADATA_OPENCODE_REQUIRES_AUTH.to_string(),
                "true".to_string(),
            );
        }
        Self {
            id: value.id,
            display_name: value.display_name,
            host: value.host,
            port: value.port,
            codex_port: value.codex_port,
            codex_ports: value.codex_ports,
            ssh_port: value.ssh_port,
            source: value.source.into(),
            metadata,
            last_seen: Instant::now(),
            reachable: value.reachable,
        }
    }
}

fn discovered_connection_path(
    server: &DiscoveredServer,
    backend_kind: AppDiscoveredBackendKind,
) -> AppServerConnectionPath {
    match server.source {
        DiscoverySource::Bundled => AppServerConnectionPath::Local,
        DiscoverySource::Tailscale => AppServerConnectionPath::Tailscale,
        _ => {
            if backend_kind == AppDiscoveredBackendKind::Codex
                && server.codex_port.is_none()
                && server.codex_ports.is_empty()
                && server.ssh_port.is_some()
            {
                AppServerConnectionPath::Ssh
            } else {
                AppServerConnectionPath::Lan
            }
        }
    }
}

fn discovered_transport_kind(
    server: &DiscoveredServer,
    backend_kind: AppDiscoveredBackendKind,
    connection_path: AppServerConnectionPath,
    opencode_base_url: Option<&str>,
) -> AppServerTransportKind {
    match backend_kind {
        AppDiscoveredBackendKind::Codex => match connection_path {
            AppServerConnectionPath::Local => AppServerTransportKind::Local,
            AppServerConnectionPath::Ssh => AppServerTransportKind::Ssh,
            _ => AppServerTransportKind::Websocket,
        },
        AppDiscoveredBackendKind::OpenCode => {
            let scheme = opencode_base_url
                .and_then(|url| url::Url::parse(url).ok())
                .map(|url| url.scheme().to_ascii_lowercase());
            match scheme.as_deref() {
                Some("https") if connection_path == AppServerConnectionPath::Tailscale => {
                    AppServerTransportKind::TailscaleHttps
                }
                Some("https") => AppServerTransportKind::Https,
                Some("http") => AppServerTransportKind::Http,
                _ if connection_path == AppServerConnectionPath::Tailscale => {
                    AppServerTransportKind::TailscaleHttps
                }
                _ if server.source == DiscoverySource::Bundled => AppServerTransportKind::Http,
                _ => AppServerTransportKind::Http,
            }
        }
    }
}

#[derive(uniffi::Record)]
pub struct AppProgressiveDiscoveryUpdate {
    pub kind: ProgressiveDiscoveryUpdateKind,
    pub source: Option<AppDiscoverySource>,
    pub servers: Vec<AppDiscoveredServer>,
    /// Overall scan progress from 0.0 to 1.0.
    pub progress: f32,
    /// Human-readable label for the phase that just completed.
    pub progress_label: Option<String>,
}

impl From<ProgressiveDiscoveryUpdate> for AppProgressiveDiscoveryUpdate {
    fn from(value: ProgressiveDiscoveryUpdate) -> Self {
        Self {
            kind: value.kind,
            source: value.source.map(Into::into),
            servers: value.servers.into_iter().map(Into::into).collect(),
            progress: value.progress,
            progress_label: value.progress_label,
        }
    }
}
