use super::*;
use codex_ipc::{BridgeEvent, BridgeOutput, IpcBridge};
use std::time::{Duration, Instant};

enum IpcStreamProcessorMessage {
    StreamEvent(ThreadStreamStateChangedParams),
    Recovery(PendingIpcStreamRecovery),
    StaleTurnCheck,
}

const IPC_STREAM_BATCH_COLLECT_WINDOW: Duration = Duration::from_millis(50);
const IPC_STALE_TURN_CHECK_INTERVAL: Duration = Duration::from_secs(5);
const IPC_STALE_TURN_QUIET_THRESHOLD: Duration = Duration::from_secs(5);

struct IpcStreamProcessorState {
    bridge: IpcBridge,
    pending_thread_events: HashMap<String, VecDeque<ThreadStreamStateChangedParams>>,
    recovering_threads: HashSet<String>,
}

impl Default for IpcStreamProcessorState {
    fn default() -> Self {
        Self {
            bridge: IpcBridge::new(),
            pending_thread_events: HashMap::new(),
            recovering_threads: HashSet::new(),
        }
    }
}

impl MobileClient {
    pub(super) fn spawn_event_reader(&self, server_id: String, session: Arc<ServerSession>) {
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

    pub(super) fn spawn_health_reader(
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

    pub(super) fn spawn_ipc_connection_state_reader(
        &self,
        server_id: String,
        session: Arc<ServerSession>,
    ) {
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

    pub(super) fn spawn_ipc_reader(&self, server_id: String, session: Arc<ServerSession>) {
        let Some(mut broadcasts) = session.ipc_broadcasts() else {
            return;
        };
        let app_store = Arc::clone(&self.app_store);
        let loop_server_id = server_id.clone();
        let processor_state = Arc::new(StdMutex::new(IpcStreamProcessorState::default()));
        let (stream_processor_tx, mut stream_processor_rx) =
            mpsc::unbounded_channel::<IpcStreamProcessorMessage>();
        Self::spawn_detached(async move {
            let (recovery_tx, mut recovery_rx) =
                mpsc::unbounded_channel::<PendingIpcStreamRecovery>();
            {
                let processor_state = Arc::clone(&processor_state);
                let processor_session = Arc::clone(&session);
                let processor_app_store = Arc::clone(&app_store);
                let processor_server_id = loop_server_id.clone();
                let processor_recovery_tx = recovery_tx.clone();
                MobileClient::spawn_detached(async move {
                    let mut stale_turn_interval =
                        tokio::time::interval(IPC_STALE_TURN_CHECK_INTERVAL);
                    stale_turn_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                    // Skip the first immediate tick.
                    stale_turn_interval.tick().await;
                    loop {
                        let first_message = tokio::select! {
                            maybe_message = stream_processor_rx.recv() => {
                                let Some(message) = maybe_message else {
                                    break;
                                };
                                message
                            }
                            maybe_recovery = recovery_rx.recv() => {
                                let Some(recovery) = maybe_recovery else {
                                    continue;
                                };
                                IpcStreamProcessorMessage::Recovery(recovery)
                            }
                            _ = stale_turn_interval.tick() => {
                                IpcStreamProcessorMessage::StaleTurnCheck
                            }
                        };
                        let mut messages = vec![first_message];
                        let batch_deadline = Instant::now() + IPC_STREAM_BATCH_COLLECT_WINDOW;
                        loop {
                            while let Ok(message) = stream_processor_rx.try_recv() {
                                messages.push(message);
                            }
                            while let Ok(recovery) = recovery_rx.try_recv() {
                                messages.push(IpcStreamProcessorMessage::Recovery(recovery));
                            }

                            let now = Instant::now();
                            if now >= batch_deadline {
                                break;
                            }

                            let remaining = batch_deadline.saturating_duration_since(now);
                            let next_message = tokio::time::timeout(remaining, async {
                                tokio::select! {
                                    maybe_message = stream_processor_rx.recv() => maybe_message,
                                    maybe_recovery = recovery_rx.recv() => {
                                        maybe_recovery.map(IpcStreamProcessorMessage::Recovery)
                                    }
                                }
                            })
                            .await
                            .ok()
                            .flatten();

                            let Some(message) = next_message else {
                                break;
                            };
                            messages.push(message);
                        }

                        let processor_state = Arc::clone(&processor_state);
                        let processor_session = Arc::clone(&processor_session);
                        let processor_app_store = Arc::clone(&processor_app_store);
                        let processor_server_id = processor_server_id.clone();
                        let processor_server_id_for_log = processor_server_id.clone();
                        let processor_recovery_tx = processor_recovery_tx.clone();
                        let result = tokio::task::spawn_blocking(move || {
                            let mut state = processor_state
                                .lock()
                                .expect("ipc stream processor state poisoned");
                            process_ipc_stream_processor_messages(
                                &mut state,
                                messages,
                                processor_session,
                                processor_app_store,
                                &processor_server_id,
                                &processor_recovery_tx,
                            );
                        })
                        .await;

                        if let Err(error) = result {
                            warn!(
                                "MobileClient: IPC stream processor task failed on {}: {}",
                                processor_server_id_for_log, error
                            );
                        }
                    }
                });
            }
            loop {
                tokio::select! {
                    broadcast = broadcasts.recv() => match broadcast {
                        Ok(TypedBroadcast::ThreadStreamStateChanged(params)) => {
                            app_store.note_server_ipc_broadcast(&loop_server_id);

                            if !app_store.is_server_ipc_primary(&loop_server_id) {
                                debug!(
                                    "IPC in: ignoring ThreadStreamStateChanged for server={} thread={} because authority is not IPC-primary",
                                    loop_server_id, params.conversation_id
                                );
                                continue;
                            }
                            let change_type = match &params.change {
                                StreamChange::Snapshot { .. } => "snapshot",
                                StreamChange::Patches { .. } => "patches",
                            };
                            debug!(
                                "IPC in: ThreadStreamStateChanged server={} thread={} protocol_version={} change={}",
                                loop_server_id, params.conversation_id, params.version, change_type
                            );
                            if stream_processor_tx
                                .send(IpcStreamProcessorMessage::StreamEvent(params))
                                .is_err()
                            {
                                warn!(
                                    "MobileClient: IPC stream processor channel closed for {}",
                                    loop_server_id
                                );
                                break;
                            }
                        }
                        Ok(TypedBroadcast::ThreadArchived(ref params)) => {
                            if let Ok(mut state) = processor_state.lock() {
                                state.bridge.remove_thread(&params.conversation_id);
                                state.pending_thread_events.remove(&params.conversation_id);
                                state.recovering_threads.remove(&params.conversation_id);
                            }
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
                            app_store.note_server_ipc_broadcast(&loop_server_id);
                            if !app_store.is_server_ipc_primary(&loop_server_id) {
                                debug!(
                                    "IPC in: ignoring ThreadQueuedFollowupsChanged for server={} thread={} because authority is not IPC-primary",
                                    loop_server_id, params.conversation_id
                                );
                                continue;
                            }
                            let drafts = queued_follow_up_drafts_from_message_values(&params.messages);
                            debug!(
                                "IPC in: ThreadQueuedFollowupsChanged server={} thread={} previews={}",
                                loop_server_id,
                                params.conversation_id,
                                drafts.len()
                            );
                            let key = ThreadKey {
                                server_id: loop_server_id.clone(),
                                thread_id: params.conversation_id,
                            };
                            let keep_local_drafts = drafts.is_empty()
                                && app_store.server_pending_mutation_kind(&loop_server_id)
                                    == Some(ServerMutatingCommandKind::SetQueuedFollowUpsState)
                                && app_store.thread_snapshot(&key).is_some_and(|thread| {
                                    thread.active_turn_id.is_some()
                                        && !thread.queued_follow_up_drafts.is_empty()
                                });
                            if keep_local_drafts {
                                debug!(
                                    "IPC in: ignoring empty ThreadQueuedFollowupsChanged for server={} thread={} while local queued follow-up mutation is still pending",
                                    loop_server_id, key.thread_id
                                );
                                continue;
                            }
                            app_store.set_thread_follow_up_drafts(&key, drafts);
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
                            if let Ok(mut state) = processor_state.lock() {
                                state.bridge.reset();
                                state.pending_thread_events.clear();
                                state.recovering_threads.clear();
                            }
                        }
                    }
                }
            }
        });
    }

    pub(super) fn mark_server_transport_disconnected(&self, server_id: &str) {
        self.app_store
            .update_server_health(server_id, ServerHealthSnapshot::Disconnected);
        self.app_store.update_server_ipc_state(server_id, false);
        self.app_store.fail_server_over_to_direct_only(
            server_id,
            IpcFailureClassification::IpcConnectionLost,
        );
    }

    pub(super) fn reconcile_transport_error(&self, server_id: &str, error: &RpcError) {
        if matches!(error, RpcError::Transport(_)) {
            self.mark_server_transport_disconnected(server_id);
        }
    }

    pub(crate) fn get_session(&self, server_id: &str) -> Result<Arc<ServerSession>, RpcError> {
        self.sessions_read().get(server_id).cloned().ok_or_else(|| {
            // Don't mark pi-mono servers as disconnected — they don't use codex sessions
            if !self.is_pi_mono_server(server_id) {
                self.mark_server_transport_disconnected(server_id);
            }
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
        let wire_method = client_request_wire_method(&request);
        let started_at = Instant::now();
        let session = self.get_session(server_id).map_err(|e| e.to_string())?;
        info!(
            "server request start server_id={} method={}",
            server_id, wire_method
        );
        let value = session.request_client(request).await.map_err(|error| {
            self.reconcile_transport_error(server_id, &error);
            warn!(
                "server request failed server_id={} method={} duration_ms={} error={}",
                server_id,
                wire_method,
                started_at.elapsed().as_millis(),
                error
            );
            error.to_string()
        })?;
        info!(
            "server request ok server_id={} method={} duration_ms={}",
            server_id,
            wire_method,
            started_at.elapsed().as_millis()
        );
        self.app_store.note_server_direct_request_success(server_id);
        serde_json::from_value(value.clone()).map_err(|e| {
            warn!("deserialize typed RPC response: {e}\nraw payload: {value}");
            format!("deserialize typed RPC response: {e}")
        })
    }

    pub(super) fn pending_approval(&self, request_id: &str) -> Result<PendingApproval, RpcError> {
        self.app_store
            .snapshot()
            .pending_approvals
            .into_iter()
            .find(|approval| approval.id == request_id)
            .ok_or_else(|| {
                RpcError::Deserialization(format!("unknown approval request {request_id}"))
            })
    }

    pub(super) fn pending_user_input(
        &self,
        request_id: &str,
    ) -> Result<PendingUserInputRequest, RpcError> {
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

fn process_ipc_stream_processor_messages(
    state: &mut IpcStreamProcessorState,
    messages: Vec<IpcStreamProcessorMessage>,
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: &str,
    recovery_tx: &mpsc::UnboundedSender<PendingIpcStreamRecovery>,
) {
    for message in messages {
        process_ipc_stream_processor_message(
            state,
            message,
            Arc::clone(&session),
            Arc::clone(&app_store),
            server_id,
            recovery_tx,
        );
    }
}

fn process_ipc_stream_processor_message(
    state: &mut IpcStreamProcessorState,
    message: IpcStreamProcessorMessage,
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: &str,
    recovery_tx: &mpsc::UnboundedSender<PendingIpcStreamRecovery>,
) {
    match message {
        IpcStreamProcessorMessage::StreamEvent(params) => {
            let thread_id = params.conversation_id.clone();

            // If recovering, queue the event
            if state.recovering_threads.contains(&thread_id) {
                state
                    .pending_thread_events
                    .entry(thread_id)
                    .or_default()
                    .push_back(params);
                return;
            }

            let broadcast = TypedBroadcast::ThreadStreamStateChanged(params);
            let output = state.bridge.process_broadcast(&broadcast);

            handle_bridge_output(
                &mut state.bridge,
                &mut state.recovering_threads,
                &mut state.pending_thread_events,
                output,
                &thread_id,
                server_id,
                &app_store,
                &session,
                recovery_tx,
            );
        }
        IpcStreamProcessorMessage::Recovery(recovery) => match recovery {
            PendingIpcStreamRecovery::Recovered {
                thread_id,
                conversation_state,
            } => {
                let queued_events = state
                    .pending_thread_events
                    .get(&thread_id)
                    .map_or(0, VecDeque::len);
                debug!(
                    "IPC: async cache recovery completed server={} thread={} queued_events={}",
                    server_id, thread_id, queued_events
                );
                state.recovering_threads.remove(&thread_id);
                state.bridge.seed_thread(&thread_id, conversation_state);
                // Drain pending events through the bridge
                if let Some(pending) = state.pending_thread_events.remove(&thread_id) {
                    for params in pending {
                        let tid = params.conversation_id.clone();
                        let broadcast = TypedBroadcast::ThreadStreamStateChanged(params);
                        let output = state.bridge.process_broadcast(&broadcast);
                        handle_bridge_output(
                            &mut state.bridge,
                            &mut state.recovering_threads,
                            &mut state.pending_thread_events,
                            output,
                            &tid,
                            server_id,
                            &app_store,
                            &session,
                            recovery_tx,
                        );
                        // If recovery was triggered again, stop draining
                        if state.recovering_threads.contains(&tid) {
                            break;
                        }
                    }
                }
            }
            PendingIpcStreamRecovery::Failed { thread_id, error } => {
                state.recovering_threads.remove(&thread_id);
                state.pending_thread_events.remove(&thread_id);
                warn!(
                    "IPC: async cache recovery failed for thread {}: {}",
                    thread_id, error
                );
            }
        },
        IpcStreamProcessorMessage::StaleTurnCheck => {
            let events = state.bridge.check_stale_turns(
                Instant::now(),
                IPC_STALE_TURN_QUIET_THRESHOLD,
            );
            for event in events {
                apply_bridge_event(&app_store, server_id, event);
            }
        }
    }
}

fn handle_bridge_output(
    bridge: &mut IpcBridge,
    recovering_threads: &mut HashSet<String>,
    pending_thread_events: &mut HashMap<String, VecDeque<ThreadStreamStateChangedParams>>,
    output: BridgeOutput,
    thread_id: &str,
    server_id: &str,
    app_store: &Arc<AppStoreReducer>,
    session: &Arc<ServerSession>,
    recovery_tx: &mpsc::UnboundedSender<PendingIpcStreamRecovery>,
) {
    match output {
        BridgeOutput::Events(events) => {
            for event in events {
                apply_bridge_event(app_store, server_id, event);
            }
            // Sync pending approvals/user inputs from bridge projection
            if let Some(proj) = bridge.projected_state(thread_id) {
                sync_ipc_thread_requests_from_projection(
                    app_store, server_id, thread_id, proj,
                );
            }
        }
        BridgeOutput::FullReplace { thread_id: replace_thread_id } => {
            // Bridge has authoritative state but can't diff granularly
            // (e.g., synthesized turn IDs resolved to real server IDs).
            // Build a full thread snapshot from the bridge's cached raw state
            // and upsert it directly — no network call needed.
            if let Some(proj) = bridge.projected_state(&replace_thread_id) {
                let key = ThreadKey {
                    server_id: server_id.to_string(),
                    thread_id: replace_thread_id.clone(),
                };
                let projection_result = thread_projection_from_conversation_json(
                    server_id,
                    &replace_thread_id,
                    &bridge.raw_state(&replace_thread_id).unwrap_or_default(),
                );
                match projection_result {
                    Ok(projection) => {
                        let mut snapshot = projection.snapshot;
                        if let Some(existing) = app_store.snapshot().threads.get(&key) {
                            copy_thread_runtime_fields(existing, &mut snapshot);
                        }
                        app_store.upsert_thread_snapshot(snapshot);
                        sync_ipc_thread_requests_from_projection(
                            app_store, server_id, &replace_thread_id, proj,
                        );
                    }
                    Err(e) => {
                        warn!(
                            "IPC: FullReplace projection failed for thread={}: {}, falling back to recovery",
                            replace_thread_id, e
                        );
                        // Fall through to recovery
                        queue_ipc_thread_stream_recovery(
                            pending_thread_events,
                            recovering_threads,
                            Arc::clone(session),
                            Arc::clone(app_store),
                            server_id,
                            ThreadStreamStateChangedParams {
                                conversation_id: replace_thread_id.clone(),
                                version: 0,
                                change: StreamChange::Patches { patches: vec![] },
                            },
                            "bridge_full_replace_fallback",
                            recovery_tx,
                        );
                    }
                }
            }
        }
        BridgeOutput::NeedsRefresh { thread_id: refresh_thread_id } => {
            queue_ipc_thread_stream_recovery(
                pending_thread_events,
                recovering_threads,
                Arc::clone(session),
                Arc::clone(app_store),
                server_id,
                // Create a dummy params for queuing — the recovery will do a full thread/read
                ThreadStreamStateChangedParams {
                    conversation_id: refresh_thread_id.clone(),
                    version: 0,
                    change: StreamChange::Patches { patches: vec![] },
                },
                "bridge_needs_refresh",
                recovery_tx,
            );
        }
        BridgeOutput::ThreadArchived { thread_id } => {
            bridge.remove_thread(&thread_id);
        }
        BridgeOutput::ThreadUnarchived { .. } => {
            // Thread list refresh is handled by the outer broadcast loop
        }
        BridgeOutput::None => {}
    }
}

fn apply_bridge_event(app_store: &AppStoreReducer, server_id: &str, event: BridgeEvent) {
    use codex_app_server_protocol::ServerNotification;
    let key = ThreadKey {
        server_id: server_id.to_string(),
        thread_id: event.thread_id.clone(),
    };
    let ui_event = match event.notification {
        ServerNotification::TurnStarted(n) => UiEvent::TurnStarted {
            key,
            turn_id: n.turn.id,
        },
        ServerNotification::TurnCompleted(n) => UiEvent::TurnCompleted {
            key,
            turn_id: n.turn.id,
        },
        ServerNotification::ItemStarted(n) => UiEvent::ItemStarted {
            key,
            notification: n,
        },
        ServerNotification::ItemCompleted(n) => UiEvent::ItemCompleted {
            key,
            notification: n,
        },
        ServerNotification::AgentMessageDelta(n) => UiEvent::MessageDelta {
            key,
            item_id: n.item_id,
            delta: n.delta,
        },
        ServerNotification::ReasoningTextDelta(n) => UiEvent::ReasoningDelta {
            key,
            item_id: n.item_id,
            delta: n.delta,
        },
        ServerNotification::ReasoningSummaryTextDelta(n) => UiEvent::ReasoningDelta {
            key,
            item_id: n.item_id,
            delta: n.delta,
        },
        ServerNotification::PlanDelta(n) => UiEvent::PlanDelta {
            key,
            item_id: n.item_id,
            delta: n.delta,
        },
        ServerNotification::CommandExecutionOutputDelta(n) => UiEvent::CommandOutputDelta {
            key,
            item_id: n.item_id,
            delta: n.delta,
        },
        ServerNotification::ThreadStatusChanged(_) => {
            // Thread status is handled by TurnStarted/TurnCompleted
            return;
        }
        ServerNotification::ServerRequestResolved(_) => {
            // Handled via sync_ipc_thread_requests_from_projection
            return;
        }
        _ => return,
    };
    app_store.apply_ui_event(&ui_event);
}

fn sync_ipc_thread_requests_from_projection(
    app_store: &AppStoreReducer,
    server_id: &str,
    thread_id: &str,
    projection: &codex_ipc::conversation_state::ProjectedConversationState,
) {
    let pending_approvals: Vec<PendingApprovalWithSeed> = projection
        .pending_approvals
        .iter()
        .map(|approval| pending_approval_from_ipc_projection(server_id, approval.clone()))
        .collect();
    let pending_user_inputs: Vec<PendingUserInputRequest> = projection
        .pending_user_inputs
        .iter()
        .map(|request| pending_user_input_from_ipc_projection(server_id, request.clone()))
        .collect();
    sync_ipc_thread_requests(
        app_store,
        server_id,
        thread_id,
        pending_approvals,
        pending_user_inputs,
    );
}

fn client_request_wire_method(request: &upstream::ClientRequest) -> &'static str {
    match request {
        upstream::ClientRequest::GetAccount { .. } => "account/read",
        upstream::ClientRequest::GetAccountRateLimits { .. } => "account/rateLimits/read",
        upstream::ClientRequest::ModelList { .. } => "model/list",
        upstream::ClientRequest::LoginAccount { .. } => "account/login/start",
        upstream::ClientRequest::CancelLoginAccount { .. } => "account/login/cancel",
        upstream::ClientRequest::LogoutAccount { .. } => "account/logout",
        upstream::ClientRequest::ThreadList { .. } => "thread/list",
        upstream::ClientRequest::ThreadStart { .. } => "thread/start",
        upstream::ClientRequest::ThreadRead { .. } => "thread/read",
        upstream::ClientRequest::ThreadResume { .. } => "thread/resume",
        upstream::ClientRequest::ThreadFork { .. } => "thread/fork",
        upstream::ClientRequest::ThreadRollback { .. } => "thread/rollback",
        upstream::ClientRequest::TurnStart { .. } => "turn/start",
        upstream::ClientRequest::TurnSteer { .. } => "turn/steer",
        upstream::ClientRequest::CollaborationModeList { .. } => "collaboration_mode/list",
        _ => "unknown",
    }
}
