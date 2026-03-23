use crate::discovery::{DiscoveredServer, DiscoverySource, MdnsSeed};
use std::collections::HashMap;
use std::time::Instant;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum FfiDiscoverySource {
    Bonjour,
    Tailscale,
    LanProbe,
    ArpScan,
    Manual,
    Local,
}

impl From<DiscoverySource> for FfiDiscoverySource {
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

impl From<FfiDiscoverySource> for DiscoverySource {
    fn from(value: FfiDiscoverySource) -> Self {
        match value {
            FfiDiscoverySource::Bonjour => Self::Bonjour,
            FfiDiscoverySource::Tailscale => Self::Tailscale,
            FfiDiscoverySource::LanProbe => Self::LanProbe,
            FfiDiscoverySource::ArpScan => Self::ArpScan,
            FfiDiscoverySource::Manual => Self::Manual,
            FfiDiscoverySource::Local => Self::Bundled,
        }
    }
}

#[derive(uniffi::Record)]
pub struct FfiMdnsSeed {
    pub name: String,
    pub host: String,
    pub port: Option<u16>,
    pub service_type: String,
}

impl From<FfiMdnsSeed> for MdnsSeed {
    fn from(value: FfiMdnsSeed) -> Self {
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
pub struct FfiDiscoveredServer {
    pub id: String,
    pub display_name: String,
    pub host: String,
    pub port: u16,
    pub codex_port: Option<u16>,
    pub ssh_port: Option<u16>,
    pub source: FfiDiscoverySource,
    pub reachable: bool,
}

impl From<DiscoveredServer> for FfiDiscoveredServer {
    fn from(value: DiscoveredServer) -> Self {
        Self {
            id: value.id,
            display_name: value.display_name,
            host: value.host,
            port: value.port,
            codex_port: value.codex_port,
            ssh_port: value.ssh_port,
            source: value.source.into(),
            reachable: value.reachable,
        }
    }
}

impl From<FfiDiscoveredServer> for DiscoveredServer {
    fn from(value: FfiDiscoveredServer) -> Self {
        Self {
            id: value.id,
            display_name: value.display_name,
            host: value.host,
            port: value.port,
            codex_port: value.codex_port,
            ssh_port: value.ssh_port,
            source: value.source.into(),
            metadata: HashMap::new(),
            last_seen: Instant::now(),
            reachable: value.reachable,
        }
    }
}
