use futures::FutureExt;
use std::collections::HashMap;
use std::future::Future;
use std::panic::AssertUnwindSafe;
use std::sync::{Arc, RwLock};
use tokio::sync::broadcast;
use tracing::{debug, info, warn};

use crate::discovery::{DiscoveredServer, DiscoveryConfig, DiscoveryService, MdnsSeed};
use crate::session::connection::InProcessConfig;
use crate::session::connection::{
    RemoteSessionResources, ServerConfig, ServerEvent, ServerSession,
};
use crate::session::events::{EventProcessor, UiEvent};
use crate::ssh::{SshClient, SshCredentials};
use crate::store::{AppSnapshot, AppStoreReducer, AppUpdate, ServerHealthSnapshot, ThreadSnapshot};
use crate::transport::{RpcError, TransportError};
use crate::types::{
    ApprovalDecisionValue, PendingApproval, PendingUserInputAnswer, PendingUserInputRequest,
    ThreadInfo, ThreadKey, generated,
};
use codex_app_server_protocol as upstream;
use codex_ipc::{
    ClientStatus, CommandExecutionApprovalDecision, ExternalResumeThreadParams,
    FileChangeApprovalDecision, IpcClient, IpcClientConfig,
    ThreadFollowerCommandApprovalDecisionParams, ThreadFollowerFileApprovalDecisionParams,
    ThreadFollowerStartTurnParams, ThreadFollowerSubmitUserInputParams, TypedBroadcast,
};

/// Top-level entry point for platform code (iOS / Android).
///
/// Ties together server sessions, thread management, event processing,
/// discovery, auth, caching, and voice handoff into a single facade.
/// All methods are safe to call from any thread (`Send + Sync`).
pub struct MobileClient {
    pub(crate) sessions: RwLock<HashMap<String, Arc<ServerSession>>>,
    pub(crate) event_processor: Arc<EventProcessor>,
    pub(crate) app_store: Arc<AppStoreReducer>,
    pub(crate) discovery: RwLock<DiscoveryService>,
}

impl MobileClient {
    /// Create a new `MobileClient`.
    pub fn new() -> Self {
        let event_processor = Arc::new(EventProcessor::new());
        let app_store = Arc::new(AppStoreReducer::new());
        spawn_store_listener(Arc::clone(&app_store), event_processor.subscribe());
        Self {
            sessions: RwLock::new(HashMap::new()),
            event_processor,
            app_store,
            discovery: RwLock::new(DiscoveryService::new(DiscoveryConfig::default())),
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

    fn existing_active_session(&self, server_id: &str) -> Option<Arc<ServerSession>> {
        let session = self.sessions_read().get(server_id).cloned()?;
        let health_rx = session.health();
        match health_rx.borrow().clone() {
            crate::session::connection::ConnectionHealth::Disconnected => None,
            _ => Some(session),
        }
    }

    async fn replace_existing_session(&self, server_id: &str) {
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
        mut config: ServerConfig,
        ssh_credentials: SshCredentials,
        accept_unknown_host: bool,
        working_dir: Option<String>,
        ipc_socket_path_override: Option<String>,
    ) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
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

        let use_ipv6 = config.host.contains(':');
        let bootstrap = match ssh_client
            .bootstrap_codex_server(working_dir.as_deref(), use_ipv6)
            .await
        {
            Ok(result) => result,
            Err(error) => {
                eprintln!(
                    "[codex-mobile-client] remote ssh bootstrap failed server={} error={}",
                    config.server_id, error
                );
                ssh_client.disconnect().await;
                return Err(map_ssh_transport_error(error));
            }
        };

        config.port = bootstrap.server_port;
        #[cfg(target_os = "android")]
        {
            // Keep Android's app-server websocket off the SSH transport.
            // SSH remains responsible for bootstrap, remote process cleanup,
            // and desktop IPC attachment.
            config.websocket_url = Some(websocket_url_for_host(
                ssh_credentials.host.as_str(),
                bootstrap.server_port,
            ));
        }
        #[cfg(not(target_os = "android"))]
        {
            config.websocket_url = Some(format!("ws://127.0.0.1:{}", bootstrap.tunnel_local_port));
        }
        config.is_local = false;
        config.tls = false;

        let ipc_ssh_client = None;
        let ipc_bridge_pid = None;

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
        let ipc_client = attach_ipc_client_via_ssh(
            &ssh_client,
            config.server_id.as_str(),
            ipc_socket_path_override.as_deref(),
        )
        .await;

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
                eprintln!(
                    "[codex-mobile-client] remote ssh session connect failed server={} error={}",
                    server_id, error
                );
                ssh_client.disconnect().await;
                return Err(error);
            }
        };

        self.app_store
            .upsert_server(session.config(), ServerHealthSnapshot::Connected);
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
        if let Err(error) = refresh_thread_list_from_app_server(
            Arc::clone(&session),
            Arc::clone(&self.app_store),
            server_id.as_str(),
        )
        .await
        {
            warn!("MobileClient: failed to refresh thread list for {server_id}: {error}");
        }

        info!("MobileClient: connected remote SSH server {server_id}");
        Ok(server_id)
    }

    /// Disconnect a server by its ID.
    pub fn disconnect_server(&self, server_id: &str) {
        let session = self.sessions_write().remove(server_id);

        if let Some(session) = session {
            // Swift/Kotlin can call this from outside any Tokio runtime.
            self.app_store.remove_server(server_id);
            Self::spawn_detached(async move {
                session.disconnect().await;
            });
            info!("MobileClient: disconnected server {server_id}");
        } else {
            warn!("MobileClient: disconnect_server called for unknown {server_id}");
        }
    }

    /// Return the configs of all currently connected servers.
    #[cfg(test)]
    pub(crate) fn connected_servers(&self) -> Vec<ServerConfig> {
        self.sessions_read()
            .values()
            .map(|s| s.config().clone())
            .collect()
    }

    // ── Threads ───────────────────────────────────────────────────────

    /// List threads from a specific server.
    #[cfg(test)]
    pub(crate) async fn list_threads(&self, server_id: &str) -> Result<Vec<ThreadInfo>, RpcError> {
        self.get_session(server_id)?;
        let response = self
            .generated_thread_list(
                server_id,
                generated::ThreadListParams {
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
            .filter_map(thread_info_from_generated_thread)
            .collect::<Vec<_>>();
        self.app_store.sync_thread_list(server_id, &threads);
        Ok(threads)
    }

    pub async fn sync_server_account(&self, server_id: &str) -> Result<(), RpcError> {
        self.get_session(server_id)?;
        let response = self
            .generated_get_account(
                server_id,
                generated::GetAccountParams {
                    refresh_token: false,
                },
            )
            .await
            .map_err(map_rpc_client_error)?;
        self.apply_account_response(server_id, &response);
        Ok(())
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
        ipc_client
            .external_resume_thread(ExternalResumeThreadParams {
                conversation_id: thread_id.to_string(),
                host_id,
            })
            .await
            .map_err(|error| RpcError::Deserialization(format!("IPC external resume: {error}")))?;
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
        params: generated::TurnStartParams,
    ) -> Result<(), RpcError> {
        let session = self.get_session(server_id)?;
        let direct_params = params.clone();

        if let Some(ipc_client) = session.ipc_client() {
            let thread_id = params.thread_id.clone();
            let turn_start_params: upstream::TurnStartParams =
                crate::rpc::convert_generated_field(params)
                    .map_err(|error| RpcError::Deserialization(error.to_string()))?;
            let ipc_result = ipc_client
                .start_turn(ThreadFollowerStartTurnParams {
                    conversation_id: thread_id.clone(),
                    turn_start_params,
                })
                .await;
            match ipc_result {
                Ok(_) => {
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
                    warn!(
                        "MobileClient: IPC follower start turn failed for {} thread {}: {}",
                        server_id, thread_id, error
                    );
                    self.app_store.update_server_ipc_state(server_id, false);
                }
            }
        }

        let reconcile_params = direct_params.clone();
        let response = self
            .generated_turn_start(server_id, direct_params)
            .await
            .map_err(|error| RpcError::Deserialization(error.to_string()))?;
        self.reconcile_public_rpc("turn/start", server_id, Some(&reconcile_params), &response)
            .await
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
                .generated_thread_rollback(
                    &key.server_id,
                    generated::ThreadRollbackParams {
                        thread_id: key.thread_id.clone(),
                        num_turns: rollback_depth,
                    },
                )
                .await
                .map_err(|e| RpcError::Deserialization(e.to_string()))?;
            let mut snapshot = thread_snapshot_from_generated_thread(
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
        approval_policy: Option<generated::AskForApproval>,
        sandbox: Option<generated::SandboxMode>,
        developer_instructions: Option<String>,
        persist_extended_history: bool,
    ) -> Result<ThreadKey, RpcError> {
        self.get_session(&key.server_id)?;
        let source = self.snapshot_thread(key)?;
        ensure_thread_is_editable(&source)?;
        let rollback_depth = rollback_depth_for_turn(&source, selected_turn_index as usize)?;

        let response = self
            .generated_thread_fork(
                &key.server_id,
                generated::ThreadForkParams {
                    thread_id: key.thread_id.clone(),
                    path: None,
                    model,
                    model_provider: None,
                    service_tier: None,
                    cwd,
                    approval_policy,
                    approvals_reviewer: None,
                    sandbox,
                    config: None,
                    base_instructions: None,
                    developer_instructions,
                    ephemeral: false,
                    persist_extended_history: true,
                },
            )
            .await
            .map_err(|e| RpcError::Deserialization(e.to_string()))?;

        let fork_model = Some(response.model);
        let fork_reasoning = response.reasoning_effort.map(reasoning_effort_string);
        let mut snapshot = thread_snapshot_from_generated_thread(
            &key.server_id,
            response.thread,
            fork_model.clone(),
            fork_reasoning.clone(),
        )
        .map_err(RpcError::Deserialization)?;
        let next_key = snapshot.key.clone();

        if rollback_depth > 0 {
            let rollback_response = self
                .generated_thread_rollback(
                    &key.server_id,
                    generated::ThreadRollbackParams {
                        thread_id: next_key.thread_id.clone(),
                        num_turns: rollback_depth,
                    },
                )
                .await
                .map_err(|e| RpcError::Deserialization(e.to_string()))?;
            snapshot = thread_snapshot_from_generated_thread(
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
        let response_json = approval_response_json(&approval, decision)?;
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
            self.app_store.resolve_pending_user_input(request_id);
            return Ok(());
        }
        let response = generated::ToolRequestUserInputResponse {
            answers: answers
                .into_iter()
                .map(
                    |answer| generated::ToolRequestUserInputResponseAnswersEntry {
                        key: answer.question_id,
                        value: generated::ToolRequestUserInputAnswer {
                            answers: answer.answers,
                        },
                    },
                )
                .collect(),
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
        self.app_store.resolve_pending_user_input(request_id);
        Ok(())
    }

    pub(crate) fn validate_login_account_target(
        &self,
        server_id: &str,
        params: &generated::LoginAccountParams,
    ) -> Result<(), String> {
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        if session.config().is_local {
            return Ok(());
        }

        match params {
            generated::LoginAccountParams::ApiKey { .. } => {
                Err("API keys can only be saved on the local server.".to_string())
            }
            generated::LoginAccountParams::ChatgptAuthTokens { .. } => {
                Err("Local ChatGPT tokens can only be sent to the local server.".to_string())
            }
            generated::LoginAccountParams::Chatgpt => Ok(()),
        }
    }

    pub fn snapshot(&self) -> AppSnapshot {
        self.app_store.snapshot()
    }

    pub fn subscribe_updates(&self) -> broadcast::Receiver<AppUpdate> {
        self.app_store.subscribe()
    }

    pub fn app_snapshot(&self) -> AppSnapshot {
        self.snapshot()
    }

    pub fn subscribe_app_updates(&self) -> broadcast::Receiver<AppUpdate> {
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
        Self::spawn_detached(async move {
            loop {
                match events.recv().await {
                    Ok(ServerEvent::Notification(notification)) => {
                        eprintln!(
                            "[codex-mobile-client] event reader server_id={} notification={:?}",
                            server_id, notification
                        );
                        processor.process_notification(&server_id, &notification);
                    }
                    Ok(ServerEvent::LegacyNotification { method, params }) => {
                        eprintln!(
                            "[codex-mobile-client] event reader server_id={} legacy_method={} params={}",
                            server_id, method, params
                        );
                        processor.process_legacy_notification(&server_id, &method, &params);
                    }
                    Ok(ServerEvent::Request(request)) => {
                        eprintln!(
                            "[codex-mobile-client] event reader server_id={} request={:?}",
                            server_id, request
                        );
                        processor.process_server_request(&server_id, &request);
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        debug!("MobileClient: event stream closed for {server_id}");
                        eprintln!(
                            "[codex-mobile-client] event reader closed server_id={}",
                            server_id
                        );
                        break;
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        warn!("MobileClient: lagged {skipped} events for {server_id}");
                        eprintln!(
                            "[codex-mobile-client] event reader lagged server_id={} skipped={}",
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
            loop {
                match broadcasts.recv().await {
                    Ok(TypedBroadcast::ThreadStreamStateChanged(params)) => {
                        if let Err(error) = refresh_thread_snapshot_from_app_server(
                            Arc::clone(&session),
                            Arc::clone(&app_store),
                            &loop_server_id,
                            &params.conversation_id,
                        )
                        .await
                        {
                            warn!(
                                "MobileClient: failed to refresh IPC thread {} on {}: {}",
                                params.conversation_id, loop_server_id, error
                            );
                            let _ = refresh_thread_list_from_app_server(
                                Arc::clone(&session),
                                Arc::clone(&app_store),
                                &loop_server_id,
                            )
                            .await;
                        }
                    }
                    Ok(TypedBroadcast::ThreadArchived(_))
                    | Ok(TypedBroadcast::ThreadUnarchived(_))
                    | Ok(TypedBroadcast::ThreadQueuedFollowupsChanged(_))
                    | Ok(TypedBroadcast::QueryCacheInvalidate(_)) => {
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
                        app_store.update_server_ipc_state(&loop_server_id, false);
                        break;
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        warn!("MobileClient: lagged {skipped} IPC events for {loop_server_id}");
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

    pub(crate) async fn request_typed_for_server<R>(
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
        serde_json::from_value(value).map_err(|e| format!("deserialize typed RPC response: {e}"))
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

fn websocket_url_for_host(host: &str, port: u16) -> String {
    let host = host.trim();
    if host.contains(':') && !host.starts_with('[') && !host.ends_with(']') {
        format!("ws://[{host}]:{port}")
    } else {
        format!("ws://{host}:{port}")
    }
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
            eprintln!(
                "[codex-mobile-client] ssh ipc socket detected server={} path={}",
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
                        eprintln!(
                            "[codex-mobile-client] ssh ipc attached server={} path={}",
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

pub fn thread_info_from_generated_thread(thread: generated::Thread) -> Option<ThreadInfo> {
    thread_info_from_generated_thread_list_item(thread, None, None)
}

fn thread_info_from_generated_thread_list_item(
    thread: generated::Thread,
    model: Option<String>,
    _reasoning_effort: Option<String>,
) -> Option<ThreadInfo> {
    let upstream_thread: upstream::Thread = crate::rpc::convert_generated_field(thread).ok()?;
    let mut info = ThreadInfo::from(upstream_thread);
    info.model = model;
    Some(info)
}

pub fn thread_snapshot_from_generated_thread(
    server_id: &str,
    thread: generated::Thread,
    model: Option<String>,
    reasoning_effort: Option<String>,
) -> Result<ThreadSnapshot, String> {
    let upstream_thread: upstream::Thread =
        crate::rpc::convert_generated_field(thread).map_err(|e| e.to_string())?;
    let info = ThreadInfo::from(upstream_thread.clone());
    let items = crate::conversation::hydrate_turns(&upstream_thread.turns, &Default::default());
    let mut snapshot = ThreadSnapshot::from_info(server_id, info);
    snapshot.items = items;
    snapshot.model = model;
    snapshot.reasoning_effort = reasoning_effort;
    Ok(snapshot)
}

pub fn copy_thread_runtime_fields(source: &ThreadSnapshot, target: &mut ThreadSnapshot) {
    if target.model.is_none() {
        target.model = source.model.clone();
    }
    if target.reasoning_effort.is_none() {
        target.reasoning_effort = source.reasoning_effort.clone();
    }
    target.active_turn_id = source.active_turn_id.clone();
    target.context_tokens_used = source.context_tokens_used;
    target.model_context_window = source.model_context_window;
    target.rate_limits = source.rate_limits.clone();
    target.realtime_session_id = source.realtime_session_id.clone();
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
                crate::conversation::ConversationItemContent::User(_)
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
                crate::conversation::ConversationItemContent::User(_)
            )
        })
        .nth(selected_turn_index)
        .ok_or_else(|| {
            RpcError::Deserialization(format!("unknown user turn index {}", selected_turn_index))
        })?;
    match &item.content {
        crate::conversation::ConversationItemContent::User(data) => Ok(data.text.clone()),
        _ => Err(RpcError::Deserialization(
            "selected turn has no editable text".to_string(),
        )),
    }
}

pub fn reasoning_effort_string(value: generated::ReasoningEffort) -> String {
    match value {
        generated::ReasoningEffort::None => "none".to_string(),
        generated::ReasoningEffort::Minimal => "minimal".to_string(),
        generated::ReasoningEffort::Low => "low".to_string(),
        generated::ReasoningEffort::Medium => "medium".to_string(),
        generated::ReasoningEffort::High => "high".to_string(),
        generated::ReasoningEffort::XHigh => "xhigh".to_string(),
    }
}

pub fn reasoning_effort_from_string(value: &str) -> Option<generated::ReasoningEffort> {
    match value.trim().to_ascii_lowercase().as_str() {
        "none" => Some(generated::ReasoningEffort::None),
        "minimal" => Some(generated::ReasoningEffort::Minimal),
        "low" => Some(generated::ReasoningEffort::Low),
        "medium" => Some(generated::ReasoningEffort::Medium),
        "high" => Some(generated::ReasoningEffort::High),
        "xhigh" => Some(generated::ReasoningEffort::XHigh),
        _ => None,
    }
}

fn map_transport_error(error: TransportError) -> RpcError {
    RpcError::Transport(error)
}

fn map_rpc_client_error(error: crate::rpc::RpcClientError) -> RpcError {
    match error {
        crate::rpc::RpcClientError::Rpc(message)
        | crate::rpc::RpcClientError::Serialization(message) => RpcError::Deserialization(message),
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
    let existing = app_store
        .snapshot()
        .threads
        .get(&ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        })
        .cloned();
    let response = session
        .request(
            "thread/read",
            serde_json::json!({ "threadId": thread_id, "includeTurns": true }),
        )
        .await?;
    let thread = response
        .get("thread")
        .cloned()
        .ok_or_else(|| RpcError::Deserialization("thread/read response missing thread".to_string()))
        .and_then(|value| {
            serde_json::from_value::<upstream::Thread>(value).map_err(|error| {
                RpcError::Deserialization(format!("deserialize thread/read response: {error}"))
            })
        })?;
    let mut snapshot = thread_snapshot_from_upstream_thread(server_id, thread);
    if let Some(existing) = existing.as_ref() {
        copy_thread_runtime_fields(existing, &mut snapshot);
    }
    app_store.upsert_thread_snapshot(snapshot);
    Ok(())
}

fn thread_snapshot_from_upstream_thread(
    server_id: &str,
    thread: upstream::Thread,
) -> ThreadSnapshot {
    let info = ThreadInfo::from(thread.clone());
    let items = crate::conversation::hydrate_turns(&thread.turns, &Default::default());
    let mut snapshot = ThreadSnapshot::from_info(server_id, info);
    snapshot.items = items;
    snapshot
}

async fn send_ipc_approval_response(
    ipc_client: &IpcClient,
    approval: &PendingApproval,
    thread_id: &str,
    decision: ApprovalDecisionValue,
) -> Result<bool, RpcError> {
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
    let response_json = serde_json::to_value(generated::ToolRequestUserInputResponse {
        answers: answers
            .into_iter()
            .map(
                |answer| generated::ToolRequestUserInputResponseAnswersEntry {
                    key: answer.question_id,
                    value: generated::ToolRequestUserInputAnswer {
                        answers: answer.answers,
                    },
                },
            )
            .collect(),
    })
    .map_err(|error| {
        RpcError::Deserialization(format!("serialize user input response: {error}"))
    })?;
    let response = serde_json::from_value(response_json).map_err(|error| {
        RpcError::Deserialization(format!("deserialize IPC user input response: {error}"))
    })?;
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
    decision: ApprovalDecisionValue,
) -> Result<serde_json::Value, RpcError> {
    match approval.kind {
        crate::types::ApprovalKind::Command => {
            serde_json::to_value(generated::CommandExecutionRequestApprovalResponse {
                decision: match decision {
                    ApprovalDecisionValue::Accept => {
                        generated::CommandExecutionApprovalDecision::Accept
                    }
                    ApprovalDecisionValue::AcceptForSession => {
                        generated::CommandExecutionApprovalDecision::AcceptForSession
                    }
                    ApprovalDecisionValue::Decline => {
                        generated::CommandExecutionApprovalDecision::Decline
                    }
                    ApprovalDecisionValue::Cancel => {
                        generated::CommandExecutionApprovalDecision::Cancel
                    }
                },
            })
        }
        crate::types::ApprovalKind::FileChange => {
            serde_json::to_value(generated::FileChangeRequestApprovalResponse {
                decision: match decision {
                    ApprovalDecisionValue::Accept => generated::FileChangeApprovalDecision::Accept,
                    ApprovalDecisionValue::AcceptForSession => {
                        generated::FileChangeApprovalDecision::AcceptForSession
                    }
                    ApprovalDecisionValue::Decline => {
                        generated::FileChangeApprovalDecision::Decline
                    }
                    ApprovalDecisionValue::Cancel => generated::FileChangeApprovalDecision::Cancel,
                },
            })
        }
        crate::types::ApprovalKind::Permissions | crate::types::ApprovalKind::McpElicitation => {
            let requested_permissions =
                serde_json::from_str::<serde_json::Value>(&approval.raw_params_json)
                    .ok()
                    .and_then(|value| value.get("permissions").cloned())
                    .and_then(|value| {
                        serde_json::from_value::<generated::GrantedPermissionProfile>(value).ok()
                    })
                    .unwrap_or(generated::GrantedPermissionProfile {
                        network: None,
                        file_system: None,
                    });
            serde_json::to_value(generated::PermissionsRequestApprovalResponse {
                permissions: match decision {
                    ApprovalDecisionValue::Accept | ApprovalDecisionValue::AcceptForSession => {
                        requested_permissions
                    }
                    ApprovalDecisionValue::Decline | ApprovalDecisionValue::Cancel => {
                        generated::GrantedPermissionProfile {
                            network: None,
                            file_system: None,
                        }
                    }
                },
                scope: match decision {
                    ApprovalDecisionValue::AcceptForSession => "session".to_string(),
                    _ => "once".to_string(),
                },
            })
        }
    }
    .map_err(|e| RpcError::Deserialization(format!("serialize approval response: {e}")))
}

#[cfg(test)]
mod mobile_client_tests {
    use super::*;
    use crate::types::ThreadSummaryStatus;

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
            Some(generated::ReasoningEffort::Low)
        );
        assert_eq!(
            reasoning_effort_from_string("MEDIUM"),
            Some(generated::ReasoningEffort::Medium)
        );
        assert_eq!(
            reasoning_effort_from_string(" high "),
            Some(generated::ReasoningEffort::High)
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
        assert_eq!(target.active_turn_id.as_deref(), Some("turn-1"));
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
}
