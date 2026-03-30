#[cfg(target_os = "android")]
use futures::FutureExt;
use std::collections::{BTreeSet, HashMap};
use std::future::Future;
#[cfg(target_os = "android")]
use std::panic::AssertUnwindSafe;
use std::sync::{Arc, RwLock};
use tokio::sync::{Mutex, broadcast};
use tracing::{debug, info, trace, warn};
use url::Url;

use crate::discovery::{DiscoveredServer, DiscoveryConfig, DiscoveryService, MdnsSeed};
use crate::session::connection::InProcessConfig;
use crate::session::connection::{
    RemoteSessionResources, ServerConfig, ServerEvent, ServerSession,
};
use crate::session::events::{EventProcessor, UiEvent};
use crate::ssh::{SshBootstrapResult, SshClient, SshCredentials};
use crate::store::updates::ThreadStreamingDeltaKind;
use crate::store::{
    AppSnapshot, AppStoreReducer, AppStoreUpdateRecord, AppQueuedFollowUpPreview, ServerHealthSnapshot,
    ThreadSnapshot,
};
use crate::transport::{RpcError, TransportError};
use crate::types::{
    ApprovalDecisionValue, PendingApproval, PendingApprovalSeed, PendingApprovalWithSeed,
    PendingUserInputAnswer, PendingUserInputRequest, ThreadInfo, ThreadKey, ThreadSummaryStatus,
};
use crate::types::AppOperationStatus;
use codex_app_server_protocol as upstream;
use codex_ipc::{
    ClientStatus, CommandExecutionApprovalDecision, ConversationStreamApplyError,
    ExternalResumeThreadParams, FileChangeApprovalDecision, ImmerOp, ImmerPatch, ImmerPathSegment,
    IpcClient, IpcClientConfig, ProjectedApprovalKind, ProjectedApprovalRequest,
    ProjectedUserInputRequest, StreamChange, ThreadFollowerCommandApprovalDecisionParams,
    ThreadFollowerFileApprovalDecisionParams, ThreadFollowerStartTurnParams,
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

impl MobileClient {
    /// Create a new `MobileClient`.
    pub fn new() -> Self {
        crate::logging::install_ipc_wire_trace_logger();
        let event_processor = Arc::new(EventProcessor::new());
        let app_store = Arc::new(AppStoreReducer::new());
        spawn_store_listener(Arc::clone(&app_store), event_processor.subscribe());
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
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
        self.app_store
            .upsert_server(session.config(), ServerHealthSnapshot::Connected);

        self.spawn_event_reader(server_id.clone(), Arc::clone(&session));
        self.spawn_health_reader(server_id.clone(), session.health());

        self.sessions_write().insert(server_id.clone(), session);

        if let Err(error) = self.sync_server_account(server_id.as_str()).await {
            warn!("MobileClient: failed to sync account for {server_id}: {error}");
        }

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
        self.app_store
            .upsert_server(session.config(), ServerHealthSnapshot::Connected);

        self.spawn_event_reader(server_id.clone(), Arc::clone(&session));
        self.spawn_health_reader(server_id.clone(), session.health());

        self.sessions_write().insert(server_id.clone(), session);

        if let Err(error) = self.sync_server_account(server_id.as_str()).await {
            warn!("MobileClient: failed to sync account for {server_id}: {error}");
        }

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
        if self.existing_active_session(server_id.as_str()).is_some() {
            info!("MobileClient: reusing existing remote SSH server session {server_id}");
            return Ok(server_id);
        }
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

        self.finish_connect_remote_over_ssh(
            config,
            ssh_credentials,
            ssh_client,
            bootstrap,
            ipc_socket_path_override,
        )
        .await
    }

    pub(crate) async fn finish_connect_remote_over_ssh(
        &self,
        mut config: ServerConfig,
        ssh_credentials: SshCredentials,
        ssh_client: Arc<SshClient>,
        bootstrap: SshBootstrapResult,
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

        let ipc_ssh_client = None;
        let ipc_bridge_pid = None;

        #[cfg(target_os = "android")]
        trace!(
            "MobileClient: finish_connect_remote_over_ssh attaching IPC over SSH server_id={}",
            server_id
        );
        #[cfg(target_os = "android")]
        let ipc_client = match AssertUnwindSafe(attach_ipc_client_via_ssh(
            &ssh_client,
            config.server_id.as_str(),
            ipc_socket_path_override.as_deref(),
        ))
        .catch_unwind()
        .await
        {
            Ok(client) => client,
            Err(_) => {
                warn!(
                    "MobileClient: Android IPC attach panicked for {}; continuing without IPC",
                    config.server_id
                );
                None
            }
        };

        #[cfg(not(target_os = "android"))]
        trace!(
            "MobileClient: finish_connect_remote_over_ssh attaching IPC over SSH server_id={}",
            server_id
        );
        #[cfg(not(target_os = "android"))]
        let ipc_client = attach_ipc_client_via_ssh(
            &ssh_client,
            config.server_id.as_str(),
            ipc_socket_path_override.as_deref(),
        )
        .await;
        trace!(
            "MobileClient: finish_connect_remote_over_ssh IPC attach result server_id={} attached={}",
            server_id,
            ipc_client.is_some()
        );

        let session = match ServerSession::connect_remote_with_resources(
            config,
            RemoteSessionResources {
                ssh_client: Some(Arc::clone(&ssh_client)),
                ssh_pid: bootstrap.pid,
                ipc_client,
                ipc_ssh_client,
                ipc_bridge_pid,
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

        self.app_store
            .upsert_server(session.config(), ServerHealthSnapshot::Connected);
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

        self.sessions_write()
            .insert(server_id.clone(), Arc::clone(&session));

        if let Err(error) = self.sync_server_account(server_id.as_str()).await {
            warn!("MobileClient: failed to sync account for {server_id}: {error}");
        }
        trace!(
            "MobileClient: finish_connect_remote_over_ssh account sync completed server_id={}",
            server_id
        );
        if let Err(error) = refresh_thread_list_from_app_server(
            Arc::clone(&session),
            Arc::clone(&self.app_store),
            server_id.as_str(),
        )
        .await
        {
            warn!("MobileClient: failed to refresh thread list for {server_id}: {error}");
        }
        trace!(
            "MobileClient: finish_connect_remote_over_ssh thread refresh completed server_id={}",
            server_id
        );

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
        let ipc_client = session.ipc_client().ok_or_else(|| {
            RpcError::Transport(TransportError::ConnectionFailed(
                "desktop IPC is not connected".to_string(),
            ))
        })?;
        info!(
            "IPC out: external_resume_thread server={} thread={}",
            server_id, thread_id
        );
        ipc_client
            .external_resume_thread(ExternalResumeThreadParams {
                conversation_id: thread_id.to_string(),
                host_id,
            })
            .await
            .map_err(|error| {
                warn!(
                    "IPC out: external_resume_thread failed server={} error={}",
                    server_id, error
                );
                RpcError::Deserialization(format!("IPC external resume: {error}"))
            })?;
        refresh_thread_snapshot_from_app_server(
            Arc::clone(&session),
            Arc::clone(&self.app_store),
            server_id,
            thread_id,
        )
        .await?;
        Ok(())
    }

    pub async fn start_turn(
        &self,
        server_id: &str,
        params: upstream::TurnStartParams,
    ) -> Result<(), RpcError> {
        let session = self.get_session(server_id)?;
        let thread_key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: params.thread_id.clone(),
        };
        let queued_preview = self
            .snapshot_thread(&thread_key)
            .ok()
            .filter(|thread| {
                thread.active_turn_id.is_some() || thread.info.status == ThreadSummaryStatus::Active
            })
            .and_then(|_| queued_follow_up_preview_from_inputs(&params.input));
        if let Some(preview) = queued_preview.clone() {
            self.app_store
                .enqueue_thread_follow_up_preview(&thread_key, preview);
        }
        let direct_params = params.clone();

        if let Some(ipc_client) = session.ipc_client() {
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
                    refresh_thread_snapshot_from_app_server(
                        Arc::clone(&session),
                        Arc::clone(&self.app_store),
                        server_id,
                        &thread_id,
                    )
                    .await?;
                    return Ok(());
                }
                Err(error) => {
                    if let Some(preview) = queued_preview.as_ref() {
                        self.app_store
                            .remove_thread_follow_up_preview(&thread_key, &preview.id);
                    }
                    warn!(
                        "MobileClient: IPC follower start turn failed for {} thread {}: {}",
                        server_id, thread_id, error
                    );
                    self.app_store.update_server_ipc_state(server_id, false);
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
                if let Some(preview) = queued_preview.as_ref() {
                    self.app_store
                        .remove_thread_follow_up_preview(&thread_key, &preview.id);
                }
                RpcError::Deserialization(error)
            })?;
        let _ = response;
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
                .map_err(|e: crate::RpcClientError| {
                    RpcError::Deserialization(e.to_string())
                })?,
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
            && send_ipc_approval_response(&ipc_client, &approval, &thread_id, decision.clone())
                .await?
        {
            debug!(
                "MobileClient: approval response sent over IPC for server={} request_id={}",
                approval.server_id, request_id
            );
            self.app_store.resolve_approval(request_id);
            return Ok(());
        }
        let response_json = approval_response_json(&approval, approval_seed.as_ref(), decision)?;
        session
            .respond(
                serde_json::Value::String(approval.id.clone()),
                response_json,
            )
            .await?;
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
        let answered_inputs = answers.clone();
        let request = self.pending_user_input(request_id)?;
        let session = self.get_session(&request.server_id)?;
        if let Some(ipc_client) = session.ipc_client()
            && send_ipc_user_input_response(
                &ipc_client,
                &request.thread_id,
                &request.id,
                answers.clone(),
            )
            .await?
        {
            debug!(
                "MobileClient: user input response sent over IPC for server={} request_id={}",
                request.server_id, request_id
            );
            self.app_store
                .resolve_pending_user_input_with_response(request_id, answered_inputs);
            return Ok(());
        }
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
        Ok(())
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

    fn spawn_ipc_reader(&self, server_id: String, session: Arc<ServerSession>) {
        let Some(mut broadcasts) = session.ipc_broadcasts() else {
            return;
        };
        let app_store = Arc::clone(&self.app_store);
        let loop_server_id = server_id.clone();
        Self::spawn_detached(async move {
            let mut stream_cache: HashMap<String, serde_json::Value> = HashMap::new();
            loop {
                match broadcasts.recv().await {
                    Ok(TypedBroadcast::ThreadStreamStateChanged(params)) => {
                        let change_type = match &params.change {
                            StreamChange::Snapshot { .. } => "snapshot",
                            StreamChange::Patches { .. } => "patches",
                        };
                        debug!(
                            "IPC in: ThreadStreamStateChanged server={} thread={} protocol_version={} change={}",
                            loop_server_id, params.conversation_id, params.version, change_type
                        );

                        match handle_stream_state_change(
                            &mut stream_cache,
                            &app_store,
                            &loop_server_id,
                            &params,
                        ) {
                            Ok(()) => {}
                            Err(StreamHandleError::NoCachedState) => {
                                debug!(
                                    "IPC: no cached state for thread={}, seeding stream cache from RPC",
                                    params.conversation_id
                                );
                                if let Err(e) = recover_ipc_stream_cache_from_app_server(
                                    Arc::clone(&session),
                                    Arc::clone(&app_store),
                                    &mut stream_cache,
                                    &loop_server_id,
                                    &params.conversation_id,
                                )
                                .await
                                {
                                    warn!(
                                        "IPC: RPC cache recovery failed for thread {}: {}",
                                        params.conversation_id, e
                                    );
                                }
                            }
                            Err(StreamHandleError::DeserializeFailed(msg)) => {
                                warn!(
                                    "IPC: deserialize failed for thread={}: {}",
                                    params.conversation_id, msg
                                );
                                stream_cache.remove(&params.conversation_id);
                                if let Err(e) = recover_ipc_stream_cache_from_app_server(
                                    Arc::clone(&session),
                                    Arc::clone(&app_store),
                                    &mut stream_cache,
                                    &loop_server_id,
                                    &params.conversation_id,
                                )
                                .await
                                {
                                    warn!(
                                        "IPC: RPC cache recovery failed for thread {}: {}",
                                        params.conversation_id, e
                                    );
                                }
                            }
                            Err(StreamHandleError::PatchFailed(msg)) => {
                                warn!(
                                    "IPC: patch failed for thread={}: {}",
                                    params.conversation_id, msg
                                );
                                stream_cache.remove(&params.conversation_id);
                                if let Err(e) = recover_ipc_stream_cache_from_app_server(
                                    Arc::clone(&session),
                                    Arc::clone(&app_store),
                                    &mut stream_cache,
                                    &loop_server_id,
                                    &params.conversation_id,
                                )
                                .await
                                {
                                    warn!(
                                        "IPC: RPC cache recovery failed for thread {}: {}",
                                        params.conversation_id, e
                                    );
                                }
                            }
                        }
                    }
                    Ok(TypedBroadcast::ThreadArchived(ref params)) => {
                        stream_cache.remove(&params.conversation_id);
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
                    | Ok(TypedBroadcast::ThreadQueuedFollowupsChanged(_))
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
                    }
                }
            }
        });
    }

    pub(crate) fn get_session(&self, server_id: &str) -> Result<Arc<ServerSession>, RpcError> {
        self.sessions_read()
            .get(server_id)
            .cloned()
            .ok_or_else(|| RpcError::Transport(TransportError::Disconnected))
    }

    /// Send a raw `ClientRequest` and return the JSON response value.
    /// Used by tooling (e.g. fixture export) that needs raw upstream data.
    pub async fn request_raw_for_server(
        &self,
        server_id: &str,
        request: upstream::ClientRequest,
    ) -> Result<serde_json::Value, String> {
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        session
            .request_client(request)
            .await
            .map_err(|e| e.to_string())
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
        let value = session
            .request_client(request)
            .await
            .map_err(|e| e.to_string())?;
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

#[cfg(target_os = "android")]
fn shell_quote_remote(value: &str) -> String {
    if value.is_empty() {
        return "''".to_string();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

async fn attach_ipc_client_via_ssh(
    ssh_client: &Arc<SshClient>,
    server_id: &str,
    ipc_socket_path_override: Option<&str>,
) -> Option<IpcClient> {
    match ssh_client
        .remote_ipc_socket_if_present(ipc_socket_path_override)
        .await
    {
        Ok(Some(socket_path)) => {
            info!(
                "IPC socket detected server={} path={}",
                server_id, socket_path
            );
            let ipc_config = IpcClientConfig {
                socket_path: std::path::PathBuf::from(&socket_path),
                client_type: "mobile".to_string(),
                ..IpcClientConfig::default()
            };
            match ssh_client.open_streamlocal(&socket_path).await {
                Ok(stream) => match IpcClient::connect_with_stream(&ipc_config, stream).await {
                    Ok(client) => {
                        info!("IPC attached server={} path={}", server_id, socket_path);
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

#[cfg(target_os = "android")]
async fn attach_ipc_client_via_tcp_bridge(
    ssh_client: &Arc<SshClient>,
    server_id: &str,
    ipc_socket_path_override: Option<&str>,
) -> Option<(IpcClient, Option<u32>)> {
    let socket_path = match ssh_client
        .remote_ipc_socket_if_present(ipc_socket_path_override)
        .await
    {
        Ok(Some(path)) => path,
        Ok(None) => return None,
        Err(error) => {
            warn!(
                "MobileClient: failed to probe IPC socket for {}: {}",
                server_id, error
            );
            return None;
        }
    };

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
        Ok(stream) => match IpcClient::connect_with_stream(&ipc_config, stream).await {
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
        },
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

impl Default for MobileClient {
    fn default() -> Self {
        Self::new()
    }
}

fn spawn_store_listener(app_store: Arc<AppStoreReducer>, mut rx: broadcast::Receiver<UiEvent>) {
    MobileClient::spawn_detached(async move {
        loop {
            match rx.recv().await {
                Ok(event) => app_store.apply_ui_event(&event),
                Err(broadcast::error::RecvError::Closed) => break,
                Err(broadcast::error::RecvError::Lagged(skipped)) => {
                    warn!("MobileClient: lagged {skipped} UI events");
                }
            }
        }
    });
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

    serialize_dynamic_tool_payload(
        serde_json::json!({
            "type": "servers",
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

    let mut payload = serde_json::json!({
        "type": "sessions",
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
) -> Result<ThreadSnapshot, String> {
    Ok(thread_snapshot_from_upstream_thread_state(
        server_id,
        thread,
        model,
        reasoning_effort,
        None,
    ))
}

pub fn copy_thread_runtime_fields(source: &ThreadSnapshot, target: &mut ThreadSnapshot) {
    if target.model.is_none() {
        target.model = source.model.clone();
    }
    if target.reasoning_effort.is_none() {
        target.reasoning_effort = source.reasoning_effort.clone();
    }
    if target.queued_follow_ups.is_empty() {
        target.queued_follow_ups = source.queued_follow_ups.clone();
    }
    target.context_tokens_used = source.context_tokens_used;
    target.model_context_window = source.model_context_window;
    target.rate_limits = source.rate_limits.clone();
    target.realtime_session_id = source.realtime_session_id.clone();
}

fn queued_follow_up_preview_from_inputs(
    inputs: &[upstream::UserInput],
) -> Option<AppQueuedFollowUpPreview> {
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

    let text = if !text_parts.is_empty() {
        text_parts.join("\n")
    } else if attachment_count > 0 {
        if attachment_count == 1 {
            "1 image attachment".to_string()
        } else {
            format!("{attachment_count} image attachments")
        }
    } else {
        return None;
    };

    Some(AppQueuedFollowUpPreview {
        id: uuid::Uuid::new_v4().to_string(),
        text,
    })
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
        crate::conversation_uniffi::HydratedConversationItemContent::User(data) => Ok(data.text.clone()),
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

fn map_rpc_client_error(error: crate::RpcClientError) -> RpcError {
    match error {
        crate::RpcClientError::Rpc(message)
        | crate::RpcClientError::Serialization(message) => RpcError::Deserialization(message),
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

async fn refresh_thread_snapshot_from_app_server(
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: &str,
    thread_id: &str,
) -> Result<(), RpcError> {
    let thread = read_thread_from_app_server(session, thread_id).await?;
    upsert_thread_snapshot_from_app_server_thread(&app_store, server_id, thread);
    Ok(())
}

async fn read_thread_from_app_server(
    session: Arc<ServerSession>,
    thread_id: &str,
) -> Result<upstream::Thread, RpcError> {
    let response = session
        .request(
            "thread/read",
            serde_json::json!({ "threadId": thread_id, "includeTurns": true }),
        )
        .await?;
    response
        .get("thread")
        .cloned()
        .ok_or_else(|| RpcError::Deserialization("thread/read response missing thread".to_string()))
        .and_then(|value| {
            serde_json::from_value::<upstream::Thread>(value).map_err(|error| {
                RpcError::Deserialization(format!("deserialize thread/read response: {error}"))
            })
        })
}

fn upsert_thread_snapshot_from_app_server_thread(
    app_store: &AppStoreReducer,
    server_id: &str,
    thread: upstream::Thread,
) {
    let thread_id = thread.id.clone();
    let existing = app_store
        .snapshot()
        .threads
        .get(&ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        })
        .cloned();
    let mut snapshot = thread_snapshot_from_upstream_thread(server_id, thread);
    if let Some(existing) = existing.as_ref() {
        copy_thread_runtime_fields(existing, &mut snapshot);
    }
    app_store.upsert_thread_snapshot(snapshot);
}

async fn recover_ipc_stream_cache_from_app_server(
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    cache: &mut HashMap<String, serde_json::Value>,
    server_id: &str,
    thread_id: &str,
) -> Result<(), RpcError> {
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

    let thread = read_thread_from_app_server(session, thread_id).await?;
    upsert_thread_snapshot_from_app_server_thread(&app_store, server_id, thread.clone());

    let mut conversation_state = seed_conversation_state_from_thread(&thread);
    hydrate_seeded_ipc_conversation_state(
        &app_store,
        &mut conversation_state,
        existing_thread.as_ref(),
        &pending_approvals,
        &pending_user_inputs,
    );
    cache.insert(thread_id.to_string(), conversation_state);
    Ok(())
}

fn thread_snapshot_from_upstream_thread(
    server_id: &str,
    thread: upstream::Thread,
) -> ThreadSnapshot {
    thread_snapshot_from_upstream_thread_state(server_id, thread, None, None, None)
}

fn thread_snapshot_from_upstream_thread_state(
    server_id: &str,
    thread: upstream::Thread,
    model: Option<String>,
    reasoning_effort: Option<String>,
    active_turn_id: Option<String>,
) -> ThreadSnapshot {
    let info = ThreadInfo::from(thread.clone());
    let items = crate::conversation::hydrate_turns(&thread.turns, &Default::default());
    let mut snapshot = ThreadSnapshot::from_info(server_id, info);
    snapshot.items = items;
    snapshot.model = model;
    snapshot.reasoning_effort = reasoning_effort;
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
        .map(|projection| ThreadProjection {
            snapshot: thread_snapshot_from_upstream_thread_state(
                server_id,
                projection.thread,
                projection.latest_model,
                projection.latest_reasoning_effort,
                projection.active_turn_id,
            ),
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

    if mutation_result.requires_thread_upsert {
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
) -> Result<bool, RpcError> {
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
                .await
                .map_err(|error| {
                    RpcError::Deserialization(format!("IPC approval response: {error}"))
                })?;
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
                .await
                .map_err(|error| {
                    RpcError::Deserialization(format!("IPC file approval response: {error}"))
                })?;
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
) -> Result<bool, RpcError> {
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
        .await
        .map_err(|error| RpcError::Deserialization(format!("IPC user input response: {error}")))?;
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

#[cfg(test)]
mod mobile_client_tests {
    use super::*;
    use crate::conversation_uniffi::HydratedConversationItemContent;
    use crate::store::AppStoreUpdateRecord;
    use crate::store::updates::ThreadStreamingDeltaKind;
    use crate::types::ThreadSummaryStatus;
    use serde_json::json;
    use std::path::PathBuf;
    use tokio::sync::broadcast::error::TryRecvError;

    fn drain_app_updates(rx: &mut tokio::sync::broadcast::Receiver<AppStoreUpdateRecord>) -> Vec<AppStoreUpdateRecord> {
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
    fn copy_thread_runtime_fields_preserves_existing_runtime_state() {
        let source = ThreadSnapshot {
            key: ThreadKey {
                server_id: "srv".to_string(),
                thread_id: "thread-1".to_string(),
            },
            info: make_thread_info("thread-1"),
            model: Some("gpt-5".to_string()),
            reasoning_effort: Some("high".to_string()),
            items: Vec::new(),
            local_overlay_items: Vec::new(),
            queued_follow_ups: vec![AppQueuedFollowUpPreview {
                id: "queued-1".to_string(),
                text: "follow-up".to_string(),
            }],
            active_turn_id: Some("turn-1".to_string()),
            context_tokens_used: Some(12_345),
            model_context_window: Some(200_000),
            rate_limits: Some(crate::types::RateLimits {
                requests_remaining: Some(10),
                tokens_remaining: Some(20_000),
                reset_at: Some("2026-03-25T12:00:00Z".to_string()),
            }),
            realtime_session_id: Some("rt-1".to_string()),
        };
        let mut target = ThreadSnapshot::from_info("srv", make_thread_info("thread-1"));

        copy_thread_runtime_fields(&source, &mut target);

        assert_eq!(target.model.as_deref(), Some("gpt-5"));
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
    }

    #[test]
    fn remote_oauth_callback_port_reads_localhost_redirect() {
        let auth_url = "https://auth.openai.com/oauth/authorize?response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=abc";
        assert_eq!(remote_oauth_callback_port(auth_url).unwrap(), 1455);
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
}
