use std::collections::HashSet;
use std::sync::RwLock;

use tokio::sync::broadcast;

use crate::conversation::ConversationItemContent;
use crate::session::connection::ServerConfig;
use crate::session::events::UiEvent;
use crate::types::{
    PendingApproval, PendingUserInputOption, PendingUserInputQuestion, PendingUserInputRequest,
    ThreadInfo, ThreadKey, ThreadSummaryStatus, generated,
};

use super::actions::{
    conversation_item_from_upstream, thread_info_from_upstream,
    thread_info_from_upstream_status_change,
};
use super::snapshot::{
    AppSnapshot, ServerHealthSnapshot, ServerSnapshot, ThreadSnapshot, VoiceSessionSnapshot,
};
use super::updates::AppUpdate;
use super::voice::{VoiceDerivedUpdate, VoiceRealtimeState};

pub struct AppStoreReducer {
    snapshot: RwLock<AppSnapshot>,
    updates_tx: broadcast::Sender<AppUpdate>,
    voice_state: VoiceRealtimeState,
}

impl AppStoreReducer {
    pub fn new() -> Self {
        let (updates_tx, _) = broadcast::channel(256);
        Self {
            snapshot: RwLock::new(AppSnapshot::default()),
            updates_tx,
            voice_state: VoiceRealtimeState::default(),
        }
    }

    pub fn snapshot(&self) -> AppSnapshot {
        self.snapshot
            .read()
            .expect("app store lock poisoned")
            .clone()
    }

    pub fn subscribe(&self) -> broadcast::Receiver<AppUpdate> {
        self.updates_tx.subscribe()
    }

    pub fn upsert_server(&self, config: &ServerConfig, health: ServerHealthSnapshot) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            let existing_account = snapshot
                .servers
                .get(&config.server_id)
                .and_then(|existing| existing.account.clone());
            let requires_openai_auth = snapshot
                .servers
                .get(&config.server_id)
                .is_some_and(|existing| existing.requires_openai_auth);
            let existing_rate_limits = snapshot
                .servers
                .get(&config.server_id)
                .and_then(|existing| existing.rate_limits.clone());
            let existing_available_models = snapshot
                .servers
                .get(&config.server_id)
                .and_then(|existing| existing.available_models.clone());
            snapshot.servers.insert(
                config.server_id.clone(),
                ServerSnapshot {
                    server_id: config.server_id.clone(),
                    display_name: config.display_name.clone(),
                    host: config.host.clone(),
                    port: config.port,
                    is_local: config.is_local,
                    health,
                    account: existing_account,
                    requires_openai_auth,
                    rate_limits: existing_rate_limits,
                    available_models: existing_available_models,
                },
            );
        }
        self.emit(AppUpdate::ServerChanged {
            server_id: config.server_id.clone(),
        });
    }

    pub fn remove_server(&self, server_id: &str) {
        let mut removed_thread_keys = Vec::new();
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            snapshot.servers.remove(server_id);
            snapshot.threads.retain(|key, _| {
                let keep = key.server_id != server_id;
                if !keep {
                    removed_thread_keys.push(key.clone());
                }
                keep
            });
            if snapshot
                .active_thread
                .as_ref()
                .is_some_and(|key| key.server_id == server_id)
            {
                snapshot.active_thread = None;
            }
            snapshot.pending_approvals.retain(|approval| {
                approval
                    .thread_id
                    .as_deref()
                    .is_none_or(|tid| !removed_thread_keys.iter().any(|key| key.thread_id == tid))
            });
            snapshot
                .pending_user_inputs
                .retain(|request| request.server_id != server_id);
            if snapshot
                .voice_session
                .active_thread
                .as_ref()
                .is_some_and(|key| key.server_id == server_id)
            {
                snapshot.voice_session = VoiceSessionSnapshot::default();
            }
        }
        self.emit(AppUpdate::ServerRemoved {
            server_id: server_id.to_string(),
        });
        for key in removed_thread_keys {
            self.emit(AppUpdate::ThreadRemoved { key });
        }
        self.emit(AppUpdate::ActiveThreadChanged { key: None });
    }

    pub fn sync_thread_list(&self, server_id: &str, threads: &[ThreadInfo]) {
        let incoming_ids = threads
            .iter()
            .map(|info| info.id.clone())
            .collect::<HashSet<_>>();
        let mut removed_thread_keys = Vec::new();
        let mut active_thread_cleared = false;
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            snapshot.threads.retain(|key, _| {
                let keep = key.server_id != server_id || incoming_ids.contains(&key.thread_id);
                if !keep {
                    removed_thread_keys.push(key.clone());
                }
                keep
            });
            for info in threads {
                let key = ThreadKey {
                    server_id: server_id.to_string(),
                    thread_id: info.id.clone(),
                };
                let entry = snapshot
                    .threads
                    .entry(key.clone())
                    .or_insert_with(|| ThreadSnapshot::from_info(server_id, info.clone()));
                entry.info = info.clone();
                entry.model = info.model.clone().or(entry.model.clone());
            }
            if snapshot
                .active_thread
                .as_ref()
                .is_some_and(|key| key.server_id == server_id && !incoming_ids.contains(&key.thread_id))
            {
                snapshot.active_thread = None;
                active_thread_cleared = true;
            }
            snapshot.pending_approvals.retain(|approval| {
                approval.thread_id.as_deref().is_none_or(|tid| {
                    !removed_thread_keys
                        .iter()
                        .any(|key| key.thread_id.as_str() == tid)
                })
            });
            snapshot.pending_user_inputs.retain(|request| {
                !(request.server_id == server_id
                    && removed_thread_keys
                        .iter()
                        .any(|key| key.thread_id == request.thread_id))
            });
            if snapshot
                .voice_session
                .active_thread
                .as_ref()
                .is_some_and(|key| key.server_id == server_id && !incoming_ids.contains(&key.thread_id))
            {
                snapshot.voice_session = VoiceSessionSnapshot::default();
            }
        }
        for key in removed_thread_keys {
            self.emit(AppUpdate::ThreadRemoved { key });
        }
        if active_thread_cleared {
            self.emit(AppUpdate::ActiveThreadChanged { key: None });
        }
        self.emit(AppUpdate::FullResync);
    }

    pub fn upsert_thread_snapshot(&self, thread: ThreadSnapshot) {
        let key = thread.key.clone();
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            snapshot.threads.insert(key.clone(), thread);
        }
        self.emit(AppUpdate::ThreadChanged { key });
    }

    pub fn remove_thread(&self, key: &ThreadKey) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            snapshot.threads.remove(key);
            if snapshot.active_thread.as_ref() == Some(key) {
                snapshot.active_thread = None;
            }
            if snapshot.voice_session.active_thread.as_ref() == Some(key) {
                snapshot.voice_session = VoiceSessionSnapshot::default();
            }
            snapshot
                .pending_approvals
                .retain(|approval| approval.thread_id.as_deref() != Some(key.thread_id.as_str()));
            snapshot.pending_user_inputs.retain(|request| {
                !(request.server_id == key.server_id && request.thread_id == key.thread_id)
            });
        }
        self.emit(AppUpdate::ThreadRemoved { key: key.clone() });
    }

    pub fn set_active_thread(&self, key: Option<ThreadKey>) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            snapshot.active_thread = key.clone();
        }
        self.emit(AppUpdate::ActiveThreadChanged { key });
    }

    pub fn replace_pending_approvals(&self, approvals: Vec<PendingApproval>) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            snapshot.pending_approvals = approvals.clone();
        }
        self.emit(AppUpdate::PendingApprovalsChanged { approvals });
    }

    pub fn resolve_approval(&self, request_id: &str) {
        let approvals = {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            snapshot
                .pending_approvals
                .retain(|approval| approval.id != request_id);
            snapshot.pending_approvals.clone()
        };
        self.emit(AppUpdate::PendingApprovalsChanged { approvals });
    }

    pub fn resolve_pending_user_input(&self, request_id: &str) {
        let requests = {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            snapshot
                .pending_user_inputs
                .retain(|request| request.id != request_id);
            snapshot.pending_user_inputs.clone()
        };
        self.emit(AppUpdate::PendingUserInputsChanged { requests });
    }

    pub fn update_server_account(
        &self,
        server_id: &str,
        account: Option<generated::Account>,
        requires_openai_auth: bool,
    ) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.account = account;
                server.requires_openai_auth = requires_openai_auth;
            }
        }
        self.emit(AppUpdate::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub fn update_server_rate_limits(
        &self,
        server_id: &str,
        rate_limits: Option<generated::RateLimitSnapshot>,
    ) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.rate_limits = rate_limits;
            }
        }
        self.emit(AppUpdate::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub fn update_server_models(&self, server_id: &str, models: Option<Vec<generated::Model>>) {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            if let Some(server) = snapshot.servers.get_mut(server_id) {
                server.available_models = models;
            }
        }
        self.emit(AppUpdate::ServerChanged {
            server_id: server_id.to_string(),
        });
    }

    pub fn apply_ui_event(&self, event: &UiEvent) {
        match event {
            UiEvent::ThreadStarted { key, notification } => {
                let info = thread_info_from_upstream(notification.thread.clone());
                self.upsert_or_merge_thread(key.clone(), info, |thread| {
                    thread.info.status = ThreadSummaryStatus::Active;
                    if thread.info.parent_thread_id.is_some() {
                        thread.info.agent_status = Some("running".to_string());
                    }
                });
            }
            UiEvent::ThreadArchived { key } => {
                self.remove_thread(key);
            }
            UiEvent::ThreadNameUpdated { key, thread_name } => {
                self.mutate_thread(key, |thread| {
                    thread.info.title = thread_name.clone();
                });
            }
            UiEvent::ThreadStatusChanged { key, notification } => {
                let info = thread_info_from_upstream_status_change(
                    &notification.thread_id,
                    notification.status.clone(),
                );
                self.upsert_or_merge_thread(key.clone(), info, |thread| {
                    if thread.info.parent_thread_id.is_some() {
                        thread.info.agent_status = match thread.info.status {
                            ThreadSummaryStatus::Active => Some("running".to_string()),
                            ThreadSummaryStatus::SystemError => Some("errored".to_string()),
                            ThreadSummaryStatus::Idle => thread
                                .info
                                .agent_status
                                .clone()
                                .or(Some("completed".to_string())),
                            ThreadSummaryStatus::NotLoaded => thread.info.agent_status.clone(),
                        };
                    }
                });
            }
            UiEvent::ModelRerouted { key, notification } => {
                self.mutate_thread(key, |thread| {
                    thread.model = Some(notification.to_model.clone());
                    thread.info.model = Some(notification.to_model.clone());
                });
            }
            UiEvent::TurnStarted { key, turn_id } => {
                self.mutate_thread(key, |thread| {
                    thread.active_turn_id = Some(turn_id.clone());
                    thread.info.status = ThreadSummaryStatus::Active;
                    if thread.info.parent_thread_id.is_some() {
                        thread.info.agent_status = Some("running".to_string());
                    }
                });
            }
            UiEvent::TurnCompleted { key, .. } => {
                self.mutate_thread(key, |thread| {
                    thread.active_turn_id = None;
                    thread.info.status = ThreadSummaryStatus::Idle;
                    if thread.info.parent_thread_id.is_some() {
                        thread.info.agent_status = Some("completed".to_string());
                    }
                });
            }
            UiEvent::ItemStarted { key, notification } => {
                if let Some(item) = conversation_item_from_upstream(notification.item.clone()) {
                    self.mutate_thread(key, |thread| upsert_item(thread, item.clone()));
                }
            }
            UiEvent::ItemCompleted { key, notification } => {
                if let Some(item) = conversation_item_from_upstream(notification.item.clone()) {
                    self.mutate_thread(key, |thread| upsert_item(thread, item.clone()));
                }
            }
            UiEvent::MessageDelta {
                key,
                item_id,
                delta,
            } => {
                self.mutate_thread(key, |thread| append_assistant_delta(thread, item_id, delta));
            }
            UiEvent::ReasoningDelta {
                key,
                item_id,
                delta,
            } => {
                self.mutate_thread(key, |thread| append_reasoning_delta(thread, item_id, delta));
            }
            UiEvent::PlanDelta {
                key,
                item_id,
                delta,
            } => {
                self.mutate_thread(key, |thread| append_plan_delta(thread, item_id, delta));
            }
            UiEvent::CommandOutputDelta {
                key,
                item_id,
                delta,
            } => {
                self.mutate_thread(key, |thread| {
                    append_command_output_delta(thread, item_id, delta)
                });
            }
            UiEvent::ApprovalRequested { approval, .. } => {
                let approvals = {
                    let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
                    if !snapshot
                        .pending_approvals
                        .iter()
                        .any(|existing| existing.id == approval.id)
                    {
                        snapshot.pending_approvals.push(approval.clone());
                    }
                    snapshot.pending_approvals.clone()
                };
                self.emit(AppUpdate::PendingApprovalsChanged { approvals });
            }
            UiEvent::ServerRequestResolved { notification, .. } => {
                let request_id = match &notification.request_id {
                    codex_app_server_protocol::RequestId::String(value) => value.as_str(),
                    codex_app_server_protocol::RequestId::Integer(_) => return,
                };
                self.resolve_approval(request_id);
                self.resolve_pending_user_input(request_id);
            }
            UiEvent::AccountRateLimitsUpdated {
                server_id,
                notification,
            } => {
                if let Ok(rate_limits) =
                    crate::rpc::convert_generated_field(notification.rate_limits.clone())
                {
                    self.update_server_rate_limits(server_id, Some(rate_limits));
                }
            }
            UiEvent::ConnectionStateChanged { server_id, health } => {
                {
                    let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
                    if let Some(server) = snapshot.servers.get_mut(server_id) {
                        server.health = ServerHealthSnapshot::from_wire(health);
                    }
                }
                self.emit(AppUpdate::ServerChanged {
                    server_id: server_id.clone(),
                });
            }
            UiEvent::ContextTokensUpdated { key, used, limit } => {
                self.mutate_thread(key, |thread| {
                    thread.context_tokens_used = Some(*used);
                    thread.model_context_window = Some(*limit);
                });
            }
            UiEvent::RealtimeStarted { key, notification } => {
                self.voice_state.reset_thread(key);
                {
                    let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
                    snapshot.voice_session.active_thread = Some(key.clone());
                    snapshot.voice_session.session_id = notification.session_id.clone();
                    snapshot.voice_session.phase = Some("active".to_string());
                    if let Some(thread) = snapshot.threads.get_mut(key) {
                        thread.realtime_session_id = notification.session_id.clone();
                    }
                }
                self.emit(AppUpdate::VoiceSessionChanged);
                let generated_notification = generated::ThreadRealtimeStartedNotification {
                    thread_id: notification.thread_id.clone(),
                    session_id: notification.session_id.clone(),
                };
                self.emit(AppUpdate::RealtimeStarted {
                    key: key.clone(),
                    notification: generated_notification,
                });
                self.emit(AppUpdate::ThreadChanged { key: key.clone() });
            }
            UiEvent::RealtimeItemAdded { key, notification } => {
                if let Ok(generated_item) =
                    crate::rpc::convert_generated_field(notification.item.clone())
                {
                    for update in self.voice_state.handle_item(key, &generated_item) {
                        match update {
                            VoiceDerivedUpdate::Transcript(update) => {
                                self.emit(AppUpdate::RealtimeTranscriptUpdated {
                                    key: key.clone(),
                                    update,
                                });
                            }
                            VoiceDerivedUpdate::HandoffRequest(request) => {
                                self.emit(AppUpdate::RealtimeHandoffRequested {
                                    key: key.clone(),
                                    request,
                                });
                            }
                            VoiceDerivedUpdate::SpeechStarted => {
                                self.emit(AppUpdate::RealtimeSpeechStarted { key: key.clone() });
                            }
                        }
                    }
                }
            }
            UiEvent::RealtimeOutputAudioDelta { key, notification } => {
                let generated_notification = generated::ThreadRealtimeOutputAudioDeltaNotification {
                    thread_id: notification.thread_id.clone(),
                    audio: generated::ThreadRealtimeAudioChunk {
                        data: notification.audio.data.clone(),
                        sample_rate: notification.audio.sample_rate,
                        num_channels: notification.audio.num_channels as u32,
                        samples_per_channel: notification.audio.samples_per_channel,
                    },
                };
                self.emit(AppUpdate::RealtimeOutputAudioDelta {
                    key: key.clone(),
                    notification: generated_notification,
                });
            }
            UiEvent::RealtimeError { key, notification } => {
                {
                    let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
                    snapshot.voice_session.phase = Some("error".to_string());
                    snapshot.voice_session.last_error = Some(notification.message.clone());
                }
                self.emit(AppUpdate::VoiceSessionChanged);
                let generated_notification = generated::ThreadRealtimeErrorNotification {
                    thread_id: notification.thread_id.clone(),
                    message: notification.message.clone(),
                };
                self.emit(AppUpdate::RealtimeError {
                    key: key.clone(),
                    notification: generated_notification,
                });
            }
            UiEvent::RealtimeClosed { key, notification } => {
                self.voice_state.clear_thread(key);
                {
                    let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
                    if let Some(thread) = snapshot.threads.get_mut(key) {
                        thread.realtime_session_id = None;
                    }
                    snapshot.voice_session = VoiceSessionSnapshot::default();
                }
                self.emit(AppUpdate::VoiceSessionChanged);
                let generated_notification = generated::ThreadRealtimeClosedNotification {
                    thread_id: notification.thread_id.clone(),
                    reason: notification.reason.clone(),
                };
                self.emit(AppUpdate::RealtimeClosed {
                    key: key.clone(),
                    notification: generated_notification,
                });
                self.emit(AppUpdate::ThreadChanged { key: key.clone() });
            }
            UiEvent::RawNotification {
                server_id,
                method,
                params_json,
            } => {
                if method == "item/tool/requestUserInput" {
                    if let Some(request) = pending_user_input_from_raw(server_id, params_json) {
                        let requests = {
                            let mut snapshot =
                                self.snapshot.write().expect("app store lock poisoned");
                            snapshot
                                .pending_user_inputs
                                .retain(|existing| existing.id != request.id);
                            snapshot.pending_user_inputs.push(request);
                            snapshot.pending_user_inputs.clone()
                        };
                        self.emit(AppUpdate::PendingUserInputsChanged { requests });
                    }
                }
            }
            _ => {}
        }
    }

    fn upsert_or_merge_thread<F>(&self, key: ThreadKey, info: ThreadInfo, mutate: F)
    where
        F: FnOnce(&mut ThreadSnapshot),
    {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            let thread = snapshot
                .threads
                .entry(key.clone())
                .or_insert_with(|| ThreadSnapshot::from_info(&key.server_id, info.clone()));
            thread.info.id = info.id;
            if info.title.is_some() {
                thread.info.title = info.title;
            }
            if info.preview.is_some() {
                thread.info.preview = info.preview;
            }
            if info.cwd.is_some() {
                thread.info.cwd = info.cwd;
            }
            if info.path.is_some() {
                thread.info.path = info.path;
            }
            if info.model_provider.is_some() {
                thread.info.model_provider = info.model_provider;
            }
            if info.agent_nickname.is_some() {
                thread.info.agent_nickname = info.agent_nickname;
            }
            if info.agent_role.is_some() {
                thread.info.agent_role = info.agent_role;
            }
            if info.created_at.is_some() {
                thread.info.created_at = info.created_at;
            }
            if info.updated_at.is_some() {
                thread.info.updated_at = info.updated_at;
            }
            thread.info.status = info.status;
            mutate(thread);
        }
        self.emit(AppUpdate::ThreadChanged { key });
    }

    fn mutate_thread<F>(&self, key: &ThreadKey, mutate: F)
    where
        F: FnOnce(&mut ThreadSnapshot),
    {
        {
            let mut snapshot = self.snapshot.write().expect("app store lock poisoned");
            let Some(thread) = snapshot.threads.get_mut(key) else {
                return;
            };
            mutate(thread);
        }
        self.emit(AppUpdate::ThreadChanged { key: key.clone() });
    }

    fn emit(&self, update: AppUpdate) {
        let _ = self.updates_tx.send(update);
    }
}

fn pending_user_input_from_raw(
    server_id: &str,
    params_json: &str,
) -> Option<PendingUserInputRequest> {
    let raw: serde_json::Value = serde_json::from_str(params_json).ok()?;
    let request_id = raw.get("requestId")?.as_str()?.to_string();
    let params = raw.get("params")?;
    let thread_id = params
        .get("thread_id")
        .or_else(|| params.get("threadId"))?
        .as_str()?
        .to_string();
    let turn_id = params
        .get("turn_id")
        .or_else(|| params.get("turnId"))?
        .as_str()?
        .to_string();
    let item_id = params
        .get("item_id")
        .or_else(|| params.get("itemId"))?
        .as_str()?
        .to_string();
    let questions = params
        .get("questions")?
        .as_array()?
        .iter()
        .filter_map(|question| {
            Some(PendingUserInputQuestion {
                id: question.get("id")?.as_str()?.to_string(),
                header: question
                    .get("header")
                    .and_then(|value| value.as_str())
                    .map(ToString::to_string),
                question: question.get("question")?.as_str()?.to_string(),
                is_other_allowed: question
                    .get("is_other_allowed")
                    .or_else(|| question.get("isOtherAllowed"))
                    .and_then(|value| value.as_bool())
                    .unwrap_or(false),
                is_secret: question
                    .get("is_secret")
                    .or_else(|| question.get("isSecret"))
                    .and_then(|value| value.as_bool())
                    .unwrap_or(false),
                options: question
                    .get("options")
                    .and_then(|value| value.as_array())
                    .map(|options| {
                        options
                            .iter()
                            .filter_map(|option| {
                                Some(PendingUserInputOption {
                                    label: option.get("label")?.as_str()?.to_string(),
                                    description: option
                                        .get("description")
                                        .and_then(|value| value.as_str())
                                        .map(ToString::to_string),
                                })
                            })
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default(),
            })
        })
        .collect::<Vec<_>>();

    if questions.is_empty() {
        return None;
    }

    Some(PendingUserInputRequest {
        id: request_id,
        server_id: server_id.to_string(),
        thread_id,
        turn_id,
        item_id,
        questions,
        requester_agent_nickname: None,
        requester_agent_role: None,
    })
}

fn upsert_item(thread: &mut ThreadSnapshot, item: crate::conversation::ConversationItem) {
    if let Some(existing) = thread
        .items
        .iter_mut()
        .find(|existing| existing.id == item.id)
    {
        *existing = item;
    } else {
        thread.items.push(item);
    }
}

fn append_assistant_delta(thread: &mut ThreadSnapshot, item_id: &str, delta: &str) {
    let Some(item) = thread.items.iter_mut().find(|item| item.id == item_id) else {
        return;
    };
    if let ConversationItemContent::Assistant(message) = &mut item.content {
        message.text.push_str(delta);
    }
}

fn append_reasoning_delta(thread: &mut ThreadSnapshot, item_id: &str, delta: &str) {
    let Some(item) = thread.items.iter_mut().find(|item| item.id == item_id) else {
        return;
    };
    if let ConversationItemContent::Reasoning(reasoning) = &mut item.content {
        if let Some(last) = reasoning.content.last_mut() {
            last.push_str(delta);
        } else {
            reasoning.content.push(delta.to_string());
        }
    }
}

fn append_plan_delta(thread: &mut ThreadSnapshot, item_id: &str, delta: &str) {
    let Some(item) = thread.items.iter_mut().find(|item| item.id == item_id) else {
        return;
    };
    if let ConversationItemContent::ProposedPlan(plan) = &mut item.content {
        plan.content.push_str(delta);
    }
}

fn append_command_output_delta(thread: &mut ThreadSnapshot, item_id: &str, delta: &str) {
    let Some(item) = thread.items.iter_mut().find(|item| item.id == item_id) else {
        return;
    };
    if let ConversationItemContent::CommandExecution(command) = &mut item.content {
        command
            .output
            .get_or_insert_with(String::new)
            .push_str(delta);
    }
}
