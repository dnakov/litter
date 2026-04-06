#[cfg(target_os = "android")]
use futures::FutureExt;
use std::collections::hash_map::DefaultHasher;
use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};
use std::future::Future;
use std::hash::{Hash, Hasher};
#[cfg(target_os = "android")]
use std::panic::AssertUnwindSafe;
use std::sync::{Arc, Mutex as StdMutex, RwLock};
use tokio::sync::{Mutex, broadcast, mpsc};
use tracing::{debug, info, trace, warn};
use url::Url;

use codex_utils_rustls_provider::ensure_rustls_crypto_provider;
use crate::discovery::{DiscoveredServer, DiscoveryConfig, DiscoveryService, MdnsSeed};
use crate::session::connection::InProcessConfig;
use crate::session::connection::{
    RemoteSessionResources, ServerConfig, ServerEvent, ServerSession, SshReconnectTransport,
};
use crate::session::events::{EventProcessor, UiEvent};
use crate::ssh::{SshBootstrapResult, SshClient, SshCredentials};
use crate::store::updates::ThreadStreamingDeltaKind;
use crate::store::{
    AppConnectionProgressSnapshot, AppQueuedFollowUpKind, AppQueuedFollowUpPreview, AppSnapshot,
    AppStoreReducer, AppStoreUpdateRecord, ServerHealthSnapshot, ThreadSnapshot,
};
use crate::transport::{RpcError, TransportError};
use crate::types::AppOperationStatus;
use crate::types::{
    AppCollaborationModePreset, AppModeKind, ApprovalDecisionValue, PendingApproval,
    PendingApprovalSeed, PendingApprovalWithSeed, PendingUserInputAnswer, PendingUserInputRequest,
    ThreadInfo, ThreadKey, ThreadSummaryStatus,
};
use codex_app_server_protocol as upstream;
use codex_ipc::{
    ClientStatus, CommandExecutionApprovalDecision, ConversationStreamApplyError,
    FileChangeApprovalDecision, ImmerOp, ImmerPatch, ImmerPathSegment, IpcClient, IpcClientConfig,
    IpcError, ProjectedApprovalKind, ProjectedApprovalRequest, ProjectedUserInputRequest,
    ReconnectPolicy, ReconnectingIpcClient, RequestError, StreamChange,
    ThreadFollowerCommandApprovalDecisionParams, ThreadFollowerFileApprovalDecisionParams,
    ThreadFollowerSetCollaborationModeParams, ThreadFollowerStartTurnParams,
    ThreadFollowerSubmitUserInputParams, ThreadStreamStateChangedParams, TypedBroadcast,
    apply_stream_change_to_conversation_state, project_conversation_request_state,
    project_conversation_state, project_conversation_turn, seed_conversation_state_from_thread,
};

/// Top-level entry point for platform code (iOS / Android).
///
/// Ties together server sessions, thread management, event processing,
/// discovery, auth, caching, and voice handoff into a single facade.
/// All methods are safe to call from any thread (`Send + Sync`).
pub struct MobileClient {
    pub(crate) sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    pub(crate) event_processor: Arc<EventProcessor>,
    pub app_store: Arc<AppStoreReducer>,
    pub(crate) discovery: RwLock<DiscoveryService>,
    oauth_callback_tunnels: Arc<Mutex<HashMap<String, OAuthCallbackTunnel>>>,
}

#[derive(Debug, Clone)]
struct OAuthCallbackTunnel {
    login_id: String,
    local_port: u16,
}

const USER_INPUT_NOTE_PREFIX: &str = "user_note: ";
const USER_INPUT_OTHER_OPTION_LABEL: &str = "None of the above";
const USER_INPUT_RECONCILE_DELAYS_MS: [u64; 3] = [150, 800, 2500];

fn ipc_command_error_clears_server_ipc_state(error: &IpcError) -> bool {
    matches!(
        error,
        IpcError::Transport(_)
            | IpcError::NotConnected
            | IpcError::Request(RequestError::NoClientFound | RequestError::ClientDisconnected)
    )
}

fn ipc_command_error_context(error: &IpcError) -> &'static str {
    if ipc_command_error_clears_server_ipc_state(error) {
        "IPC transport is no longer connected"
    } else {
        "IPC stream is still attached, but desktop follower commands are unavailable"
    }
}

fn server_supports_ipc(session: &ServerSession) -> bool {
    session.ssh_client().is_some() || session.has_ipc()
}

fn normalize_pending_user_input_answers(
    request: &PendingUserInputRequest,
    answers: &[PendingUserInputAnswer],
) -> Vec<PendingUserInputAnswer> {
    request
        .questions
        .iter()
        .map(|question| {
            let raw_answers = answers
                .iter()
                .find(|answer| answer.question_id == question.id)
                .map(|answer| answer.answers.as_slice())
                .unwrap_or(&[]);
            PendingUserInputAnswer {
                question_id: question.id.clone(),
                answers: normalize_pending_user_input_answer_entries(question, raw_answers),
            }
        })
        .collect()
}

fn ipc_pending_user_input_submission_id(request: &PendingUserInputRequest) -> &str {
    // Desktop thread-follower user-input replies resolve the pending app-server request,
    // not the turn id that originally emitted it.
    &request.id
}

fn normalize_pending_user_input_answer_entries(
    question: &crate::types::PendingUserInputQuestion,
    raw_answers: &[String],
) -> Vec<String> {
    let mut selected_options = Vec::new();
    let mut note_parts = Vec::new();

    for raw_answer in raw_answers {
        let trimmed = raw_answer.trim();
        if trimmed.is_empty() {
            continue;
        }

        if let Some(note) = trimmed.strip_prefix(USER_INPUT_NOTE_PREFIX) {
            let note = note.trim();
            if !note.is_empty() {
                note_parts.push(note.to_string());
            }
            continue;
        }

        if !question.options.is_empty()
            && (question
                .options
                .iter()
                .any(|option| option.label == trimmed)
                || trimmed == USER_INPUT_OTHER_OPTION_LABEL)
        {
            selected_options.push(trimmed.to_string());
        } else {
            note_parts.push(trimmed.to_string());
        }
    }

    if question.options.is_empty() {
        return if note_parts.is_empty() {
            Vec::new()
        } else {
            vec![format!("{USER_INPUT_NOTE_PREFIX}{}", note_parts.join("\n"))]
        };
    }

    if question.is_other_allowed && !note_parts.is_empty() && selected_options.is_empty() {
        selected_options.push(USER_INPUT_OTHER_OPTION_LABEL.to_string());
    }

    if note_parts.is_empty() {
        return selected_options;
    }

    let mut normalized = selected_options;
    normalized.push(format!("{USER_INPUT_NOTE_PREFIX}{}", note_parts.join("\n")));
    normalized
}

impl MobileClient {
    /// Create a new `MobileClient`.
    pub fn new() -> Self {
        crate::logging::install_ipc_wire_trace_logger();
        ensure_rustls_crypto_provider();
        let event_processor = Arc::new(EventProcessor::new());
        let app_store = Arc::new(AppStoreReducer::new());
        let sessions = Arc::new(RwLock::new(HashMap::new()));
        spawn_store_listener(
            Arc::clone(&app_store),
            Arc::clone(&sessions),
            event_processor.subscribe(),
        );
        Self {
            sessions,
            event_processor,
            app_store,
            discovery: RwLock::new(DiscoveryService::new(DiscoveryConfig::default())),
            oauth_callback_tunnels: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn sessions_write(
        &self,
    ) -> std::sync::RwLockWriteGuard<'_, HashMap<String, Arc<ServerSession>>> {
        match self.sessions.write() {
            Ok(guard) => guard,
            Err(error) => {
                warn!("MobileClient: recovering poisoned sessions write lock");
                error.into_inner()
            }
        }
    }

    fn sessions_read(&self) -> std::sync::RwLockReadGuard<'_, HashMap<String, Arc<ServerSession>>> {
        match self.sessions.read() {
            Ok(guard) => guard,
            Err(error) => {
                warn!("MobileClient: recovering poisoned sessions read lock");
                error.into_inner()
            }
        }
    }

    // ── Internal RPC helpers ──────────────────────────────────────────────

    pub(crate) async fn server_get_account(
        &self,
        server_id: &str,
        params: upstream::GetAccountParams,
    ) -> Result<upstream::GetAccountResponse, crate::RpcClientError> {
        use crate::{RpcClientError, next_request_id};
        self.request_typed_for_server(
            server_id,
            upstream::ClientRequest::GetAccount {
                request_id: upstream::RequestId::Integer(next_request_id()),
                params,
            },
        )
        .await
        .map_err(RpcClientError::Rpc)
    }

    pub(crate) async fn server_thread_fork(
        &self,
        server_id: &str,
        params: upstream::ThreadForkParams,
    ) -> Result<upstream::ThreadForkResponse, crate::RpcClientError> {
        use crate::{RpcClientError, next_request_id};
        self.request_typed_for_server(
            server_id,
            upstream::ClientRequest::ThreadFork {
                request_id: upstream::RequestId::Integer(next_request_id()),
                params,
            },
        )
        .await
        .map_err(RpcClientError::Rpc)
    }

    pub(crate) async fn server_thread_rollback(
        &self,
        server_id: &str,
        params: upstream::ThreadRollbackParams,
    ) -> Result<upstream::ThreadRollbackResponse, crate::RpcClientError> {
        use crate::{RpcClientError, next_request_id};
        self.request_typed_for_server(
            server_id,
            upstream::ClientRequest::ThreadRollback {
                request_id: upstream::RequestId::Integer(next_request_id()),
                params,
            },
        )
        .await
        .map_err(RpcClientError::Rpc)
    }

    pub(crate) async fn server_thread_list(
        &self,
        server_id: &str,
        params: upstream::ThreadListParams,
    ) -> Result<upstream::ThreadListResponse, crate::RpcClientError> {
        use crate::{RpcClientError, next_request_id};
        self.request_typed_for_server(
            server_id,
            upstream::ClientRequest::ThreadList {
                request_id: upstream::RequestId::Integer(next_request_id()),
                params,
            },
        )
        .await
        .map_err(RpcClientError::Rpc)
    }

    pub(crate) async fn server_collaboration_mode_list(
        &self,
        server_id: &str,
    ) -> Result<Vec<AppCollaborationModePreset>, crate::RpcClientError> {
        use crate::{RpcClientError, next_request_id};
        let response = self
            .request_typed_for_server::<upstream::CollaborationModeListResponse>(
                server_id,
                upstream::ClientRequest::CollaborationModeList {
                    request_id: upstream::RequestId::Integer(next_request_id()),
                    params: upstream::CollaborationModeListParams::default(),
                },
            )
            .await
            .map_err(RpcClientError::Rpc)?;

        Ok(response
            .data
            .into_iter()
            .filter_map(|mask| AppCollaborationModePreset::try_from(mask).ok())
            .collect())
    }

    fn discovery_write(&self) -> std::sync::RwLockWriteGuard<'_, DiscoveryService> {
        match self.discovery.write() {
            Ok(guard) => guard,
            Err(error) => {
                warn!("MobileClient: recovering poisoned discovery write lock");
                error.into_inner()
            }
        }
    }

    fn discovery_read(&self) -> std::sync::RwLockReadGuard<'_, DiscoveryService> {
        match self.discovery.read() {
            Ok(guard) => guard,
            Err(error) => {
                warn!("MobileClient: recovering poisoned discovery read lock");
                error.into_inner()
            }
        }
    }

    async fn clear_oauth_callback_tunnel(&self, server_id: &str) {
        let tunnel = {
            let mut tunnels = self.oauth_callback_tunnels.lock().await;
            tunnels.remove(server_id)
        };
        let session = self.sessions_read().get(server_id).cloned();
        if let Some(tunnel) = tunnel
            && let Some(session) = session
            && let Some(ssh_client) = session.ssh_client()
        {
            ssh_client.abort_forward_port(tunnel.local_port).await;
        }
    }

    async fn replace_oauth_callback_tunnel(
        &self,
        server_id: &str,
        login_id: &str,
        local_port: u16,
    ) {
        self.clear_oauth_callback_tunnel(server_id).await;
        let mut tunnels = self.oauth_callback_tunnels.lock().await;
        tunnels.insert(
            server_id.to_string(),
            OAuthCallbackTunnel {
                login_id: login_id.to_string(),
                local_port,
            },
        );
    }

    fn existing_active_session(&self, server_id: &str) -> Option<Arc<ServerSession>> {
        let session = self.sessions_read().get(server_id).cloned()?;
        let health_rx = session.health();
        match health_rx.borrow().clone() {
            crate::session::connection::ConnectionHealth::Disconnected => None,
            _ => Some(session),
        }
    }

    async fn replace_existing_session(&self, server_id: &str) {
        self.clear_oauth_callback_tunnel(server_id).await;
        let existing = self.sessions_write().remove(server_id);
        if let Some(session) = existing {
            info!("MobileClient: replacing existing server session {server_id}");
            session.disconnect().await;
        }
    }

    // ── Server Management ─────────────────────────────────────────────

    /// Connect to a local (in-process) Codex server.
    ///
    /// Returns the `server_id` from the config on success.
    pub async fn connect_local(
        &self,
        config: ServerConfig,
        in_process: InProcessConfig,
    ) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
        if self.existing_active_session(server_id.as_str()).is_some() {
            info!("MobileClient: reusing existing local server session {server_id}");
            return Ok(server_id);
        }
        self.replace_existing_session(server_id.as_str()).await;
        let session = Arc::new(ServerSession::connect_local(config, in_process).await?);
        self.app_store.upsert_server(
            session.config(),
            ServerHealthSnapshot::Connected,
            server_supports_ipc(&session),
        );

        self.spawn_event_reader(server_id.clone(), Arc::clone(&session));
        self.spawn_health_reader(server_id.clone(), session.health());

        self.sessions_write()
            .insert(server_id.clone(), Arc::clone(&session));
        self.spawn_post_connect_warmup(server_id.clone(), session);

        info!("MobileClient: connected local server {server_id}");
        Ok(server_id)
    }

    /// Connect to a remote Codex server via WebSocket.
    ///
    /// Returns the `server_id` from the config on success.
    pub async fn connect_remote(&self, config: ServerConfig) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
        if self.existing_active_session(server_id.as_str()).is_some() {
            info!("MobileClient: reusing existing remote server session {server_id}");
            return Ok(server_id);
        }
        self.replace_existing_session(server_id.as_str()).await;
        let session = Arc::new(ServerSession::connect_remote(config).await?);
        self.app_store.upsert_server(
            session.config(),
            ServerHealthSnapshot::Connected,
            server_supports_ipc(&session),
        );

        self.spawn_event_reader(server_id.clone(), Arc::clone(&session));
        self.spawn_health_reader(server_id.clone(), session.health());

        self.sessions_write()
            .insert(server_id.clone(), Arc::clone(&session));
        self.spawn_post_connect_warmup(server_id.clone(), session);

        info!("MobileClient: connected remote server {server_id}");
        Ok(server_id)
    }

    pub async fn connect_remote_over_ssh(
        &self,
        config: ServerConfig,
        ssh_credentials: SshCredentials,
        accept_unknown_host: bool,
        working_dir: Option<String>,
        ipc_socket_path_override: Option<String>,
    ) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
        info!(
            "MobileClient: connect_remote_over_ssh start server_id={} host={} ssh_port={} accept_unknown_host={} working_dir={}",
            server_id,
            ssh_credentials.host.as_str(),
            ssh_credentials.port,
            accept_unknown_host,
            working_dir.as_deref().unwrap_or("<none>")
        );
        self.app_store
            .upsert_server(&config, ServerHealthSnapshot::Connecting, true);
        self.app_store.update_server_connection_progress(
            server_id.as_str(),
            Some(AppConnectionProgressSnapshot::ssh_bootstrap()),
        );
        // SSH-backed sessions depend on a local tunnel and optional IPC bridge
        // that may be torn down while the app is backgrounded even if the
        // session health never observed a clean disconnect. Prefer replacing
        // any existing session so resume can rebuild the full SSH transport.
        self.replace_existing_session(server_id.as_str()).await;

        let ssh_client = Arc::new(
            SshClient::connect(
                ssh_credentials.clone(),
                make_accept_unknown_host_callback(accept_unknown_host),
            )
            .await
            .map_err(map_ssh_transport_error)?,
        );
        info!(
            "MobileClient: SSH transport established server_id={} host={} ssh_port={}",
            config.server_id,
            ssh_credentials.host.as_str(),
            ssh_credentials.port
        );

        let use_ipv6 = config.host.contains(':');
        let bootstrap = match ssh_client
            .bootstrap_codex_server(working_dir.as_deref(), use_ipv6)
            .await
        {
            Ok(result) => result,
            Err(error) => {
                warn!(
                    "remote ssh bootstrap failed server={} error={}",
                    config.server_id, error
                );
                warn!(
                    "MobileClient: remote ssh bootstrap failed server_id={} host={} error={}",
                    config.server_id,
                    ssh_credentials.host.as_str(),
                    error
                );
                ssh_client.disconnect().await;
                self.app_store
                    .update_server_health(server_id.as_str(), ServerHealthSnapshot::Disconnected);
                self.app_store
                    .update_server_connection_progress(server_id.as_str(), None);
                return Err(map_ssh_transport_error(error));
            }
        };
        info!(
            "MobileClient: remote ssh bootstrap succeeded server_id={} host={} remote_port={} local_tunnel_port={} pid={:?}",
            config.server_id,
            ssh_credentials.host.as_str(),
            bootstrap.server_port,
            bootstrap.tunnel_local_port,
            bootstrap.pid
        );

        let result = self
            .finish_connect_remote_over_ssh(
                config,
                ssh_credentials,
                accept_unknown_host,
                ssh_client,
                bootstrap,
                working_dir,
                ipc_socket_path_override,
            )
            .await;
        match &result {
            Ok(_) => {
                self.app_store
                    .update_server_connection_progress(server_id.as_str(), None);
            }
            Err(_) => {
                self.app_store
                    .update_server_health(server_id.as_str(), ServerHealthSnapshot::Disconnected);
                self.app_store
                    .update_server_connection_progress(server_id.as_str(), None);
            }
        }
        result
    }

    pub(crate) async fn finish_connect_remote_over_ssh(
        &self,
        mut config: ServerConfig,
        ssh_credentials: SshCredentials,
        _accept_unknown_host: bool,
        ssh_client: Arc<SshClient>,
        bootstrap: SshBootstrapResult,
        working_dir: Option<String>,
        ipc_socket_path_override: Option<String>,
    ) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
        trace!(
            "MobileClient: finish_connect_remote_over_ssh start server_id={} host={} bootstrap_remote_port={} bootstrap_local_port={} pid={:?} ipc_socket_path_override={}",
            server_id,
            ssh_credentials.host.as_str(),
            bootstrap.server_port,
            bootstrap.tunnel_local_port,
            bootstrap.pid,
            ipc_socket_path_override.as_deref().unwrap_or("<none>")
        );

        config.port = bootstrap.server_port;
        config.websocket_url = Some(format!("ws://127.0.0.1:{}", bootstrap.tunnel_local_port));
        config.is_local = false;
        config.tls = false;
        let ssh_pid = Arc::new(StdMutex::new(bootstrap.pid));
        let ssh_reconnect_transport = SshReconnectTransport {
            ssh_client: Arc::clone(&ssh_client),
            local_port: bootstrap.tunnel_local_port,
            remote_port: Arc::new(StdMutex::new(bootstrap.server_port)),
            prefer_ipv6: config.host.contains(':'),
            working_dir,
            ssh_pid: Some(Arc::clone(&ssh_pid)),
        };

        let ipc_enabled = ipc_socket_path_override
            .as_deref()
            .is_none_or(|path| !path.trim().is_empty());
        let ipc_bridge_pid = ipc_enabled.then(|| Arc::new(StdMutex::new(None)));
        let ipc_client = if ipc_enabled {
            let reconnect_ssh_client = Arc::clone(&ssh_client);
            let reconnect_server_id = config.server_id.clone();
            let reconnect_ipc_socket_path_override = ipc_socket_path_override.clone();
            let reconnect_bridge_pid = ipc_bridge_pid.as_ref().map(Arc::clone);
            Some(ReconnectingIpcClient::start_with_connector(
                None,
                move || {
                    let reconnect_ssh_client = Arc::clone(&reconnect_ssh_client);
                    let reconnect_server_id = reconnect_server_id.clone();
                    let reconnect_ipc_socket_path_override =
                        reconnect_ipc_socket_path_override.clone();
                    let reconnect_bridge_pid = reconnect_bridge_pid.as_ref().map(Arc::clone);
                    async move {
                        if let Some(bridge_pid_slot) = reconnect_bridge_pid.as_ref() {
                            let previous_pid = match bridge_pid_slot.lock() {
                                Ok(mut guard) => guard.take(),
                                Err(error) => {
                                    warn!("MobileClient: recovering poisoned ipc_bridge_pid lock");
                                    error.into_inner().take()
                                }
                            };
                            if let Some(pid) = previous_pid {
                                let _ = reconnect_ssh_client
                                    .exec(&format!("kill {pid} 2>/dev/null"))
                                    .await;
                            }
                        }

                        let (client, bridge_pid) = attach_ipc_client_for_remote_session(
                            &reconnect_ssh_client,
                            reconnect_server_id.as_str(),
                            reconnect_ipc_socket_path_override.as_deref(),
                        )
                        .await;

                        if let Some(bridge_pid_slot) = reconnect_bridge_pid.as_ref() {
                            match bridge_pid_slot.lock() {
                                Ok(mut guard) => *guard = bridge_pid,
                                Err(error) => {
                                    warn!("MobileClient: recovering poisoned ipc_bridge_pid lock");
                                    *error.into_inner() = bridge_pid;
                                }
                            }
                        }

                        client.ok_or(IpcError::NotConnected)
                    }
                },
                ipc_reconnect_policy(),
            ))
        } else {
            None
        };
        trace!(
            "MobileClient: finish_connect_remote_over_ssh IPC attach result server_id={} attached={}",
            server_id,
            ipc_client
                .as_ref()
                .is_some_and(ReconnectingIpcClient::is_connected)
        );

        let session = match ServerSession::connect_remote_with_resources(
            config,
            RemoteSessionResources {
                ssh_client: Some(Arc::clone(&ssh_client)),
                ssh_pid: Some(Arc::clone(&ssh_pid)),
                ipc_client,
                ipc_ssh_client: None,
                ipc_bridge_pid,
                ssh_reconnect_transport: Some(ssh_reconnect_transport),
            },
        )
        .await
        {
            Ok(session) => Arc::new(session),
            Err(error) => {
                warn!(
                    "remote ssh session connect failed server={} error={}",
                    server_id, error
                );
                warn!(
                    "MobileClient: remote ssh session connect failed server_id={} host={} error={}",
                    server_id,
                    ssh_credentials.host.as_str(),
                    error
                );
                ssh_client.disconnect().await;
                return Err(error);
            }
        };

        self.app_store.upsert_server(
            session.config(),
            ServerHealthSnapshot::Connected,
            server_supports_ipc(&session),
        );
        trace!(
            "MobileClient: finish_connect_remote_over_ssh session connected server_id={} websocket_url={}",
            server_id,
            session
                .config()
                .websocket_url
                .as_deref()
                .unwrap_or("<none>")
        );
        if session.has_ipc() {
            self.app_store
                .update_server_ipc_state(server_id.as_str(), true);
        }

        self.spawn_event_reader(server_id.clone(), Arc::clone(&session));
        self.spawn_health_reader(server_id.clone(), session.health());
        self.spawn_ipc_reader(server_id.clone(), Arc::clone(&session));
        self.spawn_ipc_connection_state_reader(server_id.clone(), Arc::clone(&session));

        self.sessions_write()
            .insert(server_id.clone(), Arc::clone(&session));
        self.spawn_post_connect_warmup(server_id.clone(), session);

        info!("MobileClient: connected remote SSH server {server_id}");
        Ok(server_id)
    }

    /// Disconnect a server by its ID.
    pub fn disconnect_server(&self, server_id: &str) {
        let session = self.sessions_write().remove(server_id);

        if let Some(session) = session {
            // Swift/Kotlin can call this from outside any Tokio runtime.
            self.app_store.remove_server(server_id);
            let inner = Arc::clone(&self.oauth_callback_tunnels);
            let server_id_owned = server_id.to_string();
            Self::spawn_detached(async move {
                inner.lock().await.remove(&server_id_owned);
                session.disconnect().await;
            });
            info!("MobileClient: disconnected server {server_id}");
        } else {
            warn!("MobileClient: disconnect_server called for unknown {server_id}");
        }
    }

    /// Return the configs of all currently connected servers.
    #[cfg(test)]
    #[allow(dead_code)]
    pub(crate) fn connected_servers(&self) -> Vec<ServerConfig> {
        self.sessions_read()
            .values()
            .map(|s| s.config().clone())
            .collect()
    }

    // ── Threads ───────────────────────────────────────────────────────

    /// List threads from a specific server.
    #[cfg(test)]
    #[allow(dead_code)]
    pub(crate) async fn list_threads(&self, server_id: &str) -> Result<Vec<ThreadInfo>, RpcError> {
        self.get_session(server_id)?;
        let response = self
            .server_thread_list(
                server_id,
                upstream::ThreadListParams {
                    limit: None,
                    cursor: None,
                    sort_key: None,
                    model_providers: None,
                    source_kinds: None,
                    archived: None,
                    cwd: None,
                    search_term: None,
                },
            )
            .await
            .map_err(map_rpc_client_error)?;
        let threads = response
            .data
            .into_iter()
            .filter_map(thread_info_from_upstream_thread)
            .collect::<Vec<_>>();
        self.app_store.sync_thread_list(server_id, &threads);
        Ok(threads)
    }

    pub async fn sync_server_account(&self, server_id: &str) -> Result<(), RpcError> {
        self.get_session(server_id)?;
        let response = self
            .server_get_account(
                server_id,
                upstream::GetAccountParams {
                    refresh_token: false,
                },
            )
            .await
            .map_err(map_rpc_client_error)?;
        self.apply_account_response(server_id, &response);
        Ok(())
    }

    fn spawn_post_connect_warmup(&self, server_id: String, session: Arc<ServerSession>) {
        let sessions = Arc::clone(&self.sessions);
        let app_store = Arc::clone(&self.app_store);
        Self::spawn_detached(async move {
            let account_future = refresh_account_from_app_server(
                Arc::clone(&session),
                Arc::clone(&app_store),
                Arc::clone(&sessions),
                server_id.as_str(),
            );
            let threads_future = refresh_thread_list_from_app_server_if_current(
                Arc::clone(&session),
                Arc::clone(&app_store),
                Arc::clone(&sessions),
                server_id.as_str(),
            );
            let (account_result, thread_result) = tokio::join!(account_future, threads_future);

            match account_result {
                Ok(()) => trace!(
                    "MobileClient: post-connect account sync completed server_id={}",
                    server_id
                ),
                Err(error) => warn!(
                    "MobileClient: failed to sync account for {}: {}",
                    server_id, error
                ),
            }

            match thread_result {
                Ok(()) => trace!(
                    "MobileClient: post-connect thread refresh completed server_id={}",
                    server_id
                ),
                Err(error) => warn!(
                    "MobileClient: failed to refresh thread list for {}: {}",
                    server_id, error
                ),
            }
        });
    }

    pub async fn start_remote_ssh_oauth_login(&self, server_id: &str) -> Result<String, RpcError> {
        let session = self.get_session(server_id)?;
        if session.config().is_local {
            return Err(RpcError::Transport(TransportError::ConnectionFailed(
                "remote SSH OAuth is only available for remote servers".to_string(),
            )));
        }
        let ssh_client = session.ssh_client().ok_or_else(|| {
            RpcError::Transport(TransportError::ConnectionFailed(
                "remote ChatGPT login requires an SSH-backed connection".to_string(),
            ))
        })?;

        let params = upstream::LoginAccountParams::Chatgpt;
        let response = self
            .request_typed_for_server::<upstream::LoginAccountResponse>(
                server_id,
                upstream::ClientRequest::LoginAccount {
                    request_id: upstream::RequestId::Integer(crate::next_request_id()),
                    params,
                },
            )
            .await
            .map_err(RpcError::Deserialization)?;
        self.reconcile_public_rpc(
            "account/login/start",
            server_id,
            Option::<&()>::None,
            &response,
        )
        .await?;

        let upstream::LoginAccountResponse::Chatgpt { login_id, auth_url } = response else {
            return Err(RpcError::Deserialization(
                "expected ChatGPT login response for remote SSH OAuth".to_string(),
            ));
        };

        let callback_port = remote_oauth_callback_port(&auth_url)?;
        self.clear_oauth_callback_tunnel(server_id).await;
        if let Err(error) = ssh_client
            .ensure_forward_port_to(callback_port, "127.0.0.1", callback_port)
            .await
        {
            let _ = self
                .request_typed_for_server::<upstream::CancelLoginAccountResponse>(
                    server_id,
                    upstream::ClientRequest::CancelLoginAccount {
                        request_id: upstream::RequestId::Integer(crate::next_request_id()),
                        params: upstream::CancelLoginAccountParams {
                            login_id: login_id.clone(),
                        },
                    },
                )
                .await;
            return Err(RpcError::Transport(TransportError::ConnectionFailed(
                format!(
                    "failed to open localhost callback tunnel on port {callback_port}: {error}"
                ),
            )));
        }
        self.replace_oauth_callback_tunnel(server_id, &login_id, callback_port)
            .await;
        Ok(auth_url)
    }

    pub async fn external_resume_thread(
        &self,
        server_id: &str,
        thread_id: &str,
        host_id: Option<String>,
    ) -> Result<(), RpcError> {
        let session = self.get_session(server_id)?;
        if host_id.is_some() {
            trace!(
                "IPC out: external_resume_thread ignoring explicit host_id for server={} thread={}",
                server_id, thread_id
            );
        }
        if session.ipc_client().is_some() {
            debug!(
                "IPC out: external_resume_thread uses targeted thread/read fallback for server={} thread={} because desktop does not expose a raw resume RPC to socket clients",
                server_id, thread_id
            );
        }
        let response = read_thread_response_from_app_server(Arc::clone(&session), thread_id)
            .await
            .inspect_err(|error| self.reconcile_transport_error(server_id, error))?;
        upsert_thread_snapshot_from_app_server_read_response(&self.app_store, server_id, response)?;
        Ok(())
    }

    pub async fn start_turn(
        &self,
        server_id: &str,
        params: upstream::TurnStartParams,
    ) -> Result<(), RpcError> {
        let session = self.get_session(server_id)?;
        let mut params = params;
        let thread_key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: params.thread_id.clone(),
        };
        self.app_store
            .dismiss_plan_implementation_prompt(&thread_key);
        let thread_snapshot = self.snapshot_thread(&thread_key).ok();
        if let Some(thread) = thread_snapshot.as_ref()
            && thread.collaboration_mode == AppModeKind::Plan
            && params.collaboration_mode.is_none()
        {
            params.collaboration_mode = collaboration_mode_from_thread(
                thread,
                AppModeKind::Plan,
                params.model.clone(),
                params.effort,
            );
        }
        let has_active_session = thread_snapshot.as_ref().is_some_and(|thread| {
            thread.active_turn_id.is_some() || thread.info.status == ThreadSummaryStatus::Active
        });
        let direct_params = params.clone();
        let queued_draft = has_active_session
            .then(|| {
                queued_follow_up_draft_from_inputs(&params.input, AppQueuedFollowUpKind::Message)
            })
            .flatten();
        if let Some(draft) = queued_draft.clone() {
            self.app_store
                .enqueue_thread_follow_up_draft(&thread_key, draft.clone());

            if let Some(ipc_client) = session.ipc_client() {
                let mut next_drafts = thread_snapshot
                    .as_ref()
                    .map(|thread| thread.queued_follow_up_drafts.clone())
                    .unwrap_or_default();
                next_drafts.push(draft);
                let thread_id = params.thread_id.clone();
                info!(
                    "IPC out: set_queued_follow_ups_state server={} thread={}",
                    server_id, thread_id
                );
                let ipc_result = ipc_client
                    .set_queued_follow_ups_state(
                        codex_ipc::ThreadFollowerSetQueuedFollowUpsStateParams {
                            conversation_id: thread_id.clone(),
                            state: queued_follow_up_state_json_from_drafts(&next_drafts),
                        },
                    )
                    .await;
                match ipc_result {
                    Ok(_) => {
                        debug!(
                            "IPC out: set_queued_follow_ups_state ok server={} thread={}",
                            server_id, thread_id
                        );
                        return Ok(());
                    }
                    Err(error) => {
                        warn!(
                            "MobileClient: IPC queued follow-up update failed for {} thread {}: {} ({})",
                            server_id,
                            thread_id,
                            error,
                            ipc_command_error_context(&error)
                        );
                        if ipc_command_error_clears_server_ipc_state(&error) {
                            self.app_store.update_server_ipc_state(server_id, false);
                        }
                    }
                }
            } else {
                return Ok(());
            }
        }

        if queued_draft.is_none()
            && let Some(ipc_client) = session.ipc_client()
        {
            let thread_id = params.thread_id.clone();
            info!(
                "IPC out: start_turn server={} thread={}",
                server_id, thread_id
            );
            let ipc_result = ipc_client
                .start_turn(ThreadFollowerStartTurnParams {
                    conversation_id: thread_id.clone(),
                    turn_start_params: params.clone(),
                })
                .await;
            match ipc_result {
                Ok(_) => {
                    debug!(
                        "IPC out: start_turn ok server={} thread={}",
                        server_id, thread_id
                    );
                    // When the desktop follower accepts the turn, the IPC stream is
                    // the authoritative source for the new in-progress state. An
                    // immediate thread/read can race behind the follower update and
                    // briefly regress the store back to older "not loaded"/completed
                    // thread state before stream deltas catch up.
                    return Ok(());
                }
                Err(error) => {
                    warn!(
                        "MobileClient: IPC follower start turn failed for {} thread {}: {} ({})",
                        server_id,
                        thread_id,
                        error,
                        ipc_command_error_context(&error)
                    );
                    if ipc_command_error_clears_server_ipc_state(&error) {
                        self.app_store.update_server_ipc_state(server_id, false);
                    }
                }
            }
        }

        let response = self
            .request_typed_for_server::<upstream::TurnStartResponse>(
                server_id,
                upstream::ClientRequest::TurnStart {
                    request_id: upstream::RequestId::Integer(crate::next_request_id()),
                    params: direct_params,
                },
            )
            .await
            .map_err(|error| {
                if let Some(draft) = queued_draft.as_ref() {
                    self.app_store
                        .remove_thread_follow_up_draft(&thread_key, &draft.preview.id);
                }
                RpcError::Deserialization(error)
            })?;
        let _ = response;
        Ok(())
    }

    pub async fn steer_queued_follow_up(
        &self,
        key: &ThreadKey,
        preview_id: &str,
    ) -> Result<(), RpcError> {
        let session = self.get_session(&key.server_id)?;
        let thread = self.snapshot_thread(key)?;
        let Some(draft) = thread
            .queued_follow_up_drafts
            .iter()
            .find(|draft| draft.preview.id == preview_id)
            .cloned()
        else {
            return Err(RpcError::Deserialization(format!(
                "queued follow-up not found: {preview_id}"
            )));
        };

        if let Some(ipc_client) = session.ipc_client() {
            let next_drafts = thread
                .queued_follow_up_drafts
                .into_iter()
                .map(|mut queued| {
                    if queued.preview.id == preview_id {
                        queued.preview.kind = AppQueuedFollowUpKind::PendingSteer;
                    }
                    queued
                })
                .collect::<Vec<_>>();
            match ipc_client
                .set_queued_follow_ups_state(
                    codex_ipc::ThreadFollowerSetQueuedFollowUpsStateParams {
                        conversation_id: key.thread_id.clone(),
                        state: queued_follow_up_state_json_from_drafts(&next_drafts),
                    },
                )
                .await
            {
                Ok(_) => {
                    self.app_store.set_thread_follow_up_drafts(key, next_drafts);
                    return Ok(());
                }
                Err(error) => {
                    warn!(
                        "MobileClient: IPC steer queued follow-up failed for {} thread {}: {} ({})",
                        key.server_id,
                        key.thread_id,
                        error,
                        ipc_command_error_context(&error)
                    );
                    if ipc_command_error_clears_server_ipc_state(&error) {
                        self.app_store
                            .update_server_ipc_state(&key.server_id, false);
                    } else {
                        return Err(RpcError::Deserialization(format!(
                            "IPC steer queued follow-up: {error}"
                        )));
                    }
                }
            }
        }

        let active_turn_id = thread.active_turn_id.ok_or_else(|| {
            RpcError::Deserialization("no active turn available to steer".to_string())
        })?;

        self.request_typed_for_server::<upstream::TurnSteerResponse>(
            &key.server_id,
            upstream::ClientRequest::TurnSteer {
                request_id: upstream::RequestId::Integer(crate::next_request_id()),
                params: upstream::TurnSteerParams {
                    thread_id: key.thread_id.clone(),
                    input: draft.inputs,
                    expected_turn_id: active_turn_id,
                },
            },
        )
        .await
        .map_err(RpcError::Deserialization)?;
        self.app_store
            .remove_thread_follow_up_draft(key, preview_id);
        Ok(())
    }

    pub async fn delete_queued_follow_up(
        &self,
        key: &ThreadKey,
        preview_id: &str,
    ) -> Result<(), RpcError> {
        let session = self.get_session(&key.server_id)?;
        let thread = self.snapshot_thread(key)?;
        let next_drafts = thread
            .queued_follow_up_drafts
            .into_iter()
            .filter(|draft| draft.preview.id != preview_id)
            .collect::<Vec<_>>();

        if let Some(ipc_client) = session.ipc_client() {
            match ipc_client
                .set_queued_follow_ups_state(
                    codex_ipc::ThreadFollowerSetQueuedFollowUpsStateParams {
                        conversation_id: key.thread_id.clone(),
                        state: queued_follow_up_state_json_from_drafts(&next_drafts),
                    },
                )
                .await
            {
                Ok(_) => {}
                Err(error) => {
                    warn!(
                        "MobileClient: IPC delete queued follow-up failed for {} thread {}: {} ({})",
                        key.server_id,
                        key.thread_id,
                        error,
                        ipc_command_error_context(&error)
                    );
                    if ipc_command_error_clears_server_ipc_state(&error) {
                        self.app_store
                            .update_server_ipc_state(&key.server_id, false);
                    } else {
                        return Err(RpcError::Deserialization(format!(
                            "IPC delete queued follow-up: {error}"
                        )));
                    }
                }
            }
        }

        self.app_store.set_thread_follow_up_drafts(key, next_drafts);
        Ok(())
    }

    /// Roll back the current thread to a selected user turn and return the
    /// message text that should be restored into the composer for editing.
    pub async fn edit_message(
        &self,
        key: &ThreadKey,
        selected_turn_index: u32,
    ) -> Result<String, RpcError> {
        self.get_session(&key.server_id)?;
        let current = self.snapshot_thread(key)?;
        ensure_thread_is_editable(&current)?;
        let rollback_depth = rollback_depth_for_turn(&current, selected_turn_index as usize)?;
        let prefill_text = user_boundary_text_for_turn(&current, selected_turn_index as usize)?;

        if rollback_depth > 0 {
            let response = self
                .server_thread_rollback(
                    &key.server_id,
                    upstream::ThreadRollbackParams {
                        thread_id: key.thread_id.clone(),
                        num_turns: rollback_depth,
                    },
                )
                .await
                .map_err(|e| RpcError::Deserialization(e.to_string()))?;
            let mut snapshot = thread_snapshot_from_upstream_thread_with_overrides(
                &key.server_id,
                response.thread,
                current.model.clone(),
                current.reasoning_effort.clone(),
                current.effective_approval_policy.clone(),
                current.effective_sandbox_policy.clone(),
            )
            .map_err(RpcError::Deserialization)?;
            copy_thread_runtime_fields(&current, &mut snapshot);
            self.app_store.upsert_thread_snapshot(snapshot);
        }

        self.set_active_thread(Some(key.clone()));
        Ok(prefill_text)
    }

    /// Fork a thread from a selected user message boundary.
    pub async fn fork_thread_from_message(
        &self,
        key: &ThreadKey,
        selected_turn_index: u32,
        cwd: Option<String>,
        model: Option<String>,
        approval_policy: Option<crate::types::AppAskForApproval>,
        sandbox: Option<crate::types::AppSandboxMode>,
        developer_instructions: Option<String>,
        persist_extended_history: bool,
    ) -> Result<ThreadKey, RpcError> {
        self.get_session(&key.server_id)?;
        let source = self.snapshot_thread(key)?;
        ensure_thread_is_editable(&source)?;
        let rollback_depth = rollback_depth_for_turn(&source, selected_turn_index as usize)?;

        let response = self
            .server_thread_fork(
                &key.server_id,
                crate::types::AppForkThreadRequest {
                    thread_id: key.thread_id.clone(),
                    model,
                    cwd,
                    approval_policy,
                    sandbox,
                    developer_instructions,
                    persist_extended_history,
                }
                .try_into()
                .map_err(|e: crate::RpcClientError| RpcError::Deserialization(e.to_string()))?,
            )
            .await
            .map_err(|e| RpcError::Deserialization(e.to_string()))?;

        let fork_model = Some(response.model);
        let fork_reasoning = response
            .reasoning_effort
            .map(|value| reasoning_effort_string(value.into()));
        let mut snapshot = thread_snapshot_from_upstream_thread_with_overrides(
            &key.server_id,
            response.thread,
            fork_model.clone(),
            fork_reasoning.clone(),
            Some(response.approval_policy.into()),
            Some(response.sandbox.into()),
        )
        .map_err(RpcError::Deserialization)?;
        let next_key = snapshot.key.clone();

        if rollback_depth > 0 {
            let rollback_response = self
                .server_thread_rollback(
                    &key.server_id,
                    upstream::ThreadRollbackParams {
                        thread_id: next_key.thread_id.clone(),
                        num_turns: rollback_depth,
                    },
                )
                .await
                .map_err(|e| RpcError::Deserialization(e.to_string()))?;
            snapshot = thread_snapshot_from_upstream_thread_with_overrides(
                &key.server_id,
                rollback_response.thread,
                fork_model,
                fork_reasoning,
                snapshot.effective_approval_policy.clone(),
                snapshot.effective_sandbox_policy.clone(),
            )
            .map_err(RpcError::Deserialization)?;
        }

        self.app_store.upsert_thread_snapshot(snapshot);
        self.set_active_thread(Some(next_key.clone()));
        Ok(next_key)
    }

    pub async fn respond_to_approval(
        &self,
        request_id: &str,
        decision: ApprovalDecisionValue,
    ) -> Result<(), RpcError> {
        let approval = self.pending_approval(request_id)?;
        let approval_seed = self
            .app_store
            .pending_approval_seed(&approval.server_id, &approval.id);
        let session = self.get_session(&approval.server_id)?;
        if let Some(ipc_client) = session.ipc_client()
            && let Some(thread_id) = approval.thread_id.clone()
        {
            match send_ipc_approval_response(&ipc_client, &approval, &thread_id, decision.clone())
                .await
            {
                Ok(true) => {
                    debug!(
                        "MobileClient: approval response sent over IPC for server={} request_id={}",
                        approval.server_id, request_id
                    );
                    self.app_store.resolve_approval(request_id);
                    return Ok(());
                }
                Ok(false) => {}
                Err(error) => {
                    warn!(
                        "MobileClient: IPC approval response failed for server={} request_id={}: {} ({})",
                        approval.server_id,
                        request_id,
                        error,
                        ipc_command_error_context(&error)
                    );
                    if ipc_command_error_clears_server_ipc_state(&error) {
                        self.app_store
                            .update_server_ipc_state(&approval.server_id, false);
                    }
                }
            }
        }
        let response_json = approval_response_json(&approval, approval_seed.as_ref(), decision)?;
        let response_request_id =
            server_request_id_json(approval_request_id(&approval, approval_seed.as_ref()));
        session.respond(response_request_id, response_json).await?;
        debug!(
            "MobileClient: approval response sent for server={} request_id={}",
            approval.server_id, request_id
        );
        self.app_store.resolve_approval(request_id);
        Ok(())
    }

    pub async fn respond_to_user_input(
        &self,
        request_id: &str,
        answers: Vec<PendingUserInputAnswer>,
    ) -> Result<(), RpcError> {
        let request = self.pending_user_input(request_id)?;
        let normalized_answers = normalize_pending_user_input_answers(&request, &answers);
        let answered_inputs = normalized_answers.clone();
        let session = self.get_session(&request.server_id)?;
        if let Some(ipc_client) = session.ipc_client() {
            let submission_id = ipc_pending_user_input_submission_id(&request).to_string();
            match send_ipc_user_input_response(
                &ipc_client,
                &request.thread_id,
                &submission_id,
                normalized_answers.clone(),
            )
            .await
            {
                Ok(true) => {
                    debug!(
                        "MobileClient: user input response sent over IPC for server={} request_id={} submission_id={}",
                        request.server_id, request_id, submission_id
                    );
                    self.app_store
                        .resolve_pending_user_input_with_response(request_id, answered_inputs);
                    self.spawn_post_user_input_reconcile(
                        request.server_id.clone(),
                        request.thread_id.clone(),
                        Arc::clone(&session),
                    );
                    return Ok(());
                }
                Ok(false) => {}
                Err(error) => {
                    warn!(
                        "MobileClient: IPC user input response failed for server={} request_id={}: {} ({})",
                        request.server_id,
                        request_id,
                        error,
                        ipc_command_error_context(&error)
                    );
                    if ipc_command_error_clears_server_ipc_state(&error) {
                        self.app_store
                            .update_server_ipc_state(&request.server_id, false);
                    }
                }
            }
        }
        let response = upstream::ToolRequestUserInputResponse {
            answers: normalized_answers
                .into_iter()
                .map(|answer| {
                    (
                        answer.question_id,
                        upstream::ToolRequestUserInputAnswer {
                            answers: answer.answers,
                        },
                    )
                })
                .collect::<HashMap<_, _>>(),
        };
        let response_json = serde_json::to_value(response).map_err(|e| {
            RpcError::Deserialization(format!("serialize user input response: {e}"))
        })?;
        session
            .respond(serde_json::Value::String(request.id.clone()), response_json)
            .await?;
        debug!(
            "MobileClient: user input response sent for server={} request_id={}",
            request.server_id, request_id
        );
        self.app_store
            .resolve_pending_user_input_with_response(request_id, answered_inputs);
        self.spawn_post_user_input_reconcile(
            request.server_id.clone(),
            request.thread_id.clone(),
            Arc::clone(&session),
        );
        Ok(())
    }

    fn spawn_post_user_input_reconcile(
        &self,
        server_id: String,
        thread_id: String,
        session: Arc<ServerSession>,
    ) {
        let app_store = Arc::clone(&self.app_store);
        Self::spawn_detached(async move {
            for delay_ms in USER_INPUT_RECONCILE_DELAYS_MS {
                tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
                match read_thread_response_from_app_server(Arc::clone(&session), &thread_id).await {
                    Ok(response) => {
                        if let Err(error) = upsert_thread_snapshot_from_app_server_read_response(
                            &app_store, &server_id, response,
                        ) {
                            warn!(
                                "MobileClient: failed to reconcile thread after user input for server={} thread={}: {}",
                                server_id, thread_id, error
                            );
                            continue;
                        }
                        let key = ThreadKey {
                            server_id: server_id.clone(),
                            thread_id: thread_id.clone(),
                        };
                        let should_keep_polling = app_store
                            .snapshot()
                            .threads
                            .get(&key)
                            .is_some_and(|thread| thread.active_turn_id.is_some());
                        if !should_keep_polling {
                            break;
                        }
                    }
                    Err(error) => {
                        warn!(
                            "MobileClient: failed to refresh thread after user input for server={} thread={}: {}",
                            server_id, thread_id, error
                        );
                    }
                }
            }
        });
    }

    pub fn snapshot(&self) -> AppSnapshot {
        self.app_store.snapshot()
    }

    pub fn subscribe_updates(&self) -> broadcast::Receiver<AppStoreUpdateRecord> {
        self.app_store.subscribe()
    }

    pub fn app_snapshot(&self) -> AppSnapshot {
        self.snapshot()
    }

    pub fn subscribe_app_updates(&self) -> broadcast::Receiver<AppStoreUpdateRecord> {
        self.subscribe_updates()
    }

    pub fn set_active_thread(&self, key: Option<ThreadKey>) {
        self.app_store.set_active_thread(key);
    }

    pub async fn set_thread_collaboration_mode(
        &self,
        key: &ThreadKey,
        mode: AppModeKind,
    ) -> Result<(), RpcError> {
        let session = self.get_session(&key.server_id)?;
        let thread = self.snapshot_thread(key)?;
        self.app_store.set_thread_collaboration_mode(key, mode);

        let Some(ipc_client) = session.ipc_client() else {
            return Ok(());
        };
        let Some(collaboration_mode) = collaboration_mode_from_thread(&thread, mode, None, None)
        else {
            return Ok(());
        };

        info!(
            "IPC out: set_collaboration_mode server={} thread={}",
            key.server_id, key.thread_id
        );
        let ipc_result = ipc_client
            .set_collaboration_mode(ThreadFollowerSetCollaborationModeParams {
                conversation_id: key.thread_id.clone(),
                collaboration_mode,
            })
            .await;
        match ipc_result {
            Ok(_) => {
                debug!(
                    "IPC out: set_collaboration_mode ok server={} thread={}",
                    key.server_id, key.thread_id
                );
            }
            Err(error) => {
                warn!(
                    "MobileClient: IPC collaboration mode sync failed for {} thread {}: {} ({})",
                    key.server_id,
                    key.thread_id,
                    error,
                    ipc_command_error_context(&error)
                );
                if ipc_command_error_clears_server_ipc_state(&error) {
                    self.app_store
                        .update_server_ipc_state(&key.server_id, false);
                }
            }
        }
        Ok(())
    }

    pub fn dismiss_plan_implementation_prompt(&self, key: &ThreadKey) {
        self.app_store.dismiss_plan_implementation_prompt(key);
    }

    pub async fn implement_plan(&self, key: &ThreadKey) -> Result<(), RpcError> {
        self.app_store.dismiss_plan_implementation_prompt(key);
        self.app_store
            .set_thread_collaboration_mode(key, AppModeKind::Default);
        self.start_turn(
            &key.server_id,
            upstream::TurnStartParams {
                thread_id: key.thread_id.clone(),
                input: vec![upstream::UserInput::Text {
                    text: "Implement the plan.".to_string(),
                    text_elements: Vec::new(),
                }],
                cwd: None,
                approval_policy: None,
                approvals_reviewer: None,
                sandbox_policy: None,
                model: None,
                service_tier: None,
                effort: None,
                summary: None,
                personality: None,
                output_schema: None,
                collaboration_mode: None,
            },
        )
        .await
    }

    pub fn set_voice_handoff_thread(&self, key: Option<ThreadKey>) {
        self.app_store.set_voice_handoff_thread(key);
    }

    pub async fn scan_servers_with_mdns_context(
        &self,
        mdns_results: Vec<MdnsSeed>,
        local_ipv4: Option<String>,
    ) -> Vec<DiscoveredServer> {
        let discovery = self.discovery_write();
        discovery
            .scan_once_with_context(&mdns_results, local_ipv4.as_deref())
            .await
    }

    pub fn subscribe_scan_servers_with_mdns_context(
        &self,
        mdns_results: Vec<MdnsSeed>,
        local_ipv4: Option<String>,
    ) -> broadcast::Receiver<crate::discovery::ProgressiveDiscoveryUpdate> {
        let (tx, rx) = broadcast::channel(32);
        let discovery = self.discovery_read().clone_for_one_shot();

        Self::spawn_detached(async move {
            let _ = discovery
                .scan_once_progressive_with_context(&mdns_results, local_ipv4.as_deref(), &tx)
                .await;
        });

        rx
    }

    fn spawn_event_reader(&self, server_id: String, session: Arc<ServerSession>) {
        let mut events = session.events();
        let processor = Arc::clone(&self.event_processor);
        let oauth_callback_tunnels = Arc::clone(&self.oauth_callback_tunnels);
        let oauth_session = Arc::clone(&session);
        let sessions = Arc::clone(&self.sessions);
        let app_store = Arc::clone(&self.app_store);
        Self::spawn_detached(async move {
            loop {
                match events.recv().await {
                    Ok(ServerEvent::Notification(notification)) => {
                        if let upstream::ServerNotification::AccountLoginCompleted(payload) =
                            &notification
                        {
                            let maybe_tunnel = {
                                let mut tunnels = oauth_callback_tunnels.lock().await;
                                match payload.login_id.as_deref() {
                                    Some(login_id)
                                        if tunnels
                                            .get(&server_id)
                                            .map(|existing| existing.login_id.as_str())
                                            == Some(login_id) =>
                                    {
                                        tunnels.remove(&server_id)
                                    }
                                    _ => None,
                                }
                            };
                            if let Some(tunnel) = maybe_tunnel
                                && let Some(ssh_client) = oauth_session.ssh_client()
                            {
                                ssh_client.abort_forward_port(tunnel.local_port).await;
                            }
                        }
                        debug!(
                            "event reader server_id={} notification={:?}",
                            server_id, notification
                        );
                        processor.process_notification(&server_id, &notification);
                    }
                    Ok(ServerEvent::LegacyNotification { method, params }) => {
                        debug!(
                            "event reader server_id={} legacy_method={} params={}",
                            server_id, method, params
                        );
                        processor.process_legacy_notification(&server_id, &method, &params);
                    }
                    Ok(ServerEvent::Request(request)) => {
                        debug!("event reader server_id={} request={:?}", server_id, request);
                        let dynamic_tool_request = match &request {
                            upstream::ServerRequest::DynamicToolCall { request_id, params } => {
                                Some((request_id.clone(), params.clone()))
                            }
                            _ => None,
                        };
                        processor.process_server_request(&server_id, &request);
                        if let Some((request_id, params)) = dynamic_tool_request {
                            let server_id = server_id.clone();
                            let session = Arc::clone(&oauth_session);
                            let sessions = Arc::clone(&sessions);
                            let app_store = Arc::clone(&app_store);
                            MobileClient::spawn_detached(async move {
                                if let Err(error) = handle_dynamic_tool_call_request(
                                    session, sessions, app_store, request_id, params,
                                )
                                .await
                                {
                                    warn!(
                                        "MobileClient: failed to handle dynamic tool call on {}: {}",
                                        server_id, error
                                    );
                                }
                            });
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        info!("event stream closed for {server_id}");
                        break;
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        warn!(
                            "event reader lagged server_id={} skipped={}",
                            server_id, skipped
                        );
                    }
                }
            }
        });
    }

    fn spawn_health_reader(
        &self,
        server_id: String,
        mut health_rx: tokio::sync::watch::Receiver<crate::session::connection::ConnectionHealth>,
    ) {
        let processor = Arc::clone(&self.event_processor);
        Self::spawn_detached(async move {
            processor.emit_connection_state(&server_id, "connecting");
            loop {
                let health = health_rx.borrow().clone();
                let health_wire = match health {
                    crate::session::connection::ConnectionHealth::Disconnected => "disconnected",
                    crate::session::connection::ConnectionHealth::Connecting { .. } => "connecting",
                    crate::session::connection::ConnectionHealth::Connected => "connected",
                    crate::session::connection::ConnectionHealth::Unresponsive { .. } => {
                        "unresponsive"
                    }
                };
                processor.emit_connection_state(&server_id, health_wire);

                if health_rx.changed().await.is_err() {
                    break;
                }
            }
        });
    }

    fn spawn_ipc_connection_state_reader(&self, server_id: String, session: Arc<ServerSession>) {
        let Some(mut ipc_state_rx) = session.ipc_connection_state() else {
            return;
        };
        let app_store = Arc::clone(&self.app_store);
        Self::spawn_detached(async move {
            loop {
                let has_ipc = *ipc_state_rx.borrow();
                app_store.update_server_ipc_state(&server_id, has_ipc);
                if ipc_state_rx.changed().await.is_err() {
                    break;
                }
            }
        });
    }

    fn spawn_ipc_reader(&self, server_id: String, session: Arc<ServerSession>) {
        let Some(mut broadcasts) = session.ipc_broadcasts() else {
            return;
        };
        let app_store = Arc::clone(&self.app_store);
        let loop_server_id = server_id.clone();
        Self::spawn_detached(async move {
            let mut stream_cache: HashMap<String, serde_json::Value> = HashMap::new();
            let mut pending_thread_events: HashMap<
                String,
                VecDeque<ThreadStreamStateChangedParams>,
            > = HashMap::new();
            let mut recovering_threads: HashSet<String> = HashSet::new();
            let (recovery_tx, mut recovery_rx) =
                mpsc::unbounded_channel::<PendingIpcStreamRecovery>();
            loop {
                tokio::select! {
                    maybe_recovery = recovery_rx.recv() => {
                        let Some(recovery) = maybe_recovery else {
                            continue;
                        };
                        match recovery {
                            PendingIpcStreamRecovery::Recovered {
                                thread_id,
                                conversation_state,
                            } => {
                                let queued_events =
                                    pending_thread_events.get(&thread_id).map_or(0, VecDeque::len);
                                debug!(
                                    "IPC: async cache recovery completed server={} thread={} queued_events={}",
                                    loop_server_id, thread_id, queued_events
                                );
                                recovering_threads.remove(&thread_id);
                                stream_cache.insert(thread_id.clone(), conversation_state);
                                drain_pending_ipc_thread_events(
                                    &thread_id,
                                    &mut stream_cache,
                                    &mut pending_thread_events,
                                    &mut recovering_threads,
                                    Arc::clone(&session),
                                    Arc::clone(&app_store),
                                    &loop_server_id,
                                    &recovery_tx,
                                );
                            }
                            PendingIpcStreamRecovery::Failed { thread_id, error } => {
                                recovering_threads.remove(&thread_id);
                                pending_thread_events.remove(&thread_id);
                                warn!(
                                    "IPC: async cache recovery failed for thread {}: {}",
                                    thread_id, error
                                );
                            }
                        }
                    }
                    broadcast = broadcasts.recv() => match broadcast {
                        Ok(TypedBroadcast::ThreadStreamStateChanged(params)) => {
                            let change_type = match &params.change {
                                StreamChange::Snapshot { .. } => "snapshot",
                                StreamChange::Patches { .. } => "patches",
                            };
                            debug!(
                                "IPC in: ThreadStreamStateChanged server={} thread={} protocol_version={} change={}",
                                loop_server_id, params.conversation_id, params.version, change_type
                            );
                            handle_ipc_thread_stream_event(
                                &mut stream_cache,
                                &mut pending_thread_events,
                                &mut recovering_threads,
                                Arc::clone(&session),
                                Arc::clone(&app_store),
                                &loop_server_id,
                                params,
                                &recovery_tx,
                            );
                        }
                        Ok(TypedBroadcast::ThreadArchived(ref params)) => {
                            stream_cache.remove(&params.conversation_id);
                            pending_thread_events.remove(&params.conversation_id);
                            recovering_threads.remove(&params.conversation_id);
                            debug!(
                                "IPC in: ThreadArchived server={} thread={}",
                                loop_server_id, params.conversation_id
                            );
                            if let Err(error) = refresh_thread_list_from_app_server(
                                Arc::clone(&session),
                                Arc::clone(&app_store),
                                &loop_server_id,
                            )
                            .await
                            {
                                warn!(
                                    "MobileClient: failed to refresh IPC thread list on {}: {}",
                                    loop_server_id, error
                                );
                            }
                        }
                        Ok(TypedBroadcast::ThreadUnarchived(_))
                        | Ok(TypedBroadcast::QueryCacheInvalidate(_)) => {
                            debug!(
                                "IPC in: thread list change broadcast server={}",
                                loop_server_id
                            );
                            if let Err(error) = refresh_thread_list_from_app_server(
                                Arc::clone(&session),
                                Arc::clone(&app_store),
                                &loop_server_id,
                            )
                            .await
                            {
                                warn!(
                                    "MobileClient: failed to refresh IPC thread list on {}: {}",
                                    loop_server_id, error
                                );
                            }
                        }
                        Ok(TypedBroadcast::ThreadQueuedFollowupsChanged(params)) => {
                            let drafts = queued_follow_up_drafts_from_message_values(&params.messages);
                            debug!(
                                "IPC in: ThreadQueuedFollowupsChanged server={} thread={} previews={}",
                                loop_server_id,
                                params.conversation_id,
                                drafts.len()
                            );
                            if let Err(error) = refresh_thread_list_from_app_server(
                                Arc::clone(&session),
                                Arc::clone(&app_store),
                                &loop_server_id,
                            )
                            .await
                            {
                                warn!(
                                    "MobileClient: failed to refresh IPC thread list on {}: {}",
                                    loop_server_id, error
                                );
                            }
                            app_store.set_thread_follow_up_drafts(
                                &ThreadKey {
                                    server_id: loop_server_id.clone(),
                                    thread_id: params.conversation_id,
                                },
                                drafts,
                            );
                        }
                        Ok(TypedBroadcast::ClientStatusChanged(params)) => {
                            debug!(
                                "IPC in: ClientStatusChanged server={} client_type={} status={:?}",
                                loop_server_id, params.client_type, params.status
                            );
                            if params.client_type != "mobile" {
                                match params.status {
                                    ClientStatus::Connected => {
                                        app_store.update_server_ipc_state(&loop_server_id, true);
                                    }
                                    ClientStatus::Disconnected => {
                                        app_store.update_server_ipc_state(&loop_server_id, false);
                                    }
                                }
                            }
                        }
                        Ok(TypedBroadcast::Unknown { method, .. }) => {
                            debug!(
                                "MobileClient: ignoring unknown IPC broadcast for {} method={}",
                                loop_server_id, method
                            );
                        }
                        Err(broadcast::error::RecvError::Closed) => {
                            info!("IPC in: broadcast stream closed server={}", loop_server_id);
                            app_store.update_server_ipc_state(&loop_server_id, false);
                            break;
                        }
                        Err(broadcast::error::RecvError::Lagged(skipped)) => {
                            warn!("MobileClient: lagged {skipped} IPC events for {loop_server_id}");
                            stream_cache.clear();
                            pending_thread_events.clear();
                        }
                    }
                }
            }
        });
    }

    fn mark_server_transport_disconnected(&self, server_id: &str) {
        self.app_store
            .update_server_health(server_id, ServerHealthSnapshot::Disconnected);
        self.app_store.update_server_ipc_state(server_id, false);
    }

    fn reconcile_transport_error(&self, server_id: &str, error: &RpcError) {
        if matches!(error, RpcError::Transport(_)) {
            self.mark_server_transport_disconnected(server_id);
        }
    }

    pub(crate) fn get_session(&self, server_id: &str) -> Result<Arc<ServerSession>, RpcError> {
        self.sessions_read().get(server_id).cloned().ok_or_else(|| {
            self.mark_server_transport_disconnected(server_id);
            RpcError::Transport(TransportError::Disconnected)
        })
    }

    /// Send a raw `ClientRequest` and return the JSON response value.
    /// Used by tooling (e.g. fixture export) that needs raw upstream data.
    pub async fn request_raw_for_server(
        &self,
        server_id: &str,
        request: upstream::ClientRequest,
    ) -> Result<serde_json::Value, String> {
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        session.request_client(request).await.map_err(|error| {
            self.reconcile_transport_error(server_id, &error);
            error.to_string()
        })
    }

    /// Return the configs of all currently connected servers (public for tooling).
    pub fn connected_server_configs(&self) -> Vec<ServerConfig> {
        self.sessions_read()
            .values()
            .map(|s| s.config().clone())
            .collect()
    }

    pub(crate) fn snapshot_thread(&self, key: &ThreadKey) -> Result<ThreadSnapshot, RpcError> {
        self.app_store
            .snapshot()
            .threads
            .get(key)
            .cloned()
            .ok_or_else(|| RpcError::Deserialization(format!("unknown thread {}", key.thread_id)))
    }

    pub async fn request_typed_for_server<R>(
        &self,
        server_id: &str,
        request: upstream::ClientRequest,
    ) -> Result<R, String>
    where
        R: serde::de::DeserializeOwned,
    {
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        let value = session.request_client(request).await.map_err(|error| {
            self.reconcile_transport_error(server_id, &error);
            error.to_string()
        })?;
        serde_json::from_value(value.clone()).map_err(|e| {
            warn!("deserialize typed RPC response: {e}\nraw payload: {value}");
            format!("deserialize typed RPC response: {e}")
        })
    }

    fn pending_approval(&self, request_id: &str) -> Result<PendingApproval, RpcError> {
        self.app_store
            .snapshot()
            .pending_approvals
            .into_iter()
            .find(|approval| approval.id == request_id)
            .ok_or_else(|| {
                RpcError::Deserialization(format!("unknown approval request {request_id}"))
            })
    }

    fn pending_user_input(&self, request_id: &str) -> Result<PendingUserInputRequest, RpcError> {
        self.app_store
            .snapshot()
            .pending_user_inputs
            .into_iter()
            .find(|request| request.id == request_id)
            .ok_or_else(|| {
                RpcError::Deserialization(format!("unknown user input request {request_id}"))
            })
    }

    pub(crate) fn spawn_detached<F>(future: F)
    where
        F: Future<Output = ()> + Send + 'static,
    {
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(future);
        } else {
            std::thread::spawn(move || {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .expect("create detached runtime");
                runtime.block_on(future);
            });
        }
    }
}

fn make_accept_unknown_host_callback(
    accept_unknown_host: bool,
) -> Box<
    dyn Fn(&str) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send>> + Send + Sync,
> {
    Box::new(move |_fingerprint| Box::pin(async move { accept_unknown_host }))
}

fn shell_quote_remote(value: &str) -> String {
    if value.is_empty() {
        return "''".to_string();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn ipc_reconnect_policy() -> ReconnectPolicy {
    ReconnectPolicy {
        initial_delay: std::time::Duration::ZERO,
        ..ReconnectPolicy::default()
    }
}

async fn resolve_remote_ipc_socket_path_for_session(
    ssh_client: &Arc<SshClient>,
    server_id: &str,
    ipc_socket_path_override: Option<&str>,
) -> Option<String> {
    match ssh_client
        .remote_ipc_socket_if_present(ipc_socket_path_override)
        .await
    {
        Ok(Some(socket_path)) => {
            info!(
                "IPC socket detected server={} path={}",
                server_id, socket_path
            );
            Some(socket_path)
        }
        Ok(None) => None,
        Err(error) => {
            warn!(
                "MobileClient: failed to probe IPC socket for {}: {}",
                server_id, error
            );
            None
        }
    }
}

async fn attach_ipc_client_via_ssh(
    ssh_client: &Arc<SshClient>,
    server_id: &str,
    socket_path: &str,
) -> Option<IpcClient> {
    let ipc_config = IpcClientConfig {
        socket_path: std::path::PathBuf::from(socket_path),
        client_type: "mobile".to_string(),
        ..IpcClientConfig::default()
    };
    match ssh_client.open_streamlocal(socket_path).await {
        Ok(stream) => match IpcClient::connect_with_stream(&ipc_config, stream).await {
            Ok(client) => {
                info!(
                    "IPC attached server={} transport=direct-streamlocal path={}",
                    server_id, socket_path
                );
                Some(client)
            }
            Err(error) => {
                warn!(
                    "MobileClient: failed to attach IPC for {} at {}: {}",
                    server_id, socket_path, error
                );
                None
            }
        },
        Err(error) => {
            warn!(
                "MobileClient: failed to open IPC streamlocal for {} at {}: {}",
                server_id, socket_path, error
            );
            None
        }
    }
}

async fn attach_ipc_client_via_tcp_bridge(
    ssh_client: &Arc<SshClient>,
    server_id: &str,
    socket_path: &str,
) -> Option<(IpcClient, Option<u32>)> {
    let mut selected_port = None;
    for port in 39400..39420 {
        let check = format!(
            r#"if command -v lsof >/dev/null 2>&1; then
  lsof -nP -iTCP:{port} -sTCP:LISTEN -t 2>/dev/null | head -n 1
elif command -v ss >/dev/null 2>&1; then
  ss -ltn "sport = :{port}" 2>/dev/null | tail -n +2 | head -n 1
elif command -v netstat >/dev/null 2>&1; then
  netstat -ltn 2>/dev/null | awk '{{print $4}}' | grep -E '[:\.]{port}$' | head -n 1
fi"#
        );
        match ssh_client.exec(&check).await {
            Ok(result) if result.stdout.trim().is_empty() => {
                selected_port = Some(port);
                break;
            }
            Ok(_) => {}
            Err(error) => {
                warn!(
                    "MobileClient: failed to probe Android IPC TCP bridge port {} on {}: {}",
                    port, server_id, error
                );
            }
        }
    }

    let remote_port = match selected_port {
        Some(port) => port,
        None => {
            warn!(
                "MobileClient: no free Android IPC TCP bridge port found for {}",
                server_id
            );
            return None;
        }
    };

    let bridge_script = format!(
        r#"python3 -c 'import socket,threading,sys
sock_path = sys.argv[1]
port = int(sys.argv[2])
listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", port))
listener.listen(5)
def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        try:
            src.close()
        except OSError:
            pass
def handle(client):
    try:
        upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        upstream.connect(sock_path)
    except OSError:
        client.close()
        return
    threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pump, args=(upstream, client), daemon=True).start()
while True:
    client, _ = listener.accept()
    threading.Thread(target=handle, args=(client,), daemon=True).start()' {} {} </dev/null >/tmp/codex-mobile-ipc-bridge-{}.log 2>&1 & echo $!"#,
        shell_quote_remote(&socket_path),
        remote_port,
        remote_port
    );

    let launch = match ssh_client.exec(&bridge_script).await {
        Ok(result) => result,
        Err(error) => {
            warn!(
                "MobileClient: failed to launch Android IPC TCP bridge for {}: {}",
                server_id, error
            );
            return None;
        }
    };
    let bridge_pid = launch.stdout.trim().parse::<u32>().ok();

    tokio::time::sleep(std::time::Duration::from_millis(250)).await;

    let local_port = match ssh_client
        .forward_port_to(0, "127.0.0.1", remote_port)
        .await
    {
        Ok(port) => port,
        Err(error) => {
            warn!(
                "MobileClient: failed to forward Android IPC TCP bridge for {}: {}",
                server_id, error
            );
            if let Some(pid) = bridge_pid {
                let _ = ssh_client.exec(&format!("kill {pid} 2>/dev/null")).await;
            }
            return None;
        }
    };

    let ipc_config = IpcClientConfig {
        socket_path: std::path::PathBuf::from(&socket_path),
        client_type: "mobile".to_string(),
        ..IpcClientConfig::default()
    };
    match tokio::net::TcpStream::connect(("127.0.0.1", local_port)).await {
        Ok(stream) => {
            if let Err(error) = stream.set_nodelay(true) {
                warn!(
                    "MobileClient: failed to disable Nagle on IPC TCP bridge for {}: {}",
                    server_id, error
                );
            }
            match IpcClient::connect_with_stream(&ipc_config, stream).await {
                Ok(client) => Some((client, bridge_pid)),
                Err(error) => {
                    warn!(
                        "MobileClient: failed to attach Android IPC TCP bridge for {}: {}",
                        server_id, error
                    );
                    if let Some(pid) = bridge_pid {
                        let _ = ssh_client.exec(&format!("kill {pid} 2>/dev/null")).await;
                    }
                    None
                }
            }
        }
        Err(error) => {
            warn!(
                "MobileClient: failed to connect local Android IPC TCP bridge for {}: {}",
                server_id, error
            );
            if let Some(pid) = bridge_pid {
                let _ = ssh_client.exec(&format!("kill {pid} 2>/dev/null")).await;
            }
            None
        }
    }
}

async fn attach_ipc_client_for_remote_session(
    ssh_client: &Arc<SshClient>,
    server_id: &str,
    ipc_socket_path_override: Option<&str>,
) -> (Option<IpcClient>, Option<u32>) {
    let Some(socket_path) =
        resolve_remote_ipc_socket_path_for_session(ssh_client, server_id, ipc_socket_path_override)
            .await
    else {
        return (None, None);
    };

    if let Some(client) = attach_ipc_client_via_ssh(ssh_client, server_id, &socket_path).await {
        return (Some(client), None);
    }

    if let Some((client, bridge_pid)) =
        attach_ipc_client_via_tcp_bridge(ssh_client, server_id, &socket_path).await
    {
        info!(
            "IPC attached server={} transport=tcp-bridge bridge_pid={:?}",
            server_id, bridge_pid
        );
        return (Some(client), bridge_pid);
    }

    (None, None)
}

impl Default for MobileClient {
    fn default() -> Self {
        Self::new()
    }
}

fn spawn_store_listener(
    app_store: Arc<AppStoreReducer>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    mut rx: broadcast::Receiver<UiEvent>,
) {
    MobileClient::spawn_detached(async move {
        loop {
            match rx.recv().await {
                Ok(event) => {
                    app_store.apply_ui_event(&event);
                    if let UiEvent::TurnCompleted { key, .. } = &event {
                        maybe_send_next_local_queued_follow_up(
                            Arc::clone(&app_store),
                            Arc::clone(&sessions),
                            key.clone(),
                        )
                        .await;
                    }
                }
                Err(broadcast::error::RecvError::Closed) => break,
                Err(broadcast::error::RecvError::Lagged(skipped)) => {
                    warn!("MobileClient: lagged {skipped} UI events");
                }
            }
        }
    });
}

async fn maybe_send_next_local_queued_follow_up(
    app_store: Arc<AppStoreReducer>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    key: ThreadKey,
) {
    let snapshot = app_store.snapshot();
    let server_has_ipc = snapshot
        .servers
        .get(&key.server_id)
        .map(|server| server.has_ipc)
        .unwrap_or(false);
    let Some(thread) = snapshot.threads.get(&key).cloned() else {
        return;
    };
    if thread.active_turn_id.is_some() || thread.queued_follow_up_drafts.is_empty() {
        return;
    }

    let session = match sessions.read() {
        Ok(guard) => guard.get(&key.server_id).cloned(),
        Err(error) => {
            warn!("MobileClient: recovering poisoned sessions read lock");
            error.into_inner().get(&key.server_id).cloned()
        }
    };
    let Some(session) = session else {
        return;
    };
    if session.ipc_client().is_some() && server_has_ipc {
        return;
    }

    let next = thread.queued_follow_up_drafts.first().cloned();
    let Some(draft) = next else {
        return;
    };
    let response = session.request(
        "turn/start",
        serde_json::json!({
            "threadId": key.thread_id,
            "input": draft.inputs,
        }),
    );
    if let Err(error) = response.await {
        warn!(
            "MobileClient: failed to autosend queued follow-up for {} thread {}: {}",
            key.server_id, key.thread_id, error
        );
    }
}

#[derive(Clone)]
struct DynamicToolSessionTarget {
    server_id: String,
    session: Arc<ServerSession>,
    config: ServerConfig,
}

async fn handle_dynamic_tool_call_request(
    session: Arc<ServerSession>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    app_store: Arc<AppStoreReducer>,
    request_id: upstream::RequestId,
    params: upstream::DynamicToolCallParams,
) -> Result<(), RpcError> {
    let response = match execute_dynamic_tool_call(sessions, Arc::clone(&app_store), &params).await
    {
        Ok(text) => upstream::DynamicToolCallResponse {
            content_items: vec![upstream::DynamicToolCallOutputContentItem::InputText { text }],
            success: true,
        },
        Err(message) => upstream::DynamicToolCallResponse {
            content_items: vec![upstream::DynamicToolCallOutputContentItem::InputText {
                text: message,
            }],
            success: false,
        },
    };

    let request_id = match request_id {
        upstream::RequestId::Integer(value) => serde_json::Value::Number(value.into()),
        upstream::RequestId::String(value) => serde_json::Value::String(value),
    };
    let result = serde_json::to_value(response).map_err(|error| {
        RpcError::Deserialization(format!("serialize dynamic tool response: {error}"))
    })?;
    session.respond(request_id, result).await
}

async fn execute_dynamic_tool_call(
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    app_store: Arc<AppStoreReducer>,
    params: &upstream::DynamicToolCallParams,
) -> Result<String, String> {
    let targets = snapshot_dynamic_tool_sessions(&sessions);

    match params.tool.as_str() {
        "list_servers" => Ok(list_servers_tool_output(&targets)),
        "list_sessions" => list_sessions_tool_output(&targets, app_store, &params.arguments).await,
        "visualize_read_me" => {
            crate::widget_guidelines::handle_visualize_read_me(&params.arguments)
        }
        "show_widget" => crate::widget_guidelines::handle_show_widget(&params.arguments),
        tool => Err(format!("Unknown dynamic tool: {tool}")),
    }
}

fn snapshot_dynamic_tool_sessions(
    sessions: &Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
) -> Vec<DynamicToolSessionTarget> {
    let guard = match sessions.read() {
        Ok(guard) => guard,
        Err(error) => {
            warn!("MobileClient: recovering poisoned sessions read lock");
            error.into_inner()
        }
    };

    let mut targets = guard
        .iter()
        .map(|(server_id, session)| DynamicToolSessionTarget {
            server_id: server_id.clone(),
            session: Arc::clone(session),
            config: session.config().clone(),
        })
        .collect::<Vec<_>>();
    targets.sort_by(|lhs, rhs| dynamic_tool_server_name(lhs).cmp(&dynamic_tool_server_name(rhs)));
    targets
}

fn dynamic_tool_server_name(target: &DynamicToolSessionTarget) -> String {
    if target.config.is_local {
        "local".to_string()
    } else {
        target.config.display_name.clone()
    }
}

fn dynamic_tool_matches_server(target: &DynamicToolSessionTarget, requested_server: &str) -> bool {
    let requested = requested_server.trim();
    if requested.is_empty() {
        return false;
    }
    target.server_id.eq_ignore_ascii_case(requested)
        || target.config.display_name.eq_ignore_ascii_case(requested)
        || target.config.host.eq_ignore_ascii_case(requested)
        || (target.config.is_local && requested.eq_ignore_ascii_case("local"))
}

fn dynamic_tool_sessions_for_request(
    targets: &[DynamicToolSessionTarget],
    requested_server: Option<&str>,
    allow_all_if_missing: bool,
) -> Result<Vec<DynamicToolSessionTarget>, String> {
    match requested_server
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(requested_server) => {
            let matches = targets
                .iter()
                .filter(|target| dynamic_tool_matches_server(target, requested_server))
                .cloned()
                .collect::<Vec<_>>();
            if matches.is_empty() {
                Err(format!("Server '{requested_server}' is not connected."))
            } else {
                Ok(matches)
            }
        }
        None if allow_all_if_missing => Ok(targets.to_vec()),
        None => Err("A server name or ID is required.".to_string()),
    }
}

fn dynamic_tool_string(arguments: &serde_json::Value, keys: &[&str]) -> Option<String> {
    let object = arguments.as_object()?;
    keys.iter().find_map(|key| {
        object
            .get(*key)
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
    })
}

fn dynamic_tool_u32(arguments: &serde_json::Value, keys: &[&str]) -> Option<u32> {
    let object = arguments.as_object()?;
    keys.iter().find_map(|key| match object.get(*key) {
        Some(serde_json::Value::Number(value)) => {
            value.as_u64().and_then(|n| u32::try_from(n).ok())
        }
        Some(serde_json::Value::String(value)) => value.trim().parse::<u32>().ok(),
        _ => None,
    })
}

fn truncate_dynamic_tool_text(text: &str, max_bytes: usize) -> String {
    if text.len() <= max_bytes {
        return text.to_string();
    }
    let mut end = max_bytes;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    let mut truncated = text[..end].trim_end().to_string();
    truncated.push_str("...");
    truncated
}

fn serialize_dynamic_tool_payload(payload: serde_json::Value, max_bytes: usize) -> String {
    let text = serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string());
    truncate_dynamic_tool_text(&text, max_bytes)
}

fn list_servers_tool_output(targets: &[DynamicToolSessionTarget]) -> String {
    let items = targets
        .iter()
        .map(|target| {
            serde_json::json!({
                "id": target.server_id,
                "name": dynamic_tool_server_name(target),
                "hostname": truncate_dynamic_tool_text(&target.config.host, 200),
                "isConnected": true,
                "isLocal": target.config.is_local,
            })
        })
        .collect::<Vec<_>>();

    let summary = match items.len() {
        0 => "No connected servers found.".to_string(),
        1 => {
            let name = items[0]
                .get("name")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("the server");
            format!("Found 1 connected server: {name}.")
        }
        count => {
            let names = items
                .iter()
                .take(3)
                .filter_map(|item| item.get("name").and_then(serde_json::Value::as_str))
                .collect::<Vec<_>>();
            let listed = names.join(", ");
            let extra = count.saturating_sub(names.len());
            if extra > 0 {
                format!("Found {count} connected servers: {listed}, and {extra} more.")
            } else {
                format!("Found {count} connected servers: {listed}.")
            }
        }
    };

    serialize_dynamic_tool_payload(
        serde_json::json!({
            "type": "servers",
            "summary": summary,
            "items": items,
        }),
        24_000,
    )
}

async fn list_sessions_tool_output(
    targets: &[DynamicToolSessionTarget],
    app_store: Arc<AppStoreReducer>,
    arguments: &serde_json::Value,
) -> Result<String, String> {
    let limit = dynamic_tool_u32(arguments, &["limit"])
        .unwrap_or(20)
        .clamp(1, 40);
    let requested_server = dynamic_tool_string(arguments, &["server_id", "server"]);
    let targets = dynamic_tool_sessions_for_request(targets, requested_server.as_deref(), true)?;

    let mut items = Vec::new();
    let mut errors = Vec::new();

    for target in targets {
        let response = dynamic_tool_request_typed::<upstream::ThreadListResponse, _>(
            &target.session,
            "thread/list",
            &upstream::ThreadListParams {
                cursor: None,
                limit: Some(limit),
                sort_key: None,
                model_providers: None,
                source_kinds: None,
                archived: None,
                cwd: None,
                search_term: None,
            },
        )
        .await;

        match response {
            Ok(response) => {
                let threads = response
                    .data
                    .into_iter()
                    .filter_map(thread_info_from_upstream_thread)
                    .collect::<Vec<_>>();
                app_store.sync_thread_list(&target.server_id, &threads);
                items.extend(threads.into_iter().map(|thread| {
                    serde_json::json!({
                        "id": thread.id,
                        "preview": thread.preview.map(|value| truncate_dynamic_tool_text(&value, 280)),
                        "modelProvider": thread.model_provider,
                        "updatedAt": thread.updated_at,
                        "cwd": thread.cwd.map(|value| truncate_dynamic_tool_text(&value, 240)),
                        "serverId": target.server_id,
                        "serverName": truncate_dynamic_tool_text(&dynamic_tool_server_name(&target), 160),
                    })
                }));
            }
            Err(error) => {
                errors.push(serde_json::json!({
                    "serverId": target.server_id,
                    "serverName": truncate_dynamic_tool_text(&dynamic_tool_server_name(&target), 160),
                    "message": truncate_dynamic_tool_text(&error, 240),
                }));
            }
        }
    }

    items.sort_by(|lhs, rhs| {
        let lhs_updated = lhs
            .get("updatedAt")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or_default();
        let rhs_updated = rhs
            .get("updatedAt")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or_default();
        rhs_updated.cmp(&lhs_updated)
    });
    if items.len() > limit as usize {
        items.truncate(limit as usize);
    }

    let summary = if items.is_empty() {
        if errors.is_empty() {
            "No sessions found.".to_string()
        } else {
            format!(
                "No sessions found. {} server lookup{} failed.",
                errors.len(),
                if errors.len() == 1 { "" } else { "s" }
            )
        }
    } else {
        let server_count = items
            .iter()
            .filter_map(|item| item.get("serverId").and_then(serde_json::Value::as_str))
            .collect::<std::collections::HashSet<_>>()
            .len();
        let preview = items[0]
            .get("preview")
            .and_then(serde_json::Value::as_str)
            .map(|value| truncate_dynamic_tool_text(value, 80))
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| "an untitled session".to_string());
        let server_name = items[0]
            .get("serverName")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("unknown server");
        let mut summary = format!(
            "Found {} session{} across {} server{}. The most recent is {} on {}.",
            items.len(),
            if items.len() == 1 { "" } else { "s" },
            server_count,
            if server_count == 1 { "" } else { "s" },
            preview,
            server_name,
        );
        if !errors.is_empty() {
            summary.push_str(" Some servers could not be queried.");
        }
        summary
    };

    let mut payload = serde_json::json!({
        "type": "sessions",
        "summary": summary,
        "items": items,
    });
    if let serde_json::Value::Object(object) = &mut payload
        && !errors.is_empty()
    {
        object.insert("errors".to_string(), serde_json::Value::Array(errors));
    }
    Ok(serialize_dynamic_tool_payload(payload, 64_000))
}

async fn dynamic_tool_request_typed<R, P>(
    session: &Arc<ServerSession>,
    method: &str,
    params: &P,
) -> Result<R, String>
where
    R: serde::de::DeserializeOwned,
    P: serde::Serialize,
{
    let params_json = serde_json::to_value(params)
        .map_err(|error| format!("serialize {method} params: {error}"))?;
    let response = session
        .request(method, params_json)
        .await
        .map_err(|error| format!("{method} request failed: {error}"))?;
    serde_json::from_value(response)
        .map_err(|error| format!("deserialize {method} response: {error}"))
}

pub fn thread_info_from_upstream_thread(thread: upstream::Thread) -> Option<ThreadInfo> {
    thread_info_from_upstream_thread_list_item(thread, None, None)
}

fn thread_info_from_upstream_thread_list_item(
    thread: upstream::Thread,
    model: Option<String>,
    _reasoning_effort: Option<String>,
) -> Option<ThreadInfo> {
    let mut info = ThreadInfo::from(thread);
    info.model = model;
    Some(info)
}

pub fn thread_snapshot_from_upstream_thread_with_overrides(
    server_id: &str,
    thread: upstream::Thread,
    model: Option<String>,
    reasoning_effort: Option<String>,
    effective_approval_policy: Option<crate::types::AppAskForApproval>,
    effective_sandbox_policy: Option<crate::types::AppSandboxPolicy>,
) -> Result<ThreadSnapshot, String> {
    Ok(thread_snapshot_from_upstream_thread_state(
        server_id,
        thread,
        model,
        reasoning_effort,
        effective_approval_policy,
        effective_sandbox_policy,
        None,
    ))
}

pub fn copy_thread_runtime_fields(source: &ThreadSnapshot, target: &mut ThreadSnapshot) {
    target.collaboration_mode = source.collaboration_mode;
    if target.model.is_none() {
        target.model = source.model.clone();
    }
    if target.reasoning_effort.is_none() {
        target.reasoning_effort = source.reasoning_effort.clone();
    }
    if target.queued_follow_ups.is_empty() {
        target.queued_follow_ups = source.queued_follow_ups.clone();
    }
    if target.queued_follow_up_drafts.is_empty() {
        target.queued_follow_up_drafts = source.queued_follow_up_drafts.clone();
    }
    target.context_tokens_used = source.context_tokens_used;
    target.model_context_window = source.model_context_window;
    target.rate_limits = source.rate_limits.clone();
    target.realtime_session_id = source.realtime_session_id.clone();
    if target.active_plan_progress.is_none() {
        target.active_plan_progress = source.active_plan_progress.clone();
    }
    if target.pending_plan_implementation_turn_id.is_none() {
        target.pending_plan_implementation_turn_id =
            source.pending_plan_implementation_turn_id.clone();
    }
}

#[cfg(test)]
fn queued_follow_up_preview_from_inputs(
    inputs: &[upstream::UserInput],
    kind: AppQueuedFollowUpKind,
) -> Option<AppQueuedFollowUpPreview> {
    queued_follow_up_draft_from_inputs(inputs, kind).map(|draft| draft.preview)
}

fn queued_follow_up_draft_from_inputs(
    inputs: &[upstream::UserInput],
    kind: AppQueuedFollowUpKind,
) -> Option<crate::store::QueuedFollowUpDraft> {
    let text = queued_follow_up_text_from_inputs(inputs)?;

    Some(crate::store::QueuedFollowUpDraft {
        preview: AppQueuedFollowUpPreview {
            id: uuid::Uuid::new_v4().to_string(),
            kind,
            text,
        },
        inputs: inputs.to_vec(),
        source_message_json: queued_follow_up_message_json_from_inputs(inputs),
    })
}

fn queued_follow_up_text_from_inputs(inputs: &[upstream::UserInput]) -> Option<String> {
    let mut text_parts: Vec<String> = Vec::new();
    let mut attachment_count = 0usize;

    for input in inputs {
        match input {
            upstream::UserInput::Text { text, .. } => {
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    text_parts.push(trimmed.to_string());
                }
            }
            upstream::UserInput::Image { .. } | upstream::UserInput::LocalImage { .. } => {
                attachment_count += 1;
            }
            upstream::UserInput::Skill { .. } | upstream::UserInput::Mention { .. } => {}
        }
    }

    if !text_parts.is_empty() {
        Some(text_parts.join("\n"))
    } else {
        attachment_summary(attachment_count)
    }
}

fn queued_follow_up_drafts_from_message_values(
    messages: &[serde_json::Value],
) -> Vec<crate::store::QueuedFollowUpDraft> {
    build_queued_follow_up_drafts(
        messages.iter().enumerate(),
        AppQueuedFollowUpKind::Message,
        "ipc-message",
    )
}

fn queued_follow_up_drafts_from_conversation_json(
    conversation_state: &serde_json::Value,
) -> Vec<crate::store::QueuedFollowUpDraft> {
    conversation_state
        .get("inputState")
        .or_else(|| conversation_state.get("input_state"))
        .map(queued_follow_up_drafts_from_input_state)
        .unwrap_or_default()
}

fn queued_follow_up_drafts_from_input_state(
    input_state: &serde_json::Value,
) -> Vec<crate::store::QueuedFollowUpDraft> {
    let mut drafts = Vec::new();
    let sections = [
        (
            input_state
                .get("pending_steers")
                .or_else(|| input_state.get("pendingSteers")),
            AppQueuedFollowUpKind::PendingSteer,
            "pending-steer",
        ),
        (
            input_state
                .get("rejected_steers_queue")
                .or_else(|| input_state.get("rejectedSteersQueue"))
                .or_else(|| input_state.get("rejectedSteers")),
            AppQueuedFollowUpKind::RetryingSteer,
            "rejected-steer",
        ),
        (
            input_state
                .get("queued_user_messages")
                .or_else(|| input_state.get("queuedUserMessages"))
                .or_else(|| input_state.get("queued_messages"))
                .or_else(|| input_state.get("queuedMessages")),
            AppQueuedFollowUpKind::Message,
            "queued-message",
        ),
    ];

    for (section_value, fallback_kind, id_scope) in sections {
        let Some(messages) = section_value.and_then(serde_json::Value::as_array) else {
            continue;
        };
        drafts.extend(build_queued_follow_up_drafts(
            messages.iter().enumerate(),
            fallback_kind,
            id_scope,
        ));
    }

    drafts
}

fn build_queued_follow_up_drafts<'a>(
    messages: impl IntoIterator<Item = (usize, &'a serde_json::Value)>,
    fallback_kind: AppQueuedFollowUpKind,
    id_scope: &str,
) -> Vec<crate::store::QueuedFollowUpDraft> {
    messages
        .into_iter()
        .filter_map(|(index, message)| {
            let text = queued_follow_up_text_from_json_value(message)?;
            let kind = queued_follow_up_kind_from_json_value(message).unwrap_or(fallback_kind);
            Some(crate::store::QueuedFollowUpDraft {
                preview: AppQueuedFollowUpPreview {
                    id: stable_follow_up_preview_id(id_scope, index, &text),
                    kind,
                    text,
                },
                inputs: queued_follow_up_inputs_from_json_value(message),
                source_message_json: Some(message.clone()),
            })
        })
        .collect()
}

fn queued_follow_up_kind_from_json_value(
    value: &serde_json::Value,
) -> Option<AppQueuedFollowUpKind> {
    let object = value.as_object()?;
    let raw_kind = object
        .get("kind")
        .or_else(|| object.get("category"))
        .or_else(|| object.get("queueKind"))
        .or_else(|| object.get("queue_kind"))
        .and_then(serde_json::Value::as_str)?
        .trim()
        .to_ascii_lowercase();

    match raw_kind.as_str() {
        "pending_steer" | "pending-steer" | "pendingsteer" | "steer" => {
            Some(AppQueuedFollowUpKind::PendingSteer)
        }
        "rejected_steer" | "rejected-steer" | "rejectedsteer" | "retrying_steer"
        | "retrying-steer" | "retryingsteer" => Some(AppQueuedFollowUpKind::RetryingSteer),
        "queued" | "queued_follow_up" | "queued-follow-up" | "queuedfollowup" => {
            Some(AppQueuedFollowUpKind::Message)
        }
        _ => None,
    }
}

fn queued_follow_up_text_from_json_value(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(text) => {
            let trimmed = text.trim();
            (!trimmed.is_empty()).then(|| trimmed.to_string())
        }
        serde_json::Value::Object(object) => {
            if let Some(nested) = object
                .get("userMessage")
                .or_else(|| object.get("user_message"))
            {
                return queued_follow_up_text_from_json_value(nested);
            }

            if let Some(text) = string_field(object, &["text", "message", "summary"]) {
                return Some(text);
            }

            let attachment_count = array_field_len(object, &["localImages", "local_images"])
                + array_field_len(object, &["remoteImageUrls", "remote_image_urls"])
                + array_field_len(object, &["images", "imageUrls", "image_urls"]);

            attachment_summary(attachment_count)
        }
        _ => None,
    }
}

fn queued_follow_up_inputs_from_json_value(value: &serde_json::Value) -> Vec<upstream::UserInput> {
    let Some(object) = value.as_object() else {
        return Vec::new();
    };

    let message = object
        .get("userMessage")
        .or_else(|| object.get("user_message"))
        .and_then(serde_json::Value::as_object)
        .unwrap_or(object);

    let mut inputs = Vec::new();

    let text_elements = message
        .get("textElements")
        .or_else(|| message.get("text_elements"))
        .cloned()
        .and_then(|value| serde_json::from_value::<Vec<upstream::TextElement>>(value).ok())
        .unwrap_or_default();

    if let Some(text) = string_field(message, &["text", "message", "summary"]) {
        inputs.push(upstream::UserInput::Text {
            text,
            text_elements,
        });
    }

    let remote_images = message
        .get("remoteImageUrls")
        .or_else(|| message.get("remote_image_urls"))
        .or_else(|| message.get("images"))
        .or_else(|| message.get("imageUrls"))
        .or_else(|| message.get("image_urls"))
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_str)
        .map(|url| upstream::UserInput::Image {
            url: url.to_string(),
        });
    inputs.extend(remote_images);

    let local_images = message
        .get("localImages")
        .or_else(|| message.get("local_images"))
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_object)
        .filter_map(|image| {
            image
                .get("path")
                .and_then(serde_json::Value::as_str)
                .map(std::path::PathBuf::from)
        })
        .map(|path| upstream::UserInput::LocalImage { path });
    inputs.extend(local_images);

    let mentions = message
        .get("mentionBindings")
        .or_else(|| message.get("mention_bindings"))
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_object)
        .filter_map(|binding| {
            let name = binding
                .get("mention")
                .or_else(|| binding.get("name"))
                .and_then(serde_json::Value::as_str)?;
            let path = binding.get("path").and_then(serde_json::Value::as_str)?;
            Some(upstream::UserInput::Mention {
                name: name.to_string(),
                path: path.to_string(),
            })
        });
    inputs.extend(mentions);

    let skills = message
        .get("skillBindings")
        .or_else(|| message.get("skill_bindings"))
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_object)
        .filter_map(|binding| {
            let name = binding
                .get("name")
                .or_else(|| binding.get("skill"))
                .and_then(serde_json::Value::as_str)?;
            let path = binding.get("path").and_then(serde_json::Value::as_str)?;
            Some(upstream::UserInput::Skill {
                name: name.to_string(),
                path: std::path::PathBuf::from(path),
            })
        });
    inputs.extend(skills);

    inputs
}

fn queued_follow_up_message_json_from_inputs(
    inputs: &[upstream::UserInput],
) -> Option<serde_json::Value> {
    let mut text = None;
    let mut text_elements = Vec::new();
    let mut remote_image_urls = Vec::new();
    let mut local_images = Vec::new();
    let mut mention_bindings = Vec::new();
    let mut skill_bindings = Vec::new();

    for input in inputs {
        match input {
            upstream::UserInput::Text {
                text: current_text,
                text_elements: current_elements,
            } => {
                let trimmed = current_text.trim();
                if !trimmed.is_empty() {
                    text = Some(trimmed.to_string());
                }
                text_elements = current_elements.clone();
            }
            upstream::UserInput::Image { url } => {
                remote_image_urls.push(url.clone());
            }
            upstream::UserInput::LocalImage { path } => {
                let placeholder = format!("[Image #{}]", local_images.len() + 1);
                local_images.push(serde_json::json!({
                    "placeholder": placeholder,
                    "path": path,
                }));
            }
            upstream::UserInput::Mention { name, path } => {
                mention_bindings.push(serde_json::json!({
                    "mention": name,
                    "path": path,
                }));
            }
            upstream::UserInput::Skill { name, path } => {
                skill_bindings.push(serde_json::json!({
                    "name": name,
                    "path": path,
                }));
            }
        }
    }

    if text.is_none()
        && text_elements.is_empty()
        && remote_image_urls.is_empty()
        && local_images.is_empty()
        && mention_bindings.is_empty()
        && skill_bindings.is_empty()
    {
        return None;
    }

    Some(serde_json::json!({
        "text": text.unwrap_or_default(),
        "textElements": text_elements,
        "remoteImageUrls": remote_image_urls,
        "localImages": local_images,
        "mentionBindings": mention_bindings,
        "skillBindings": skill_bindings,
    }))
}

fn queued_follow_up_state_json_from_drafts(
    drafts: &[crate::store::QueuedFollowUpDraft],
) -> serde_json::Value {
    let mut pending_steers = Vec::new();
    let mut rejected_steers_queue = Vec::new();
    let mut queued_user_messages = Vec::new();

    for draft in drafts {
        let Some(message_json) = draft
            .source_message_json
            .clone()
            .or_else(|| queued_follow_up_message_json_from_inputs(&draft.inputs))
        else {
            continue;
        };

        match draft.preview.kind {
            AppQueuedFollowUpKind::PendingSteer => pending_steers.push(message_json),
            AppQueuedFollowUpKind::RetryingSteer => rejected_steers_queue.push(message_json),
            AppQueuedFollowUpKind::Message => queued_user_messages.push(message_json),
        }
    }

    serde_json::json!({
        "pendingSteers": pending_steers,
        "rejectedSteersQueue": rejected_steers_queue,
        "queuedUserMessages": queued_user_messages,
    })
}

fn string_field(
    object: &serde_json::Map<String, serde_json::Value>,
    keys: &[&str],
) -> Option<String> {
    keys.iter()
        .filter_map(|key| object.get(*key))
        .find_map(|value| match value {
            serde_json::Value::String(text) => {
                let trimmed = text.trim();
                (!trimmed.is_empty()).then(|| trimmed.to_string())
            }
            serde_json::Value::Array(values) => {
                let joined = values
                    .iter()
                    .filter_map(serde_json::Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .collect::<Vec<_>>()
                    .join("\n");
                (!joined.is_empty()).then_some(joined)
            }
            _ => None,
        })
}

fn array_field_len(object: &serde_json::Map<String, serde_json::Value>, keys: &[&str]) -> usize {
    keys.iter()
        .filter_map(|key| object.get(*key))
        .find_map(|value| value.as_array().map(Vec::len))
        .unwrap_or(0)
}

fn attachment_summary(attachment_count: usize) -> Option<String> {
    match attachment_count {
        0 => None,
        1 => Some("1 image attachment".to_string()),
        count => Some(format!("{count} image attachments")),
    }
}

fn stable_follow_up_preview_id(scope: &str, index: usize, text: &str) -> String {
    let mut hasher = DefaultHasher::new();
    scope.hash(&mut hasher);
    index.hash(&mut hasher);
    text.hash(&mut hasher);
    format!("{scope}-{index}-{:016x}", hasher.finish())
}

fn remote_oauth_callback_port(auth_url: &str) -> Result<u16, RpcError> {
    let parsed = Url::parse(auth_url).map_err(|error| {
        RpcError::Deserialization(format!("invalid auth URL for remote OAuth: {error}"))
    })?;
    let redirect_uri = parsed
        .query_pairs()
        .find(|(key, _)| key == "redirect_uri")
        .map(|(_, value)| value.into_owned())
        .ok_or_else(|| {
            RpcError::Deserialization("missing redirect_uri in remote OAuth auth URL".to_string())
        })?;
    let redirect = Url::parse(&redirect_uri).map_err(|error| {
        RpcError::Deserialization(format!(
            "invalid redirect_uri in remote OAuth auth URL: {error}"
        ))
    })?;
    let host = redirect.host_str().unwrap_or_default();
    if host != "localhost" && host != "127.0.0.1" {
        return Err(RpcError::Deserialization(format!(
            "unsupported remote OAuth callback host: {host}"
        )));
    }
    redirect.port_or_known_default().ok_or_else(|| {
        RpcError::Deserialization("missing callback port in remote OAuth redirect_uri".to_string())
    })
}

fn ensure_thread_is_editable(snapshot: &ThreadSnapshot) -> Result<(), RpcError> {
    if snapshot.items.is_empty() {
        return Err(RpcError::Deserialization(
            "thread has no conversation items".to_string(),
        ));
    }
    Ok(())
}

fn rollback_depth_for_turn(
    snapshot: &ThreadSnapshot,
    selected_turn_index: usize,
) -> Result<u32, RpcError> {
    let user_turn_indices = snapshot
        .items
        .iter()
        .enumerate()
        .filter_map(|(idx, item)| {
            matches!(
                item.content,
                crate::conversation_uniffi::HydratedConversationItemContent::User(_)
            )
            .then_some(idx)
        })
        .collect::<Vec<_>>();
    let item_index = *user_turn_indices.get(selected_turn_index).ok_or_else(|| {
        RpcError::Deserialization(format!("unknown user turn index {}", selected_turn_index))
    })?;
    let turns_after = snapshot.items.len().saturating_sub(item_index + 1);
    u32::try_from(turns_after)
        .map_err(|_| RpcError::Deserialization("rollback depth overflow".to_string()))
}

fn user_boundary_text_for_turn(
    snapshot: &ThreadSnapshot,
    selected_turn_index: usize,
) -> Result<String, RpcError> {
    let item = snapshot
        .items
        .iter()
        .filter(|item| {
            matches!(
                item.content,
                crate::conversation_uniffi::HydratedConversationItemContent::User(_)
            )
        })
        .nth(selected_turn_index)
        .ok_or_else(|| {
            RpcError::Deserialization(format!("unknown user turn index {}", selected_turn_index))
        })?;
    match &item.content {
        crate::conversation_uniffi::HydratedConversationItemContent::User(data) => {
            Ok(data.text.clone())
        }
        _ => Err(RpcError::Deserialization(
            "selected turn has no editable text".to_string(),
        )),
    }
}

pub fn reasoning_effort_string(value: crate::types::ReasoningEffort) -> String {
    match value {
        crate::types::ReasoningEffort::None => "none".to_string(),
        crate::types::ReasoningEffort::Minimal => "minimal".to_string(),
        crate::types::ReasoningEffort::Low => "low".to_string(),
        crate::types::ReasoningEffort::Medium => "medium".to_string(),
        crate::types::ReasoningEffort::High => "high".to_string(),
        crate::types::ReasoningEffort::XHigh => "xhigh".to_string(),
    }
}

pub fn reasoning_effort_from_string(value: &str) -> Option<crate::types::ReasoningEffort> {
    match value.trim().to_ascii_lowercase().as_str() {
        "none" => Some(crate::types::ReasoningEffort::None),
        "minimal" => Some(crate::types::ReasoningEffort::Minimal),
        "low" => Some(crate::types::ReasoningEffort::Low),
        "medium" => Some(crate::types::ReasoningEffort::Medium),
        "high" => Some(crate::types::ReasoningEffort::High),
        "xhigh" => Some(crate::types::ReasoningEffort::XHigh),
        _ => None,
    }
}

fn core_reasoning_effort_from_mobile(
    value: crate::types::ReasoningEffort,
) -> codex_protocol::openai_models::ReasoningEffort {
    match value {
        crate::types::ReasoningEffort::None => codex_protocol::openai_models::ReasoningEffort::None,
        crate::types::ReasoningEffort::Minimal => {
            codex_protocol::openai_models::ReasoningEffort::Minimal
        }
        crate::types::ReasoningEffort::Low => codex_protocol::openai_models::ReasoningEffort::Low,
        crate::types::ReasoningEffort::Medium => {
            codex_protocol::openai_models::ReasoningEffort::Medium
        }
        crate::types::ReasoningEffort::High => codex_protocol::openai_models::ReasoningEffort::High,
        crate::types::ReasoningEffort::XHigh => {
            codex_protocol::openai_models::ReasoningEffort::XHigh
        }
    }
}

fn collaboration_mode_from_thread(
    thread: &ThreadSnapshot,
    mode: AppModeKind,
    model_override: Option<String>,
    effort_override: Option<codex_protocol::openai_models::ReasoningEffort>,
) -> Option<codex_protocol::config_types::CollaborationMode> {
    let model = model_override
        .or_else(|| thread.model.clone())
        .or_else(|| thread.info.model.clone())?;
    let reasoning_effort = effort_override.or_else(|| {
        thread
            .reasoning_effort
            .as_deref()
            .and_then(reasoning_effort_from_string)
            .map(core_reasoning_effort_from_mobile)
    });
    Some(codex_protocol::config_types::CollaborationMode {
        mode: match mode {
            AppModeKind::Default => codex_protocol::config_types::ModeKind::Default,
            AppModeKind::Plan => codex_protocol::config_types::ModeKind::Plan,
        },
        settings: codex_protocol::config_types::Settings {
            model,
            reasoning_effort,
            developer_instructions: None,
        },
    })
}

fn map_rpc_client_error(error: crate::RpcClientError) -> RpcError {
    match error {
        crate::RpcClientError::Rpc(message) | crate::RpcClientError::Serialization(message) => {
            RpcError::Deserialization(message)
        }
    }
}

fn map_ssh_transport_error(error: crate::ssh::SshError) -> TransportError {
    TransportError::ConnectionFailed(error.to_string())
}

async fn refresh_thread_list_from_app_server(
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: &str,
) -> Result<(), RpcError> {
    let response = session
        .request("thread/list", serde_json::json!({}))
        .await?;
    let threads = response
        .get("data")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| RpcError::Deserialization("thread/list response missing data".to_string()))?
        .iter()
        .cloned()
        .filter_map(|value| serde_json::from_value::<upstream::Thread>(value).ok())
        .map(ThreadInfo::from)
        .collect::<Vec<_>>();
    app_store.sync_thread_list(server_id, &threads);
    Ok(())
}

async fn refresh_account_from_app_server(
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    server_id: &str,
) -> Result<(), RpcError> {
    let response = session
        .request("account/read", serde_json::json!({ "refreshToken": false }))
        .await?;
    if !session_is_current(&sessions, server_id, &session) {
        return Ok(());
    }
    let response =
        serde_json::from_value::<upstream::GetAccountResponse>(response).map_err(|error| {
            RpcError::Deserialization(format!("deserialize account/read response: {error}"))
        })?;
    app_store.update_server_account(
        server_id,
        response.account.map(Into::into),
        response.requires_openai_auth,
    );
    Ok(())
}

async fn refresh_thread_list_from_app_server_if_current(
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    server_id: &str,
) -> Result<(), RpcError> {
    if !session_is_current(&sessions, server_id, &session) {
        return Ok(());
    }
    let response = session
        .request("thread/list", serde_json::json!({}))
        .await?;
    if !session_is_current(&sessions, server_id, &session) {
        return Ok(());
    }
    let threads = response
        .get("data")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| RpcError::Deserialization("thread/list response missing data".to_string()))?
        .iter()
        .cloned()
        .filter_map(|value| serde_json::from_value::<upstream::Thread>(value).ok())
        .map(ThreadInfo::from)
        .collect::<Vec<_>>();
    app_store.sync_thread_list(server_id, &threads);
    Ok(())
}

fn session_is_current(
    sessions: &Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    server_id: &str,
    session: &Arc<ServerSession>,
) -> bool {
    match sessions.read() {
        Ok(guard) => guard
            .get(server_id)
            .map(|current| Arc::ptr_eq(current, session))
            .unwrap_or(false),
        Err(error) => error
            .into_inner()
            .get(server_id)
            .map(|current| Arc::ptr_eq(current, session))
            .unwrap_or(false),
    }
}

async fn read_thread_response_from_app_server(
    session: Arc<ServerSession>,
    thread_id: &str,
) -> Result<upstream::ThreadReadResponse, RpcError> {
    let response = session
        .request(
            "thread/read",
            serde_json::json!({ "threadId": thread_id, "includeTurns": true }),
        )
        .await?;
    serde_json::from_value::<upstream::ThreadReadResponse>(response).map_err(|error| {
        RpcError::Deserialization(format!("deserialize thread/read response: {error}"))
    })
}

fn upsert_thread_snapshot_from_app_server_read_response(
    app_store: &AppStoreReducer,
    server_id: &str,
    response: upstream::ThreadReadResponse,
) -> Result<(), RpcError> {
    let thread_id = response.thread.id.clone();
    let existing = app_store
        .snapshot()
        .threads
        .get(&ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        })
        .cloned();
    let mut snapshot = thread_snapshot_from_upstream_thread_with_overrides(
        server_id,
        response.thread,
        None,
        None,
        response.approval_policy.map(Into::into),
        response.sandbox.map(Into::into),
    )
    .map_err(RpcError::Deserialization)?;
    if let Some(existing) = existing.as_ref() {
        copy_thread_runtime_fields(existing, &mut snapshot);
    }
    app_store.upsert_thread_snapshot(snapshot);
    Ok(())
}

fn seed_ipc_stream_cache_from_existing_app_state(
    app_store: &AppStoreReducer,
    cache: &mut HashMap<String, serde_json::Value>,
    server_id: &str,
    thread_id: &str,
) -> bool {
    let key = ThreadKey {
        server_id: server_id.to_string(),
        thread_id: thread_id.to_string(),
    };
    let snapshot = app_store.snapshot();
    let existing_thread = snapshot.threads.get(&key).cloned();
    let pending_approvals = snapshot
        .pending_approvals
        .iter()
        .filter(|approval| {
            approval.server_id == server_id && approval.thread_id.as_deref() == Some(thread_id)
        })
        .cloned()
        .collect::<Vec<_>>();
    let pending_user_inputs = snapshot
        .pending_user_inputs
        .iter()
        .filter(|request| request.server_id == server_id && request.thread_id == thread_id)
        .cloned()
        .collect::<Vec<_>>();
    drop(snapshot);

    let Some(existing_thread) = existing_thread else {
        return false;
    };

    let mut conversation_state =
        minimal_ipc_conversation_state_from_thread_snapshot(&existing_thread);
    hydrate_seeded_ipc_conversation_state(
        app_store,
        &mut conversation_state,
        Some(&existing_thread),
        &pending_approvals,
        &pending_user_inputs,
    );
    cache.insert(thread_id.to_string(), conversation_state);
    true
}

async fn recover_ipc_stream_cache_from_app_server(
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: &str,
    thread_id: &str,
) -> Result<serde_json::Value, RpcError> {
    let key = ThreadKey {
        server_id: server_id.to_string(),
        thread_id: thread_id.to_string(),
    };
    let app_snapshot = app_store.snapshot();
    let existing_thread = app_snapshot.threads.get(&key).cloned();
    let pending_approvals = app_snapshot
        .pending_approvals
        .iter()
        .filter(|approval| {
            approval.server_id == server_id && approval.thread_id.as_deref() == Some(thread_id)
        })
        .cloned()
        .collect::<Vec<_>>();
    let pending_user_inputs = app_snapshot
        .pending_user_inputs
        .iter()
        .filter(|request| request.server_id == server_id && request.thread_id == thread_id)
        .cloned()
        .collect::<Vec<_>>();
    drop(app_snapshot);

    let response = read_thread_response_from_app_server(session, thread_id).await?;
    let thread = response.thread.clone();
    upsert_thread_snapshot_from_app_server_read_response(&app_store, server_id, response)?;

    let mut conversation_state = seed_conversation_state_from_thread(&thread);
    hydrate_seeded_ipc_conversation_state(
        &app_store,
        &mut conversation_state,
        existing_thread.as_ref(),
        &pending_approvals,
        &pending_user_inputs,
    );
    Ok(conversation_state)
}

fn minimal_ipc_conversation_state_from_thread_snapshot(
    thread: &ThreadSnapshot,
) -> serde_json::Value {
    serde_json::json!({
        "title": thread.info.title.clone(),
        "cwd": thread.info.cwd.clone().unwrap_or_default(),
        "rolloutPath": thread.info.path.clone(),
        "source": upstream::SessionSource::default(),
        "gitInfo": serde_json::Value::Null,
        "turns": [],
        "createdAt": thread.info.created_at.unwrap_or_default(),
        "updatedAt": thread.info.updated_at.unwrap_or_default(),
        "threadRuntimeStatus": upstream_thread_status_from_summary_status(thread.info.status.clone()),
        "ephemeral": false,
        "modelProvider": thread.info.model_provider.clone().unwrap_or_default(),
        "cliVersion": "",
        "agentNickname": thread.info.agent_nickname.clone(),
        "agentRole": thread.info.agent_role.clone(),
        "requests": [],
    })
}

fn upstream_thread_status_from_summary_status(
    status: ThreadSummaryStatus,
) -> upstream::ThreadStatus {
    match status {
        ThreadSummaryStatus::NotLoaded | ThreadSummaryStatus::Idle => upstream::ThreadStatus::Idle,
        ThreadSummaryStatus::Active => upstream::ThreadStatus::Active {
            active_flags: Vec::new(),
        },
        ThreadSummaryStatus::SystemError => upstream::ThreadStatus::SystemError,
    }
}

fn thread_snapshot_from_upstream_thread(
    server_id: &str,
    thread: upstream::Thread,
) -> ThreadSnapshot {
    thread_snapshot_from_upstream_thread_state(server_id, thread, None, None, None, None, None)
}

fn thread_snapshot_from_upstream_thread_state(
    server_id: &str,
    thread: upstream::Thread,
    model: Option<String>,
    reasoning_effort: Option<String>,
    effective_approval_policy: Option<crate::types::AppAskForApproval>,
    effective_sandbox_policy: Option<crate::types::AppSandboxPolicy>,
    active_turn_id: Option<String>,
) -> ThreadSnapshot {
    let info = ThreadInfo::from(thread.clone());
    let items = crate::conversation::hydrate_turns(&thread.turns, &Default::default());
    let mut snapshot = ThreadSnapshot::from_info(server_id, info);
    snapshot.items = items;
    snapshot.model = model;
    snapshot.reasoning_effort = reasoning_effort;
    snapshot.effective_approval_policy = effective_approval_policy;
    snapshot.effective_sandbox_policy = effective_sandbox_policy;
    snapshot.active_turn_id = active_turn_id.or_else(|| active_turn_id_from_turns(&thread.turns));
    snapshot
}

fn active_turn_id_from_turns(turns: &[upstream::Turn]) -> Option<String> {
    turns
        .iter()
        .rev()
        .find(|turn| matches!(turn.status, upstream::TurnStatus::InProgress))
        .map(|turn| turn.id.clone())
}

struct ThreadProjection {
    snapshot: ThreadSnapshot,
    pending_approvals: Vec<PendingApprovalWithSeed>,
    pending_user_inputs: Vec<PendingUserInputRequest>,
}

fn thread_projection_from_conversation_json(
    server_id: &str,
    conversation_id: &str,
    conversation_state: &serde_json::Value,
) -> Result<ThreadProjection, String> {
    project_conversation_state(conversation_id, conversation_state)
        .map(|projection| {
            let mut snapshot = thread_snapshot_from_upstream_thread_state(
                server_id,
                projection.thread,
                projection.latest_model,
                projection.latest_reasoning_effort,
                None,
                None,
                projection.active_turn_id,
            );
            snapshot.queued_follow_up_drafts =
                queued_follow_up_drafts_from_conversation_json(conversation_state);
            snapshot.queued_follow_ups = snapshot
                .queued_follow_up_drafts
                .iter()
                .map(|draft| draft.preview.clone())
                .collect();
            ThreadProjection {
                snapshot,
                pending_approvals: projection
                    .pending_approvals
                    .into_iter()
                    .map(|approval| pending_approval_from_ipc_projection(server_id, approval))
                    .collect(),
                pending_user_inputs: projection
                    .pending_user_inputs
                    .into_iter()
                    .map(|request| pending_user_input_from_ipc_projection(server_id, request))
                    .collect(),
            }
        })
        .or_else(|ipc_error| {
            let thread: upstream::Thread = serde_json::from_value(conversation_state.clone())
                .map_err(|error| {
                    format!(
                        "deserialize desktop conversation_state: {ipc_error}; deserialize upstream thread: {error}"
                    )
                })?;
            Ok(ThreadProjection {
                snapshot: thread_snapshot_from_upstream_thread(server_id, thread),
                pending_approvals: Vec::new(),
                pending_user_inputs: Vec::new(),
            })
        })
}

fn pending_approval_from_ipc_projection(
    server_id: &str,
    approval: ProjectedApprovalRequest,
) -> PendingApprovalWithSeed {
    let request_id = approval.id.clone();
    let public_approval = PendingApproval {
        id: approval.id,
        server_id: server_id.to_string(),
        kind: match approval.kind {
            ProjectedApprovalKind::Command => crate::types::ApprovalKind::Command,
            ProjectedApprovalKind::FileChange => crate::types::ApprovalKind::FileChange,
            ProjectedApprovalKind::Permissions => crate::types::ApprovalKind::Permissions,
        },
        thread_id: approval.thread_id,
        turn_id: approval.turn_id,
        item_id: approval.item_id,
        command: approval.command,
        path: approval.path,
        grant_root: approval.grant_root,
        cwd: approval.cwd,
        reason: approval.reason,
    };
    PendingApprovalWithSeed {
        approval: public_approval,
        seed: PendingApprovalSeed {
            request_id: upstream::RequestId::String(request_id),
            raw_params: approval.raw_params,
        },
    }
}

fn pending_user_input_from_ipc_projection(
    server_id: &str,
    request: ProjectedUserInputRequest,
) -> PendingUserInputRequest {
    PendingUserInputRequest {
        id: request.id,
        server_id: server_id.to_string(),
        thread_id: request.thread_id,
        turn_id: request.turn_id,
        item_id: request.item_id,
        questions: request
            .questions
            .into_iter()
            .map(|question| crate::types::PendingUserInputQuestion {
                id: question.id,
                header: question.header,
                question: question.question,
                is_other_allowed: question.is_other_allowed,
                is_secret: question.is_secret,
                options: question
                    .options
                    .into_iter()
                    .map(|option| crate::types::PendingUserInputOption {
                        label: option.label,
                        description: option.description,
                    })
                    .collect(),
            })
            .collect(),
        requester_agent_nickname: request.requester_agent_nickname,
        requester_agent_role: request.requester_agent_role,
    }
}

fn sync_ipc_thread_requests(
    app_store: &AppStoreReducer,
    server_id: &str,
    thread_id: &str,
    pending_approvals: Vec<PendingApprovalWithSeed>,
    pending_user_inputs: Vec<PendingUserInputRequest>,
) {
    let snapshot = app_store.snapshot();

    let mut merged_approvals = snapshot
        .pending_approvals
        .into_iter()
        .filter(|approval| {
            !(approval.server_id == server_id && approval.thread_id.as_deref() == Some(thread_id))
        })
        .map(|approval| PendingApprovalWithSeed {
            seed: app_store
                .pending_approval_seed(&approval.server_id, &approval.id)
                .unwrap_or(PendingApprovalSeed {
                    request_id: fallback_server_request_id(&approval.id),
                    raw_params: seed_ipc_approval_request_params(&approval)
                        .unwrap_or(serde_json::Value::Null),
                }),
            approval,
        })
        .collect::<Vec<_>>();
    merged_approvals.extend(pending_approvals);
    app_store.replace_pending_approvals_with_seeds(merged_approvals);

    let mut merged_user_inputs = snapshot
        .pending_user_inputs
        .into_iter()
        .filter(|request| !(request.server_id == server_id && request.thread_id == thread_id))
        .collect::<Vec<_>>();
    merged_user_inputs.extend(pending_user_inputs);
    app_store.replace_pending_user_inputs(merged_user_inputs);
}

fn hydrate_seeded_ipc_conversation_state(
    app_store: &AppStoreReducer,
    conversation_state: &mut serde_json::Value,
    existing_thread: Option<&ThreadSnapshot>,
    pending_approvals: &[PendingApproval],
    pending_user_inputs: &[PendingUserInputRequest],
) {
    let Some(object) = conversation_state.as_object_mut() else {
        return;
    };

    if let Some(thread) = existing_thread {
        if let Some(model) = thread.model.as_ref() {
            object.insert(
                "latestModel".to_string(),
                serde_json::Value::String(model.clone()),
            );
        }
        if let Some(reasoning_effort) = thread.reasoning_effort.as_ref() {
            object.insert(
                "latestReasoningEffort".to_string(),
                serde_json::Value::String(reasoning_effort.clone()),
            );
        }
    }

    if !object.contains_key("agentNickname")
        && let Some(agent_nickname) = pending_user_inputs
            .iter()
            .find_map(|request| request.requester_agent_nickname.clone())
    {
        object.insert(
            "agentNickname".to_string(),
            serde_json::Value::String(agent_nickname),
        );
    }

    if !object.contains_key("agentRole")
        && let Some(agent_role) = pending_user_inputs
            .iter()
            .find_map(|request| request.requester_agent_role.clone())
    {
        object.insert(
            "agentRole".to_string(),
            serde_json::Value::String(agent_role),
        );
    }

    let requests = pending_approvals
        .iter()
        .filter_map(|approval| {
            seed_ipc_approval_request(
                approval,
                app_store
                    .pending_approval_seed(&approval.server_id, &approval.id)
                    .as_ref(),
            )
        })
        .chain(pending_user_inputs.iter().map(seed_ipc_user_input_request))
        .collect::<Vec<_>>();
    if !requests.is_empty() {
        object.insert("requests".to_string(), serde_json::Value::Array(requests));
    }
}

fn seed_ipc_approval_request(
    approval: &PendingApproval,
    seed: Option<&PendingApprovalSeed>,
) -> Option<serde_json::Value> {
    if matches!(approval.kind, crate::types::ApprovalKind::McpElicitation) {
        return None;
    }

    let params = seed
        .map(|seed| seed.raw_params.clone())
        .or_else(|| seed_ipc_approval_request_params(approval))?;

    Some(serde_json::json!({
        "id": approval.id,
        "method": approval_method(&approval.kind),
        "params": params,
    }))
}

fn approval_method(kind: &crate::types::ApprovalKind) -> &'static str {
    match kind {
        crate::types::ApprovalKind::Command => "item/commandExecution/requestApproval",
        crate::types::ApprovalKind::FileChange => "item/fileChange/requestApproval",
        crate::types::ApprovalKind::Permissions => "item/permissions/requestApproval",
        crate::types::ApprovalKind::McpElicitation => "mcpServer/elicitation/request",
    }
}

fn seed_ipc_approval_request_params(approval: &PendingApproval) -> Option<serde_json::Value> {
    let thread_id = approval.thread_id.clone()?;
    let turn_id = approval.turn_id.clone()?;
    let item_id = approval.item_id.clone()?;

    match approval.kind {
        crate::types::ApprovalKind::Command => Some(serde_json::json!({
            "threadId": thread_id,
            "turnId": turn_id,
            "itemId": item_id,
            "command": approval.command,
            "cwd": approval.cwd,
            "reason": approval.reason,
        })),
        crate::types::ApprovalKind::FileChange => Some(serde_json::json!({
            "threadId": thread_id,
            "turnId": turn_id,
            "itemId": item_id,
            "grantRoot": approval.grant_root,
            "reason": approval.reason,
        })),
        crate::types::ApprovalKind::Permissions => Some(serde_json::json!({
            "threadId": thread_id,
            "turnId": turn_id,
            "itemId": item_id,
            "reason": approval.reason,
        })),
        crate::types::ApprovalKind::McpElicitation => None,
    }
}

fn seed_ipc_user_input_request(request: &PendingUserInputRequest) -> serde_json::Value {
    serde_json::json!({
        "id": request.id,
        "method": "item/tool/requestUserInput",
        "params": {
            "threadId": request.thread_id,
            "turnId": request.turn_id,
            "itemId": request.item_id,
            "questions": request.questions.iter().map(|question| {
                serde_json::json!({
                    "id": question.id,
                    "header": question.header.clone().unwrap_or_default(),
                    "question": question.question,
                    "isOther": question.is_other_allowed,
                    "isSecret": question.is_secret,
                    "options": if question.options.is_empty() {
                        serde_json::Value::Null
                    } else {
                        serde_json::Value::Array(
                            question.options.iter().map(|option| {
                                serde_json::json!({
                                    "label": option.label,
                                    "description": option.description.clone().unwrap_or_default(),
                                })
                            }).collect()
                        )
                    },
                })
            }).collect::<Vec<_>>(),
        },
    })
}

// -- IPC stream state change handler --

#[derive(Debug, Default)]
struct IncrementalIpcPatchSummary {
    affected_turn_indices: Vec<usize>,
    requests_changed: bool,
    latest_model_changed: bool,
    latest_reasoning_effort_changed: bool,
    updated_at_changed: bool,
}

#[derive(Debug, Clone)]
struct IncrementalProjectedTurn {
    turn_index: usize,
    items: Vec<crate::conversation_uniffi::HydratedConversationItem>,
}

#[derive(Debug, Clone)]
struct IncrementalStreamingDelta {
    item_id: String,
    kind: ThreadStreamingDeltaKind,
    text: String,
}

#[derive(Debug, Clone)]
struct IncrementalCommandExecutionUpdate {
    item_id: String,
    status: AppOperationStatus,
    exit_code: Option<i32>,
    duration_ms: Option<i64>,
    process_id: Option<String>,
}

#[derive(Debug, Clone)]
enum IncrementalThreadEvent {
    Streaming(IncrementalStreamingDelta),
    CommandExecutionUpdated(IncrementalCommandExecutionUpdate),
    ItemUpsert(crate::conversation_uniffi::HydratedConversationItem),
}

#[derive(Debug, Clone)]
enum IncrementalTurnMutation {
    Unchanged,
    Patched {
        projected_turn: IncrementalProjectedTurn,
        events: Vec<IncrementalThreadEvent>,
    },
    Replace(IncrementalProjectedTurn),
}

#[derive(Debug, Clone)]
struct IncrementalThreadMutation {
    turn_mutations: Vec<IncrementalTurnMutation>,
    active_turn_id: Option<String>,
    updated_at: Option<i64>,
    latest_model: Option<String>,
    latest_reasoning_effort: Option<String>,
    thread_status: ThreadSummaryStatus,
}

#[derive(Debug)]
struct IncrementalMutationResult {
    requires_thread_upsert: bool,
    emitted_deltas: Vec<IncrementalStreamingDelta>,
    emitted_command_updates: Vec<IncrementalCommandExecutionUpdate>,
    emitted_item_upserts: Vec<crate::conversation_uniffi::HydratedConversationItem>,
    emit_thread_state_update: bool,
}

const MAX_INCREMENTAL_IPC_GRANULAR_NON_STREAMING_UPDATES: usize = 8;
const MAX_INCREMENTAL_IPC_GRANULAR_TURN_UPDATES: usize = 1;

fn should_emit_thread_upsert_for_incremental_patch_burst(
    summary: &IncrementalIpcPatchSummary,
    result: &IncrementalMutationResult,
) -> bool {
    if result.requires_thread_upsert {
        return true;
    }

    let non_streaming_update_count =
        result.emitted_item_upserts.len() + result.emitted_command_updates.len();
    if non_streaming_update_count >= MAX_INCREMENTAL_IPC_GRANULAR_NON_STREAMING_UPDATES {
        return true;
    }

    summary.affected_turn_indices.len() > MAX_INCREMENTAL_IPC_GRANULAR_TURN_UPDATES
        && non_streaming_update_count > 0
}

fn summarize_incremental_ipc_patches(patches: &[ImmerPatch]) -> Option<IncrementalIpcPatchSummary> {
    let mut affected_turn_indices = BTreeSet::new();
    let mut summary = IncrementalIpcPatchSummary::default();

    for patch in patches {
        match patch.path.as_slice() {
            [ImmerPathSegment::Key(key)] if key == "requests" => {
                summary.requests_changed = true;
            }
            [ImmerPathSegment::Key(key)] if key == "latestModel" => {
                summary.latest_model_changed = true;
            }
            [ImmerPathSegment::Key(key)] if key == "latestReasoningEffort" => {
                summary.latest_reasoning_effort_changed = true;
            }
            [ImmerPathSegment::Key(key)] if key == "updatedAt" => {
                summary.updated_at_changed = true;
            }
            [
                ImmerPathSegment::Key(key),
                ImmerPathSegment::Index(turn_index),
            ] if key == "turns" => {
                if matches!(&patch.op, ImmerOp::Remove) {
                    return None;
                }
                affected_turn_indices.insert(*turn_index);
            }
            [
                ImmerPathSegment::Key(key),
                ImmerPathSegment::Index(turn_index),
                ..,
            ] if key == "turns" => {
                affected_turn_indices.insert(*turn_index);
            }
            _ => return None,
        }
    }

    summary.affected_turn_indices = affected_turn_indices.into_iter().collect();
    Some(summary)
}

fn incremental_ipc_thread_status(
    existing: ThreadSummaryStatus,
    active_turn_id: &Option<String>,
    pending_approval_count: usize,
    pending_user_inputs: &[PendingUserInputRequest],
) -> ThreadSummaryStatus {
    if active_turn_id.is_some() || pending_approval_count > 0 || !pending_user_inputs.is_empty() {
        ThreadSummaryStatus::Active
    } else {
        match existing {
            ThreadSummaryStatus::SystemError => ThreadSummaryStatus::SystemError,
            ThreadSummaryStatus::NotLoaded => ThreadSummaryStatus::Idle,
            ThreadSummaryStatus::Idle | ThreadSummaryStatus::Active => ThreadSummaryStatus::Idle,
        }
    }
}

fn active_turn_id_from_ipc_conversation_state(
    conversation_state: &serde_json::Value,
) -> Option<String> {
    let turns = conversation_state.get("turns")?.as_array()?;
    turns
        .iter()
        .enumerate()
        .rev()
        .find_map(|(turn_index, turn)| {
            (turn.get("status").and_then(serde_json::Value::as_str) == Some("inProgress")).then(
                || {
                    turn.get("turnId")
                        .and_then(serde_json::Value::as_str)
                        .map(ToOwned::to_owned)
                        .unwrap_or_else(|| format!("ipc-turn-{turn_index}"))
                },
            )
        })
}

fn updated_at_from_ipc_conversation_state(conversation_state: &serde_json::Value) -> Option<i64> {
    match conversation_state.get("updatedAt") {
        Some(serde_json::Value::Number(number)) => number.as_i64(),
        Some(serde_json::Value::String(text)) => text.parse().ok(),
        _ => None,
    }
}

fn project_incremental_turn(
    conversation_state: &serde_json::Value,
    turn_index: usize,
) -> Result<Option<IncrementalProjectedTurn>, String> {
    let Some(raw_turn) = conversation_state
        .get("turns")
        .and_then(serde_json::Value::as_array)
        .and_then(|turns| turns.get(turn_index))
    else {
        return Ok(None);
    };

    let turn = project_conversation_turn(raw_turn, turn_index)
        .map_err(|error| format!("project turn {turn_index}: {error}"))?;
    let items = turn
        .items
        .iter()
        .filter_map(|item| {
            crate::conversation::hydrate_thread_item(
                item,
                Some(&turn.id),
                Some(turn_index),
                &Default::default(),
            )
        })
        .collect();

    Ok(Some(IncrementalProjectedTurn { turn_index, items }))
}

fn replace_items_for_turn(
    thread: &mut ThreadSnapshot,
    turn_index: usize,
    items: Vec<crate::conversation_uniffi::HydratedConversationItem>,
) {
    let insertion_index = thread
        .items
        .iter()
        .position(|item| item.source_turn_index == Some(turn_index as u32))
        .unwrap_or_else(|| {
            thread
                .items
                .iter()
                .position(|item| {
                    item.source_turn_index
                        .is_some_and(|index| index > turn_index as u32)
                })
                .unwrap_or(thread.items.len())
        });

    thread
        .items
        .retain(|item| item.source_turn_index != Some(turn_index as u32));

    let mut insertion_index = insertion_index.min(thread.items.len());
    for item in items {
        thread.items.insert(insertion_index, item);
        insertion_index += 1;
    }
}

fn appended_text_delta(existing: &str, projected: &str) -> Option<String> {
    projected
        .starts_with(existing)
        .then(|| projected[existing.len()..].to_string())
}

fn appended_optional_text_delta(
    existing: &Option<String>,
    projected: &Option<String>,
) -> Option<String> {
    match (existing.as_deref(), projected.as_deref()) {
        (None, None) => Some(String::new()),
        (None, Some(projected)) => Some(projected.to_string()),
        (Some(existing), Some(projected)) => appended_text_delta(existing, projected),
        (Some(_), None) => None,
    }
}

fn appended_reasoning_delta(existing: &[String], projected: &[String]) -> Option<String> {
    match (existing, projected) {
        ([], []) => Some(String::new()),
        ([], [first]) => Some(first.clone()),
        ([..], [..]) if existing == projected => Some(String::new()),
        ([existing_last], [projected_last]) => appended_text_delta(existing_last, projected_last),
        _ if existing.len() == projected.len() && !existing.is_empty() => {
            let prefix_len = existing.len() - 1;
            if existing[..prefix_len] != projected[..prefix_len] {
                return None;
            }
            appended_text_delta(
                existing[prefix_len].as_str(),
                projected[prefix_len].as_str(),
            )
        }
        _ => None,
    }
}

fn diff_incremental_projected_item(
    existing: &crate::conversation_uniffi::HydratedConversationItem,
    projected: &crate::conversation_uniffi::HydratedConversationItem,
) -> Option<Vec<IncrementalThreadEvent>> {
    use crate::conversation_uniffi::HydratedConversationItemContent;

    if existing.id != projected.id
        || existing.source_turn_id != projected.source_turn_id
        || existing.source_turn_index != projected.source_turn_index
        || existing.timestamp != projected.timestamp
        || existing.is_from_user_turn_boundary != projected.is_from_user_turn_boundary
    {
        return None;
    }

    match (&existing.content, &projected.content) {
        (
            HydratedConversationItemContent::Assistant(existing_data),
            HydratedConversationItemContent::Assistant(projected_data),
        ) => {
            if existing_data.agent_nickname != projected_data.agent_nickname
                || existing_data.agent_role != projected_data.agent_role
                || existing_data.phase != projected_data.phase
            {
                return None;
            }
            let delta =
                appended_text_delta(existing_data.text.as_str(), projected_data.text.as_str())?;
            Some(if delta.is_empty() {
                Vec::new()
            } else {
                vec![IncrementalThreadEvent::Streaming(
                    IncrementalStreamingDelta {
                        item_id: existing.id.clone(),
                        kind: ThreadStreamingDeltaKind::AssistantText,
                        text: delta,
                    },
                )]
            })
        }
        (
            HydratedConversationItemContent::Reasoning(existing_data),
            HydratedConversationItemContent::Reasoning(projected_data),
        ) => {
            if existing_data.summary != projected_data.summary {
                return None;
            }
            let delta = appended_reasoning_delta(&existing_data.content, &projected_data.content)?;
            Some(if delta.is_empty() {
                Vec::new()
            } else {
                vec![IncrementalThreadEvent::Streaming(
                    IncrementalStreamingDelta {
                        item_id: existing.id.clone(),
                        kind: ThreadStreamingDeltaKind::ReasoningText,
                        text: delta,
                    },
                )]
            })
        }
        (
            HydratedConversationItemContent::ProposedPlan(existing_data),
            HydratedConversationItemContent::ProposedPlan(projected_data),
        ) => {
            let delta = appended_text_delta(
                existing_data.content.as_str(),
                projected_data.content.as_str(),
            )?;
            Some(if delta.is_empty() {
                Vec::new()
            } else {
                vec![IncrementalThreadEvent::Streaming(
                    IncrementalStreamingDelta {
                        item_id: existing.id.clone(),
                        kind: ThreadStreamingDeltaKind::PlanText,
                        text: delta,
                    },
                )]
            })
        }
        (
            HydratedConversationItemContent::CommandExecution(existing_data),
            HydratedConversationItemContent::CommandExecution(projected_data),
        ) => {
            if existing_data.command != projected_data.command
                || existing_data.cwd != projected_data.cwd
                || existing_data.actions != projected_data.actions
            {
                return None;
            }
            let delta =
                appended_optional_text_delta(&existing_data.output, &projected_data.output)?;
            let mut events = Vec::new();
            if !delta.is_empty() {
                events.push(IncrementalThreadEvent::Streaming(
                    IncrementalStreamingDelta {
                        item_id: existing.id.clone(),
                        kind: ThreadStreamingDeltaKind::CommandOutput,
                        text: delta,
                    },
                ));
            }
            if existing_data.status != projected_data.status
                || existing_data.exit_code != projected_data.exit_code
                || existing_data.duration_ms != projected_data.duration_ms
                || existing_data.process_id != projected_data.process_id
            {
                events.push(IncrementalThreadEvent::CommandExecutionUpdated(
                    IncrementalCommandExecutionUpdate {
                        item_id: existing.id.clone(),
                        status: projected_data.status.clone(),
                        exit_code: projected_data.exit_code,
                        duration_ms: projected_data.duration_ms,
                        process_id: projected_data.process_id.clone(),
                    },
                ));
            }
            Some(events)
        }
        (
            HydratedConversationItemContent::McpToolCall(existing_data),
            HydratedConversationItemContent::McpToolCall(projected_data),
        ) => {
            if existing_data.server != projected_data.server
                || existing_data.tool != projected_data.tool
                || existing_data.status != projected_data.status
                || existing_data.duration_ms != projected_data.duration_ms
                || existing_data.arguments_json != projected_data.arguments_json
                || existing_data.content_summary != projected_data.content_summary
                || existing_data.structured_content_json != projected_data.structured_content_json
                || existing_data.raw_output_json != projected_data.raw_output_json
                || existing_data.error_message != projected_data.error_message
            {
                return None;
            }
            if !projected_data
                .progress_messages
                .starts_with(&existing_data.progress_messages)
            {
                return None;
            }

            let appended =
                &projected_data.progress_messages[existing_data.progress_messages.len()..];
            if appended.iter().any(|message| message.trim().is_empty()) {
                return None;
            }

            Some(
                appended
                    .iter()
                    .map(|message| {
                        IncrementalThreadEvent::Streaming(IncrementalStreamingDelta {
                            item_id: existing.id.clone(),
                            kind: ThreadStreamingDeltaKind::McpProgress,
                            text: message.clone(),
                        })
                    })
                    .collect(),
            )
        }
        _ if existing.content == projected.content => Some(Vec::new()),
        _ => None,
    }
}

fn diff_incremental_projected_turn(
    existing_thread: &ThreadSnapshot,
    projected_turn: IncrementalProjectedTurn,
) -> IncrementalTurnMutation {
    let existing_items = existing_thread
        .items
        .iter()
        .filter(|item| item.source_turn_index == Some(projected_turn.turn_index as u32))
        .collect::<Vec<_>>();

    if existing_items.len() > projected_turn.items.len() {
        return IncrementalTurnMutation::Replace(projected_turn);
    }

    let mut events = Vec::new();
    for (existing_item, projected_item) in existing_items.iter().zip(projected_turn.items.iter()) {
        let Some(mut item_events) = diff_incremental_projected_item(existing_item, projected_item)
        else {
            return IncrementalTurnMutation::Replace(projected_turn);
        };
        events.append(&mut item_events);
    }

    if projected_turn.items.len() > existing_items.len() {
        for projected_item in projected_turn.items.iter().skip(existing_items.len()) {
            events.push(IncrementalThreadEvent::ItemUpsert(projected_item.clone()));
        }
    }

    if events.is_empty() {
        IncrementalTurnMutation::Unchanged
    } else {
        IncrementalTurnMutation::Patched {
            projected_turn,
            events,
        }
    }
}

fn apply_incremental_thread_event(
    thread: &mut ThreadSnapshot,
    event: &IncrementalThreadEvent,
) -> bool {
    use crate::conversation_uniffi::HydratedConversationItemContent;

    match event {
        IncrementalThreadEvent::Streaming(delta) => {
            let Some(item) = thread
                .items
                .iter_mut()
                .find(|item| item.id == delta.item_id)
            else {
                return false;
            };

            match (&mut item.content, &delta.kind) {
                (
                    HydratedConversationItemContent::Assistant(data),
                    ThreadStreamingDeltaKind::AssistantText,
                ) => {
                    data.text.push_str(delta.text.as_str());
                    true
                }
                (
                    HydratedConversationItemContent::Reasoning(data),
                    ThreadStreamingDeltaKind::ReasoningText,
                ) => {
                    if let Some(last) = data.content.last_mut() {
                        last.push_str(delta.text.as_str());
                    } else {
                        data.content.push(delta.text.clone());
                    }
                    true
                }
                (
                    HydratedConversationItemContent::ProposedPlan(data),
                    ThreadStreamingDeltaKind::PlanText,
                ) => {
                    data.content.push_str(delta.text.as_str());
                    true
                }
                (
                    HydratedConversationItemContent::CommandExecution(data),
                    ThreadStreamingDeltaKind::CommandOutput,
                ) => {
                    data.output
                        .get_or_insert_with(String::new)
                        .push_str(delta.text.as_str());
                    true
                }
                (
                    HydratedConversationItemContent::McpToolCall(data),
                    ThreadStreamingDeltaKind::McpProgress,
                ) => {
                    if !delta.text.trim().is_empty() {
                        data.progress_messages.push(delta.text.clone());
                    }
                    true
                }
                _ => false,
            }
        }
        IncrementalThreadEvent::CommandExecutionUpdated(update) => {
            let Some(item) = thread
                .items
                .iter_mut()
                .find(|item| item.id == update.item_id)
            else {
                return false;
            };
            let HydratedConversationItemContent::CommandExecution(data) = &mut item.content else {
                return false;
            };
            if update.status != AppOperationStatus::Unknown {
                data.status = update.status.clone();
            }
            data.exit_code = update.exit_code;
            data.duration_ms = update.duration_ms;
            data.process_id = update.process_id.clone();
            true
        }
        IncrementalThreadEvent::ItemUpsert(item) => {
            if let Some(existing) = thread
                .items
                .iter_mut()
                .find(|existing| existing.id == item.id)
            {
                *existing = item.clone();
            } else {
                thread.items.push(item.clone());
            }
            true
        }
    }
}

fn try_apply_incremental_ipc_patch_burst(
    app_store: &AppStoreReducer,
    server_id: &str,
    thread_id: &str,
    conversation_state: &serde_json::Value,
    summary: &IncrementalIpcPatchSummary,
) -> Result<bool, String> {
    let key = ThreadKey {
        server_id: server_id.to_string(),
        thread_id: thread_id.to_string(),
    };
    let snapshot = app_store.snapshot();
    let Some(existing_thread) = snapshot.threads.get(&key).cloned() else {
        return Ok(false);
    };

    let mut pending_approvals = snapshot
        .pending_approvals
        .iter()
        .filter(|approval| {
            approval.server_id == server_id && approval.thread_id.as_deref() == Some(thread_id)
        })
        .cloned()
        .map(|approval| PendingApprovalWithSeed {
            seed: app_store
                .pending_approval_seed(&approval.server_id, &approval.id)
                .unwrap_or(PendingApprovalSeed {
                    request_id: fallback_server_request_id(&approval.id),
                    raw_params: seed_ipc_approval_request_params(&approval)
                        .unwrap_or(serde_json::Value::Null),
                }),
            approval,
        })
        .collect::<Vec<_>>();
    let mut pending_user_inputs = snapshot
        .pending_user_inputs
        .iter()
        .filter(|request| request.server_id == server_id && request.thread_id == thread_id)
        .cloned()
        .collect::<Vec<_>>();

    if summary.requests_changed {
        let projected = project_conversation_request_state(conversation_state)
            .map_err(|error| format!("project request state: {error}"))?;
        pending_approvals = projected
            .pending_approvals
            .into_iter()
            .map(|approval| pending_approval_from_ipc_projection(server_id, approval))
            .collect();
        pending_user_inputs = projected
            .pending_user_inputs
            .into_iter()
            .map(|request| pending_user_input_from_ipc_projection(server_id, request))
            .collect();
    }

    let mut projected_turns = Vec::with_capacity(summary.affected_turn_indices.len());
    for &turn_index in &summary.affected_turn_indices {
        if let Some(projected_turn) = project_incremental_turn(conversation_state, turn_index)? {
            projected_turns.push(projected_turn);
        }
    }

    let turn_mutations = projected_turns
        .into_iter()
        .map(|projected_turn| diff_incremental_projected_turn(&existing_thread, projected_turn))
        .collect::<Vec<_>>();

    let active_turn_id = if summary.affected_turn_indices.is_empty() && !summary.requests_changed {
        existing_thread.active_turn_id.clone()
    } else {
        active_turn_id_from_ipc_conversation_state(conversation_state)
    };
    let updated_at = if summary.updated_at_changed {
        updated_at_from_ipc_conversation_state(conversation_state)
    } else {
        existing_thread.info.updated_at
    };
    let latest_model = if summary.latest_model_changed {
        conversation_state
            .get("latestModel")
            .and_then(serde_json::Value::as_str)
            .map(ToOwned::to_owned)
    } else {
        existing_thread.model.clone()
    };
    let latest_reasoning_effort = if summary.latest_reasoning_effort_changed {
        conversation_state
            .get("latestReasoningEffort")
            .and_then(serde_json::Value::as_str)
            .map(ToOwned::to_owned)
    } else {
        existing_thread.reasoning_effort.clone()
    };
    let thread_status = incremental_ipc_thread_status(
        existing_thread.info.status.clone(),
        &active_turn_id,
        pending_approvals.len(),
        &pending_user_inputs,
    );
    let meta_changed = existing_thread.active_turn_id != active_turn_id
        || existing_thread.info.status != thread_status
        || existing_thread.info.updated_at != updated_at
        || existing_thread.model != latest_model
        || existing_thread.reasoning_effort != latest_reasoning_effort;

    let mutation = IncrementalThreadMutation {
        turn_mutations,
        active_turn_id,
        updated_at,
        latest_model,
        latest_reasoning_effort,
        thread_status,
    };

    let Some(mutation_result) = app_store.mutate_thread_with_result(&key, |thread| {
        let mut emitted_deltas = Vec::new();
        let mut emitted_command_updates = Vec::new();
        let mut emitted_item_upserts = Vec::new();
        let mut requires_thread_upsert = false;

        for turn_mutation in &mutation.turn_mutations {
            match turn_mutation {
                IncrementalTurnMutation::Unchanged => {}
                IncrementalTurnMutation::Replace(projected_turn) => {
                    replace_items_for_turn(
                        thread,
                        projected_turn.turn_index,
                        projected_turn.items.clone(),
                    );
                    requires_thread_upsert = true;
                }
                IncrementalTurnMutation::Patched {
                    projected_turn,
                    events,
                } => {
                    let mut applied = true;
                    for event in events {
                        if !apply_incremental_thread_event(thread, event) {
                            applied = false;
                            break;
                        }
                    }

                    if applied {
                        for event in events {
                            match event {
                                IncrementalThreadEvent::Streaming(delta) => {
                                    emitted_deltas.push(delta.clone());
                                }
                                IncrementalThreadEvent::CommandExecutionUpdated(update) => {
                                    emitted_command_updates.push(update.clone());
                                }
                                IncrementalThreadEvent::ItemUpsert(item) => {
                                    emitted_item_upserts.push(item.clone());
                                }
                            }
                        }
                    } else {
                        replace_items_for_turn(
                            thread,
                            projected_turn.turn_index,
                            projected_turn.items.clone(),
                        );
                        requires_thread_upsert = true;
                    }
                }
            }
        }

        thread.active_turn_id = mutation.active_turn_id.clone();
        thread.info.status = mutation.thread_status.clone();
        thread.info.updated_at = mutation.updated_at;
        thread.model = mutation.latest_model.clone();
        thread.reasoning_effort = mutation.latest_reasoning_effort.clone();

        IncrementalMutationResult {
            requires_thread_upsert,
            emitted_deltas,
            emitted_command_updates,
            emitted_item_upserts,
            emit_thread_state_update: meta_changed,
        }
    }) else {
        return Ok(false);
    };

    if should_emit_thread_upsert_for_incremental_patch_burst(summary, &mutation_result) {
        app_store.emit_thread_upsert(&key);
    } else {
        if mutation_result.emit_thread_state_update {
            app_store.emit_thread_state_update(&key);
        }
        for item in mutation_result.emitted_item_upserts {
            app_store.emit_thread_item_upsert(&key, &item);
        }
        for update in mutation_result.emitted_command_updates {
            app_store.emit_thread_command_execution_updated(
                &key,
                &update.item_id,
                update.status,
                update.exit_code,
                update.duration_ms,
                update.process_id,
            );
        }
        for delta in mutation_result.emitted_deltas {
            app_store.emit_thread_streaming_delta(&key, &delta.item_id, delta.kind, &delta.text);
        }
    }

    if summary.requests_changed {
        sync_ipc_thread_requests(
            app_store,
            server_id,
            thread_id,
            pending_approvals,
            pending_user_inputs,
        );
    }

    Ok(true)
}

#[derive(Debug)]
enum StreamHandleError {
    NoCachedState,
    DeserializeFailed(String),
    PatchFailed(String),
}

enum PendingIpcStreamRecovery {
    Recovered {
        thread_id: String,
        conversation_state: serde_json::Value,
    },
    Failed {
        thread_id: String,
        error: String,
    },
}

fn handle_ipc_thread_stream_event(
    stream_cache: &mut HashMap<String, serde_json::Value>,
    pending_thread_events: &mut HashMap<String, VecDeque<ThreadStreamStateChangedParams>>,
    recovering_threads: &mut HashSet<String>,
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: &str,
    params: ThreadStreamStateChangedParams,
    recovery_tx: &mpsc::UnboundedSender<PendingIpcStreamRecovery>,
) {
    let thread_id = params.conversation_id.clone();
    if recovering_threads.contains(&thread_id) {
        let queued_events = {
            let queue = pending_thread_events.entry(thread_id.clone()).or_default();
            queue.push_back(params);
            queue.len()
        };
        trace!(
            "IPC: queued stream event during cache recovery server={} thread={} queued_events={}",
            server_id, thread_id, queued_events
        );
        return;
    }

    match handle_stream_state_change(stream_cache, &app_store, server_id, &params) {
        Ok(()) => {}
        Err(StreamHandleError::NoCachedState) => {
            let mut recovered_from_local_state = false;
            if seed_ipc_stream_cache_from_existing_app_state(
                &app_store,
                stream_cache,
                server_id,
                &thread_id,
            ) {
                match handle_stream_state_change(stream_cache, &app_store, server_id, &params) {
                    Ok(()) => {
                        debug!(
                            "IPC: recovered cached state for thread={} from local app state",
                            thread_id
                        );
                        recovered_from_local_state = true;
                    }
                    Err(error) => {
                        debug!(
                            "IPC: local app-state seed failed for thread {}: {:?}",
                            thread_id, error
                        );
                        stream_cache.remove(&thread_id);
                    }
                }
            }

            if !recovered_from_local_state {
                queue_ipc_thread_stream_recovery(
                    pending_thread_events,
                    recovering_threads,
                    session,
                    app_store,
                    server_id,
                    params,
                    "missing cached state",
                    recovery_tx,
                );
            }
        }
        Err(StreamHandleError::DeserializeFailed(msg)) => {
            warn!("IPC: deserialize failed for thread={}: {}", thread_id, msg);
            stream_cache.remove(&thread_id);
            queue_ipc_thread_stream_recovery(
                pending_thread_events,
                recovering_threads,
                session,
                app_store,
                server_id,
                params,
                "deserialize failed",
                recovery_tx,
            );
        }
        Err(StreamHandleError::PatchFailed(msg)) => {
            warn!("IPC: patch failed for thread={}: {}", thread_id, msg);
            stream_cache.remove(&thread_id);
            queue_ipc_thread_stream_recovery(
                pending_thread_events,
                recovering_threads,
                session,
                app_store,
                server_id,
                params,
                "patch failed",
                recovery_tx,
            );
        }
    }
}

fn queue_ipc_thread_stream_recovery(
    pending_thread_events: &mut HashMap<String, VecDeque<ThreadStreamStateChangedParams>>,
    recovering_threads: &mut HashSet<String>,
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: &str,
    params: ThreadStreamStateChangedParams,
    reason: &str,
    recovery_tx: &mpsc::UnboundedSender<PendingIpcStreamRecovery>,
) {
    let thread_id = params.conversation_id.clone();
    let queued_events = {
        let queue = pending_thread_events.entry(thread_id.clone()).or_default();
        queue.push_back(params);
        queue.len()
    };

    if !recovering_threads.insert(thread_id.clone()) {
        return;
    }

    debug!(
        "IPC: starting async cache recovery server={} thread={} reason={} queued_events={}",
        server_id, thread_id, reason, queued_events
    );
    spawn_ipc_thread_stream_recovery(
        session,
        app_store,
        server_id.to_string(),
        thread_id,
        recovery_tx.clone(),
    );
}

fn spawn_ipc_thread_stream_recovery(
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: String,
    thread_id: String,
    recovery_tx: mpsc::UnboundedSender<PendingIpcStreamRecovery>,
) {
    MobileClient::spawn_detached(async move {
        let recovery = match recover_ipc_stream_cache_from_app_server(
            session, app_store, &server_id, &thread_id,
        )
        .await
        {
            Ok(conversation_state) => PendingIpcStreamRecovery::Recovered {
                thread_id,
                conversation_state,
            },
            Err(error) => PendingIpcStreamRecovery::Failed {
                thread_id,
                error: error.to_string(),
            },
        };
        let _ = recovery_tx.send(recovery);
    });
}

fn drain_pending_ipc_thread_events(
    thread_id: &str,
    stream_cache: &mut HashMap<String, serde_json::Value>,
    pending_thread_events: &mut HashMap<String, VecDeque<ThreadStreamStateChangedParams>>,
    recovering_threads: &mut HashSet<String>,
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: &str,
    recovery_tx: &mpsc::UnboundedSender<PendingIpcStreamRecovery>,
) {
    loop {
        let maybe_params = pending_thread_events
            .get_mut(thread_id)
            .and_then(VecDeque::pop_front);
        let Some(params) = maybe_params else {
            pending_thread_events.remove(thread_id);
            break;
        };

        if pending_thread_events
            .get(thread_id)
            .is_some_and(VecDeque::is_empty)
        {
            pending_thread_events.remove(thread_id);
        }

        handle_ipc_thread_stream_event(
            stream_cache,
            pending_thread_events,
            recovering_threads,
            Arc::clone(&session),
            Arc::clone(&app_store),
            server_id,
            params,
            recovery_tx,
        );

        if recovering_threads.contains(thread_id) {
            break;
        }
    }
}

fn handle_stream_state_change(
    cache: &mut HashMap<String, serde_json::Value>,
    app_store: &AppStoreReducer,
    server_id: &str,
    params: &ThreadStreamStateChangedParams,
) -> Result<(), StreamHandleError> {
    let mut cached_state = cache.remove(&params.conversation_id);
    apply_stream_change_to_conversation_state(&mut cached_state, params).map_err(|error| {
        match error {
            ConversationStreamApplyError::NoCachedState => StreamHandleError::NoCachedState,
            ConversationStreamApplyError::PatchFailed(error) => {
                StreamHandleError::PatchFailed(error.to_string())
            }
        }
    })?;

    let conversation_state = cached_state
        .as_ref()
        .expect("cached state should exist after successful stream apply");

    if let StreamChange::Patches { patches } = &params.change
        && let Some(summary) = summarize_incremental_ipc_patches(patches)
    {
        match try_apply_incremental_ipc_patch_burst(
            app_store,
            server_id,
            &params.conversation_id,
            conversation_state,
            &summary,
        ) {
            Ok(true) => {
                trace!(
                    "IPC: applied incremental patch burst for thread={} turns={:?} requests_changed={}",
                    params.conversation_id, summary.affected_turn_indices, summary.requests_changed
                );
                cache.insert(
                    params.conversation_id.clone(),
                    cached_state.expect("cached state should exist after successful stream apply"),
                );
                return Ok(());
            }
            Ok(false) => {}
            Err(error) => {
                debug!(
                    "IPC: incremental patch burst fallback for thread={}: {}",
                    params.conversation_id, error
                );
            }
        }
    }

    let ThreadProjection {
        mut snapshot,
        pending_approvals,
        pending_user_inputs,
    } = thread_projection_from_conversation_json(
        server_id,
        &params.conversation_id,
        conversation_state,
    )
    .map_err(|e| {
        let preview: String = conversation_state.to_string().chars().take(500).collect();
        StreamHandleError::DeserializeFailed(format!("{e}; json preview: {preview}"))
    })?;

    let key = ThreadKey {
        server_id: server_id.to_string(),
        thread_id: params.conversation_id.clone(),
    };
    if let Some(existing) = app_store.snapshot().threads.get(&key) {
        copy_thread_runtime_fields(existing, &mut snapshot);
    }

    app_store.upsert_thread_snapshot(snapshot);
    sync_ipc_thread_requests(
        app_store,
        server_id,
        &params.conversation_id,
        pending_approvals,
        pending_user_inputs,
    );
    cache.insert(
        params.conversation_id.clone(),
        cached_state.expect("cached state should exist after successful stream apply"),
    );
    Ok(())
}

async fn send_ipc_approval_response(
    ipc_client: &IpcClient,
    approval: &PendingApproval,
    thread_id: &str,
    decision: ApprovalDecisionValue,
) -> Result<bool, IpcError> {
    tracing::info!(
        "IPC out: approval_response thread={} request_id={} kind={:?} decision={:?}",
        thread_id,
        approval.id,
        approval.kind,
        decision
    );
    match approval.kind {
        crate::types::ApprovalKind::Command => {
            ipc_client
                .command_approval_decision(ThreadFollowerCommandApprovalDecisionParams {
                    conversation_id: thread_id.to_string(),
                    request_id: approval.id.clone(),
                    decision: match decision {
                        ApprovalDecisionValue::Accept => CommandExecutionApprovalDecision::Accept,
                        ApprovalDecisionValue::AcceptForSession => {
                            CommandExecutionApprovalDecision::AcceptForSession
                        }
                        ApprovalDecisionValue::Decline => CommandExecutionApprovalDecision::Decline,
                        ApprovalDecisionValue::Cancel => CommandExecutionApprovalDecision::Cancel,
                    },
                })
                .await?;
            Ok(true)
        }
        crate::types::ApprovalKind::FileChange => {
            ipc_client
                .file_approval_decision(ThreadFollowerFileApprovalDecisionParams {
                    conversation_id: thread_id.to_string(),
                    request_id: approval.id.clone(),
                    decision: match decision {
                        ApprovalDecisionValue::Accept => FileChangeApprovalDecision::Accept,
                        ApprovalDecisionValue::AcceptForSession => {
                            FileChangeApprovalDecision::AcceptForSession
                        }
                        ApprovalDecisionValue::Decline => FileChangeApprovalDecision::Decline,
                        ApprovalDecisionValue::Cancel => FileChangeApprovalDecision::Cancel,
                    },
                })
                .await?;
            Ok(true)
        }
        crate::types::ApprovalKind::Permissions | crate::types::ApprovalKind::McpElicitation => {
            Ok(false)
        }
    }
}

async fn send_ipc_user_input_response(
    ipc_client: &IpcClient,
    thread_id: &str,
    request_id: &str,
    answers: Vec<PendingUserInputAnswer>,
) -> Result<bool, IpcError> {
    let response = upstream::ToolRequestUserInputResponse {
        answers: answers
            .into_iter()
            .map(|answer| {
                (
                    answer.question_id,
                    upstream::ToolRequestUserInputAnswer {
                        answers: answer.answers,
                    },
                )
            })
            .collect::<HashMap<_, _>>(),
    };
    tracing::info!(
        "IPC out: submit_user_input thread={} request_id={}",
        thread_id,
        request_id
    );
    ipc_client
        .submit_user_input(ThreadFollowerSubmitUserInputParams {
            conversation_id: thread_id.to_string(),
            request_id: request_id.to_string(),
            response,
        })
        .await?;
    Ok(true)
}

fn approval_response_json(
    approval: &PendingApproval,
    seed: Option<&PendingApprovalSeed>,
    decision: ApprovalDecisionValue,
) -> Result<serde_json::Value, RpcError> {
    match approval.kind {
        crate::types::ApprovalKind::Command => {
            serde_json::to_value(upstream::CommandExecutionRequestApprovalResponse {
                decision: match decision {
                    ApprovalDecisionValue::Accept => {
                        upstream::CommandExecutionApprovalDecision::Accept
                    }
                    ApprovalDecisionValue::AcceptForSession => {
                        upstream::CommandExecutionApprovalDecision::AcceptForSession
                    }
                    ApprovalDecisionValue::Decline => {
                        upstream::CommandExecutionApprovalDecision::Decline
                    }
                    ApprovalDecisionValue::Cancel => {
                        upstream::CommandExecutionApprovalDecision::Cancel
                    }
                },
            })
        }
        crate::types::ApprovalKind::FileChange => {
            serde_json::to_value(upstream::FileChangeRequestApprovalResponse {
                decision: match decision {
                    ApprovalDecisionValue::Accept => upstream::FileChangeApprovalDecision::Accept,
                    ApprovalDecisionValue::AcceptForSession => {
                        upstream::FileChangeApprovalDecision::AcceptForSession
                    }
                    ApprovalDecisionValue::Decline => upstream::FileChangeApprovalDecision::Decline,
                    ApprovalDecisionValue::Cancel => upstream::FileChangeApprovalDecision::Cancel,
                },
            })
        }
        crate::types::ApprovalKind::Permissions | crate::types::ApprovalKind::McpElicitation => {
            let requested_permissions = seed
                .map(|seed| seed.raw_params.clone())
                .and_then(|value: serde_json::Value| value.get("permissions").cloned())
                .and_then(|value| {
                    serde_json::from_value::<upstream::GrantedPermissionProfile>(value).ok()
                })
                .unwrap_or(upstream::GrantedPermissionProfile {
                    network: None,
                    file_system: None,
                });
            serde_json::to_value(upstream::PermissionsRequestApprovalResponse {
                permissions: match decision {
                    ApprovalDecisionValue::Accept | ApprovalDecisionValue::AcceptForSession => {
                        requested_permissions
                    }
                    ApprovalDecisionValue::Decline | ApprovalDecisionValue::Cancel => {
                        upstream::GrantedPermissionProfile {
                            network: None,
                            file_system: None,
                        }
                    }
                },
                scope: match decision {
                    ApprovalDecisionValue::AcceptForSession => {
                        upstream::PermissionGrantScope::Session
                    }
                    _ => upstream::PermissionGrantScope::Turn,
                },
            })
        }
    }
    .map_err(|e| RpcError::Deserialization(format!("serialize approval response: {e}")))
}

fn approval_request_id(
    approval: &PendingApproval,
    seed: Option<&PendingApprovalSeed>,
) -> upstream::RequestId {
    seed.map(|seed| seed.request_id.clone())
        .unwrap_or_else(|| fallback_server_request_id(&approval.id))
}

fn fallback_server_request_id(id: &str) -> upstream::RequestId {
    id.parse::<i64>()
        .map(upstream::RequestId::Integer)
        .unwrap_or_else(|_| upstream::RequestId::String(id.to_string()))
}

fn server_request_id_json(id: upstream::RequestId) -> serde_json::Value {
    match id {
        upstream::RequestId::Integer(value) => serde_json::Value::Number(value.into()),
        upstream::RequestId::String(value) => serde_json::Value::String(value),
    }
}

#[cfg(test)]
mod mobile_client_tests {
    use super::*;
    use crate::conversation_uniffi::HydratedConversationItemContent;
    use crate::store::AppStoreUpdateRecord;
    use crate::store::updates::ThreadStreamingDeltaKind;
    use crate::types::ThreadSummaryStatus;
    use crate::types::{PendingUserInputOption, PendingUserInputQuestion};
    use serde_json::json;
    use std::path::PathBuf;
    use tokio::sync::broadcast::error::TryRecvError;

    fn drain_app_updates(
        rx: &mut tokio::sync::broadcast::Receiver<AppStoreUpdateRecord>,
    ) -> Vec<AppStoreUpdateRecord> {
        let mut updates = Vec::new();
        loop {
            match rx.try_recv() {
                Ok(update) => updates.push(update),
                Err(TryRecvError::Empty) | Err(TryRecvError::Closed) => break,
                Err(TryRecvError::Lagged(_)) => continue,
            }
        }
        updates
    }

    fn make_thread_info(id: &str) -> ThreadInfo {
        ThreadInfo {
            id: id.to_string(),
            title: Some("Thread".to_string()),
            model: None,
            status: ThreadSummaryStatus::Active,
            preview: Some("preview".to_string()),
            cwd: Some("/tmp".to_string()),
            path: Some("/tmp".to_string()),
            model_provider: Some("openai".to_string()),
            agent_nickname: None,
            agent_role: None,
            parent_thread_id: None,
            agent_status: None,
            created_at: Some(1),
            updated_at: Some(2),
        }
    }

    fn make_user_input_request(question: PendingUserInputQuestion) -> PendingUserInputRequest {
        PendingUserInputRequest {
            id: "req-1".to_string(),
            server_id: "srv".to_string(),
            thread_id: "thread".to_string(),
            turn_id: "turn-1".to_string(),
            item_id: "item-1".to_string(),
            questions: vec![question],
            requester_agent_nickname: None,
            requester_agent_role: None,
        }
    }

    #[test]
    fn reasoning_effort_parsing_accepts_known_values() {
        assert_eq!(
            reasoning_effort_from_string("low"),
            Some(crate::types::ReasoningEffort::Low)
        );
        assert_eq!(
            reasoning_effort_from_string("MEDIUM"),
            Some(crate::types::ReasoningEffort::Medium)
        );
        assert_eq!(
            reasoning_effort_from_string(" high "),
            Some(crate::types::ReasoningEffort::High)
        );
        assert_eq!(reasoning_effort_from_string(""), None);
    }

    #[test]
    fn normalize_pending_user_input_wraps_freeform_answers_as_notes() {
        let request = make_user_input_request(PendingUserInputQuestion {
            id: "q-1".to_string(),
            header: None,
            question: "Explain the choice".to_string(),
            is_other_allowed: true,
            is_secret: false,
            options: Vec::new(),
        });

        let normalized = normalize_pending_user_input_answers(
            &request,
            &[PendingUserInputAnswer {
                question_id: "q-1".to_string(),
                answers: vec!["Need to update the reducer".to_string()],
            }],
        );

        assert_eq!(
            normalized,
            vec![PendingUserInputAnswer {
                question_id: "q-1".to_string(),
                answers: vec!["user_note: Need to update the reducer".to_string()],
            }]
        );
    }

    #[test]
    fn normalize_pending_user_input_injects_other_option_for_custom_answers() {
        let request = make_user_input_request(PendingUserInputQuestion {
            id: "q-1".to_string(),
            header: None,
            question: "Choose one".to_string(),
            is_other_allowed: true,
            is_secret: false,
            options: vec![PendingUserInputOption {
                label: "Option A".to_string(),
                description: None,
            }],
        });

        let normalized = normalize_pending_user_input_answers(
            &request,
            &[PendingUserInputAnswer {
                question_id: "q-1".to_string(),
                answers: vec!["My custom answer".to_string()],
            }],
        );

        assert_eq!(
            normalized,
            vec![PendingUserInputAnswer {
                question_id: "q-1".to_string(),
                answers: vec![
                    "None of the above".to_string(),
                    "user_note: My custom answer".to_string(),
                ],
            }]
        );
    }

    #[test]
    fn ipc_pending_user_input_submission_id_uses_request_id() {
        let request = make_user_input_request(PendingUserInputQuestion {
            id: "q-1".to_string(),
            header: None,
            question: "Choose one".to_string(),
            is_other_allowed: false,
            is_secret: false,
            options: Vec::new(),
        });

        assert_eq!(ipc_pending_user_input_submission_id(&request), "req-1");
    }

    #[test]
    fn copy_thread_runtime_fields_preserves_existing_runtime_state() {
        let source = ThreadSnapshot {
            key: ThreadKey {
                server_id: "srv".to_string(),
                thread_id: "thread-1".to_string(),
            },
            info: make_thread_info("thread-1"),
            collaboration_mode: AppModeKind::Plan,
            model: Some("gpt-5".to_string()),
            reasoning_effort: Some("high".to_string()),
            effective_approval_policy: None,
            effective_sandbox_policy: None,
            items: Vec::new(),
            local_overlay_items: Vec::new(),
            queued_follow_ups: vec![AppQueuedFollowUpPreview {
                id: "queued-1".to_string(),
                kind: AppQueuedFollowUpKind::Message,
                text: "follow-up".to_string(),
            }],
            queued_follow_up_drafts: Vec::new(),
            active_turn_id: Some("turn-1".to_string()),
            context_tokens_used: Some(12_345),
            model_context_window: Some(200_000),
            rate_limits: Some(crate::types::RateLimits {
                requests_remaining: Some(10),
                tokens_remaining: Some(20_000),
                reset_at: Some("2026-03-25T12:00:00Z".to_string()),
            }),
            realtime_session_id: Some("rt-1".to_string()),
            active_plan_progress: Some(crate::types::AppPlanProgressSnapshot {
                turn_id: "turn-1".to_string(),
                explanation: Some("Ship plan mode".to_string()),
                plan: vec![crate::types::AppPlanStep {
                    step: "Build parser".to_string(),
                    status: crate::types::AppPlanStepStatus::InProgress,
                }],
            }),
            pending_plan_implementation_turn_id: Some("turn-1".to_string()),
        };
        let mut target = ThreadSnapshot::from_info("srv", make_thread_info("thread-1"));

        copy_thread_runtime_fields(&source, &mut target);

        assert_eq!(target.model.as_deref(), Some("gpt-5"));
        assert_eq!(target.collaboration_mode, AppModeKind::Plan);
        assert_eq!(target.reasoning_effort.as_deref(), Some("high"));
        assert_eq!(target.queued_follow_ups, source.queued_follow_ups);
        assert_eq!(target.active_turn_id, None);
        assert_eq!(target.context_tokens_used, Some(12_345));
        assert_eq!(target.model_context_window, Some(200_000));
        assert_eq!(
            target
                .rate_limits
                .as_ref()
                .and_then(|limits| limits.tokens_remaining),
            Some(20_000)
        );
        assert_eq!(target.realtime_session_id.as_deref(), Some("rt-1"));
        assert_eq!(target.active_plan_progress, source.active_plan_progress);
        assert_eq!(
            target.pending_plan_implementation_turn_id,
            source.pending_plan_implementation_turn_id
        );
    }

    #[test]
    fn copy_thread_runtime_fields_does_not_preserve_effective_permissions() {
        let source = ThreadSnapshot {
            key: ThreadKey {
                server_id: "srv".to_string(),
                thread_id: "thread-1".to_string(),
            },
            info: make_thread_info("thread-1"),
            collaboration_mode: AppModeKind::Default,
            model: None,
            reasoning_effort: None,
            effective_approval_policy: Some(crate::types::AppAskForApproval::Never),
            effective_sandbox_policy: Some(crate::types::AppSandboxPolicy::DangerFullAccess),
            items: Vec::new(),
            local_overlay_items: Vec::new(),
            queued_follow_ups: Vec::new(),
            queued_follow_up_drafts: Vec::new(),
            active_turn_id: None,
            context_tokens_used: None,
            model_context_window: None,
            rate_limits: None,
            realtime_session_id: None,
            active_plan_progress: None,
            pending_plan_implementation_turn_id: None,
        };
        let mut target = ThreadSnapshot::from_info("srv", make_thread_info("thread-1"));

        copy_thread_runtime_fields(&source, &mut target);

        assert_eq!(target.effective_approval_policy, None);
        assert_eq!(target.effective_sandbox_policy, None);
    }

    #[test]
    fn upsert_thread_snapshot_from_thread_read_response_uses_effective_permissions() {
        let reducer = AppStoreReducer::new();
        let response: upstream::ThreadReadResponse = serde_json::from_value(serde_json::json!({
            "thread": {
                "id": "thread-1",
                "preview": "hi",
                "ephemeral": false,
                "modelProvider": "openai",
                "createdAt": 1,
                "updatedAt": 2,
                "status": { "type": "idle" },
                "path": "/tmp/thread",
                "cwd": "/tmp/thread",
                "cliVersion": "1.0.0",
                "source": "cli",
                "agentNickname": null,
                "agentRole": null,
                "gitInfo": null,
                "name": "thread",
                "turns": []
            },
            "approvalPolicy": "never",
            "sandbox": {
                "type": "dangerFullAccess"
            }
        }))
        .expect("thread/read response should deserialize");

        upsert_thread_snapshot_from_app_server_read_response(&reducer, "srv", response)
            .expect("upsert should succeed");

        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let snapshot = reducer
            .snapshot()
            .threads
            .into_iter()
            .find_map(|(thread_key, thread)| (thread_key == key).then_some(thread))
            .expect("thread snapshot should exist");

        assert_eq!(
            snapshot.effective_approval_policy,
            Some(crate::types::AppAskForApproval::Never)
        );
        assert_eq!(
            snapshot.effective_sandbox_policy,
            Some(crate::types::AppSandboxPolicy::DangerFullAccess)
        );
    }

    #[test]
    fn remote_oauth_callback_port_reads_localhost_redirect() {
        let auth_url = "https://auth.openai.com/oauth/authorize?response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=abc";
        assert_eq!(remote_oauth_callback_port(auth_url).unwrap(), 1455);
    }

    #[test]
    fn approval_request_id_prefers_seed_type_for_local_responses() {
        let approval = PendingApproval {
            id: "42".to_string(),
            server_id: "srv".to_string(),
            kind: crate::types::ApprovalKind::Permissions,
            thread_id: Some("thread-1".to_string()),
            turn_id: Some("turn-1".to_string()),
            item_id: Some("item-1".to_string()),
            command: None,
            path: None,
            grant_root: None,
            cwd: None,
            reason: None,
        };
        let seed = PendingApprovalSeed {
            request_id: upstream::RequestId::Integer(42),
            raw_params: json!({}),
        };

        assert_eq!(
            server_request_id_json(approval_request_id(&approval, Some(&seed))),
            json!(42)
        );
    }

    #[test]
    fn approval_request_id_falls_back_to_string_for_non_numeric_ids() {
        let approval = PendingApproval {
            id: "req-42".to_string(),
            server_id: "srv".to_string(),
            kind: crate::types::ApprovalKind::Permissions,
            thread_id: Some("thread-1".to_string()),
            turn_id: Some("turn-1".to_string()),
            item_id: Some("item-1".to_string()),
            command: None,
            path: None,
            grant_root: None,
            cwd: None,
            reason: None,
        };

        assert_eq!(
            server_request_id_json(approval_request_id(&approval, None)),
            json!("req-42")
        );
    }

    #[test]
    fn handle_stream_state_change_streams_patches_and_updates_ipc_request_state() {
        let app_store = AppStoreReducer::new();
        let mut updates = app_store.subscribe();
        let mut cache = HashMap::new();
        let thread_id = "thread-1";
        let server_id = "srv";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };

        let snapshot_params = ThreadStreamStateChangedParams {
            conversation_id: thread_id.to_string(),
            version: 5,
            change: StreamChange::Snapshot {
                conversation_state: json!({
                    "latestModel": "gpt-5.4",
                    "latestReasoningEffort": "medium",
                    "turns": [
                        {
                            "turnId": "turn-1",
                            "status": "inProgress",
                            "params": {
                                "input": [
                                    { "type": "text", "text": "hello", "textElements": [] }
                                ]
                            },
                            "items": [
                                { "id": "assistant-1", "type": "agentMessage", "text": "hel" }
                            ]
                        }
                    ],
                    "requests": [
                        {
                            "id": "approval-1",
                            "method": "item/commandExecution/requestApproval",
                            "params": {
                                "threadId": "thread-1",
                                "turnId": "turn-1",
                                "itemId": "exec-1",
                                "command": "ls",
                                "cwd": "/repo"
                            }
                        }
                    ]
                }),
            },
        };

        handle_stream_state_change(&mut cache, &app_store, server_id, &snapshot_params).unwrap();
        drain_app_updates(&mut updates);

        let snapshot = app_store.snapshot();
        let thread = snapshot.threads.get(&key).unwrap();
        assert_eq!(thread.model.as_deref(), Some("gpt-5.4"));
        assert_eq!(thread.reasoning_effort.as_deref(), Some("medium"));
        assert_eq!(thread.active_turn_id.as_deref(), Some("turn-1"));
        assert_eq!(snapshot.pending_approvals.len(), 1);
        assert_eq!(
            thread.items.iter().find_map(|item| match &item.content {
                HydratedConversationItemContent::Assistant(data) => Some(data.text.as_str()),
                _ => None,
            }),
            Some("hel")
        );

        let text_patch = ThreadStreamStateChangedParams {
            conversation_id: thread_id.to_string(),
            version: 5,
            change: StreamChange::Patches {
                patches: vec![
                    codex_ipc::ImmerPatch {
                        op: codex_ipc::ImmerOp::Replace,
                        path: vec![
                            codex_ipc::ImmerPathSegment::Key("turns".to_string()),
                            codex_ipc::ImmerPathSegment::Index(0),
                            codex_ipc::ImmerPathSegment::Key("items".to_string()),
                            codex_ipc::ImmerPathSegment::Index(0),
                            codex_ipc::ImmerPathSegment::Key("text".to_string()),
                        ],
                        value: Some(json!("hello")),
                    },
                    codex_ipc::ImmerPatch {
                        op: codex_ipc::ImmerOp::Replace,
                        path: vec![codex_ipc::ImmerPathSegment::Key("requests".to_string())],
                        value: Some(json!([])),
                    },
                ],
            },
        };

        handle_stream_state_change(&mut cache, &app_store, server_id, &text_patch).unwrap();

        let emitted = drain_app_updates(&mut updates);
        assert!(emitted.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadStreamingDelta {
                key: emitted_key,
                item_id,
                kind: ThreadStreamingDeltaKind::AssistantText,
                text,
            } if emitted_key == &key && item_id == "assistant-1" && text == "lo"
        )));
        assert!(!emitted.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadUpserted { thread, .. } if thread.key == key
        )));

        let snapshot = app_store.snapshot();
        let thread = snapshot.threads.get(&key).unwrap();
        assert_eq!(thread.active_turn_id.as_deref(), Some("turn-1"));
        assert!(snapshot.pending_approvals.is_empty());
        assert_eq!(
            thread.items.iter().find_map(|item| match &item.content {
                HydratedConversationItemContent::Assistant(data) => Some(data.text.as_str()),
                _ => None,
            }),
            Some("hello")
        );

        let completion_patch = ThreadStreamStateChangedParams {
            conversation_id: thread_id.to_string(),
            version: 5,
            change: StreamChange::Patches {
                patches: vec![codex_ipc::ImmerPatch {
                    op: codex_ipc::ImmerOp::Replace,
                    path: vec![
                        codex_ipc::ImmerPathSegment::Key("turns".to_string()),
                        codex_ipc::ImmerPathSegment::Index(0),
                        codex_ipc::ImmerPathSegment::Key("status".to_string()),
                    ],
                    value: Some(json!("completed")),
                }],
            },
        };

        handle_stream_state_change(&mut cache, &app_store, server_id, &completion_patch).unwrap();

        let completion_updates = drain_app_updates(&mut updates);
        assert!(completion_updates.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadStateUpdated { state, .. } if state.key == key
        )));

        let snapshot = app_store.snapshot();
        let thread = snapshot.threads.get(&key).unwrap();
        assert_eq!(thread.active_turn_id, None);
    }

    #[test]
    fn handle_stream_state_change_accepts_patch_on_thread_read_seeded_cache() {
        let app_store = AppStoreReducer::new();
        let thread_id = "thread-1";
        let server_id = "srv";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let thread = upstream::Thread {
            id: thread_id.to_string(),
            preview: "hello".to_string(),
            ephemeral: false,
            model_provider: "openai".to_string(),
            created_at: 1,
            updated_at: 2,
            status: upstream::ThreadStatus::Active {
                active_flags: Vec::new(),
            },
            path: Some(PathBuf::from("/tmp/thread.jsonl")),
            cwd: PathBuf::from("/tmp"),
            cli_version: "1.0.0".to_string(),
            source: upstream::SessionSource::default(),
            agent_nickname: None,
            agent_role: None,
            git_info: None,
            name: Some("Thread".to_string()),
            turns: vec![upstream::Turn {
                id: "turn-1".to_string(),
                status: upstream::TurnStatus::InProgress,
                error: None,
                items: vec![
                    upstream::ThreadItem::UserMessage {
                        id: "user-1".to_string(),
                        content: vec![upstream::UserInput::Text {
                            text: "hello".to_string(),
                            text_elements: Vec::new(),
                        }],
                    },
                    upstream::ThreadItem::AgentMessage {
                        id: "assistant-1".to_string(),
                        text: "hel".to_string(),
                        phase: None,
                        memory_citation: None,
                    },
                ],
            }],
        };
        let mut cache = HashMap::from([(
            thread_id.to_string(),
            seed_conversation_state_from_thread(&thread),
        )]);

        let text_patch = ThreadStreamStateChangedParams {
            conversation_id: thread_id.to_string(),
            version: 5,
            change: StreamChange::Patches {
                patches: vec![codex_ipc::ImmerPatch {
                    op: codex_ipc::ImmerOp::Replace,
                    path: vec![
                        codex_ipc::ImmerPathSegment::Key("turns".to_string()),
                        codex_ipc::ImmerPathSegment::Index(0),
                        codex_ipc::ImmerPathSegment::Key("items".to_string()),
                        codex_ipc::ImmerPathSegment::Index(0),
                        codex_ipc::ImmerPathSegment::Key("text".to_string()),
                    ],
                    value: Some(json!("hello")),
                }],
            },
        };

        handle_stream_state_change(&mut cache, &app_store, server_id, &text_patch).unwrap();

        let snapshot = app_store.snapshot();
        let thread = snapshot.threads.get(&key).unwrap();
        assert_eq!(thread.active_turn_id.as_deref(), Some("turn-1"));
        assert_eq!(
            thread.items.iter().find_map(|item| match &item.content {
                HydratedConversationItemContent::Assistant(data) => Some(data.text.as_str()),
                _ => None,
            }),
            Some("hello")
        );
    }

    #[test]
    fn handle_stream_state_change_applies_same_protocol_version_patch_bursts() {
        let app_store = AppStoreReducer::new();
        let mut cache = HashMap::new();
        let thread_id = "thread-1";
        let server_id = "srv";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };

        let snapshot_params = ThreadStreamStateChangedParams {
            conversation_id: thread_id.to_string(),
            version: 5,
            change: StreamChange::Snapshot {
                conversation_state: json!({
                    "turns": [
                        {
                            "turnId": "turn-1",
                            "status": "inProgress",
                            "params": {
                                "input": [
                                    { "type": "text", "text": "hello", "textElements": [] }
                                ]
                            },
                            "items": [
                                { "id": "assistant-1", "type": "agentMessage", "text": "hel" }
                            ]
                        }
                    ],
                    "requests": []
                }),
            },
        };
        handle_stream_state_change(&mut cache, &app_store, server_id, &snapshot_params).unwrap();

        let first_text_patch = ThreadStreamStateChangedParams {
            conversation_id: thread_id.to_string(),
            version: 5,
            change: StreamChange::Patches {
                patches: vec![codex_ipc::ImmerPatch {
                    op: codex_ipc::ImmerOp::Replace,
                    path: vec![
                        codex_ipc::ImmerPathSegment::Key("turns".to_string()),
                        codex_ipc::ImmerPathSegment::Index(0),
                        codex_ipc::ImmerPathSegment::Key("items".to_string()),
                        codex_ipc::ImmerPathSegment::Index(0),
                        codex_ipc::ImmerPathSegment::Key("text".to_string()),
                    ],
                    value: Some(json!("hell")),
                }],
            },
        };
        let second_text_patch = ThreadStreamStateChangedParams {
            conversation_id: thread_id.to_string(),
            version: 5,
            change: StreamChange::Patches {
                patches: vec![codex_ipc::ImmerPatch {
                    op: codex_ipc::ImmerOp::Replace,
                    path: vec![
                        codex_ipc::ImmerPathSegment::Key("turns".to_string()),
                        codex_ipc::ImmerPathSegment::Index(0),
                        codex_ipc::ImmerPathSegment::Key("items".to_string()),
                        codex_ipc::ImmerPathSegment::Index(0),
                        codex_ipc::ImmerPathSegment::Key("text".to_string()),
                    ],
                    value: Some(json!("hello")),
                }],
            },
        };
        handle_stream_state_change(&mut cache, &app_store, server_id, &first_text_patch).unwrap();
        handle_stream_state_change(&mut cache, &app_store, server_id, &second_text_patch).unwrap();

        let snapshot = app_store.snapshot();
        let thread = snapshot.threads.get(&key).unwrap();
        assert_eq!(
            thread.items.iter().find_map(|item| match &item.content {
                HydratedConversationItemContent::Assistant(data) => Some(data.text.as_str()),
                _ => None,
            }),
            Some("hello")
        );
    }

    #[test]
    fn handle_stream_state_change_coalesces_large_non_streaming_patch_bursts() {
        let app_store = AppStoreReducer::new();
        let mut updates = app_store.subscribe();
        let mut cache = HashMap::new();
        let thread_id = "thread-1";
        let server_id = "srv";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };

        let snapshot_params = ThreadStreamStateChangedParams {
            conversation_id: thread_id.to_string(),
            version: 5,
            change: StreamChange::Snapshot {
                conversation_state: json!({
                    "turns": [
                        {
                            "turnId": "turn-1",
                            "status": "inProgress",
                            "params": {
                                "input": [
                                    { "type": "text", "text": "hello", "textElements": [] }
                                ]
                            },
                            "items": []
                        }
                    ],
                    "requests": []
                }),
            },
        };
        handle_stream_state_change(&mut cache, &app_store, server_id, &snapshot_params).unwrap();
        drain_app_updates(&mut updates);

        let patches = (0..MAX_INCREMENTAL_IPC_GRANULAR_NON_STREAMING_UPDATES)
            .map(|index| codex_ipc::ImmerPatch {
                op: codex_ipc::ImmerOp::Add,
                path: vec![
                    codex_ipc::ImmerPathSegment::Key("turns".to_string()),
                    codex_ipc::ImmerPathSegment::Index(0),
                    codex_ipc::ImmerPathSegment::Key("items".to_string()),
                    codex_ipc::ImmerPathSegment::Index(index),
                ],
                value: Some(json!({
                    "id": format!("assistant-{index}"),
                    "type": "agentMessage",
                    "text": format!("part {index}"),
                })),
            })
            .collect();

        let patch_params = ThreadStreamStateChangedParams {
            conversation_id: thread_id.to_string(),
            version: 5,
            change: StreamChange::Patches { patches },
        };
        handle_stream_state_change(&mut cache, &app_store, server_id, &patch_params).unwrap();

        let emitted = drain_app_updates(&mut updates);
        assert!(emitted.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadUpserted { thread, .. } if thread.key == key
        )));
        assert!(!emitted.iter().any(|update| matches!(
            update,
            AppStoreUpdateRecord::ThreadItemUpserted { key: emitted_key, .. } if emitted_key == &key
        )));

        let snapshot = app_store.snapshot();
        let thread = snapshot.threads.get(&key).unwrap();
        assert_eq!(
            thread
                .items
                .iter()
                .filter(|item| matches!(
                    item.content,
                    HydratedConversationItemContent::Assistant(_)
                ))
                .count(),
            MAX_INCREMENTAL_IPC_GRANULAR_NON_STREAMING_UPDATES
        );
    }

    #[test]
    fn handle_stream_state_change_marks_shell_turn_active_before_real_turn_id_arrives() {
        let app_store = AppStoreReducer::new();
        let mut cache = HashMap::new();
        let thread_id = "thread-1";
        let server_id = "srv";
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };

        let snapshot_params = ThreadStreamStateChangedParams {
            conversation_id: thread_id.to_string(),
            version: 5,
            change: StreamChange::Snapshot {
                conversation_state: json!({
                    "turns": [],
                    "requests": []
                }),
            },
        };
        handle_stream_state_change(&mut cache, &app_store, server_id, &snapshot_params).unwrap();

        let add_shell_turn_patch = ThreadStreamStateChangedParams {
            conversation_id: thread_id.to_string(),
            version: 5,
            change: StreamChange::Patches {
                patches: vec![codex_ipc::ImmerPatch {
                    op: codex_ipc::ImmerOp::Add,
                    path: vec![
                        codex_ipc::ImmerPathSegment::Key("turns".to_string()),
                        codex_ipc::ImmerPathSegment::Index(0),
                    ],
                    value: Some(json!({
                        "status": "inProgress",
                        "items": [],
                        "params": { "input": [] },
                        "interruptedCommandExecutionItemIds": []
                    })),
                }],
            },
        };
        handle_stream_state_change(&mut cache, &app_store, server_id, &add_shell_turn_patch)
            .unwrap();

        let snapshot = app_store.snapshot();
        let thread = snapshot.threads.get(&key).unwrap();
        assert_eq!(thread.active_turn_id.as_deref(), Some("ipc-turn-0"));
        assert_eq!(thread.info.status, ThreadSummaryStatus::Active);

        let finalize_turn_identity_patch = ThreadStreamStateChangedParams {
            conversation_id: thread_id.to_string(),
            version: 5,
            change: StreamChange::Patches {
                patches: vec![
                    codex_ipc::ImmerPatch {
                        op: codex_ipc::ImmerOp::Replace,
                        path: vec![
                            codex_ipc::ImmerPathSegment::Key("turns".to_string()),
                            codex_ipc::ImmerPathSegment::Index(0),
                            codex_ipc::ImmerPathSegment::Key("turnId".to_string()),
                        ],
                        value: Some(json!("turn-1")),
                    },
                    codex_ipc::ImmerPatch {
                        op: codex_ipc::ImmerOp::Add,
                        path: vec![
                            codex_ipc::ImmerPathSegment::Key("turns".to_string()),
                            codex_ipc::ImmerPathSegment::Index(0),
                            codex_ipc::ImmerPathSegment::Key("items".to_string()),
                            codex_ipc::ImmerPathSegment::Index(0),
                        ],
                        value: Some(json!({
                            "id": "assistant-1",
                            "type": "agentMessage",
                            "text": "h"
                        })),
                    },
                ],
            },
        };
        handle_stream_state_change(
            &mut cache,
            &app_store,
            server_id,
            &finalize_turn_identity_patch,
        )
        .unwrap();

        let snapshot = app_store.snapshot();
        let thread = snapshot.threads.get(&key).unwrap();
        assert_eq!(thread.active_turn_id.as_deref(), Some("turn-1"));
        assert_eq!(
            thread.items.iter().find_map(|item| match &item.content {
                HydratedConversationItemContent::Assistant(data) => Some(data.text.as_str()),
                _ => None,
            }),
            Some("h")
        );
    }

    #[test]
    fn thread_projection_restores_queued_follow_up_previews_from_input_state() {
        let projection = thread_projection_from_conversation_json(
            "srv",
            "thread-1",
            &json!({
                "title": "IPC Thread",
                "cwd": "/repo",
                "rolloutPath": "/repo/.codex/session.jsonl",
                "createdAt": 1710000000000i64,
                "updatedAt": 1710000005000i64,
                "threadRuntimeStatus": { "type": "active", "activeFlags": [] },
                "source": "vscode",
                "turns": [],
                "requests": [],
                "inputState": {
                    "pendingSteers": [
                        { "text": "Please continue." }
                    ],
                    "rejectedSteersQueue": [
                        { "text": "Try again after the tool call." }
                    ],
                    "queuedUserMessages": [
                        { "text": "Queued follow-up" }
                    ]
                }
            }),
        )
        .expect("thread projection should succeed");

        assert_eq!(
            projection
                .snapshot
                .queued_follow_ups
                .iter()
                .map(|preview| (preview.kind, preview.text.as_str()))
                .collect::<Vec<_>>(),
            vec![
                (AppQueuedFollowUpKind::PendingSteer, "Please continue."),
                (
                    AppQueuedFollowUpKind::RetryingSteer,
                    "Try again after the tool call.",
                ),
                (AppQueuedFollowUpKind::Message, "Queued follow-up"),
            ]
        );
    }

    #[test]
    fn queued_followups_broadcast_payload_supports_text_and_attachment_only_messages() {
        let drafts = queued_follow_up_drafts_from_message_values(&[
            json!("Queued follow-up"),
            json!({
                "kind": "pending_steer",
                "text": "Please continue."
            }),
            json!({
                "kind": "rejected_steer",
                "localImages": [{}],
                "remoteImageUrls": ["https://example.com/image.png"]
            }),
        ]);

        assert_eq!(
            drafts
                .iter()
                .map(|draft| (draft.preview.kind, draft.preview.text.as_str()))
                .collect::<Vec<_>>(),
            vec![
                (AppQueuedFollowUpKind::Message, "Queued follow-up"),
                (AppQueuedFollowUpKind::PendingSteer, "Please continue."),
                (AppQueuedFollowUpKind::RetryingSteer, "2 image attachments",),
            ]
        );
    }

    #[test]
    fn queued_follow_up_message_json_round_trips_skill_inputs() {
        let inputs = vec![
            upstream::UserInput::Text {
                text: "Use the repo skill here.".to_string(),
                text_elements: Vec::new(),
            },
            upstream::UserInput::Skill {
                name: "repo-helper".to_string(),
                path: PathBuf::from("/tmp/repo-helper/SKILL.md"),
            },
        ];

        let message_json = queued_follow_up_message_json_from_inputs(&inputs)
            .expect("queued message json should serialize");
        let round_trip_inputs = queued_follow_up_inputs_from_json_value(&message_json);

        assert_eq!(round_trip_inputs, inputs);
    }

    #[test]
    fn queued_follow_up_preview_from_inputs_can_mark_pending_steers() {
        let preview = queued_follow_up_preview_from_inputs(
            &[upstream::UserInput::Text {
                text: "Please try the same search again.".to_string(),
                text_elements: Vec::new(),
            }],
            AppQueuedFollowUpKind::PendingSteer,
        )
        .expect("preview should be generated");

        assert_eq!(preview.kind, AppQueuedFollowUpKind::PendingSteer);
        assert_eq!(preview.text, "Please try the same search again.");
    }

    #[test]
    fn ipc_no_client_found_clears_server_ipc_state() {
        let error = IpcError::Request(RequestError::NoClientFound);
        assert!(ipc_command_error_clears_server_ipc_state(&error));
    }

    #[test]
    fn ipc_client_disconnected_clears_server_ipc_state() {
        let error = IpcError::Request(RequestError::ClientDisconnected);
        assert!(ipc_command_error_clears_server_ipc_state(&error));
    }
}
