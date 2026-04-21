//! Shared reconnection logic for iOS and Android.
//!
//! Consolidates the duplicated transport-resolution and reconnect-plan
//! computation that previously lived in platform Swift/Kotlin code.

use crate::mobile_client::MobileClient;
use crate::session::connection::{
    AppServerBackendKind, AppServerConnectionPath, AppServerTransportKind, InProcessConfig,
    ServerConfig,
};
use crate::ssh::{SshAuth, SshCredentials};
use opencode_bridge::{OpenCodeDirectoryScope, OpenCodeServerConfig};
use tracing::{info, warn};

// ── UniFFI boundary types ───────────────────────────────────────────────

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum SavedServerBackendKindRecord {
    Codex,
    OpenCode,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct SavedOpenCodeDirectoryScopeRecord {
    pub directory: String,
}

/// Mirrors the platform `SavedServer` data class / struct.
#[derive(Clone, Debug, uniffi::Record)]
pub struct SavedServerRecord {
    pub id: String,
    pub name: String,
    pub hostname: String,
    pub port: u16,
    pub codex_ports: Vec<u16>,
    pub ssh_port: Option<u16>,
    pub source: String,
    pub has_codex_server: bool,
    pub wake_mac: Option<String>,
    pub preferred_connection_mode: Option<String>,
    pub preferred_codex_port: Option<u16>,
    pub ssh_port_forwarding_enabled: Option<bool>,
    pub websocket_url: Option<String>,
    pub remembered_by_user: bool,
    pub backend_kind: SavedServerBackendKindRecord,
    pub opencode_base_url: Option<String>,
    pub opencode_basic_auth_username: Option<String>,
    pub opencode_basic_auth_password: Option<String>,
    pub opencode_known_directories: Vec<SavedOpenCodeDirectoryScopeRecord>,
}

/// SSH auth method discriminator.
#[derive(Clone, Debug, uniffi::Enum)]
pub enum SshAuthMethodRecord {
    Password,
    Key,
}

/// SSH credential record passed across the FFI boundary.
#[derive(Clone, Debug, uniffi::Record)]
pub struct SshCredentialRecord {
    pub username: String,
    pub auth_method: SshAuthMethodRecord,
    pub password: Option<String>,
    pub private_key_pem: Option<String>,
    pub passphrase: Option<String>,
}

/// Result of a single server reconnection attempt.
#[derive(Clone, Debug, uniffi::Record)]
pub struct ReconnectResult {
    pub server_id: String,
    pub success: bool,
    pub needs_local_auth_restore: bool,
    pub error_message: Option<String>,
}

/// Callback interface for platform-side SSH credential storage.
#[uniffi::export(callback_interface)]
pub trait SshCredentialProvider: Send + Sync {
    fn load_credential(&self, host: String, port: u16) -> Option<SshCredentialRecord>;
}

// ── Internal reconnect plan ─────────────────────────────────────────────

#[derive(Clone, Debug)]
pub(crate) enum ReconnectPlan {
    Ssh {
        server_id: String,
        display_name: String,
        host: String,
        ssh_port: u16,
        credential: SshCredentialRecord,
    },
    Local {
        server_id: String,
        display_name: String,
    },
    DirectRemote {
        server_id: String,
        display_name: String,
        host: String,
        port: u16,
    },
    RemoteUrl {
        server_id: String,
        display_name: String,
        websocket_url: String,
    },
    OpenCode {
        server_id: String,
        config: OpenCodeServerConfig,
    },
}

// ── Transport resolution helpers ────────────────────────────────────────

/// Resolve the effective preferred connection mode, handling legacy
/// `ssh_port_forwarding_enabled` migration.
///
/// Mirrors iOS `migratedPreferredConnectionMode` and Android
/// `resolvedPreferredConnectionMode` (simplified — the full Android version
/// also validates that the mode is still reachable, but for reconnect
/// planning the raw preference is what matters since we skip if no
/// credential is available anyway).
pub(crate) fn resolved_preferred_connection_mode(server: &SavedServerRecord) -> Option<String> {
    if let Some(ref mode) = server.preferred_connection_mode {
        return Some(mode.clone());
    }
    if server.ssh_port_forwarding_enabled == Some(true) {
        return Some("ssh".to_string());
    }
    None
}

/// Resolve the SSH port for a saved server.
///
/// Mirrors Android `resolvedSshPort`:
///   `sshPort ?: port.takeIf { !hasCodexServer && it > 0 } ?: 22`
/// and iOS `SavedServer.toDiscoveredServer()` → `DiscoveredServer.resolvedSSHPort`:
///   `sshPort ?? (hasCodexServer ? nil : port)` then `?? 22`
pub(crate) fn resolved_ssh_port(server: &SavedServerRecord) -> u16 {
    if let Some(port) = server.ssh_port {
        return port;
    }
    if !server.has_codex_server && server.port > 0 {
        return server.port;
    }
    22
}

/// Build the list of available direct Codex ports (merging port + codex_ports).
///
/// Mirrors Android `availableDirectCodexPorts`.
fn available_direct_codex_ports(server: &SavedServerRecord) -> Vec<u16> {
    let mut ordered = Vec::new();
    if server.has_codex_server && server.port > 0 {
        ordered.push(server.port);
    }
    for &p in &server.codex_ports {
        if p > 0 && !ordered.contains(&p) {
            ordered.push(p);
        }
    }
    ordered
}

/// Whether the server prefers SSH connections.
fn prefers_ssh(server: &SavedServerRecord) -> bool {
    resolved_preferred_connection_mode(server).as_deref() == Some("ssh")
}

/// Whether the server requires user to choose a connection mode before
/// we can auto-connect.
fn requires_connection_choice(server: &SavedServerRecord) -> bool {
    if server.websocket_url.is_some() {
        return false;
    }
    let mode = resolved_preferred_connection_mode(server);
    if mode.is_some() {
        return false;
    }
    let ports = available_direct_codex_ports(server);
    let can_ssh = can_connect_via_ssh(server);
    ports.len() > 1 || (!ports.is_empty() && can_ssh)
}

/// Whether SSH is a viable transport for this server.
fn can_connect_via_ssh(server: &SavedServerRecord) -> bool {
    if server.websocket_url.is_some() {
        return false;
    }
    server.ssh_port.is_some()
        || server.source == "ssh"
        || (!server.has_codex_server && resolved_ssh_port(server) > 0)
        || server.preferred_connection_mode.as_deref() == Some("ssh")
        || server.ssh_port_forwarding_enabled == Some(true)
}

/// Resolve the preferred codex port for direct-codex mode.
fn resolved_preferred_codex_port(server: &SavedServerRecord) -> Option<u16> {
    if resolved_preferred_connection_mode(server).as_deref() != Some("directCodex") {
        return None;
    }
    let ports = available_direct_codex_ports(server);
    if let Some(pref) = server.preferred_codex_port {
        if ports.contains(&pref) {
            return Some(pref);
        }
    }
    None
}

/// Resolve the direct Codex port for a saved server.
///
/// Returns `None` when SSH is preferred, when the user needs to choose,
/// or when no direct port is available.
///
/// Mirrors Android `directCodexPort`.
pub(crate) fn direct_codex_port(server: &SavedServerRecord) -> Option<u16> {
    if server.websocket_url.is_some() {
        return None;
    }
    if prefers_ssh(server) {
        return None;
    }
    if let Some(port) = resolved_preferred_codex_port(server) {
        return Some(port);
    }
    if requires_connection_choice(server) {
        return None;
    }
    let ports = available_direct_codex_ports(server);
    ports.first().copied()
}

// ── Plan computation ────────────────────────────────────────────────────

/// Compute the reconnect plan for a single saved server.
///
/// Consolidates iOS `reconnectPlan(for:)` and Android
/// `reconnectSavedServer` into a single decision tree.
pub(crate) fn compute_reconnect_plan(
    server: &SavedServerRecord,
    credential: Option<&SshCredentialRecord>,
    is_connected: bool,
) -> Option<ReconnectPlan> {
    // 1. Skip if already connected
    if is_connected {
        return None;
    }

    if server.backend_kind == SavedServerBackendKindRecord::OpenCode {
        let config = saved_server_opencode_config(server).ok()?;
        return Some(ReconnectPlan::OpenCode {
            server_id: server.id.clone(),
            config,
        });
    }

    // 2. WebSocket URL override → RemoteUrl
    if let Some(ref ws_url) = server.websocket_url {
        return Some(ReconnectPlan::RemoteUrl {
            server_id: server.id.clone(),
            display_name: server.name.clone(),
            websocket_url: ws_url.clone(),
        });
    }

    let mode = resolved_preferred_connection_mode(server);

    // 3. Explicit SSH mode + credential → Ssh
    if mode.as_deref() == Some("ssh") {
        if let Some(cred) = credential {
            return Some(ReconnectPlan::Ssh {
                server_id: server.id.clone(),
                display_name: server.name.clone(),
                host: server.hostname.clone(),
                ssh_port: resolved_ssh_port(server),
                credential: cred.clone(),
            });
        }
        // SSH preferred but no credential — cannot reconnect
        return None;
    }

    // 4. Direct Codex port available → DirectRemote
    if let Some(port) = direct_codex_port(server) {
        return Some(ReconnectPlan::DirectRemote {
            server_id: server.id.clone(),
            display_name: server.name.clone(),
            host: server.hostname.clone(),
            port,
        });
    }

    // 5. No explicit mode, but credential available → SSH (legacy fallback)
    if mode.is_none() {
        if let Some(cred) = credential {
            return Some(ReconnectPlan::Ssh {
                server_id: server.id.clone(),
                display_name: server.name.clone(),
                host: server.hostname.clone(),
                ssh_port: resolved_ssh_port(server),
                credential: cred.clone(),
            });
        }
    }

    // 6. Local source → Local
    if server.source == "local" {
        return Some(ReconnectPlan::Local {
            server_id: server.id.clone(),
            display_name: server.name.clone(),
        });
    }

    // 7. No viable transport
    None
}

fn saved_server_opencode_config(
    server: &SavedServerRecord,
) -> Result<OpenCodeServerConfig, String> {
    let base_url = server
        .opencode_base_url
        .clone()
        .ok_or_else(|| "OpenCode saved server missing base URL".to_string())?;
    let parsed =
        url::Url::parse(&base_url).map_err(|error| format!("invalid OpenCode base URL: {error}"))?;
    let host = parsed
        .host_str()
        .ok_or_else(|| "OpenCode base URL host missing".to_string())?
        .to_string();
    let port = parsed
        .port_or_known_default()
        .ok_or_else(|| "OpenCode base URL port missing".to_string())?;
    let tls = matches!(parsed.scheme(), "https");
    let mut config = OpenCodeServerConfig::new(
        server.id.clone(),
        server.name.clone(),
        base_url,
        host,
        port,
        tls,
    )
    .map_err(|error| error.to_string())?;
    config.basic_auth_username = server.opencode_basic_auth_username.clone();
    config.basic_auth_password = server.opencode_basic_auth_password.clone();
    config.known_directories = server
        .opencode_known_directories
        .iter()
        .map(|scope| {
            OpenCodeDirectoryScope::new(scope.directory.clone()).map_err(|error| error.to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    if config.known_directories.is_empty() {
        return Err("OpenCode saved server missing directory scopes".to_string());
    }
    Ok(config)
}

// ── Plan execution ──────────────────────────────────────────────────────

/// Execute a single reconnect plan against the shared `MobileClient`.
pub(crate) async fn execute_reconnect_plan(
    plan: &ReconnectPlan,
    client: &MobileClient,
    ipc_override: Option<String>,
) -> ReconnectResult {
    match plan {
        ReconnectPlan::Ssh {
            server_id,
            display_name,
            host,
            ssh_port,
            credential,
        } => {
            info!(
                "reconnect: executing SSH plan server_id={} host={} ssh_port={}",
                server_id, host, ssh_port
            );
            let auth = match credential.auth_method {
                SshAuthMethodRecord::Password => {
                    SshAuth::Password(credential.password.clone().unwrap_or_default())
                }
                SshAuthMethodRecord::Key => SshAuth::PrivateKey {
                    key_pem: credential.private_key_pem.clone().unwrap_or_default(),
                    passphrase: credential.passphrase.clone(),
                },
            };
            let ssh_creds = SshCredentials {
                host: host.clone(),
                port: *ssh_port,
                username: credential.username.clone(),
                auth,
            };
            let config = ServerConfig {
                server_id: server_id.clone(),
                display_name: display_name.clone(),
                host: host.clone(),
                port: 0,
                websocket_url: None,
                is_local: false,
                tls: false,
                backend_kind: AppServerBackendKind::Codex,
                transport_kind: AppServerTransportKind::Ssh,
                connection_path: AppServerConnectionPath::Ssh,
                known_directories: Vec::new(),
            };
            match client
                .connect_remote_over_ssh(config, ssh_creds, true, None, ipc_override)
                .await
            {
                Ok(_) => ReconnectResult {
                    server_id: server_id.clone(),
                    success: true,
                    needs_local_auth_restore: false,
                    error_message: None,
                },
                Err(e) => {
                    warn!(
                        "reconnect: SSH plan failed server_id={} error={}",
                        server_id, e
                    );
                    ReconnectResult {
                        server_id: server_id.clone(),
                        success: false,
                        needs_local_auth_restore: false,
                        error_message: Some(e.to_string()),
                    }
                }
            }
        }
        ReconnectPlan::Local {
            server_id,
            display_name,
        } => {
            info!("reconnect: executing Local plan server_id={}", server_id);
            let config = ServerConfig {
                server_id: server_id.clone(),
                display_name: display_name.clone(),
                host: "127.0.0.1".to_string(),
                port: 0,
                websocket_url: None,
                is_local: true,
                tls: false,
                backend_kind: AppServerBackendKind::Codex,
                transport_kind: AppServerTransportKind::Local,
                connection_path: AppServerConnectionPath::Local,
                known_directories: Vec::new(),
            };
            match client
                .connect_local(config, InProcessConfig::default())
                .await
            {
                Ok(_) => ReconnectResult {
                    server_id: server_id.clone(),
                    success: true,
                    needs_local_auth_restore: true,
                    error_message: None,
                },
                Err(e) => {
                    warn!(
                        "reconnect: Local plan failed server_id={} error={}",
                        server_id, e
                    );
                    ReconnectResult {
                        server_id: server_id.clone(),
                        success: false,
                        needs_local_auth_restore: false,
                        error_message: Some(e.to_string()),
                    }
                }
            }
        }
        ReconnectPlan::DirectRemote {
            server_id,
            display_name,
            host,
            port,
        } => {
            info!(
                "reconnect: executing DirectRemote plan server_id={} host={} port={}",
                server_id, host, port
            );
            let config = ServerConfig {
                server_id: server_id.clone(),
                display_name: display_name.clone(),
                host: host.clone(),
                port: *port,
                websocket_url: None,
                is_local: false,
                tls: false,
                backend_kind: AppServerBackendKind::Codex,
                transport_kind: AppServerTransportKind::Websocket,
                connection_path: AppServerConnectionPath::Lan,
                known_directories: Vec::new(),
            };
            match client.connect_remote(config).await {
                Ok(_) => ReconnectResult {
                    server_id: server_id.clone(),
                    success: true,
                    needs_local_auth_restore: false,
                    error_message: None,
                },
                Err(e) => {
                    warn!(
                        "reconnect: DirectRemote plan failed server_id={} error={}",
                        server_id, e
                    );
                    ReconnectResult {
                        server_id: server_id.clone(),
                        success: false,
                        needs_local_auth_restore: false,
                        error_message: Some(e.to_string()),
                    }
                }
            }
        }
        ReconnectPlan::RemoteUrl {
            server_id,
            display_name,
            websocket_url,
        } => {
            info!(
                "reconnect: executing RemoteUrl plan server_id={} url={}",
                server_id, websocket_url
            );
            let parsed = url::Url::parse(websocket_url).ok();
            let host = parsed
                .as_ref()
                .and_then(|url| url.host_str())
                .unwrap_or_default()
                .to_string();
            let tls = parsed
                .as_ref()
                .map(|url| matches!(url.scheme(), "wss" | "https"))
                .unwrap_or(false);
            let config = ServerConfig {
                server_id: server_id.clone(),
                display_name: display_name.clone(),
                host: host.clone(),
                port: 0,
                websocket_url: Some(websocket_url.clone()),
                is_local: false,
                tls,
                backend_kind: AppServerBackendKind::Codex,
                transport_kind: AppServerTransportKind::Websocket,
                connection_path: if host.ends_with(".ts.net") {
                    AppServerConnectionPath::Tailscale
                } else {
                    AppServerConnectionPath::Lan
                },
                known_directories: Vec::new(),
            };
            match client.connect_remote(config).await {
                Ok(_) => ReconnectResult {
                    server_id: server_id.clone(),
                    success: true,
                    needs_local_auth_restore: false,
                    error_message: None,
                },
                Err(e) => {
                    warn!(
                        "reconnect: RemoteUrl plan failed server_id={} error={}",
                        server_id, e
                    );
                    ReconnectResult {
                        server_id: server_id.clone(),
                        success: false,
                        needs_local_auth_restore: false,
                        error_message: Some(e.to_string()),
                    }
                }
            }
        }
        ReconnectPlan::OpenCode { server_id, config } => {
            info!("reconnect: executing OpenCode plan server_id={}", server_id);
            match client.connect_opencode(config.clone()).await {
                Ok(_) => ReconnectResult {
                    server_id: server_id.clone(),
                    success: true,
                    needs_local_auth_restore: false,
                    error_message: None,
                },
                Err(error) => {
                    warn!(
                        "reconnect: OpenCode plan failed server_id={} error={}",
                        server_id, error
                    );
                    ReconnectResult {
                        server_id: server_id.clone(),
                        success: false,
                        needs_local_auth_restore: false,
                        error_message: Some(error.to_string()),
                    }
                }
            }
        }
    }
}

// ── Unit tests ──────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn base_server() -> SavedServerRecord {
        SavedServerRecord {
            id: "srv-1".into(),
            name: "Test Server".into(),
            hostname: "192.168.1.100".into(),
            port: 8080,
            codex_ports: vec![],
            ssh_port: None,
            source: "manual".into(),
            has_codex_server: true,
            wake_mac: None,
            preferred_connection_mode: None,
            preferred_codex_port: None,
            ssh_port_forwarding_enabled: None,
            websocket_url: None,
            remembered_by_user: true,
            backend_kind: SavedServerBackendKindRecord::Codex,
            opencode_base_url: None,
            opencode_basic_auth_username: None,
            opencode_basic_auth_password: None,
            opencode_known_directories: vec![],
        }
    }

    fn ssh_credential() -> SshCredentialRecord {
        SshCredentialRecord {
            username: "user".into(),
            auth_method: SshAuthMethodRecord::Password,
            password: Some("pass".into()),
            private_key_pem: None,
            passphrase: None,
        }
    }

    // -- resolved_preferred_connection_mode tests --

    #[test]
    fn resolved_mode_explicit_ssh() {
        let mut s = base_server();
        s.preferred_connection_mode = Some("ssh".into());
        assert_eq!(
            resolved_preferred_connection_mode(&s).as_deref(),
            Some("ssh")
        );
    }

    #[test]
    fn resolved_mode_explicit_direct_codex() {
        let mut s = base_server();
        s.preferred_connection_mode = Some("directCodex".into());
        assert_eq!(
            resolved_preferred_connection_mode(&s).as_deref(),
            Some("directCodex")
        );
    }

    #[test]
    fn resolved_mode_legacy_ssh_port_forwarding_enabled() {
        let mut s = base_server();
        s.ssh_port_forwarding_enabled = Some(true);
        assert_eq!(
            resolved_preferred_connection_mode(&s).as_deref(),
            Some("ssh")
        );
    }

    #[test]
    fn resolved_mode_legacy_ssh_port_forwarding_disabled() {
        let mut s = base_server();
        s.ssh_port_forwarding_enabled = Some(false);
        assert!(resolved_preferred_connection_mode(&s).is_none());
    }

    #[test]
    fn resolved_mode_none_when_no_preference() {
        let s = base_server();
        assert!(resolved_preferred_connection_mode(&s).is_none());
    }

    // -- resolved_ssh_port tests --

    #[test]
    fn resolved_ssh_port_explicit() {
        let mut s = base_server();
        s.ssh_port = Some(2222);
        assert_eq!(resolved_ssh_port(&s), 2222);
    }

    #[test]
    fn resolved_ssh_port_fallback_to_port_when_no_codex() {
        let mut s = base_server();
        s.has_codex_server = false;
        s.port = 3333;
        assert_eq!(resolved_ssh_port(&s), 3333);
    }

    #[test]
    fn resolved_ssh_port_default_22_when_has_codex() {
        let s = base_server();
        assert_eq!(resolved_ssh_port(&s), 22);
    }

    #[test]
    fn resolved_ssh_port_default_22_when_port_zero() {
        let mut s = base_server();
        s.has_codex_server = false;
        s.port = 0;
        assert_eq!(resolved_ssh_port(&s), 22);
    }

    // -- direct_codex_port tests --

    #[test]
    fn direct_codex_port_returns_port_when_has_codex() {
        let s = base_server();
        // has_codex_server=true, port=8080, no SSH preference → port 8080
        assert_eq!(direct_codex_port(&s), Some(8080));
    }

    #[test]
    fn direct_codex_port_none_when_ssh_preferred() {
        let mut s = base_server();
        s.preferred_connection_mode = Some("ssh".into());
        assert_eq!(direct_codex_port(&s), None);
    }

    #[test]
    fn direct_codex_port_preferred_codex_port_in_direct_mode() {
        let mut s = base_server();
        s.preferred_connection_mode = Some("directCodex".into());
        s.codex_ports = vec![9090, 9091];
        s.preferred_codex_port = Some(9091);
        assert_eq!(direct_codex_port(&s), Some(9091));
    }

    #[test]
    fn direct_codex_port_none_when_requires_choice() {
        let mut s = base_server();
        // Two ports + SSH available + no preferred mode → requires choice
        s.codex_ports = vec![9090, 9091];
        s.ssh_port = Some(22);
        assert_eq!(direct_codex_port(&s), None);
    }

    #[test]
    fn direct_codex_port_none_when_no_codex() {
        let mut s = base_server();
        s.has_codex_server = false;
        s.port = 22;
        s.codex_ports = vec![];
        assert_eq!(direct_codex_port(&s), None);
    }

    #[test]
    fn direct_codex_port_none_when_websocket_url() {
        let mut s = base_server();
        s.websocket_url = Some("wss://example.com/ws".into());
        assert_eq!(direct_codex_port(&s), None);
    }

    // -- compute_reconnect_plan tests --

    #[test]
    fn plan_skip_when_connected() {
        let s = base_server();
        assert!(compute_reconnect_plan(&s, None, true).is_none());
    }

    #[test]
    fn plan_remote_url_when_websocket_set() {
        let mut s = base_server();
        s.websocket_url = Some("wss://example.com/ws".into());
        let plan = compute_reconnect_plan(&s, None, false);
        assert!(matches!(plan, Some(ReconnectPlan::RemoteUrl { .. })));
    }

    #[test]
    fn plan_ssh_when_mode_is_ssh_and_credential() {
        let mut s = base_server();
        s.preferred_connection_mode = Some("ssh".into());
        let cred = ssh_credential();
        let plan = compute_reconnect_plan(&s, Some(&cred), false);
        assert!(matches!(plan, Some(ReconnectPlan::Ssh { .. })));
    }

    #[test]
    fn plan_none_when_mode_is_ssh_but_no_credential() {
        let mut s = base_server();
        s.preferred_connection_mode = Some("ssh".into());
        assert!(compute_reconnect_plan(&s, None, false).is_none());
    }

    #[test]
    fn plan_direct_remote_when_port_available() {
        let s = base_server();
        let plan = compute_reconnect_plan(&s, None, false);
        assert!(matches!(plan, Some(ReconnectPlan::DirectRemote { .. })));
        if let Some(ReconnectPlan::DirectRemote { port, .. }) = plan {
            assert_eq!(port, 8080);
        }
    }

    #[test]
    fn plan_ssh_legacy_fallback_when_no_mode_but_credential() {
        let mut s = base_server();
        // No explicit mode, no direct codex port available, but has credential
        s.has_codex_server = false;
        s.port = 0;
        s.codex_ports = vec![];
        let cred = ssh_credential();
        let plan = compute_reconnect_plan(&s, Some(&cred), false);
        assert!(matches!(plan, Some(ReconnectPlan::Ssh { .. })));
    }

    #[test]
    fn plan_local_when_source_is_local() {
        let mut s = base_server();
        s.source = "local".into();
        s.has_codex_server = false;
        s.port = 0;
        s.codex_ports = vec![];
        let plan = compute_reconnect_plan(&s, None, false);
        assert!(matches!(plan, Some(ReconnectPlan::Local { .. })));
    }

    #[test]
    fn plan_none_when_no_viable_transport() {
        let mut s = base_server();
        s.has_codex_server = false;
        s.port = 0;
        s.codex_ports = vec![];
        s.source = "manual".into();
        assert!(compute_reconnect_plan(&s, None, false).is_none());
    }

    #[test]
    fn plan_opencode_when_saved_server_has_backend_config() {
        let mut s = base_server();
        s.backend_kind = SavedServerBackendKindRecord::OpenCode;
        s.opencode_base_url = Some("http://127.0.0.1:4187".into());
        s.opencode_basic_auth_username = Some("alice".into());
        s.opencode_basic_auth_password = Some("secret".into());
        s.opencode_known_directories = vec![SavedOpenCodeDirectoryScopeRecord {
            directory: "/tmp/project".into(),
        }];

        match compute_reconnect_plan(&s, None, false) {
            Some(ReconnectPlan::OpenCode { server_id, config }) => {
                assert_eq!(server_id, "srv-1");
                assert_eq!(config.server_id, "srv-1");
                assert_eq!(config.base_url.as_str(), "http://127.0.0.1:4187/");
                assert_eq!(config.basic_auth_username.as_deref(), Some("alice"));
                assert_eq!(config.basic_auth_password.as_deref(), Some("secret"));
                assert_eq!(config.known_directories[0].directory, "/tmp/project");
            }
            other => panic!("expected OpenCode plan, got {other:?}"),
        }
    }
}
