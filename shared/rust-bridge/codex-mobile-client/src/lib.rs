//! Shared mobile client library for Codex iOS and Android apps.
//!
//! This crate provides a unified client interface that both platforms consume
//! through FFI, eliminating duplicated protocol types, transport logic,
//! session management, and business logic.

#[cfg(target_os = "ios")]
mod aec;

pub mod conversation;
pub mod conversation_uniffi;
pub mod discovery_uniffi;
pub mod uniffi_shared;
/// FFI-exportable wrapper types for all Codex protocol messages.
pub mod types;

/// Transport layer: WebSocket, in-process channel, and JSON-RPC correlation.
pub mod transport;

/// Session management: connection lifecycle, thread management, event routing.
pub mod session;

/// Server discovery: Bonjour/mDNS, Tailscale, LAN probing.
pub mod discovery;

/// SSH bootstrap client for remote server setup.
pub mod ssh;

/// Tool call message parser (markdown → typed tool cards).
pub mod parser;

/// Progressive message hydration and LRU caching.
pub mod hydration;

/// Internal generated RPC client and conversion helpers.
pub mod rpc;

/// Canonical app/session/thread store built on top of the shared client.
pub mod store;

/// FFI layer: UniFFI bindings for iOS and Android.
pub mod ffi;

// UniFFI scaffolding — must be in the crate root.
uniffi::setup_scaffolding!();

// ---------------------------------------------------------------------------
// MobileClient — top-level facade
// ---------------------------------------------------------------------------

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, RwLock};
use tokio::sync::broadcast;
use tracing::{debug, info, warn};

use crate::discovery::{DiscoveredServer, DiscoveryConfig, DiscoveryService, MdnsSeed};
use crate::session::connection::InProcessConfig;
use crate::session::connection::{ServerConfig, ServerSession};
use crate::session::events::{EventProcessor, UiEvent};
use crate::store::{AppSnapshot, AppStoreReducer, AppUpdate, ServerHealthSnapshot, ThreadSnapshot};
use crate::transport::{RpcError, TransportError};
use crate::types::{PendingApproval, ThreadInfo, ThreadKey, ThreadSummaryStatus, generated};
use codex_app_server_protocol as upstream;

/// Top-level entry point for platform code (iOS / Android).
///
/// Ties together server sessions, thread management, event processing,
/// discovery, auth, caching, and voice handoff into a single facade.
/// All methods are safe to call from any thread (`Send + Sync`).
pub struct MobileClient {
    sessions: RwLock<HashMap<String, Arc<ServerSession>>>,
    event_processor: Arc<EventProcessor>,
    app_store: Arc<AppStoreReducer>,
    discovery: RwLock<DiscoveryService>,
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

    // ── Server Management ─────────────────────────────────────────────

    /// Connect to a local (in-process) Codex server.
    ///
    /// Returns the `server_id` from the config on success.
    pub(crate) async fn connect_local(
        &self,
        config: ServerConfig,
        in_process: InProcessConfig,
    ) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
        let session = Arc::new(ServerSession::connect_local(config, in_process).await?);
        self.app_store
            .upsert_server(session.config(), ServerHealthSnapshot::Connected);

        self.spawn_event_reader(server_id.clone(), Arc::clone(&session));

        self.sessions
            .write()
            .expect("sessions lock poisoned")
            .insert(server_id.clone(), session);

        if let Err(error) = self.sync_server_account(server_id.as_str()).await {
            warn!("MobileClient: failed to sync account for {server_id}: {error}");
        }

        info!("MobileClient: connected local server {server_id}");
        Ok(server_id)
    }

    /// Connect to a remote Codex server via WebSocket.
    ///
    /// Returns the `server_id` from the config on success.
    pub(crate) async fn connect_remote(&self, config: ServerConfig) -> Result<String, TransportError> {
        let server_id = config.server_id.clone();
        let session = Arc::new(ServerSession::connect_remote(config).await?);
        self.app_store
            .upsert_server(session.config(), ServerHealthSnapshot::Connected);

        self.spawn_event_reader(server_id.clone(), Arc::clone(&session));

        self.sessions
            .write()
            .expect("sessions lock poisoned")
            .insert(server_id.clone(), session);

        if let Err(error) = self.sync_server_account(server_id.as_str()).await {
            warn!("MobileClient: failed to sync account for {server_id}: {error}");
        }

        info!("MobileClient: connected remote server {server_id}");
        Ok(server_id)
    }

    /// Disconnect a server by its ID.
    pub(crate) fn disconnect_server(&self, server_id: &str) {
        let session = self
            .sessions
            .write()
            .expect("sessions lock poisoned")
            .remove(server_id);

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
        self.sessions
            .read()
            .expect("sessions lock poisoned")
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

    pub(crate) async fn sync_server_account(&self, server_id: &str) -> Result<(), RpcError> {
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

    /// Roll back the current thread to a selected user turn and return the
    /// message text that should be restored into the composer for editing.
    pub(crate) async fn edit_message(
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
            )?;
            copy_thread_runtime_fields(&current, &mut snapshot);
            self.app_store.upsert_thread_snapshot(snapshot);
        }

        self.set_active_thread(Some(key.clone()));
        Ok(prefill_text)
    }

    /// Fork a thread from a selected user message boundary.
    pub(crate) async fn fork_thread_from_message(
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
                    persist_extended_history,
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
        )?;
        let next_key = snapshot.key.clone();

        if rollback_depth > 0 {
            let rollback = self
                .generated_thread_rollback(
                    &next_key.server_id,
                    generated::ThreadRollbackParams {
                        thread_id: next_key.thread_id.clone(),
                        num_turns: rollback_depth,
                    },
                )
                .await
                .map_err(|e| RpcError::Deserialization(e.to_string()))?;
            snapshot = thread_snapshot_from_generated_thread(
                &next_key.server_id,
                rollback.thread,
                fork_model,
                fork_reasoning,
            )?;
        }

        self.app_store.upsert_thread_snapshot(snapshot);
        self.set_active_thread(Some(next_key.clone()));
        Ok(next_key)
    }

    /// Set the active thread. Pass `None` to clear.
    pub(crate) fn set_active_thread(&self, key: Option<ThreadKey>) {
        self.app_store.set_active_thread(key);
    }

    /// Get the active thread state, if any.
    #[cfg(test)]
    pub(crate) fn active_thread(&self) -> Option<ThreadSnapshot> {
        let snapshot = self.app_store.snapshot();
        let key = snapshot.active_thread?;
        snapshot.threads.get(&key).cloned()
    }

    // ── Approvals ─────────────────────────────────────────────────────

    /// Approve a pending server request (tool call / file change / etc.).
    pub async fn approve(&self, request_id: &str) -> Result<(), RpcError> {
        let approval = self
            .event_processor
            .resolve_approval(request_id)
            .ok_or_else(|| RpcError::Server {
                code: -1,
                message: format!("no pending approval with id {request_id}"),
            })?;

        let server_id = approval
            .thread_id
            .as_ref()
            .and_then(|_| {
                // The approval doesn't carry server_id directly; find the session
                // that owns the thread. For now, iterate connected sessions.
                None::<String>
            })
            .or_else(|| {
                // Try to find the session from the thread manager.
                self.find_server_for_approval(&approval)
            })
            .unwrap_or_default();

        let session = self.get_session(&server_id)?;
        let result = serde_json::json!({ "approved": true });
        let id_value = serde_json::Value::String(approval.id);
        let response = session.respond(id_value, result).await;
        if response.is_ok() {
            self.app_store.resolve_approval(request_id);
        }
        response
    }

    /// Deny a pending server request.
    pub async fn deny(&self, request_id: &str) -> Result<(), RpcError> {
        let approval = self
            .event_processor
            .resolve_approval(request_id)
            .ok_or_else(|| RpcError::Server {
                code: -1,
                message: format!("no pending approval with id {request_id}"),
            })?;

        let server_id = self.find_server_for_approval(&approval).unwrap_or_default();
        let session = self.get_session(&server_id)?;
        let result = serde_json::json!({ "approved": false });
        let id_value = serde_json::Value::String(approval.id);
        let response = session.respond(id_value, result).await;
        if response.is_ok() {
            self.app_store.resolve_approval(request_id);
        }
        response
    }

    pub(crate) async fn respond_to_approval(
        &self,
        request_id: &str,
        decision: crate::types::ApprovalDecisionValue,
    ) -> Result<(), RpcError> {
        let approval = self
            .event_processor
            .resolve_approval(request_id)
            .ok_or_else(|| RpcError::Server {
                code: -1,
                message: format!("no pending approval with id {request_id}"),
            })?;

        let server_id = if !approval.server_id.is_empty() {
            approval.server_id.clone()
        } else {
            self.find_server_for_approval(&approval).unwrap_or_default()
        };
        let session = self.get_session(&server_id)?;

        let decision_value = match approval.method.as_str() {
            "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {
                match decision {
                    crate::types::ApprovalDecisionValue::Accept => "approved",
                    crate::types::ApprovalDecisionValue::AcceptForSession => "approved_for_session",
                    crate::types::ApprovalDecisionValue::Decline => "denied",
                    crate::types::ApprovalDecisionValue::Cancel => "abort",
                }
            }
            _ => match decision {
                crate::types::ApprovalDecisionValue::Accept => "accept",
                crate::types::ApprovalDecisionValue::AcceptForSession => "accept_for_session",
                crate::types::ApprovalDecisionValue::Decline => "decline",
                crate::types::ApprovalDecisionValue::Cancel => "cancel",
            },
        };

        let result = serde_json::json!({ "decision": decision_value });
        let id_value = serde_json::Value::String(approval.id);
        let response = session.respond(id_value, result).await;
        if response.is_ok() {
            self.app_store.resolve_approval(request_id);
        }
        response
    }

    pub(crate) async fn respond_to_user_input(
        &self,
        request_id: &str,
        answers: Vec<crate::types::PendingUserInputAnswer>,
    ) -> Result<(), RpcError> {
        let request = self
            .app_store
            .snapshot()
            .pending_user_inputs
            .into_iter()
            .find(|request| request.id == request_id)
            .ok_or_else(|| RpcError::Server {
                code: -1,
                message: format!("no pending user input request with id {request_id}"),
            })?;

        let payload_answers = answers
            .into_iter()
            .map(|answer| {
                (
                    answer.question_id,
                    serde_json::json!({
                        "answers": answer.answers,
                    }),
                )
            })
            .collect::<serde_json::Map<String, serde_json::Value>>();

        let session = self.get_session(&request.server_id)?;
        let response = session
            .respond(
                serde_json::Value::String(request.id.clone()),
                serde_json::json!({ "answers": payload_answers }),
            )
            .await;
        if response.is_ok() {
            self.app_store.resolve_pending_user_input(request_id);
        }
        response
    }

    /// Return a snapshot of all pending approvals.
    #[cfg(test)]
    pub(crate) fn pending_approvals(&self) -> Vec<PendingApproval> {
        self.app_store.snapshot().pending_approvals
    }

    pub(crate) fn app_snapshot(&self) -> AppSnapshot {
        self.app_store.snapshot()
    }

    pub(crate) fn subscribe_app_updates(&self) -> broadcast::Receiver<AppUpdate> {
        self.app_store.subscribe()
    }

    // ── Discovery ─────────────────────────────────────────────────────

    /// Run a one-shot server discovery scan using platform-resolved mDNS seeds
    /// plus optional network hints from the UI layer.
    pub(crate) async fn scan_servers_with_mdns_context(
        &self,
        seeds: Vec<MdnsSeed>,
        local_ipv4: Option<String>,
    ) -> Vec<DiscoveredServer> {
        let discovery = { self.discovery.read().expect("discovery lock poisoned") };
        discovery
            .scan_once_with_context(&seeds, local_ipv4.as_deref())
            .await
    }

    // ── Internal helpers ──────────────────────────────────────────────

    /// Look up a session by server_id, returning an `Arc` clone.
    fn get_session(&self, server_id: &str) -> Result<Arc<ServerSession>, RpcError> {
        self.sessions
            .read()
            .expect("sessions lock poisoned")
            .get(server_id)
            .cloned()
            .ok_or_else(|| RpcError::Server {
                code: -1,
                message: format!("no session for server_id '{server_id}'"),
            })
    }

    fn snapshot_thread(&self, key: &ThreadKey) -> Result<ThreadSnapshot, RpcError> {
        self.app_store
            .snapshot()
            .threads
            .get(key)
            .cloned()
            .ok_or_else(|| RpcError::Deserialization("thread unavailable".to_string()))
    }

    /// Spawn a background task that reads typed server events
    /// from a session and feeds them to the event processor.
    fn spawn_event_reader(&self, server_id: String, session: Arc<ServerSession>) {
        use crate::session::connection::ServerEvent;

        let event_processor = Arc::clone(&self.event_processor);

        let sid = server_id;
        let ep = event_processor;
        let mut event_rx = session.events();
        tokio::spawn(async move {
            loop {
                match event_rx.recv().await {
                    Ok(event) => match event {
                        ServerEvent::Notification(notification) => {
                            ep.process_notification(&sid, &notification);
                        }
                        ServerEvent::Request(request) => {
                            ep.process_server_request(&sid, &request);
                        }
                        ServerEvent::LegacyNotification { method, params } => {
                            if method == "codex/event" || method.starts_with("codex/event/") {
                                ep.process_legacy_notification(&sid, &method, &params);
                            } else {
                                debug!(
                                    "MobileClient: legacy notification for {sid}: {method} — ignored"
                                );
                            }
                        }
                    },
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!("MobileClient: event reader for {sid} lagged {n}");
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        debug!("MobileClient: event channel closed for {sid}");
                        break;
                    }
                }
            }
        });
    }

    fn spawn_detached<F>(future: F)
    where
        F: Future<Output = ()> + Send + 'static,
    {
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(future);
            return;
        }

        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("failed to create Tokio runtime for detached task");
            runtime.block_on(future);
        });
    }

    /// Try to determine which server owns an approval based on thread keys.
    fn find_server_for_approval(&self, approval: &PendingApproval) -> Option<String> {
        let thread_id = approval.thread_id.as_ref()?;
        let sessions = self.sessions.read().expect("sessions lock poisoned");
        let app_snapshot = self.app_store.snapshot();
        for (server_id, _session) in sessions.iter() {
            let key = ThreadKey {
                server_id: server_id.clone(),
                thread_id: thread_id.clone(),
            };
            if app_snapshot.threads.contains_key(&key) {
                return Some(server_id.clone());
            }
        }
        // Fallback: if only one session is connected, use it.
        if sessions.len() == 1 {
            return sessions.keys().next().cloned();
        }
        None
    }

    /// Send a typed `ClientRequest` to a specific server session and deserialize the response.
    pub async fn request_typed_for_server<R: serde::de::DeserializeOwned>(
        &self,
        server_id: &str,
        request: codex_app_server_protocol::ClientRequest,
    ) -> Result<R, String> {
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        let result = session
            .request_client(request)
            .await
            .map_err(|e| e.to_string())?;
        #[cfg(feature = "rpc-trace")]
        {
            let dst = std::any::type_name::<R>();
            eprintln!("[codex-rpc] response -> {dst}");
        }
        serde_json::from_value(result.clone()).map_err(|e| {
            #[cfg(feature = "rpc-trace")]
            {
                let dst = std::any::type_name::<R>();
                let json = serde_json::to_string_pretty(&result).unwrap_or_default();
                eprintln!(
                    "[codex-rpc] FAILED response -> {dst}: {e}\n--- response JSON ---\n{json}\n---"
                );
            }
            format!("deserialize response: {e}")
        })
    }

    /// Send a response to a server request on a specific server.
    pub async fn respond_for_server(
        &self,
        server_id: &str,
        id: serde_json::Value,
        result: serde_json::Value,
    ) -> Result<(), String> {
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        session.respond(id, result).await.map_err(|e| e.to_string())
    }

    /// Reject a server request on a specific server with a JSON-RPC error.
    pub async fn reject_for_server(
        &self,
        server_id: &str,
        id: serde_json::Value,
        error: codex_app_server_protocol::JSONRPCErrorError,
    ) -> Result<(), String> {
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        session.reject(id, error).await.map_err(|e| e.to_string())
    }
}

fn spawn_store_listener(app_store: Arc<AppStoreReducer>, mut rx: broadcast::Receiver<UiEvent>) {
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("failed to create Tokio runtime for app store reducer");
        runtime.block_on(async move {
            loop {
                match rx.recv().await {
                    Ok(event) => app_store.apply_ui_event(&event),
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    });
}

pub(crate) fn thread_snapshot_from_generated_thread(
    server_id: &str,
    thread: generated::Thread,
    model: Option<String>,
    reasoning_effort: Option<String>,
) -> Result<ThreadSnapshot, RpcError> {
    let upstream_thread: upstream::Thread = crate::rpc::convert_generated_field(thread)
        .map_err(|e| RpcError::Deserialization(e.to_string()))?;
    Ok(thread_snapshot_from_upstream_thread(
        server_id,
        upstream_thread,
        model,
        reasoning_effort,
    ))
}

fn thread_snapshot_from_upstream_thread(
    server_id: &str,
    upstream_thread: upstream::Thread,
    model: Option<String>,
    reasoning_effort: Option<String>,
) -> ThreadSnapshot {
    let mut info = ThreadInfo::from(upstream_thread.clone());
    info.model = model.clone();
    let key = ThreadKey {
        server_id: server_id.to_string(),
        thread_id: info.id.clone(),
    };
    let items = crate::conversation::hydrate_turns(
        &upstream_thread.turns,
        &crate::conversation::HydrationOptions {
            default_agent_nickname: info.agent_nickname.clone(),
            default_agent_role: info.agent_role.clone(),
        },
    );
    ThreadSnapshot {
        key,
        info,
        model,
        reasoning_effort,
        items,
        active_turn_id: None,
        context_tokens_used: None,
        model_context_window: None,
        rate_limits: None,
        realtime_session_id: None,
    }
}

fn thread_info_from_generated_thread(thread: generated::Thread) -> Option<ThreadInfo> {
    let upstream_thread: upstream::Thread = crate::rpc::convert_generated_field(thread).ok()?;
    Some(ThreadInfo::from(upstream_thread))
}

pub(crate) fn copy_thread_runtime_fields(source: &ThreadSnapshot, target: &mut ThreadSnapshot) {
    target.context_tokens_used = source.context_tokens_used;
    target.model_context_window = source.model_context_window;
    target.rate_limits = source.rate_limits.clone();
    target.realtime_session_id = source.realtime_session_id.clone();
}

fn map_rpc_client_error(error: crate::rpc::RpcClientError) -> RpcError {
    RpcError::Server {
        code: -1,
        message: error.to_string(),
    }
}

fn ensure_thread_is_editable(thread: &ThreadSnapshot) -> Result<(), RpcError> {
    if thread.active_turn_id.is_some() || matches!(thread.info.status, ThreadSummaryStatus::Active)
    {
        return Err(RpcError::Deserialization(
            "Wait for the active turn to finish before editing or forking".to_string(),
        ));
    }
    Ok(())
}

fn rollback_depth_for_turn(
    thread: &ThreadSnapshot,
    selected_turn_index: usize,
) -> Result<u32, RpcError> {
    let total_turns = inferred_turn_count(&thread.items);
    if total_turns == 0 {
        return Err(RpcError::Deserialization(
            "No turn history available".to_string(),
        ));
    }
    if selected_turn_index >= total_turns {
        return Err(RpcError::Deserialization(
            "Message is outside available turn history".to_string(),
        ));
    }
    Ok((total_turns - selected_turn_index - 1) as u32)
}

fn user_boundary_text_for_turn(
    thread: &ThreadSnapshot,
    selected_turn_index: usize,
) -> Result<String, RpcError> {
    let item = thread
        .items
        .iter()
        .find(|item| {
            item.is_from_user_turn_boundary
                && item.source_turn_index == Some(selected_turn_index)
                && matches!(
                    &item.content,
                    crate::conversation::ConversationItemContent::User(_)
                )
        })
        .ok_or_else(|| {
            RpcError::Deserialization(
                "Fork from here is only supported for user messages".to_string(),
            )
        })?;

    match &item.content {
        crate::conversation::ConversationItemContent::User(data) => Ok(data.text.clone()),
        _ => Err(RpcError::Deserialization(
            "Fork from here is only supported for user messages".to_string(),
        )),
    }
}

fn inferred_turn_count(items: &[crate::conversation::ConversationItem]) -> usize {
    items
        .iter()
        .filter_map(|item| item.source_turn_index)
        .max()
        .map(|index| index + 1)
        .unwrap_or_else(|| {
            items
                .iter()
                .filter(|item| {
                    item.is_from_user_turn_boundary
                        && matches!(
                            &item.content,
                            crate::conversation::ConversationItemContent::User(_)
                        )
                })
                .count()
        })
}

pub(crate) fn reasoning_effort_string(value: generated::ReasoningEffort) -> String {
    match value {
        generated::ReasoningEffort::None => "none",
        generated::ReasoningEffort::Minimal => "minimal",
        generated::ReasoningEffort::Low => "low",
        generated::ReasoningEffort::Medium => "medium",
        generated::ReasoningEffort::High => "high",
        generated::ReasoningEffort::XHigh => "xhigh",
    }
    .to_string()
}

pub(crate) fn reasoning_effort_from_string(value: &str) -> Option<generated::ReasoningEffort> {
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod mobile_client_tests {
    use super::*;

    fn make_client() -> MobileClient {
        MobileClient::new()
    }

    // -- Construction --

    #[test]
    fn new_client_has_no_sessions() {
        let client = make_client();
        assert!(client.connected_servers().is_empty());
    }

    #[test]
    fn new_client_has_no_active_thread() {
        let client = make_client();
        assert!(client.active_thread().is_none());
    }

    #[test]
    fn new_client_has_no_pending_approvals() {
        let client = make_client();
        assert!(client.pending_approvals().is_empty());
    }

    // -- Send + Sync --

    #[test]
    fn mobile_client_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<MobileClient>();
    }

    // -- Active thread --

    #[test]
    fn set_and_get_active_thread() {
        let client = make_client();
        let key = ThreadKey {
            server_id: "srv1".into(),
            thread_id: "thr_1".into(),
        };
        client.set_active_thread(Some(key.clone()));
        // active_thread() returns None because no thread snapshot exists yet.
        assert!(client.active_thread().is_none());
    }

    #[test]
    fn clear_active_thread() {
        let client = make_client();
        client.set_active_thread(None);
        assert!(client.active_thread().is_none());
    }

    // -- Disconnect unknown server --

    #[test]
    fn disconnect_unknown_server_does_not_panic() {
        let client = make_client();
        client.disconnect_server("nonexistent");
    }

    // -- get_session errors --

    #[test]
    fn get_session_unknown_returns_error() {
        let client = make_client();
        let result = client.get_session("unknown");
        assert!(result.is_err());
    }

    // -- Integration with remote server --

    #[tokio::test]
    async fn connect_and_disconnect_remote() {
        use futures::{SinkExt, StreamExt};
        use tokio::net::TcpListener;
        use tokio_tungstenite::accept_async;
        use tokio_tungstenite::tungstenite::protocol::Message;

        // Start a WS server that handles the initialize/initialized handshake.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        let server = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let ws = match accept_async(stream).await {
                    Ok(ws) => ws,
                    Err(_) => continue,
                };
                let (mut sink, mut stream) = ws.split();
                while let Some(Ok(msg)) = stream.next().await {
                    match msg {
                        Message::Text(text) => {
                            // Handle JSON-RPC messages
                            if let Ok(parsed) =
                                serde_json::from_str::<serde_json::Value>(text.as_ref())
                            {
                                if let Some(id) = parsed.get("id") {
                                    if parsed.get("method").is_some() {
                                        // Request — respond with success
                                        let response = serde_json::json!({
                                            "id": id,
                                            "result": {}
                                        });
                                        let _ = sink
                                            .send(Message::Text(response.to_string().into()))
                                            .await;
                                    }
                                }
                                // Notifications (like "initialized") — just consume
                            }
                        }
                        Message::Ping(data) => {
                            let _ = sink.send(Message::Pong(data)).await;
                        }
                        Message::Close(_) => break,
                        _ => {}
                    }
                }
            }
        });

        let client = make_client();
        let config = ServerConfig {
            server_id: "test-1".into(),
            display_name: "Test".into(),
            host: "127.0.0.1".into(),
            port: addr.port(),
            websocket_url: None,
            is_local: false,
            tls: false,
        };

        let sid = client.connect_remote(config).await.expect("should connect");
        assert_eq!(sid, "test-1");
        assert_eq!(client.connected_servers().len(), 1);

        client.disconnect_server("test-1");
        // Give the async disconnect a moment.
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        assert!(client.connected_servers().is_empty());

        server.abort();
    }

    #[tokio::test]
    async fn connect_remote_invalid_port_fails() {
        let client = make_client();
        let config = ServerConfig {
            server_id: "bad".into(),
            display_name: "Bad".into(),
            host: "127.0.0.1".into(),
            port: 1,
            websocket_url: None,
            is_local: false,
            tls: false,
        };

        let result = client.connect_remote(config).await;
        assert!(result.is_err());
        assert!(client.connected_servers().is_empty());
    }

    #[tokio::test]
    async fn list_threads_unknown_server_returns_error() {
        let client = make_client();
        let result = client.list_threads("nonexistent").await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn approve_unknown_id_returns_error() {
        let client = make_client();
        let result = client.approve("999").await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn deny_unknown_id_returns_error() {
        let client = make_client();
        let result = client.deny("999").await;
        assert!(result.is_err());
    }

    // -- Discovery (scan_once with no network returns empty) --

    #[tokio::test]
    async fn scan_servers_with_mdns_context_returns_vec() {
        let client = make_client();
        let servers = client.scan_servers_with_mdns_context(Vec::new(), None).await;
        // With default config and no real network, may return empty.
        // Just verify it doesn't panic and returns a Vec.
        let _ = servers;
    }
}
