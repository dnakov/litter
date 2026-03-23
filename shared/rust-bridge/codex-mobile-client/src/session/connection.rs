//! `ServerSession` state machine for connection lifecycle management.
//!
//! Manages connection health, retry logic, auth flow, sandbox fallback,
//! and initialize handshake for a single Codex server.
//!
//! Uses upstream `RemoteAppServerClient` for remote connections and
//! upstream `InProcessClientHandle` for local (in-process) connections.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use codex_app_server_client::{
    AppServerClient, AppServerEvent, RemoteAppServerClient, RemoteAppServerConnectArgs,
};
use codex_app_server_protocol::{
    ClientNotification, ClientRequest, JSONRPCErrorError, RequestId, Result as JsonRpcResult,
    ServerNotification, ServerRequest,
};
use serde_json::Value as JsonValue;
use tokio::sync::{broadcast, mpsc, oneshot, watch};
use tracing::{debug, info, warn};

use crate::transport::{RpcError, TransportError};

// ---------------------------------------------------------------------------
// InProcessConfig
// ---------------------------------------------------------------------------

/// Configuration for starting an in-process Codex transport.
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct InProcessConfig {
    /// Override the Codex home directory.
    pub codex_home: Option<PathBuf>,
    /// Override the working directory for Codex operations.
    pub working_directory: Option<PathBuf>,
    /// Capacity for internal event/command channels. Defaults to 256.
    pub channel_capacity: usize,
}

impl Default for InProcessConfig {
    fn default() -> Self {
        Self {
            codex_home: None,
            working_directory: None,
            channel_capacity: 256,
        }
    }
}

#[cfg(target_os = "ios")]
static IOS_CACERT_PEM: &[u8] = include_bytes!("../../../codex-bridge/src/cacert.pem");

#[allow(unused_mut)]
fn prepare_in_process_config(
    mut config: InProcessConfig,
) -> Result<InProcessConfig, TransportError> {
    #[cfg(target_os = "ios")]
    {
        config = prepare_ios_in_process_config(config)?;
    }

    Ok(config)
}

#[cfg(target_os = "ios")]
fn prepare_ios_in_process_config(
    mut config: InProcessConfig,
) -> Result<InProcessConfig, TransportError> {
    let home_dir = std::env::var_os("HOME").map(PathBuf::from);
    let docs_root = home_dir.as_ref().map(|home| home.join("Documents"));

    if let Some(root) = &docs_root {
        for relative in ["home/codex", "tmp", "var/log", "etc"] {
            std::fs::create_dir_all(root.join(relative)).map_err(|e| {
                TransportError::ConnectionFailed(format!(
                    "failed to create local sandbox directory {:?}: {e}",
                    root.join(relative)
                ))
            })?;
        }
    }

    if config.working_directory.is_none()
        && let Some(root) = &docs_root
    {
        config.working_directory = Some(root.join("home").join("codex"));
    }

    if let Some(ref working_directory) = config.working_directory {
        std::fs::create_dir_all(working_directory).map_err(|e| {
            TransportError::ConnectionFailed(format!(
                "failed to create local working directory {:?}: {e}",
                working_directory
            ))
        })?;
        unsafe {
            std::env::set_var("SSH_HOME", working_directory);
            std::env::set_var("CURL_HOME", working_directory);
        }
    }

    if config.codex_home.is_none() {
        config.codex_home = Some(resolve_ios_codex_home(&home_dir)?);
    }

    if let Some(ref codex_home) = config.codex_home {
        std::fs::create_dir_all(codex_home).map_err(|e| {
            TransportError::ConnectionFailed(format!(
                "failed to create CODEX_HOME {:?}: {e}",
                codex_home
            ))
        })?;
        let canonical = codex_home
            .canonicalize()
            .unwrap_or_else(|_| codex_home.clone());
        unsafe {
            std::env::set_var("CODEX_HOME", &canonical);
        }
        init_ios_tls_roots(&canonical)?;
        config.codex_home = Some(canonical);
    }

    Ok(config)
}

#[cfg(target_os = "ios")]
fn resolve_ios_codex_home(home_dir: &Option<PathBuf>) -> Result<PathBuf, TransportError> {
    let mut candidates: Vec<PathBuf> = Vec::new();

    if let Ok(existing) = std::env::var("CODEX_HOME")
        && !existing.is_empty()
    {
        candidates.push(PathBuf::from(existing));
    }

    if let Some(home) = home_dir {
        candidates.push(
            home.join("Library")
                .join("Application Support")
                .join("codex"),
        );
        candidates.push(home.join("Documents").join(".codex"));
        candidates.push(home.join(".codex"));
    }

    if let Ok(tmpdir) = std::env::var("TMPDIR") {
        candidates.push(PathBuf::from(tmpdir).join("codex-home"));
    }

    for candidate in candidates {
        match std::fs::create_dir_all(&candidate) {
            Ok(()) => return Ok(candidate),
            Err(err) => {
                warn!(
                    "failed to create CODEX_HOME candidate {:?}: {err}",
                    candidate
                );
            }
        }
    }

    Err(TransportError::ConnectionFailed(
        "unable to initialize any writable CODEX_HOME location".to_string(),
    ))
}

#[cfg(target_os = "ios")]
fn init_ios_tls_roots(codex_home: &std::path::Path) -> Result<(), TransportError> {
    if let Some(existing) = std::env::var_os("SSL_CERT_FILE") {
        let existing_path = std::path::PathBuf::from(existing);
        if existing_path.is_file() {
            return Ok(());
        }
        warn!(
            "replacing stale SSL_CERT_FILE {:?} with a regenerated local bundle",
            existing_path
        );
    }

    let pem_path = codex_home.join("cacert.pem");
    if !pem_path.exists() {
        std::fs::write(&pem_path, IOS_CACERT_PEM).map_err(|e| {
            TransportError::ConnectionFailed(format!(
                "failed to write local TLS roots {:?}: {e}",
                pem_path
            ))
        })?;
    }

    unsafe {
        std::env::set_var("SSL_CERT_FILE", &pem_path);
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// ServerConfig
// ---------------------------------------------------------------------------

/// Configuration describing a Codex server endpoint.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerConfig {
    /// Unique identifier for this server.
    pub server_id: String,
    /// Human-readable name shown in the UI.
    pub display_name: String,
    /// Hostname or IP address.
    pub host: String,
    /// TCP port.
    pub port: u16,
    /// Explicit WebSocket URL override for remote connections.
    pub websocket_url: Option<String>,
    /// Whether this is a local (in-process) server.
    pub is_local: bool,
    /// Whether to use TLS for the WebSocket connection.
    pub tls: bool,
}

// ---------------------------------------------------------------------------
// ConnectionHealth
// ---------------------------------------------------------------------------

/// Observable health state of the connection to a server.
#[derive(Debug, Clone)]
pub enum ConnectionHealth {
    Disconnected,
    Connecting { attempt: u32, max_attempts: u32 },
    Connected,
    Unresponsive { since: Instant },
}

impl PartialEq for ConnectionHealth {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Disconnected, Self::Disconnected) => true,
            (
                Self::Connecting {
                    attempt: a1,
                    max_attempts: m1,
                },
                Self::Connecting {
                    attempt: a2,
                    max_attempts: m2,
                },
            ) => a1 == a2 && m1 == m2,
            (Self::Connected, Self::Connected) => true,
            (Self::Unresponsive { since: s1 }, Self::Unresponsive { since: s2 }) => s1 == s2,
            _ => false,
        }
    }
}

// ---------------------------------------------------------------------------
// Internal command type for the worker task
// ---------------------------------------------------------------------------

enum SessionCommand {
    Request {
        request: ClientRequest,
        response_tx: oneshot::Sender<Result<JsonValue, RpcError>>,
    },
    Notify {
        notification: ClientNotification,
        response_tx: oneshot::Sender<Result<(), RpcError>>,
    },
    Resolve {
        request_id: RequestId,
        result: JsonRpcResult,
        response_tx: oneshot::Sender<Result<(), RpcError>>,
    },
    Reject {
        request_id: RequestId,
        error: JSONRPCErrorError,
        response_tx: oneshot::Sender<Result<(), RpcError>>,
    },
    Shutdown,
}

// ---------------------------------------------------------------------------
// ServerSession
// ---------------------------------------------------------------------------

/// Typed event from the server: either a typed notification, a legacy notification,
/// or a typed server request.
#[derive(Debug, Clone)]
pub enum ServerEvent {
    Notification(ServerNotification),
    LegacyNotification { method: String, params: JsonValue },
    Request(ServerRequest),
}

/// Manages the full connection lifecycle to a single Codex server.
///
/// Wraps the upstream `AppServerClient` (both in-process and remote variants)
/// behind a worker task that owns the client and multiplexes between command
/// dispatch and event consumption.
pub struct ServerSession {
    config: ServerConfig,
    health_tx: watch::Sender<ConnectionHealth>,
    health_rx: watch::Receiver<ConnectionHealth>,
    command_tx: mpsc::Sender<SessionCommand>,
    event_tx: broadcast::Sender<ServerEvent>,
    worker_handle: tokio::task::JoinHandle<()>,
}

impl ServerSession {
    /// Connect to a local (in-process) Codex server.
    pub async fn connect_local(
        config: ServerConfig,
        in_process: InProcessConfig,
    ) -> Result<Self, TransportError> {
        use codex_app_server::in_process::InProcessStartArgs;
        use codex_app_server_protocol::{ClientInfo, InitializeCapabilities, InitializeParams};
        use codex_arg0::Arg0DispatchPaths;
        use codex_cloud_requirements::cloud_requirements_loader;
        use codex_core::ThreadManager;
        use codex_core::auth::AuthManager;
        use codex_core::config::ConfigBuilder;
        use codex_core::config_loader::LoaderOverrides;
        use codex_core::features::Feature;
        use codex_core::models_manager::collaboration_mode_presets::CollaborationModesConfig;
        use codex_feedback::CodexFeedback;
        use codex_protocol::protocol::SessionSource;

        let (health_tx, health_rx) = watch::channel(ConnectionHealth::Connecting {
            attempt: 1,
            max_attempts: 1,
        });

        let in_process = prepare_in_process_config(in_process)?;

        // Apply codex_home override if provided.
        if let Some(ref codex_home) = in_process.codex_home {
            if let Err(e) = std::fs::create_dir_all(codex_home) {
                return Err(TransportError::ConnectionFailed(format!(
                    "failed to create codex_home {:?}: {e}",
                    codex_home
                )));
            }
            unsafe {
                std::env::set_var("CODEX_HOME", codex_home);
            }
        }

        if let Some(ref working_dir) = in_process.working_directory {
            if let Err(e) = std::env::set_current_dir(working_dir) {
                return Err(TransportError::ConnectionFailed(format!(
                    "failed to set working directory {:?}: {e}",
                    working_dir
                )));
            }
        }

        let cli_overrides = vec![
            ("features.realtime_conversation".to_string(), true.into()),
            (
                "experimental_realtime_ws_model".to_string(),
                "gpt-realtime-1.5".to_string().into(),
            ),
            ("realtime.version".to_string(), "v2".to_string().into()),
            (
                "realtime.type".to_string(),
                "conversational".to_string().into(),
            ),
        ];

        let mut base_builder = ConfigBuilder::default().cli_overrides(cli_overrides.clone());
        if let Some(ref codex_home) = in_process.codex_home {
            base_builder = base_builder.codex_home(codex_home.clone());
        }
        if let Some(ref working_dir) = in_process.working_directory {
            base_builder = base_builder.fallback_cwd(Some(working_dir.clone()));
        }

        let base_config = base_builder
            .build()
            .await
            .map_err(|e| TransportError::ConnectionFailed(format!("config build failed: {e}")))?;

        let auth_manager = AuthManager::shared(
            base_config.codex_home.clone(),
            false,
            base_config.cli_auth_credentials_store_mode,
        );

        let cloud_requirements = cloud_requirements_loader(
            auth_manager.clone(),
            base_config.chatgpt_base_url.clone(),
            base_config.codex_home.clone(),
        );

        let mut resolved_builder = ConfigBuilder::default()
            .cli_overrides(cli_overrides.clone())
            .cloud_requirements(cloud_requirements.clone());
        if let Some(ref codex_home) = in_process.codex_home {
            resolved_builder = resolved_builder.codex_home(codex_home.clone());
        }
        if let Some(ref working_dir) = in_process.working_directory {
            resolved_builder = resolved_builder.fallback_cwd(Some(working_dir.clone()));
        }

        let resolved_config = resolved_builder.build().await.unwrap_or(base_config);

        let feedback = CodexFeedback::new();
        let session_source = SessionSource::VSCode;

        let thread_manager = Arc::new(ThreadManager::new(
            &resolved_config,
            auth_manager.clone(),
            session_source.clone(),
            CollaborationModesConfig {
                default_mode_request_user_input: resolved_config
                    .features
                    .enabled(Feature::DefaultModeRequestUserInput),
            },
        ));

        let args = InProcessStartArgs {
            arg0_paths: Arg0DispatchPaths::default(),
            config: Arc::new(resolved_config),
            cli_overrides,
            loader_overrides: LoaderOverrides::default(),
            cloud_requirements,
            auth_manager: Some(auth_manager),
            thread_manager: Some(thread_manager),
            feedback,
            config_warnings: Vec::new(),
            session_source,
            enable_codex_api_key_env: false,
            initialize: InitializeParams {
                client_info: ClientInfo {
                    name: "Litter".to_string(),
                    version: "1.0".to_string(),
                    title: None,
                },
                capabilities: Some(InitializeCapabilities {
                    experimental_api: true,
                    opt_out_notification_methods: None,
                }),
            },
            channel_capacity: in_process.channel_capacity,
        };

        let mut handle = codex_app_server::in_process::start(args)
            .await
            .map_err(|e| {
                TransportError::ConnectionFailed(format!("in-process start failed: {e}"))
            })?;

        let sender = handle.sender();
        let (event_tx, _) = broadcast::channel::<ServerEvent>(256);
        let (command_tx, mut command_rx) = mpsc::channel::<SessionCommand>(256);

        let evt_tx = event_tx.clone();

        let worker_handle = tokio::spawn(async move {
            loop {
                tokio::select! {
                    command = command_rx.recv() => {
                        let Some(command) = command else { break; };
                        match command {
                            SessionCommand::Request { request, response_tx } => {
                                let sender = sender.clone();
                                tokio::spawn(async move {
                                    let result = match sender.request(request).await {
                                        Ok(Ok(value)) => Ok(value),
                                        Ok(Err(error)) => Err(RpcError::Server {
                                            code: error.code,
                                            message: error.message,
                                        }),
                                        Err(e) => Err(RpcError::Transport(
                                            TransportError::SendFailed(e.to_string()),
                                        )),
                                    };
                                    let _ = response_tx.send(result);
                                });
                            }
                            SessionCommand::Notify { notification, response_tx } => {
                                let result = sender
                                    .notify(notification)
                                    .map_err(|e| {
                                        RpcError::Transport(TransportError::SendFailed(
                                            e.to_string(),
                                        ))
                                    });
                                let _ = response_tx.send(result);
                            }
                            SessionCommand::Resolve { request_id, result, response_tx } => {
                                let res = sender
                                    .respond_to_server_request(request_id, result)
                                    .map_err(|e| {
                                        RpcError::Transport(TransportError::SendFailed(
                                            e.to_string(),
                                        ))
                                    });
                                let _ = response_tx.send(res);
                            }
                            SessionCommand::Reject { request_id, error, response_tx } => {
                                let res = sender
                                    .fail_server_request(request_id, error)
                                    .map_err(|e| {
                                        RpcError::Transport(TransportError::SendFailed(
                                            e.to_string(),
                                        ))
                                    });
                                let _ = response_tx.send(res);
                            }
                            SessionCommand::Shutdown => {
                                break;
                            }
                        }
                    }
                    event = handle.next_event() => {
                        let Some(event) = event else { break; };
                        route_in_process_event(&evt_tx, event);
                    }
                }
            }
            debug!("in-process session worker exited");
        });

        let _ = health_tx.send(ConnectionHealth::Connected);
        info!("local server session connected: {}", config.display_name);

        Ok(Self {
            config,
            health_tx,
            health_rx,
            command_tx,
            event_tx,
            worker_handle,
        })
    }

    /// Connect to a remote Codex server via WebSocket.
    ///
    /// Uses the upstream `RemoteAppServerClient` which handles the
    /// initialize/initialized handshake, request routing, and event streaming.
    pub async fn connect_remote(config: ServerConfig) -> Result<Self, TransportError> {
        let (health_tx, health_rx) = watch::channel(ConnectionHealth::Connecting {
            attempt: 1,
            max_attempts: 5,
        });

        let url = if let Some(url) = config.websocket_url.clone() {
            url
        } else {
            let scheme = if config.tls { "wss" } else { "ws" };
            format!("{scheme}://{}:{}", config.host, config.port)
        };

        let args = RemoteAppServerConnectArgs {
            websocket_url: url.clone(),
            client_name: "Litter".to_string(),
            client_version: "1.0".to_string(),
            experimental_api: true,
            opt_out_notification_methods: Vec::new(),
            channel_capacity: 256,
        };

        let mut client = AppServerClient::Remote(
            RemoteAppServerClient::connect(args)
                .await
                .map_err(|e| TransportError::ConnectionFailed(e.to_string()))?,
        );

        let request_handle = client.request_handle();

        let (event_tx, _) = broadcast::channel::<ServerEvent>(256);
        let (command_tx, mut command_rx) = mpsc::channel::<SessionCommand>(256);

        let evt_tx = event_tx.clone();
        let health_tx_clone = health_tx.clone();

        let worker_handle = tokio::spawn(async move {
            loop {
                tokio::select! {
                    command = command_rx.recv() => {
                        let Some(command) = command else { break; };
                        match command {
                            SessionCommand::Request { request, response_tx } => {
                                let handle = request_handle.clone();
                                tokio::spawn(async move {
                                    let result = match handle.request(request).await {
                                        Ok(Ok(value)) => Ok(value),
                                        Ok(Err(error)) => Err(RpcError::Server {
                                            code: error.code,
                                            message: error.message,
                                        }),
                                        Err(e) => Err(RpcError::Transport(
                                            TransportError::SendFailed(e.to_string()),
                                        )),
                                    };
                                    let _ = response_tx.send(result);
                                });
                            }
                            SessionCommand::Notify { notification, response_tx } => {
                                let result = client
                                    .notify(notification)
                                    .await
                                    .map_err(|e| {
                                        RpcError::Transport(TransportError::SendFailed(
                                            e.to_string(),
                                        ))
                                    });
                                let _ = response_tx.send(result);
                            }
                            SessionCommand::Resolve { request_id, result, response_tx } => {
                                let res = client
                                    .resolve_server_request(request_id, result)
                                    .await
                                    .map_err(|e| {
                                        RpcError::Transport(TransportError::SendFailed(
                                            e.to_string(),
                                        ))
                                    });
                                let _ = response_tx.send(res);
                            }
                            SessionCommand::Reject { request_id, error, response_tx } => {
                                let res = client
                                    .reject_server_request(request_id, error)
                                    .await
                                    .map_err(|e| {
                                        RpcError::Transport(TransportError::SendFailed(
                                            e.to_string(),
                                        ))
                                    });
                                let _ = response_tx.send(res);
                            }
                            SessionCommand::Shutdown => {
                                let _ = client.shutdown().await;
                                break;
                            }
                        }
                    }
                    event = client.next_event() => {
                        let Some(event) = event else {
                            debug!("remote event stream ended");
                            break;
                        };
                        route_app_server_event(&evt_tx, &health_tx_clone, &event);
                    }
                }
            }
            debug!("remote session worker exited");
        });

        let _ = health_tx.send(ConnectionHealth::Connected);
        info!(
            "remote server session connected: {} ({})",
            config.display_name, url
        );

        Ok(Self {
            config,
            health_tx,
            health_rx,
            command_tx,
            event_tx,
            worker_handle,
        })
    }

    /// Get the server configuration.
    pub fn config(&self) -> &ServerConfig {
        &self.config
    }

    /// Get a watch receiver for health state changes.
    pub fn health(&self) -> watch::Receiver<ConnectionHealth> {
        self.health_rx.clone()
    }

    /// Send a typed `ClientRequest` and await the raw JSON response.
    pub async fn request_client(&self, request: ClientRequest) -> Result<JsonValue, RpcError> {
        let (response_tx, response_rx) = oneshot::channel();
        self.command_tx
            .send(SessionCommand::Request {
                request,
                response_tx,
            })
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?;

        response_rx
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?
    }

    /// Send a JSON-RPC request (constructed from method + params) and await the response.
    pub async fn request(&self, method: &str, params: JsonValue) -> Result<JsonValue, RpcError> {
        let request_id = RequestId::Integer(next_request_id());
        let request_value = serde_json::json!({
            "id": request_id,
            "method": method,
            "params": params,
        });
        let request: ClientRequest = serde_json::from_value(request_value)
            .map_err(|e| RpcError::Deserialization(format!("failed to build request: {e}")))?;
        self.request_client(request).await
    }

    /// Send a JSON-RPC notification (fire-and-forget).
    pub async fn notify(&self, method: &str, params: JsonValue) -> Result<(), RpcError> {
        let notif_value = serde_json::json!({
            "method": method,
            "params": params,
        });
        let notification: ClientNotification = serde_json::from_value(notif_value)
            .map_err(|e| RpcError::Deserialization(format!("failed to build notification: {e}")))?;

        let (response_tx, response_rx) = oneshot::channel();
        self.command_tx
            .send(SessionCommand::Notify {
                notification,
                response_tx,
            })
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?;

        response_rx
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?
    }

    /// Subscribe to typed server events (notifications, legacy notifications, requests).
    pub fn events(&self) -> broadcast::Receiver<ServerEvent> {
        self.event_tx.subscribe()
    }

    /// Respond to a server-initiated request.
    pub async fn respond(&self, id: JsonValue, result: JsonValue) -> Result<(), RpcError> {
        let request_id = json_value_to_request_id(&id)?;
        let (response_tx, response_rx) = oneshot::channel();
        self.command_tx
            .send(SessionCommand::Resolve {
                request_id,
                result,
                response_tx,
            })
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?;

        response_rx
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?
    }

    /// Reject a server-initiated request with a JSON-RPC error.
    pub async fn reject(&self, id: JsonValue, error: JSONRPCErrorError) -> Result<(), RpcError> {
        let request_id = json_value_to_request_id(&id)?;
        let (response_tx, response_rx) = oneshot::channel();
        self.command_tx
            .send(SessionCommand::Reject {
                request_id,
                error,
                response_tx,
            })
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?;

        response_rx
            .await
            .map_err(|_| RpcError::Transport(TransportError::Disconnected))?
    }

    /// Disconnect from the server, shutting down all background tasks.
    pub async fn disconnect(&self) {
        let _ = self.health_tx.send(ConnectionHealth::Disconnected);
        let _ = self.command_tx.send(SessionCommand::Shutdown).await;
        // Give the worker a moment to shut down gracefully.
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        self.worker_handle.abort();
        info!("server session disconnected: {}", self.config.display_name);
    }
}

// ---------------------------------------------------------------------------
// Event routing helpers
// ---------------------------------------------------------------------------

fn route_app_server_event(
    event_tx: &broadcast::Sender<ServerEvent>,
    health_tx: &watch::Sender<ConnectionHealth>,
    event: &AppServerEvent,
) {
    match event {
        AppServerEvent::ServerNotification(notification) => {
            let _ = event_tx.send(ServerEvent::Notification(notification.clone()));
        }
        AppServerEvent::LegacyNotification(notification) => {
            let method = notification.method.clone();
            let params = notification
                .params
                .clone()
                .and_then(|v| serde_json::from_value(v).ok())
                .unwrap_or(JsonValue::Null);
            let _ = event_tx.send(ServerEvent::LegacyNotification { method, params });
        }
        AppServerEvent::ServerRequest(request) => {
            let _ = event_tx.send(ServerEvent::Request(request.clone()));
        }
        AppServerEvent::Lagged { skipped } => {
            warn!("event: lagged, skipped {skipped} events");
        }
        AppServerEvent::Disconnected { message } => {
            warn!("event: disconnected: {message}");
            let _ = health_tx.send(ConnectionHealth::Disconnected);
        }
    }
}

fn route_in_process_event(
    event_tx: &broadcast::Sender<ServerEvent>,
    event: codex_app_server::in_process::InProcessServerEvent,
) {
    use codex_app_server::in_process::InProcessServerEvent;

    match event {
        InProcessServerEvent::ServerNotification(notification) => {
            let _ = event_tx.send(ServerEvent::Notification(notification));
        }
        InProcessServerEvent::LegacyNotification(notification) => {
            let method = notification.method.clone();
            let params = notification
                .params
                .clone()
                .and_then(|v| serde_json::from_value(v).ok())
                .unwrap_or(JsonValue::Null);
            let _ = event_tx.send(ServerEvent::LegacyNotification { method, params });
        }
        InProcessServerEvent::ServerRequest(request) => {
            let _ = event_tx.send(ServerEvent::Request(request));
        }
        InProcessServerEvent::Lagged { skipped } => {
            warn!("in-process event: lagged, skipped {skipped} events");
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn json_value_to_request_id(value: &JsonValue) -> Result<RequestId, RpcError> {
    match value {
        JsonValue::Number(n) => Ok(RequestId::Integer(n.as_i64().unwrap_or(0))),
        JsonValue::String(s) => Ok(RequestId::String(s.clone())),
        _ => Err(RpcError::Deserialization(
            "invalid request id type".to_string(),
        )),
    }
}

fn next_request_id() -> i64 {
    use std::sync::atomic::{AtomicI64, Ordering};
    static COUNTER: AtomicI64 = AtomicI64::new(1);
    COUNTER.fetch_add(1, Ordering::Relaxed)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn server_config_local() {
        let config = ServerConfig {
            server_id: "local-1".into(),
            display_name: "My Mac".into(),
            host: "127.0.0.1".into(),
            port: 0,
            websocket_url: None,
            is_local: true,
            tls: false,
        };
        assert!(config.is_local);
        assert_eq!(config.server_id, "local-1");
    }

    #[test]
    fn server_config_remote() {
        let config = ServerConfig {
            server_id: "remote-1".into(),
            display_name: "Cloud Server".into(),
            host: "codex.example.com".into(),
            port: 443,
            websocket_url: None,
            is_local: false,
            tls: true,
        };
        assert!(!config.is_local);
        assert!(config.tls);
        assert_eq!(config.port, 443);
    }

    #[test]
    fn connection_health_disconnected_eq() {
        assert_eq!(
            ConnectionHealth::Disconnected,
            ConnectionHealth::Disconnected
        );
    }

    #[test]
    fn connection_health_connecting_eq() {
        let a = ConnectionHealth::Connecting {
            attempt: 1,
            max_attempts: 5,
        };
        let b = ConnectionHealth::Connecting {
            attempt: 1,
            max_attempts: 5,
        };
        assert_eq!(a, b);
    }

    #[test]
    fn connection_health_connecting_ne_different_attempt() {
        let a = ConnectionHealth::Connecting {
            attempt: 1,
            max_attempts: 5,
        };
        let b = ConnectionHealth::Connecting {
            attempt: 2,
            max_attempts: 5,
        };
        assert_ne!(a, b);
    }

    #[test]
    fn connection_health_connected_eq() {
        assert_eq!(ConnectionHealth::Connected, ConnectionHealth::Connected);
    }

    #[test]
    fn connection_health_different_variants_ne() {
        assert_ne!(ConnectionHealth::Connected, ConnectionHealth::Disconnected);
        assert_ne!(
            ConnectionHealth::Connecting {
                attempt: 1,
                max_attempts: 5
            },
            ConnectionHealth::Connected,
        );
    }

    #[test]
    fn connection_health_unresponsive_same_instant() {
        let now = Instant::now();
        let a = ConnectionHealth::Unresponsive { since: now };
        let b = ConnectionHealth::Unresponsive { since: now };
        assert_eq!(a, b);
    }

    #[test]
    fn health_watch_initial_value() {
        let (tx, rx) = watch::channel(ConnectionHealth::Disconnected);
        assert_eq!(*rx.borrow(), ConnectionHealth::Disconnected);
        let _ = tx.send(ConnectionHealth::Connected);
        assert_eq!(*rx.borrow(), ConnectionHealth::Connected);
    }

    #[test]
    fn health_watch_multiple_transitions() {
        let (tx, rx) = watch::channel(ConnectionHealth::Disconnected);

        let _ = tx.send(ConnectionHealth::Connecting {
            attempt: 1,
            max_attempts: 3,
        });
        assert_eq!(
            *rx.borrow(),
            ConnectionHealth::Connecting {
                attempt: 1,
                max_attempts: 3
            }
        );

        let _ = tx.send(ConnectionHealth::Connected);
        assert_eq!(*rx.borrow(), ConnectionHealth::Connected);

        let _ = tx.send(ConnectionHealth::Disconnected);
        assert_eq!(*rx.borrow(), ConnectionHealth::Disconnected);
    }

    // -- Event bridge tests (using string-based bridge for backward compat) --

    fn spawn_string_event_bridge(
        mut event_rx: broadcast::Receiver<String>,
        notification_tx: broadcast::Sender<(String, JsonValue)>,
        server_request_tx: broadcast::Sender<(JsonValue, String, JsonValue)>,
    ) -> tokio::task::JoinHandle<()> {
        tokio::spawn(async move {
            loop {
                match event_rx.recv().await {
                    Ok(json_str) => {
                        let parsed: JsonValue = match serde_json::from_str(&json_str) {
                            Ok(v) => v,
                            Err(e) => {
                                warn!("event bridge: failed to parse event JSON: {e}");
                                continue;
                            }
                        };

                        let has_id = parsed.get("id").is_some();
                        let method = parsed
                            .get("method")
                            .and_then(|m| m.as_str())
                            .map(|s| s.to_string());
                        let params = parsed.get("params").cloned().unwrap_or(JsonValue::Null);

                        match (has_id, method) {
                            (true, Some(method)) => {
                                let id = parsed.get("id").cloned().unwrap_or(JsonValue::Null);
                                let _ = server_request_tx.send((id, method, params));
                            }
                            (false, Some(method)) => {
                                let _ = notification_tx.send((method, params));
                            }
                            (true, None) => {}
                            (false, None) => {}
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        })
    }

    #[tokio::test]
    async fn event_bridge_routes_notification() {
        let (event_tx, _) = broadcast::channel::<String>(16);
        let (notif_tx, mut notif_rx) = broadcast::channel::<(String, JsonValue)>(16);
        let (req_tx, _req_rx) = broadcast::channel::<(JsonValue, String, JsonValue)>(16);

        let event_rx = event_tx.subscribe();
        let _handle = spawn_string_event_bridge(event_rx, notif_tx, req_tx);

        let notif = json!({"method": "codex/event/turnComplete", "params": {"turn_id": "t1"}});
        event_tx.send(notif.to_string()).unwrap();

        let (method, params) =
            tokio::time::timeout(std::time::Duration::from_secs(2), notif_rx.recv())
                .await
                .expect("should receive within timeout")
                .expect("should receive notification");

        assert_eq!(method, "codex/event/turnComplete");
        assert_eq!(params, json!({"turn_id": "t1"}));
        _handle.abort();
    }

    #[tokio::test]
    async fn event_bridge_routes_server_request() {
        let (event_tx, _) = broadcast::channel::<String>(16);
        let (notif_tx, _notif_rx) = broadcast::channel::<(String, JsonValue)>(16);
        let (req_tx, mut req_rx) = broadcast::channel::<(JsonValue, String, JsonValue)>(16);

        let event_rx = event_tx.subscribe();
        let _handle = spawn_string_event_bridge(event_rx, notif_tx, req_tx);

        let req = json!({"id": "srv-42", "method": "tools/approve", "params": {"tool": "bash"}});
        event_tx.send(req.to_string()).unwrap();

        let (id, method, params) =
            tokio::time::timeout(std::time::Duration::from_secs(2), req_rx.recv())
                .await
                .expect("should receive within timeout")
                .expect("should receive server request");

        assert_eq!(id, json!("srv-42"));
        assert_eq!(method, "tools/approve");
        assert_eq!(params, json!({"tool": "bash"}));
        _handle.abort();
    }

    #[tokio::test]
    async fn event_bridge_skips_response_like_events() {
        let (event_tx, _) = broadcast::channel::<String>(16);
        let (notif_tx, mut notif_rx) = broadcast::channel::<(String, JsonValue)>(16);
        let (req_tx, mut req_rx) = broadcast::channel::<(JsonValue, String, JsonValue)>(16);

        let event_rx = event_tx.subscribe();
        let _handle = spawn_string_event_bridge(event_rx, notif_tx, req_tx);

        let resp = json!({"id": 1, "result": {"ok": true}});
        event_tx.send(resp.to_string()).unwrap();

        let notif = json!({"method": "ping"});
        event_tx.send(notif.to_string()).unwrap();

        let (method, _) = tokio::time::timeout(std::time::Duration::from_secs(2), notif_rx.recv())
            .await
            .expect("should receive within timeout")
            .expect("should receive notification");

        assert_eq!(method, "ping");
        assert!(req_rx.try_recv().is_err());
        _handle.abort();
    }

    #[tokio::test]
    async fn event_bridge_handles_malformed_json() {
        let (event_tx, _) = broadcast::channel::<String>(16);
        let (notif_tx, mut notif_rx) = broadcast::channel::<(String, JsonValue)>(16);
        let (req_tx, _req_rx) = broadcast::channel::<(JsonValue, String, JsonValue)>(16);

        let event_rx = event_tx.subscribe();
        let _handle = spawn_string_event_bridge(event_rx, notif_tx, req_tx);

        event_tx.send("not valid json".to_string()).unwrap();

        let notif = json!({"method": "test/ok"});
        event_tx.send(notif.to_string()).unwrap();

        let (method, _) = tokio::time::timeout(std::time::Duration::from_secs(2), notif_rx.recv())
            .await
            .expect("should receive within timeout")
            .expect("should receive notification");

        assert_eq!(method, "test/ok");
        _handle.abort();
    }

    #[tokio::test]
    async fn event_bridge_handles_missing_params() {
        let (event_tx, _) = broadcast::channel::<String>(16);
        let (notif_tx, mut notif_rx) = broadcast::channel::<(String, JsonValue)>(16);
        let (req_tx, _req_rx) = broadcast::channel::<(JsonValue, String, JsonValue)>(16);

        let event_rx = event_tx.subscribe();
        let _handle = spawn_string_event_bridge(event_rx, notif_tx, req_tx);

        let notif = json!({"method": "heartbeat"});
        event_tx.send(notif.to_string()).unwrap();

        let (method, params) =
            tokio::time::timeout(std::time::Duration::from_secs(2), notif_rx.recv())
                .await
                .expect("should receive within timeout")
                .expect("should receive notification");

        assert_eq!(method, "heartbeat");
        assert_eq!(params, JsonValue::Null);
        _handle.abort();
    }

    #[tokio::test]
    async fn event_bridge_stops_on_channel_close() {
        let (event_tx, _) = broadcast::channel::<String>(16);
        let (notif_tx, _notif_rx) = broadcast::channel::<(String, JsonValue)>(16);
        let (req_tx, _req_rx) = broadcast::channel::<(JsonValue, String, JsonValue)>(16);

        let event_rx = event_tx.subscribe();
        let handle = spawn_string_event_bridge(event_rx, notif_tx, req_tx);

        drop(event_tx);

        let result = tokio::time::timeout(std::time::Duration::from_secs(2), handle).await;
        assert!(
            result.is_ok(),
            "bridge task should complete when channel closes"
        );
    }

    #[test]
    fn ws_url_construction_no_tls() {
        let config = ServerConfig {
            server_id: "s1".into(),
            display_name: "Test".into(),
            host: "192.168.1.100".into(),
            port: 8080,
            websocket_url: None,
            is_local: false,
            tls: false,
        };
        let scheme = if config.tls { "wss" } else { "ws" };
        let url = format!("{scheme}://{}:{}", config.host, config.port);
        assert_eq!(url, "ws://192.168.1.100:8080");
    }

    #[test]
    fn ws_url_construction_with_tls() {
        let config = ServerConfig {
            server_id: "s2".into(),
            display_name: "Secure".into(),
            host: "codex.example.com".into(),
            port: 443,
            websocket_url: None,
            is_local: false,
            tls: true,
        };
        let scheme = if config.tls { "wss" } else { "ws" };
        let url = format!("{scheme}://{}:{}", config.host, config.port);
        assert_eq!(url, "wss://codex.example.com:443");
    }

    #[test]
    fn json_value_to_request_id_integer() {
        let id = json_value_to_request_id(&json!(42)).unwrap();
        assert!(matches!(id, RequestId::Integer(42)));
    }

    #[test]
    fn json_value_to_request_id_string() {
        let id = json_value_to_request_id(&json!("srv-1")).unwrap();
        assert!(matches!(id, RequestId::String(ref s) if s == "srv-1"));
    }

    #[test]
    fn json_value_to_request_id_invalid() {
        let result = json_value_to_request_id(&json!(true));
        assert!(result.is_err());
    }

    #[test]
    fn next_request_id_is_monotonic() {
        let a = next_request_id();
        let b = next_request_id();
        let c = next_request_id();
        assert!(b > a);
        assert!(c > b);
    }

    #[test]
    fn in_process_config_default() {
        let config = InProcessConfig::default();
        assert_eq!(config.channel_capacity, 256);
        assert!(config.codex_home.is_none());
        assert!(config.working_directory.is_none());
    }
}
