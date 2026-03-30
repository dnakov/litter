use crate::discovery::{
    DiscoveredServer, DiscoverySource, MdnsSeed, ProgressiveDiscoveryUpdate,
    ProgressiveDiscoveryUpdateKind,
};
use std::collections::HashMap;
use std::time::Instant;

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

#[derive(uniffi::Record)]
pub struct AppMdnsSeed {
    pub name: String,
    pub host: String,
    pub port: Option<u16>,
    pub service_type: String,
}

impl From<AppMdnsSeed> for MdnsSeed {
    fn from(value: AppMdnsSeed) -> Self {
        Self {
            name: value.name,
            host: value.host,
            port: value.port,
            service_type: value.service_type,
            txt: HashMap::new(),
        }
    }
}

#[derive(uniffi::Record)]
pub struct AppDiscoveredServer {
    pub id: String,
    pub display_name: String,
    pub host: String,
    pub port: u16,
    pub codex_port: Option<u16>,
    pub codex_ports: Vec<u16>,
    pub ssh_port: Option<u16>,
    pub source: AppDiscoverySource,
    pub reachable: bool,
    pub os: Option<String>,
    pub ssh_banner: Option<String>,
}

impl From<DiscoveredServer> for AppDiscoveredServer {
    fn from(value: DiscoveredServer) -> Self {
        let os = value.metadata.get("os").cloned();
        let ssh_banner = value.metadata.get("ssh_banner").cloned();
        Self {
            id: value.id,
            display_name: value.display_name,
            host: value.host,
            port: value.port,
            codex_port: value.codex_port,
            codex_ports: value.codex_ports,
            ssh_port: value.ssh_port,
            source: value.source.into(),
            reachable: value.reachable,
            os,
            ssh_banner,
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
