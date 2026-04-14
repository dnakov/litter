use super::*;
use crate::conversation_uniffi::{
    HydratedAssistantMessageData, HydratedConversationItem,
    HydratedConversationItemContent, HydratedDynamicToolCallData, HydratedErrorData,
    HydratedFileChangeData, HydratedFileChangeEntryData, HydratedNoteData, HydratedReasoningData,
    HydratedUserMessageData,
};
use crate::store::snapshot::ThreadSnapshot;
use crate::types::{
    AppInterruptTurnRequest, AppListThreadsRequest, AppOpenCodeConnectRequest, AppOperationStatus,
    AppRefreshModelsRequest, AppRenameThreadRequest, AppStartThreadRequest, ApprovalDecisionValue,
    ApprovalKind, InputModality, ModelInfo, PendingApproval, ReasoningEffort,
    ReasoningEffortOption, ThreadKey, ThreadSummaryStatus,
};
use opencode_bridge::{
    OpenCodeBridgeError, OpenCodeClient, OpenCodeConversationPart, OpenCodeDirectoryScope,
    OpenCodeEvent, OpenCodeEventStreamClient, OpenCodeMappingScope, OpenCodeMessageWithParts,
    OpenCodeModelCatalog, OpenCodeModelProjection, OpenCodeModelRef, OpenCodePendingApproval,
    OpenCodePromptAsyncRequest, OpenCodePromptFilePartInput, OpenCodePromptPartInput,
    OpenCodePromptTextPartInput, OpenCodeRequestContext,
    OpenCodeServerConfig, OpenCodeSession, OpenCodeSessionCreateRequest, OpenCodeSessionForkRequest,
    OpenCodeSessionListQuery, OpenCodeSessionUpdateRequest, OpenCodeStreamEvent, OpenCodeThreadKey,
    map_conversation_snapshot, map_model_catalog, map_pending_approval, map_thread_summaries,
};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex as StdMutex, RwLock};
use tokio::task::JoinHandle;
use tracing::{info, warn};
use url::Url;

pub(crate) struct OpenCodeServerRuntime {
    config: OpenCodeServerConfig,
    client: OpenCodeClient,
    stream_client: OpenCodeEventStreamClient,
    thread_keys: RwLock<HashMap<String, OpenCodeThreadKey>>,
    stream_tasks: StdMutex<Vec<JoinHandle<()>>>,
}

impl OpenCodeServerRuntime {
    fn new(config: OpenCodeServerConfig) -> Result<Self, OpenCodeBridgeError> {
        let client = OpenCodeClient::new(config.clone())?;
        let stream_client = OpenCodeEventStreamClient::new(config.clone())?;
        Ok(Self {
            config,
            client,
            stream_client,
            thread_keys: RwLock::new(HashMap::new()),
            stream_tasks: StdMutex::new(Vec::new()),
        })
    }

    pub(crate) fn config(&self) -> &OpenCodeServerConfig {
        &self.config
    }

    fn client(&self) -> &OpenCodeClient {
        &self.client
    }

    fn stream_client(&self) -> &OpenCodeEventStreamClient {
        &self.stream_client
    }

    fn record_thread_key(&self, key: OpenCodeThreadKey) {
        match self.thread_keys.write() {
            Ok(mut guard) => {
                guard.insert(key.session_id.clone(), key);
            }
            Err(error) => {
                error
                    .into_inner()
                    .insert(key.session_id.clone(), key);
            }
        }
    }

    fn replace_thread_keys(&self, keys: impl IntoIterator<Item = OpenCodeThreadKey>) {
        let mut next = HashMap::new();
        for key in keys {
            next.insert(key.session_id.clone(), key);
        }
        match self.thread_keys.write() {
            Ok(mut guard) => *guard = next,
            Err(error) => *error.into_inner() = next,
        }
    }

    fn thread_key(&self, session_id: &str) -> Option<OpenCodeThreadKey> {
        match self.thread_keys.read() {
            Ok(guard) => guard.get(session_id).cloned(),
            Err(error) => error.into_inner().get(session_id).cloned(),
        }
    }

    fn push_stream_task(&self, task: JoinHandle<()>) {
        match self.stream_tasks.lock() {
            Ok(mut guard) => guard.push(task),
            Err(error) => error.into_inner().push(task),
        }
    }

    pub(crate) fn close(&self) {
        match self.stream_tasks.lock() {
            Ok(mut guard) => {
                for task in guard.drain(..) {
                    task.abort();
                }
            }
            Err(error) => {
                let mut guard = error.into_inner();
                for task in guard.drain(..) {
                    task.abort();
                }
            }
        }
    }
}

impl MobileClient {
    pub(crate) fn opencode_servers_write(
        &self,
    ) -> std::sync::RwLockWriteGuard<'_, HashMap<String, Arc<OpenCodeServerRuntime>>> {
        match self.opencode_servers.write() {
            Ok(guard) => guard,
            Err(error) => {
                warn!("MobileClient: recovering poisoned opencode server write lock");
                error.into_inner()
            }
        }
    }

    pub(crate) fn opencode_servers_read(
        &self,
    ) -> std::sync::RwLockReadGuard<'_, HashMap<String, Arc<OpenCodeServerRuntime>>> {
        match self.opencode_servers.read() {
            Ok(guard) => guard,
            Err(error) => {
                warn!("MobileClient: recovering poisoned opencode server read lock");
                error.into_inner()
            }
        }
    }

    pub(crate) fn has_opencode_server(&self, server_id: &str) -> bool {
        self.opencode_servers_read().contains_key(server_id)
    }

    pub(crate) fn get_opencode_server(
        &self,
        server_id: &str,
    ) -> Result<Arc<OpenCodeServerRuntime>, RpcError> {
        self.opencode_servers_read()
            .get(server_id)
            .cloned()
            .ok_or_else(|| RpcError::Transport(TransportError::Disconnected))
    }

    pub(crate) async fn replace_existing_backend(&self, server_id: &str) {
        self.clear_oauth_callback_tunnel(server_id).await;

        let existing_codex = self.sessions_write().remove(server_id);
        if let Some(session) = existing_codex {
            info!("MobileClient: replacing existing Codex server session {server_id}");
            session.disconnect().await;
        }

        let existing_opencode = self.opencode_servers_write().remove(server_id);
        if let Some(runtime) = existing_opencode {
            info!("MobileClient: replacing existing OpenCode server session {server_id}");
            runtime.close();
        }
    }

    pub async fn connect_opencode(
        &self,
        config: OpenCodeServerConfig,
    ) -> Result<String, TransportError> {
        if config.known_directories.is_empty() {
            return Err(TransportError::ConnectionFailed(
                "OpenCode connection requires at least one directory scope".to_string(),
            ));
        }

        let server_id = config.server_id.clone();
        if self.has_opencode_server(server_id.as_str()) {
            info!("MobileClient: reusing existing OpenCode server session {server_id}");
            return Ok(server_id);
        }

        self.replace_existing_backend(server_id.as_str()).await;

        let runtime = Arc::new(OpenCodeServerRuntime::new(config).map_err(opencode_transport_error)?);
        runtime
            .client()
            .get_health()
            .await
            .map_err(opencode_transport_error)?;

        self.app_store.upsert_server(
            &server_config_from_opencode(runtime.config()),
            ServerHealthSnapshot::Connected,
            false,
        );
        self.opencode_servers_write()
            .insert(server_id.clone(), Arc::clone(&runtime));
        self.spawn_opencode_event_readers(server_id.clone(), Arc::clone(&runtime));
        self.spawn_opencode_post_connect_warmup(server_id.clone(), runtime);
        info!("MobileClient: connected OpenCode server {server_id}");
        Ok(server_id)
    }

    pub(crate) async fn opencode_list_threads(
        &self,
        server_id: &str,
        params: AppListThreadsRequest,
    ) -> Result<(), RpcError> {
        let runtime = self.get_opencode_server(server_id)?;
        let threads = collect_opencode_threads(&runtime, params.cwd.as_deref(), server_id).await?;
        self.app_store.sync_thread_list(server_id, &threads);
        Ok(())
    }

    pub(crate) async fn opencode_read_thread(
        &self,
        server_id: &str,
        thread_id: &str,
        _include_turns: bool,
    ) -> Result<ThreadKey, RpcError> {
        let runtime = self.get_opencode_server(server_id)?;
        let snapshot = opencode_thread_snapshot_from_session_id(server_id, &runtime, thread_id).await?;
        let key = snapshot.key.clone();
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    pub(crate) async fn opencode_start_thread(
        &self,
        server_id: &str,
        params: AppStartThreadRequest,
    ) -> Result<ThreadKey, RpcError> {
        let runtime = self.get_opencode_server(server_id)?;
        let context = directory_context_from_create_request(runtime.as_ref(), params.cwd.as_deref())?;
        let request = OpenCodeSessionCreateRequest {
            context: context.clone(),
            parent_id: None,
            title: None,
            workspace_id: None,
        };
        let session = runtime
            .client()
            .create_session(&request)
            .await
            .map_err(opencode_rpc_error)?;
        let snapshot =
            opencode_thread_snapshot_from_session(server_id, runtime.as_ref(), session, None).await?;
        let key = snapshot.key.clone();
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    pub(crate) async fn opencode_resume_thread(
        &self,
        server_id: &str,
        thread_id: &str,
    ) -> Result<ThreadKey, RpcError> {
        self.opencode_read_thread(server_id, thread_id, true).await
    }

    pub(crate) async fn opencode_fork_thread(
        &self,
        server_id: &str,
        thread_id: &str,
    ) -> Result<ThreadKey, RpcError> {
        let runtime = self.get_opencode_server(server_id)?;
        let context = thread_context_from_runtime(runtime.as_ref(), server_id, thread_id, None)?;
        let session = runtime
            .client()
            .fork_session(thread_id, &context, &OpenCodeSessionForkRequest::default())
            .await
            .map_err(opencode_rpc_error)?;
        let snapshot =
            opencode_thread_snapshot_from_session(server_id, runtime.as_ref(), session, None).await?;
        let key = snapshot.key.clone();
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    pub(crate) async fn opencode_rename_thread(
        &self,
        server_id: &str,
        params: AppRenameThreadRequest,
    ) -> Result<(), RpcError> {
        let runtime = self.get_opencode_server(server_id)?;
        let context =
            thread_context_from_runtime(runtime.as_ref(), server_id, &params.thread_id, None)?;
        let session = runtime
            .client()
            .rename_session(
                &params.thread_id,
                &context,
                &OpenCodeSessionUpdateRequest {
                    title: Some(params.name),
                },
            )
            .await
            .map_err(opencode_rpc_error)?;
        let snapshot =
            opencode_thread_snapshot_from_session(server_id, runtime.as_ref(), session, None).await?;
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(())
    }

    pub(crate) async fn opencode_interrupt_turn(
        &self,
        server_id: &str,
        params: AppInterruptTurnRequest,
    ) -> Result<(), RpcError> {
        let runtime = self.get_opencode_server(server_id)?;
        let context =
            thread_context_from_runtime(runtime.as_ref(), server_id, &params.thread_id, None)?;
        runtime
            .client()
            .abort_session(&params.thread_id, &context)
            .await
            .map_err(opencode_rpc_error)?;
        self.refresh_opencode_thread(server_id, runtime.as_ref(), &params.thread_id)
            .await?;
        Ok(())
    }

    pub(crate) async fn opencode_refresh_models(
        &self,
        server_id: &str,
        _params: AppRefreshModelsRequest,
    ) -> Result<(), RpcError> {
        let runtime = self.get_opencode_server(server_id)?;
        let models = fetch_opencode_models(runtime.as_ref()).await?;
        self.app_store.update_server_models(server_id, Some(models));
        Ok(())
    }

    pub(crate) async fn opencode_start_turn(
        &self,
        server_id: &str,
        params: upstream::TurnStartParams,
    ) -> Result<(), RpcError> {
        let runtime = self.get_opencode_server(server_id)?;
        let context =
            thread_context_from_runtime(
                runtime.as_ref(),
                server_id,
                &params.thread_id,
                params.cwd.as_deref().and_then(|path| path.to_str()),
            )?;
        let body = OpenCodePromptAsyncRequest {
            message_id: None,
            model: params
                .model
                .as_deref()
                .and_then(parse_opencode_model_ref),
            agent: None,
            no_reply: None,
            tools: None,
            format: None,
            system: None,
            variant: None,
            parts: params
                .input
                .iter()
                .map(prompt_part_from_user_input)
                .collect(),
        };
        runtime
            .client()
            .prompt_async(&params.thread_id, &context, &body)
            .await
            .map_err(opencode_rpc_error)?;
        mark_opencode_thread_running(
            &self.app_store,
            &ThreadKey {
                server_id: server_id.to_string(),
                thread_id: params.thread_id.clone(),
            },
        );
        Ok(())
    }

    pub(crate) async fn opencode_respond_to_approval(
        &self,
        approval: PendingApproval,
        decision: ApprovalDecisionValue,
    ) -> Result<(), RpcError> {
        let runtime = self.get_opencode_server(&approval.server_id)?;
        let thread_id = approval
            .thread_id
            .clone()
            .ok_or_else(|| RpcError::Deserialization("OpenCode approval missing thread id".to_string()))?;
        let context =
            thread_context_from_runtime(runtime.as_ref(), &approval.server_id, &thread_id, approval.cwd.as_deref())?;
        runtime
            .client()
            .reply_permission(
                &thread_id,
                &opencode_bridge::OpenCodePermissionId(approval.id.clone()),
                &context,
                &opencode_bridge::OpenCodePermissionReplyRequest {
                    response: approval_decision_to_opencode(decision),
                },
            )
            .await
            .map_err(opencode_rpc_error)?;
        self.app_store.resolve_approval(&approval.id);
        Ok(())
    }

    fn spawn_opencode_post_connect_warmup(
        &self,
        server_id: String,
        runtime: Arc<OpenCodeServerRuntime>,
    ) {
        let app_store = Arc::clone(&self.app_store);
        Self::spawn_detached(async move {
            match collect_opencode_threads(runtime.as_ref(), None, &server_id).await {
                Ok(threads) => app_store.sync_thread_list(&server_id, &threads),
                Err(error) => warn!(
                    "MobileClient: failed to refresh OpenCode thread list for {}: {}",
                    server_id, error
                ),
            }

            match fetch_opencode_models(runtime.as_ref()).await {
                Ok(models) => app_store.update_server_models(&server_id, Some(models)),
                Err(error) => warn!(
                    "MobileClient: failed to refresh OpenCode model list for {}: {}",
                    server_id, error
                ),
            }
        });
    }

    fn spawn_opencode_event_readers(
        &self,
        server_id: String,
        runtime: Arc<OpenCodeServerRuntime>,
    ) {
        for scope in &runtime.config().known_directories {
            let context = OpenCodeRequestContext::new(scope.directory.clone());
            let Ok(context) = context else {
                warn!(
                    "MobileClient: skipping invalid OpenCode stream scope server_id={} directory={}",
                    server_id, scope.directory
                );
                continue;
            };
            let Ok(mut handle) = runtime.stream_client().connect_directory(context) else {
                warn!(
                    "MobileClient: failed to connect OpenCode event stream server_id={} directory={}",
                    server_id, scope.directory
                );
                continue;
            };
            let server_id_clone = server_id.clone();
            let runtime_clone = Arc::clone(&runtime);
            let app_store = Arc::clone(&self.app_store);
            let task = tokio::spawn(async move {
                while let Some(next) = handle.next().await {
                    match next {
                        Ok(OpenCodeStreamEvent::Ready { .. }) => {
                            app_store.update_server_health(
                                &server_id_clone,
                                ServerHealthSnapshot::Connected,
                            );
                        }
                        Ok(OpenCodeStreamEvent::Disconnected { .. })
                        | Ok(OpenCodeStreamEvent::Reconnecting { .. }) => {
                            app_store.update_server_health(
                                &server_id_clone,
                                ServerHealthSnapshot::Connecting,
                            );
                        }
                        Ok(OpenCodeStreamEvent::Resynced { directory, .. }) => {
                            let _ = refresh_opencode_directory(
                                &server_id_clone,
                                runtime_clone.as_ref(),
                                Some(directory.as_str()),
                                &app_store,
                            )
                            .await;
                            app_store.update_server_health(
                                &server_id_clone,
                                ServerHealthSnapshot::Connected,
                            );
                        }
                        Ok(OpenCodeStreamEvent::Event { directory, event }) => {
                            if let Err(error) = handle_opencode_stream_event(
                                &server_id_clone,
                                runtime_clone.as_ref(),
                                &directory,
                                event,
                                &app_store,
                            )
                            .await
                            {
                                warn!(
                                    "MobileClient: failed to process OpenCode event for {}: {}",
                                    server_id_clone, error
                                );
                            }
                        }
                        Err(error) => {
                            warn!(
                                "MobileClient: OpenCode event stream failed for {}: {}",
                                server_id_clone, error
                            );
                            app_store.update_server_health(
                                &server_id_clone,
                                ServerHealthSnapshot::Unresponsive,
                            );
                        }
                    }
                }
            });
            runtime.push_stream_task(task);
        }
    }

    async fn refresh_opencode_thread(
        &self,
        server_id: &str,
        runtime: &OpenCodeServerRuntime,
        thread_id: &str,
    ) -> Result<(), RpcError> {
        let snapshot = opencode_thread_snapshot_from_session_id(server_id, runtime, thread_id).await?;
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(())
    }
}

async fn handle_opencode_stream_event(
    server_id: &str,
    runtime: &OpenCodeServerRuntime,
    directory: &str,
    event: OpenCodeEvent,
    app_store: &AppStoreReducer,
) -> Result<(), RpcError> {
    match event {
        OpenCodeEvent::SessionCreated { .. }
        | OpenCodeEvent::SessionUpdated { .. }
        | OpenCodeEvent::SessionDeleted { .. }
        | OpenCodeEvent::SessionStatus { .. }
        | OpenCodeEvent::SessionIdle { .. } => {
            refresh_opencode_directory(server_id, runtime, Some(directory), app_store).await
        }
        OpenCodeEvent::MessageUpdated { ref info } => {
            refresh_single_opencode_thread(server_id, runtime, &info.session_id, app_store).await
        }
        OpenCodeEvent::MessagePartUpdated { ref part, .. } => {
            let Some(session_id) = part.session_id() else {
                return Ok(());
            };
            refresh_single_opencode_thread(server_id, runtime, session_id, app_store).await
        }
        OpenCodeEvent::MessagePartDelta { ref session_id, .. }
        | OpenCodeEvent::MessagePartRemoved { ref session_id, .. }
        | OpenCodeEvent::SessionDiff { ref session_id, .. } => {
            refresh_single_opencode_thread(server_id, runtime, session_id, app_store).await
        }
        OpenCodeEvent::SessionError {
            session_id: Some(ref session_id),
            ..
        } => refresh_single_opencode_thread(server_id, runtime, session_id, app_store).await,
        OpenCodeEvent::PermissionUpdated { ref permission } => {
            let scope = OpenCodeMappingScope::new(server_id, directory).map_err(opencode_rpc_error)?;
            let mapped = map_pending_approval(&scope, permission).map_err(opencode_rpc_error)?;
            upsert_opencode_approval(app_store, mapped);
            Ok(())
        }
        OpenCodeEvent::PermissionReplied { ref permission_id, .. } => {
            app_store.resolve_approval(&permission_id.0);
            Ok(())
        }
        OpenCodeEvent::ServerConnected
        | OpenCodeEvent::ServerHeartbeat
        | OpenCodeEvent::SessionError { session_id: None, .. }
        | OpenCodeEvent::Unknown { .. } => Ok(()),
    }
}

async fn refresh_opencode_directory(
    server_id: &str,
    runtime: &OpenCodeServerRuntime,
    directory: Option<&str>,
    app_store: &AppStoreReducer,
) -> Result<(), RpcError> {
    let threads = collect_opencode_threads(runtime, directory, server_id).await?;
    app_store.sync_thread_list(server_id, &threads);
    Ok(())
}

async fn refresh_single_opencode_thread(
    server_id: &str,
    runtime: &OpenCodeServerRuntime,
    thread_id: &str,
    app_store: &AppStoreReducer,
) -> Result<(), RpcError> {
    let snapshot = opencode_thread_snapshot_from_session_id(server_id, runtime, thread_id).await?;
    app_store.upsert_thread_snapshot(snapshot);
    Ok(())
}

async fn collect_opencode_threads(
    runtime: &OpenCodeServerRuntime,
    only_directory: Option<&str>,
    server_id: &str,
) -> Result<Vec<crate::types::ThreadInfo>, RpcError> {
    let directories = requested_directories(runtime.config(), only_directory)?;
    let mut thread_keys = Vec::new();
    let mut all_threads = Vec::new();

    for directory in directories {
        let context = OpenCodeRequestContext::new(directory.clone()).map_err(opencode_rpc_error)?;
        let query = OpenCodeSessionListQuery {
            context: context.clone(),
            roots: None,
            start: None,
            search: None,
            limit: None,
        };
        let sessions = runtime
            .client()
            .list_sessions(&query)
            .await
            .map_err(opencode_rpc_error)?;
        let statuses = runtime
            .client()
            .get_session_status(&context)
            .await
            .map_err(opencode_rpc_error)?;
        let scope = OpenCodeMappingScope::from_request_context(server_id, &context, "thread list")
            .map_err(opencode_rpc_error)?;
        let mapped = map_thread_summaries(&scope, &sessions, &statuses).map_err(opencode_rpc_error)?;
        for summary in mapped {
            thread_keys.push(summary.thread_key.clone());
            all_threads.push(thread_info_from_opencode_summary(&summary));
        }
    }

    runtime.replace_thread_keys(thread_keys);
    Ok(all_threads)
}

async fn opencode_thread_snapshot_from_session_id(
    server_id: &str,
    runtime: &OpenCodeServerRuntime,
    session_id: &str,
) -> Result<ThreadSnapshot, RpcError> {
    let context = thread_context_from_runtime(runtime, server_id, session_id, None)?;
    let session = runtime
        .client()
        .get_session(session_id, &context)
        .await
        .map_err(opencode_rpc_error)?;
    opencode_thread_snapshot_from_session(server_id, runtime, session, Some(context)).await
}

async fn opencode_thread_snapshot_from_session(
    server_id: &str,
    runtime: &OpenCodeServerRuntime,
    session: OpenCodeSession,
    context: Option<OpenCodeRequestContext>,
) -> Result<ThreadSnapshot, RpcError> {
    let context = match context {
        Some(context) => context,
        None => OpenCodeRequestContext::new(session.directory.clone()).map_err(opencode_rpc_error)?,
    };
    let scope = OpenCodeMappingScope::from_request_context(server_id, &context, "thread read")
        .map_err(opencode_rpc_error)?;
    let messages = list_all_messages(runtime.client(), &session.id, &context).await?;
    let statuses = runtime
        .client()
        .get_session_status(&context)
        .await
        .map_err(opencode_rpc_error)?;
    let summaries =
        map_thread_summaries(&scope, std::slice::from_ref(&session), &statuses).map_err(opencode_rpc_error)?;
    let summary = summaries
        .into_iter()
        .next()
        .ok_or_else(|| RpcError::Deserialization("missing OpenCode thread summary".to_string()))?;
    runtime.record_thread_key(summary.thread_key.clone());
    let conversation =
        map_conversation_snapshot(&scope, &session, &messages).map_err(opencode_rpc_error)?;
    Ok(thread_snapshot_from_opencode(summary, conversation.messages))
}

async fn list_all_messages(
    client: &OpenCodeClient,
    session_id: &str,
    context: &OpenCodeRequestContext,
) -> Result<Vec<OpenCodeMessageWithParts>, RpcError> {
    let mut before = None;
    let mut items = Vec::new();
    loop {
        let page = client
            .list_messages(session_id, context, None, before.as_deref())
            .await
            .map_err(opencode_rpc_error)?;
        items.extend(page.items);
        let Some(next_cursor) = page.next_cursor else {
            break;
        };
        before = Some(next_cursor);
    }
    Ok(items)
}

async fn fetch_opencode_models(runtime: &OpenCodeServerRuntime) -> Result<Vec<ModelInfo>, RpcError> {
    let directory = runtime
        .config()
        .known_directories
        .first()
        .ok_or_else(|| RpcError::Deserialization("OpenCode server has no directory scopes".to_string()))?
        .directory
        .clone();
    let context = OpenCodeRequestContext::new(directory.clone()).map_err(opencode_rpc_error)?;
    let scope = OpenCodeMappingScope::from_request_context(
        runtime.config().server_id.clone(),
        &context,
        "model list",
    )
    .map_err(opencode_rpc_error)?;
    let providers = runtime
        .client()
        .list_providers(&context)
        .await
        .map_err(opencode_rpc_error)?;
    let auth_methods = runtime
        .client()
        .list_provider_auth_methods(&context)
        .await
        .map_err(opencode_rpc_error)?;
    let catalog = map_model_catalog(&scope, &providers, Some(&auth_methods));
    Ok(model_infos_from_catalog(catalog))
}

fn model_infos_from_catalog(catalog: OpenCodeModelCatalog) -> Vec<ModelInfo> {
    let mut models = Vec::new();
    for provider in catalog.providers {
        for model in provider.models {
            models.push(model_info_from_projection(&provider.provider_name, &model));
        }
    }
    models.sort_by(|lhs, rhs| lhs.display_name.cmp(&rhs.display_name));
    models
}

fn model_info_from_projection(provider_name: &str, model: &OpenCodeModelProjection) -> ModelInfo {
    ModelInfo {
        id: format!("{}:{}", model.provider_id, model.model_id),
        model: format!("{}:{}", model.provider_id, model.model_id),
        upgrade: None,
        upgrade_model: None,
        upgrade_copy: None,
        model_link: None,
        migration_markdown: None,
        availability_nux_message: None,
        display_name: model.name.clone(),
        description: provider_name.to_string(),
        hidden: false,
        supported_reasoning_efforts: vec![ReasoningEffortOption {
            reasoning_effort: ReasoningEffort::Medium,
            description: "Backend default".to_string(),
        }],
        default_reasoning_effort: ReasoningEffort::Medium,
        input_modalities: vec![InputModality::Text],
        supports_personality: false,
        is_default: model.is_default,
    }
}

pub(crate) fn server_config_from_opencode(config: &OpenCodeServerConfig) -> ServerConfig {
    ServerConfig {
        server_id: config.server_id.clone(),
        display_name: config.display_name.clone(),
        host: config.host.clone(),
        port: config.port,
        websocket_url: None,
        is_local: matches!(config.host.as_str(), "127.0.0.1" | "localhost"),
        tls: config.tls,
    }
}

fn thread_info_from_opencode_summary(
    summary: &opencode_bridge::OpenCodeThreadSummary,
) -> crate::types::ThreadInfo {
    crate::types::ThreadInfo {
        id: summary.thread_key.session_id.clone(),
        title: Some(summary.title.clone()),
        model: None,
        status: thread_status_from_opencode(summary.state.clone()),
        preview: None,
        cwd: Some(summary.cwd.clone()),
        path: Some(summary.cwd.clone()),
        model_provider: None,
        agent_nickname: None,
        agent_role: None,
        parent_thread_id: summary.parent_thread_id.clone(),
        agent_status: None,
        created_at: millis_to_seconds(summary.created_at),
        updated_at: millis_to_seconds(summary.updated_at),
    }
}

fn thread_status_from_opencode(
    state: opencode_bridge::OpenCodeThreadState,
) -> ThreadSummaryStatus {
    match state {
        opencode_bridge::OpenCodeThreadState::Idle => ThreadSummaryStatus::Idle,
        opencode_bridge::OpenCodeThreadState::Running
        | opencode_bridge::OpenCodeThreadState::Retrying => ThreadSummaryStatus::Active,
        opencode_bridge::OpenCodeThreadState::Error => ThreadSummaryStatus::SystemError,
        opencode_bridge::OpenCodeThreadState::Unknown(_) => ThreadSummaryStatus::NotLoaded,
    }
}

fn thread_snapshot_from_opencode(
    summary: opencode_bridge::OpenCodeThreadSummary,
    messages: Vec<opencode_bridge::OpenCodeConversationMessage>,
) -> ThreadSnapshot {
    let mut snapshot = ThreadSnapshot::from_info(
        &summary.thread_key.server_id,
        thread_info_from_opencode_summary(&summary),
    );
    snapshot.key = ThreadKey {
        server_id: summary.thread_key.server_id.clone(),
        thread_id: summary.thread_key.session_id.clone(),
    };
    snapshot.items = conversation_items_from_opencode_messages(&messages);
    snapshot.model = latest_model_id(&messages);
    snapshot.info.model = snapshot.model.clone();
    snapshot.info.model_provider = latest_model_provider(&messages);
    if snapshot.info.status == ThreadSummaryStatus::Active {
        snapshot.active_turn_id = Some(format!("opencode:{}", summary.thread_key.session_id));
    }
    snapshot
}

fn conversation_items_from_opencode_messages(
    messages: &[opencode_bridge::OpenCodeConversationMessage],
) -> Vec<HydratedConversationItem> {
    let mut items = Vec::new();
    for message in messages {
        let text = combined_text_parts(message);
        match message.role {
            opencode_bridge::OpenCodeConversationRole::User => {
                if !text.is_empty() || !image_data_uris_from_message(message).is_empty() {
                    items.push(HydratedConversationItem {
                        id: format!("opencode:{}:user", message.message_id),
                        content: HydratedConversationItemContent::User(HydratedUserMessageData {
                            text,
                            image_data_uris: image_data_uris_from_message(message),
                        }),
                        source_turn_id: None,
                        source_turn_index: None,
                        timestamp: None,
                        is_from_user_turn_boundary: true,
                    });
                }
            }
            opencode_bridge::OpenCodeConversationRole::Assistant
            | opencode_bridge::OpenCodeConversationRole::Unknown(_) => {
                if !text.is_empty() {
                    items.push(HydratedConversationItem {
                        id: format!("opencode:{}:assistant", message.message_id),
                        content: HydratedConversationItemContent::Assistant(
                            HydratedAssistantMessageData {
                                text,
                                agent_nickname: message.agent.clone(),
                                agent_role: None,
                                phase: None,
                            },
                        ),
                        source_turn_id: None,
                        source_turn_index: None,
                        timestamp: None,
                        is_from_user_turn_boundary: false,
                    });
                }
            }
        }

        if let Some(system) = message.system.as_ref()
            && !system.trim().is_empty()
        {
            items.push(HydratedConversationItem {
                id: format!("opencode:{}:system", message.message_id),
                content: HydratedConversationItemContent::Note(HydratedNoteData {
                    title: "System".to_string(),
                    body: system.clone(),
                }),
                source_turn_id: None,
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: false,
            });
        }

        for part in &message.parts {
            if let Some(item) = conversation_item_from_opencode_part(part) {
                items.push(item);
            }
        }

        if let Some(error) = message.error.as_ref() {
            items.push(HydratedConversationItem {
                id: format!("opencode:{}:error", message.message_id),
                content: HydratedConversationItemContent::Error(HydratedErrorData {
                    title: error.name.clone(),
                    message: serde_json::to_string_pretty(&error.data)
                        .unwrap_or_else(|_| error.data.to_string()),
                    details: None,
                }),
                source_turn_id: None,
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: false,
            });
        }
    }
    items
}

fn conversation_item_from_opencode_part(
    part: &OpenCodeConversationPart,
) -> Option<HydratedConversationItem> {
    match part {
        OpenCodeConversationPart::Reasoning(reasoning) => Some(HydratedConversationItem {
            id: format!("opencode:{}:reasoning", reasoning.part_id),
            content: HydratedConversationItemContent::Reasoning(HydratedReasoningData {
                summary: Vec::new(),
                content: vec![reasoning.text.clone()],
            }),
            source_turn_id: None,
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }),
        OpenCodeConversationPart::Tool(tool) => {
            let (status, success, arguments_json, content_summary) = match &tool.state {
                opencode_bridge::OpenCodeToolCallState::Pending(state) => (
                    AppOperationStatus::Pending,
                    None,
                    serde_json::to_string_pretty(&state.input).ok(),
                    None,
                ),
                opencode_bridge::OpenCodeToolCallState::Running(state) => (
                    AppOperationStatus::InProgress,
                    None,
                    serde_json::to_string_pretty(&state.input).ok(),
                    state.title.clone(),
                ),
                opencode_bridge::OpenCodeToolCallState::Succeeded(state) => (
                    AppOperationStatus::Completed,
                    Some(true),
                    serde_json::to_string_pretty(&state.input).ok(),
                    Some(state.output.clone()),
                ),
                opencode_bridge::OpenCodeToolCallState::Error(state) => (
                    AppOperationStatus::Failed,
                    Some(false),
                    serde_json::to_string_pretty(&state.input).ok(),
                    Some(state.error.clone()),
                ),
                opencode_bridge::OpenCodeToolCallState::Unknown(_) => {
                    (AppOperationStatus::Unknown, None, None, None)
                }
            };
            Some(HydratedConversationItem {
                id: format!("opencode:{}:tool", tool.part_id),
                content: HydratedConversationItemContent::DynamicToolCall(
                    HydratedDynamicToolCallData {
                        tool: tool.tool_name.clone(),
                        status,
                        duration_ms: None,
                        success,
                        arguments_json,
                        content_summary,
                    },
                ),
                source_turn_id: None,
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: false,
            })
        }
        OpenCodeConversationPart::Patch(patch) => Some(HydratedConversationItem {
            id: format!("opencode:{}:patch", patch.part_id),
            content: HydratedConversationItemContent::FileChange(HydratedFileChangeData {
                status: AppOperationStatus::Completed,
                changes: patch
                    .files
                    .iter()
                    .map(|path| HydratedFileChangeEntryData {
                        path: path.clone(),
                        kind: "modified".to_string(),
                        diff: String::new(),
                        additions: 0,
                        deletions: 0,
                    })
                    .collect(),
            }),
            source_turn_id: None,
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }),
        OpenCodeConversationPart::File(file) => Some(HydratedConversationItem {
            id: format!(
                "opencode:{}:file",
                file.part_id.clone().unwrap_or_else(|| file.url.clone())
            ),
            content: HydratedConversationItemContent::Note(HydratedNoteData {
                title: file
                    .filename
                    .clone()
                    .unwrap_or_else(|| "Attachment".to_string()),
                body: file.path.clone().unwrap_or_else(|| file.url.clone()),
            }),
            source_turn_id: None,
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }),
        OpenCodeConversationPart::Text(_)
        | OpenCodeConversationPart::StepBoundary(_)
        | OpenCodeConversationPart::Unknown(_) => None,
    }
}

fn combined_text_parts(message: &opencode_bridge::OpenCodeConversationMessage) -> String {
    message
        .parts
        .iter()
        .filter_map(|part| match part {
            OpenCodeConversationPart::Text(text) if !text.ignored => Some(text.text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("")
        .trim()
        .to_string()
}

fn image_data_uris_from_message(
    message: &opencode_bridge::OpenCodeConversationMessage,
) -> Vec<String> {
    message
        .parts
        .iter()
        .filter_map(|part| match part {
            OpenCodeConversationPart::File(file)
                if file.mime.starts_with("image/") && file.url.starts_with("data:") =>
            {
                Some(file.url.clone())
            }
            _ => None,
        })
        .collect()
}

fn latest_model_id(
    messages: &[opencode_bridge::OpenCodeConversationMessage],
) -> Option<String> {
    messages.iter().rev().find_map(|message| {
        message
            .model
            .as_ref()
            .map(|model| format!("{}:{}", model.provider_id, model.model_id))
    })
}

fn latest_model_provider(
    messages: &[opencode_bridge::OpenCodeConversationMessage],
) -> Option<String> {
    messages
        .iter()
        .rev()
        .find_map(|message| message.model.as_ref().map(|model| model.provider_id.clone()))
}

fn prompt_part_from_user_input(input: &upstream::UserInput) -> OpenCodePromptPartInput {
    match input {
        upstream::UserInput::Text { text, .. } => {
            OpenCodePromptPartInput::Text(OpenCodePromptTextPartInput {
                id: None,
                text: text.clone(),
                synthetic: None,
                ignored: None,
                metadata: Value::Object(Default::default()),
            })
        }
        upstream::UserInput::Image { url } => {
            OpenCodePromptPartInput::File(OpenCodePromptFilePartInput {
                id: None,
                mime: "image/*".to_string(),
                filename: None,
                url: url.clone(),
                source: None,
            })
        }
        upstream::UserInput::LocalImage { path } => {
            OpenCodePromptPartInput::File(OpenCodePromptFilePartInput {
                id: None,
                mime: "image/*".to_string(),
                filename: path.file_name().map(|name| name.to_string_lossy().to_string()),
                url: format!("file://{}", path.display()),
                source: None,
            })
        }
        upstream::UserInput::Skill { name, path } => {
            OpenCodePromptPartInput::Text(OpenCodePromptTextPartInput {
                id: None,
                text: format!("Skill: {name}\nPath: {}", path.display()),
                synthetic: Some(true),
                ignored: None,
                metadata: json!({ "type": "skill" }),
            })
        }
        upstream::UserInput::Mention { name, path } => {
            OpenCodePromptPartInput::Text(OpenCodePromptTextPartInput {
                id: None,
                text: format!("Mention: {name}\nPath: {path}"),
                synthetic: Some(true),
                ignored: None,
                metadata: json!({ "type": "mention" }),
            })
        }
    }
}

fn parse_opencode_model_ref(model: &str) -> Option<OpenCodeModelRef> {
    let (provider_id, model_id) = model.split_once(':')?;
    if provider_id.trim().is_empty() || model_id.trim().is_empty() {
        return None;
    }
    Some(OpenCodeModelRef {
        provider_id: provider_id.to_string(),
        model_id: model_id.to_string(),
    })
}

fn requested_directories(
    config: &OpenCodeServerConfig,
    only_directory: Option<&str>,
) -> Result<Vec<String>, RpcError> {
    if let Some(directory) = only_directory {
        return Ok(vec![normalize_requested_directory(directory)?]);
    }

    let directories = config
        .known_directories
        .iter()
        .map(|scope| scope.directory.clone())
        .collect::<Vec<_>>();
    if directories.is_empty() {
        return Err(RpcError::Deserialization(
            "OpenCode server has no configured directory scopes".to_string(),
        ));
    }
    Ok(directories)
}

fn directory_context_from_create_request(
    runtime: &OpenCodeServerRuntime,
    cwd: Option<&str>,
) -> Result<OpenCodeRequestContext, RpcError> {
    let directory = match cwd {
        Some(cwd) => {
            let cwd = normalize_requested_directory(cwd)?;
            let known = runtime
                .config()
                .known_directories
                .iter()
                .any(|scope| scope.directory == cwd);
            if !known {
                return Err(RpcError::Deserialization(format!(
                    "OpenCode cwd is outside configured directory scopes: {cwd}"
                )));
            }
            cwd
        }
        None => runtime
            .config()
            .known_directories
            .first()
            .map(|scope| scope.directory.clone())
            .ok_or_else(|| {
                RpcError::Deserialization(
                    "OpenCode server has no configured directory scopes".to_string(),
                )
            })?,
    };
    OpenCodeRequestContext::new(directory).map_err(opencode_rpc_error)
}

fn thread_context_from_runtime(
    runtime: &OpenCodeServerRuntime,
    server_id: &str,
    thread_id: &str,
    cwd_override: Option<&str>,
) -> Result<OpenCodeRequestContext, RpcError> {
    if let Some(cwd) = cwd_override {
        return OpenCodeRequestContext::new(normalize_requested_directory(cwd)?)
            .map_err(opencode_rpc_error);
    }

    if let Some(key) = runtime.thread_key(thread_id) {
        return OpenCodeRequestContext::new(key.directory).map_err(opencode_rpc_error);
    }

    Err(RpcError::Deserialization(format!(
        "unknown OpenCode thread context for server={} thread={}",
        server_id, thread_id
    )))
}

fn normalize_requested_directory(directory: &str) -> Result<String, RpcError> {
    let trimmed = directory.trim();
    if trimmed.is_empty() {
        return Err(RpcError::Deserialization(
            "OpenCode directory cannot be empty".to_string(),
        ));
    }
    Ok(trimmed.to_string())
}

fn upsert_opencode_approval(app_store: &AppStoreReducer, approval: OpenCodePendingApproval) {
    let mut approvals = app_store.snapshot().pending_approvals;
    let mapped = pending_approval_from_opencode(approval);
    if let Some(existing) = approvals.iter_mut().find(|entry| entry.id == mapped.id) {
        *existing = mapped;
    } else {
        approvals.push(mapped);
    }
    app_store.replace_pending_approvals(approvals);
}

fn pending_approval_from_opencode(approval: OpenCodePendingApproval) -> PendingApproval {
    let metadata = approval.metadata;
    let path = first_string(
        metadata.get("path"),
        metadata.get("file"),
        metadata.get("target"),
    );
    PendingApproval {
        id: approval.approval_id,
        server_id: approval.thread_key.server_id,
        kind: approval_kind_from_opencode(&approval.permission_type, path.as_deref()),
        thread_id: Some(approval.thread_key.session_id),
        turn_id: approval.message_id.clone(),
        item_id: approval.call_id.clone(),
        command: metadata
            .get("command")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        path,
        grant_root: metadata
            .get("grantRoot")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        cwd: Some(approval.thread_key.directory),
        reason: Some(approval.title),
    }
}

fn approval_kind_from_opencode(permission_type: &str, path: Option<&str>) -> ApprovalKind {
    let normalized = permission_type.to_ascii_lowercase();
    if normalized.contains("command") || normalized.contains("exec") || normalized.contains("shell")
    {
        ApprovalKind::Command
    } else if path.is_some()
        || normalized.contains("file")
        || normalized.contains("write")
        || normalized.contains("edit")
    {
        ApprovalKind::FileChange
    } else {
        ApprovalKind::Permissions
    }
}

fn first_string(values: Option<&Value>, other: Option<&Value>, third: Option<&Value>) -> Option<String> {
    values
        .and_then(Value::as_str)
        .or_else(|| other.and_then(Value::as_str))
        .or_else(|| third.and_then(Value::as_str))
        .map(ToOwned::to_owned)
}

fn approval_decision_to_opencode(
    decision: ApprovalDecisionValue,
) -> opencode_bridge::OpenCodePermissionResponse {
    match decision {
        ApprovalDecisionValue::Accept => opencode_bridge::OpenCodePermissionResponse::Once,
        ApprovalDecisionValue::AcceptForSession => {
            opencode_bridge::OpenCodePermissionResponse::Always
        }
        ApprovalDecisionValue::Decline | ApprovalDecisionValue::Cancel => {
            opencode_bridge::OpenCodePermissionResponse::Reject
        }
    }
}

fn mark_opencode_thread_running(app_store: &AppStoreReducer, key: &ThreadKey) {
    let Some(mut snapshot) = app_store.thread_snapshot(key) else {
        return;
    };
    snapshot.info.status = ThreadSummaryStatus::Active;
    snapshot.active_turn_id = Some(format!("opencode:{}", key.thread_id));
    app_store.upsert_thread_snapshot(snapshot);
}

fn millis_to_seconds(value: u64) -> Option<i64> {
    i64::try_from(value / 1_000).ok()
}

fn opencode_transport_error(error: OpenCodeBridgeError) -> TransportError {
    TransportError::ConnectionFailed(error.to_string())
}

fn opencode_rpc_error(error: OpenCodeBridgeError) -> RpcError {
    match error {
        OpenCodeBridgeError::HttpTransport { .. }
        | OpenCodeBridgeError::HttpStatus { .. }
        | OpenCodeBridgeError::SseConnect { .. }
        | OpenCodeBridgeError::SseRead { .. } => {
            RpcError::Transport(TransportError::ConnectionFailed(error.to_string()))
        }
        _ => RpcError::Deserialization(error.to_string()),
    }
}

pub(crate) fn opencode_connect_request_to_config(
    request: AppOpenCodeConnectRequest,
) -> Result<OpenCodeServerConfig, String> {
    let base_url = Url::parse(&request.base_url).map_err(|error| format!("invalid base URL: {error}"))?;
    let host = base_url
        .host_str()
        .ok_or_else(|| "OpenCode base URL host missing".to_string())?
        .to_string();
    let port = base_url
        .port_or_known_default()
        .ok_or_else(|| "OpenCode base URL port missing".to_string())?;
    let tls = matches!(base_url.scheme(), "https");
    let mut config = OpenCodeServerConfig::new(
        request.server_id,
        request.display_name,
        request.base_url,
        host,
        port,
        tls,
    )
    .map_err(|error| error.to_string())?;
    config.basic_auth_username = request.basic_auth_username;
    config.basic_auth_password = request.basic_auth_password;
    config.known_directories = request
        .known_directories
        .into_iter()
        .map(|scope| OpenCodeDirectoryScope::new(scope.directory).map_err(|error| error.to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;
    use opencode_bridge::{
        OpenCodeConversationMessage, OpenCodeConversationPart, OpenCodeConversationRole,
        OpenCodeStreamText, OpenCodeThreadState, OpenCodeThreadSummary,
    };

    #[test]
    fn connect_request_parses_base_url_and_directories() {
        let config = opencode_connect_request_to_config(AppOpenCodeConnectRequest {
            server_id: "opencode-local".to_string(),
            display_name: "OpenCode".to_string(),
            base_url: "http://127.0.0.1:4187".to_string(),
            basic_auth_username: Some("user".to_string()),
            basic_auth_password: Some("pass".to_string()),
            known_directories: vec![crate::types::AppOpenCodeDirectoryScope {
                directory: "/tmp/project".to_string(),
            }],
        })
        .expect("config should parse");

        assert_eq!(config.host, "127.0.0.1");
        assert_eq!(config.port, 4187);
        assert!(!config.tls);
        assert_eq!(config.known_directories[0].directory, "/tmp/project");
    }

    #[test]
    fn thread_snapshot_marks_running_opencode_threads_active() {
        let summary = OpenCodeThreadSummary {
            thread_key: OpenCodeThreadKey::new("server-1", "/tmp/project", "sess-1").unwrap(),
            title: "Fix bug".to_string(),
            cwd: "/tmp/project".to_string(),
            parent_thread_id: None,
            created_at: 1_730_000_000_000,
            updated_at: 1_730_000_100_000,
            state: OpenCodeThreadState::Running,
            retry: None,
            project_id: None,
            version: None,
            changed_files: Vec::new(),
        };
        let snapshot = thread_snapshot_from_opencode(
            summary,
            vec![OpenCodeConversationMessage {
                thread_key: OpenCodeThreadKey::new("server-1", "/tmp/project", "sess-1").unwrap(),
                message_id: "msg-1".to_string(),
                role: OpenCodeConversationRole::Assistant,
                parent_message_id: None,
                created_at: 1_730_000_000_000,
                completed_at: None,
                agent: None,
                mode: None,
                path: None,
                model: Some(opencode_bridge::OpenCodeMappedModelRef {
                    provider_id: "openai".to_string(),
                    model_id: "gpt-5.4".to_string(),
                }),
                system: None,
                finish_reason: None,
                error: None,
                parts: vec![OpenCodeConversationPart::Text(OpenCodeStreamText {
                    part_id: "part-1".to_string(),
                    text: "Working".to_string(),
                    streamable: true,
                    synthetic: false,
                    ignored: false,
                    started_at: None,
                    completed_at: None,
                    metadata: Value::Object(Default::default()),
                })],
            }],
        );

        assert_eq!(snapshot.info.status, ThreadSummaryStatus::Active);
        assert_eq!(snapshot.active_turn_id.as_deref(), Some("opencode:sess-1"));
        assert_eq!(snapshot.info.model.as_deref(), Some("openai:gpt-5.4"));
        assert_eq!(snapshot.items.len(), 1);
    }
}
