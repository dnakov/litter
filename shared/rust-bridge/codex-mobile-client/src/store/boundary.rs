use std::hash::{Hash, Hasher};

use crate::conversation_uniffi::HydratedConversationItem;
use crate::types::{PendingApproval, PendingUserInputRequest, ThreadInfo, ThreadKey};
use crate::uniffi_shared::{
    AppOperationStatus, AppSubagentStatus, AppVoiceHandoffRequest, AppVoiceTranscriptUpdate,
};

use super::snapshot::{
    AppSnapshot, QueuedFollowUpPreview, ServerConnectionProgressSnapshot, ServerHealthSnapshot,
    ServerSnapshot, ThreadSnapshot, VoiceSessionSnapshot,
};
use super::updates::{AppUpdate, ThreadStreamingDeltaKind};

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppServerSnapshot {
    pub server_id: String,
    pub display_name: String,
    pub host: String,
    pub port: u16,
    pub is_local: bool,
    pub has_ipc: bool,
    pub health: AppServerHealth,
    pub account: Option<crate::types::generated::Account>,
    pub requires_openai_auth: bool,
    pub rate_limits: Option<crate::types::generated::RateLimitSnapshot>,
    pub available_models: Option<Vec<crate::types::generated::Model>>,
    pub connection_progress: Option<ServerConnectionProgressSnapshot>,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum AppServerHealth {
    Disconnected,
    Connecting,
    Connected,
    Unresponsive,
    Unknown,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppThreadSnapshot {
    pub key: ThreadKey,
    pub info: ThreadInfo,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub hydrated_conversation_items: Vec<HydratedConversationItem>,
    pub queued_follow_ups: Vec<QueuedFollowUpPreview>,
    pub active_turn_id: Option<String>,
    pub context_tokens_used: Option<u64>,
    pub model_context_window: Option<u64>,
    pub rate_limits_json: Option<String>,
    pub realtime_session_id: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppThreadStateRecord {
    pub key: ThreadKey,
    pub info: ThreadInfo,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub queued_follow_ups: Vec<QueuedFollowUpPreview>,
    pub active_turn_id: Option<String>,
    pub context_tokens_used: Option<u64>,
    pub model_context_window: Option<u64>,
    pub rate_limits_json: Option<String>,
    pub realtime_session_id: Option<String>,
}

impl TryFrom<super::snapshot::ThreadSnapshot> for AppThreadSnapshot {
    type Error = String;

    fn try_from(thread: super::snapshot::ThreadSnapshot) -> Result<Self, Self::Error> {
        (&thread).try_into()
    }
}

impl TryFrom<&super::snapshot::ThreadSnapshot> for AppThreadSnapshot {
    type Error = String;

    fn try_from(thread: &super::snapshot::ThreadSnapshot) -> Result<Self, Self::Error> {
        let hydrated_conversation_items =
            merged_hydrated_items(&thread.items, &thread.local_overlay_items);
        Ok(Self {
            key: thread.key.clone(),
            info: thread.info.clone(),
            model: thread.model.clone(),
            reasoning_effort: thread.reasoning_effort.clone(),
            hydrated_conversation_items,
            queued_follow_ups: thread
                .queued_follow_ups
                .iter()
                .map(|preview| QueuedFollowUpPreview {
                    id: preview.id.clone(),
                    text: preview.text.clone(),
                })
                .collect(),
            active_turn_id: thread.active_turn_id.clone(),
            context_tokens_used: thread.context_tokens_used,
            model_context_window: thread.model_context_window,
            rate_limits_json: thread
                .rate_limits
                .clone()
                .map(|limits| serde_json::to_string(&limits))
                .transpose()
                .map_err(|error| format!("serialize rate limits: {error}"))?,
            realtime_session_id: thread.realtime_session_id.clone(),
        })
    }
}

impl TryFrom<&super::snapshot::ThreadSnapshot> for AppThreadStateRecord {
    type Error = String;

    fn try_from(thread: &super::snapshot::ThreadSnapshot) -> Result<Self, Self::Error> {
        Ok(Self {
            key: thread.key.clone(),
            info: thread.info.clone(),
            model: thread.model.clone(),
            reasoning_effort: thread.reasoning_effort.clone(),
            queued_follow_ups: thread
                .queued_follow_ups
                .iter()
                .map(|preview| QueuedFollowUpPreview {
                    id: preview.id.clone(),
                    text: preview.text.clone(),
                })
                .collect(),
            active_turn_id: thread.active_turn_id.clone(),
            context_tokens_used: thread.context_tokens_used,
            model_context_window: thread.model_context_window,
            rate_limits_json: thread
                .rate_limits
                .clone()
                .map(|limits| serde_json::to_string(&limits))
                .transpose()
                .map_err(|error| format!("serialize rate limits: {error}"))?,
            realtime_session_id: thread.realtime_session_id.clone(),
        })
    }
}

fn merged_hydrated_items(
    items: &[crate::conversation::ConversationItem],
    local_overlay_items: &[crate::conversation::ConversationItem],
) -> Vec<HydratedConversationItem> {
    let mut merged = Vec::with_capacity(items.len() + local_overlay_items.len());
    merged.extend(items.iter().cloned().map(Into::into));

    let mut selected_overlays: Vec<&crate::conversation::ConversationItem> = Vec::new();
    for overlay in local_overlay_items {
        if items
            .iter()
            .all(|existing| !same_overlay_semantics(overlay, existing))
            && selected_overlays
                .iter()
                .all(|existing| !same_overlay_semantics(overlay, existing))
        {
            selected_overlays.push(overlay);
        }
    }
    merged.extend(selected_overlays.into_iter().cloned().map(Into::into));
    merged
}

fn same_overlay_semantics(
    lhs: &crate::conversation::ConversationItem,
    rhs: &crate::conversation::ConversationItem,
) -> bool {
    if lhs.id == rhs.id {
        return true;
    }

    match (&lhs.content, &rhs.content) {
        (
            crate::conversation::ConversationItemContent::UserInputResponse(lhs_data),
            crate::conversation::ConversationItemContent::UserInputResponse(rhs_data),
        ) => lhs.source_turn_id == rhs.source_turn_id && lhs_data == rhs_data,
        _ => false,
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppSessionSummary {
    pub key: ThreadKey,
    pub server_display_name: String,
    pub server_host: String,
    pub title: String,
    pub preview: String,
    pub cwd: String,
    pub model: String,
    pub model_provider: String,
    pub parent_thread_id: Option<String>,
    pub agent_nickname: Option<String>,
    pub agent_role: Option<String>,
    pub agent_display_label: Option<String>,
    pub agent_status: AppSubagentStatus,
    pub updated_at: Option<i64>,
    pub has_active_turn: bool,
    pub is_subagent: bool,
    pub is_fork: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppSnapshotRecord {
    pub servers: Vec<AppServerSnapshot>,
    pub threads: Vec<AppThreadSnapshot>,
    pub session_summaries: Vec<AppSessionSummary>,
    pub agent_directory_version: u64,
    pub active_thread: Option<ThreadKey>,
    pub pending_approvals: Vec<PendingApproval>,
    pub pending_user_inputs: Vec<PendingUserInputRequest>,
    pub voice_session: VoiceSessionSnapshot,
}

impl TryFrom<AppSnapshot> for AppSnapshotRecord {
    type Error = String;

    fn try_from(snapshot: AppSnapshot) -> Result<Self, Self::Error> {
        let session_summaries = session_summaries_from_snapshot(&snapshot);
        let agent_directory_version = agent_directory_version(&session_summaries);

        let mut servers = snapshot
            .servers
            .into_values()
            .map(|server| AppServerSnapshot {
                server_id: server.server_id,
                display_name: server.display_name,
                host: server.host,
                port: server.port,
                is_local: server.is_local,
                has_ipc: server.has_ipc,
                health: server.health.into(),
                account: server.account,
                requires_openai_auth: server.requires_openai_auth,
                rate_limits: server.rate_limits,
                available_models: server.available_models,
                connection_progress: server.connection_progress,
            })
            .collect::<Vec<_>>();
        servers.sort_by(|lhs, rhs| lhs.server_id.cmp(&rhs.server_id));

        let mut threads = snapshot
            .threads
            .values()
            .map(AppThreadSnapshot::try_from)
            .collect::<Result<Vec<_>, String>>()?;
        threads.sort_by(|lhs, rhs| lhs.key.thread_id.cmp(&rhs.key.thread_id));

        Ok(Self {
            servers,
            threads,
            session_summaries,
            agent_directory_version,
            active_thread: snapshot.active_thread,
            pending_approvals: snapshot.pending_approvals,
            pending_user_inputs: snapshot.pending_user_inputs,
            voice_session: snapshot.voice_session,
        })
    }
}

pub(crate) fn session_summaries_from_snapshot(snapshot: &AppSnapshot) -> Vec<AppSessionSummary> {
    let mut session_summaries = snapshot
        .threads
        .values()
        .map(|thread| app_session_summary(thread, snapshot.servers.get(&thread.key.server_id)))
        .collect::<Vec<_>>();
    sort_session_summaries(&mut session_summaries);
    session_summaries
}

pub(crate) fn app_session_summary(
    thread: &ThreadSnapshot,
    server: Option<&ServerSnapshot>,
) -> AppSessionSummary {
    let preview = thread.info.preview.as_deref().unwrap_or_default();
    let title = {
        thread
            .info
            .title
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .or_else(|| {
                let trimmed_preview = preview.trim();
                (!trimmed_preview.is_empty()).then(|| trimmed_preview.to_string())
            })
            .unwrap_or_else(|| "Untitled session".to_string())
    };
    let parent_thread_id = thread
        .info
        .parent_thread_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let has_agent_label = thread
        .info
        .agent_nickname
        .as_deref()
        .is_some_and(|value| !value.trim().is_empty())
        || thread
            .info
            .agent_role
            .as_deref()
            .is_some_and(|value| !value.trim().is_empty());
    let is_fork = parent_thread_id.is_some();

    AppSessionSummary {
        key: thread.key.clone(),
        server_display_name: server
            .map(|server| server.display_name.clone())
            .unwrap_or_else(|| thread.key.server_id.clone()),
        server_host: server
            .map(|server| server.host.clone())
            .unwrap_or_else(|| thread.key.server_id.clone()),
        title,
        preview: preview.to_string(),
        cwd: thread.info.cwd.clone().unwrap_or_default(),
        model: thread
            .info
            .model
            .clone()
            .or_else(|| thread.model.clone())
            .unwrap_or_default(),
        model_provider: thread.info.model_provider.clone().unwrap_or_default(),
        parent_thread_id,
        agent_nickname: thread.info.agent_nickname.clone(),
        agent_role: thread.info.agent_role.clone(),
        agent_display_label: agent_display_label(
            thread.info.agent_nickname.as_deref(),
            thread.info.agent_role.as_deref(),
            None,
        ),
        agent_status: thread
            .info
            .agent_status
            .as_deref()
            .map(AppSubagentStatus::from_raw)
            .unwrap_or(AppSubagentStatus::Unknown),
        updated_at: thread.info.updated_at,
        has_active_turn: thread.active_turn_id.is_some(),
        is_subagent: is_fork && has_agent_label,
        is_fork,
    }
}

pub(crate) fn sort_session_summaries(session_summaries: &mut [AppSessionSummary]) {
    session_summaries.sort_by(|lhs, rhs| {
        rhs.updated_at
            .cmp(&lhs.updated_at)
            .then_with(|| lhs.key.server_id.cmp(&rhs.key.server_id))
            .then_with(|| lhs.key.thread_id.cmp(&rhs.key.thread_id))
    });
}

pub(crate) fn project_thread_update(
    snapshot: &AppSnapshot,
    key: &ThreadKey,
) -> Result<Option<(AppThreadSnapshot, AppSessionSummary, u64)>, String> {
    let Some(thread) = snapshot.threads.get(key) else {
        return Ok(None);
    };
    let thread_snapshot = AppThreadSnapshot::try_from(thread)?;
    let session_summary = app_session_summary(thread, snapshot.servers.get(&key.server_id));
    let agent_directory_version = current_agent_directory_version(snapshot);
    Ok(Some((
        thread_snapshot,
        session_summary,
        agent_directory_version,
    )))
}

pub(crate) fn project_thread_state_update(
    snapshot: &AppSnapshot,
    key: &ThreadKey,
) -> Result<Option<(AppThreadStateRecord, AppSessionSummary, u64)>, String> {
    let Some(thread) = snapshot.threads.get(key) else {
        return Ok(None);
    };
    let thread_state = AppThreadStateRecord::try_from(thread)?;
    let session_summary = app_session_summary(thread, snapshot.servers.get(&key.server_id));
    let agent_directory_version = current_agent_directory_version(snapshot);
    Ok(Some((
        thread_state,
        session_summary,
        agent_directory_version,
    )))
}

pub(crate) fn current_agent_directory_version(snapshot: &AppSnapshot) -> u64 {
    let mut threads = snapshot.threads.values().collect::<Vec<_>>();
    threads.sort_by(|lhs, rhs| {
        rhs.info
            .updated_at
            .cmp(&lhs.info.updated_at)
            .then_with(|| lhs.key.server_id.cmp(&rhs.key.server_id))
            .then_with(|| lhs.key.thread_id.cmp(&rhs.key.thread_id))
    });

    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    for thread in threads {
        thread.key.server_id.hash(&mut hasher);
        thread.key.thread_id.hash(&mut hasher);
        thread
            .info
            .parent_thread_id
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .hash(&mut hasher);
        thread.info.agent_nickname.hash(&mut hasher);
        thread.info.agent_role.hash(&mut hasher);
        agent_display_label(
            thread.info.agent_nickname.as_deref(),
            thread.info.agent_role.as_deref(),
            None,
        )
        .hash(&mut hasher);
        thread
            .info
            .agent_status
            .as_deref()
            .map(AppSubagentStatus::from_raw)
            .unwrap_or(AppSubagentStatus::Unknown)
            .hash(&mut hasher);
        thread.info.updated_at.hash(&mut hasher);
        thread.active_turn_id.is_some().hash(&mut hasher);
    }
    hasher.finish()
}

impl From<ServerHealthSnapshot> for AppServerHealth {
    fn from(value: ServerHealthSnapshot) -> Self {
        match value {
            ServerHealthSnapshot::Disconnected => Self::Disconnected,
            ServerHealthSnapshot::Connecting => Self::Connecting,
            ServerHealthSnapshot::Connected => Self::Connected,
            ServerHealthSnapshot::Unresponsive => Self::Unresponsive,
            ServerHealthSnapshot::Unknown(_) => Self::Unknown,
        }
    }
}

fn agent_directory_version(session_summaries: &[AppSessionSummary]) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    for summary in session_summaries {
        summary.key.server_id.hash(&mut hasher);
        summary.key.thread_id.hash(&mut hasher);
        summary.parent_thread_id.hash(&mut hasher);
        summary.agent_nickname.hash(&mut hasher);
        summary.agent_role.hash(&mut hasher);
        summary.agent_display_label.hash(&mut hasher);
        summary.agent_status.hash(&mut hasher);
        summary.updated_at.hash(&mut hasher);
        summary.has_active_turn.hash(&mut hasher);
    }
    hasher.finish()
}

fn agent_display_label(
    nickname: Option<&str>,
    role: Option<&str>,
    fallback_identifier: Option<&str>,
) -> Option<String> {
    let clean_nickname = sanitized_label_field(nickname);
    let clean_role = sanitized_label_field(role);
    match (clean_nickname, clean_role) {
        (Some(nickname), Some(role)) => Some(format!("{nickname} [{role}]")),
        (Some(nickname), None) => Some(nickname.to_string()),
        (None, Some(role)) => Some(format!("[{role}]")),
        (None, None) => sanitized_label_field(fallback_identifier).map(str::to_string),
    }
}

fn sanitized_label_field(raw: Option<&str>) -> Option<&str> {
    raw.and_then(|value| {
        let trimmed = value.trim();
        (!trimmed.is_empty()).then_some(trimmed)
    })
}

#[cfg(test)]
mod tests {
    use super::{
        agent_directory_version, current_agent_directory_version, session_summaries_from_snapshot,
    };
    use crate::store::{AppSnapshot, ThreadSnapshot};
    use crate::types::{ThreadInfo, ThreadKey, ThreadSummaryStatus};

    #[test]
    fn current_agent_directory_version_matches_summary_hash() {
        let mut snapshot = AppSnapshot::default();

        let mut parent = ThreadSnapshot::from_info(
            "srv",
            ThreadInfo {
                id: "thread-a".to_string(),
                title: Some("Parent".to_string()),
                model: None,
                preview: Some("Preview".to_string()),
                cwd: None,
                path: None,
                model_provider: None,
                agent_nickname: None,
                agent_role: None,
                parent_thread_id: None,
                agent_status: None,
                created_at: None,
                status: ThreadSummaryStatus::Idle,
                updated_at: Some(20),
            },
        );
        parent.active_turn_id = Some("turn-a".to_string());
        snapshot.threads.insert(parent.key.clone(), parent);

        let child_key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-b".to_string(),
        };
        snapshot.threads.insert(
            child_key.clone(),
            ThreadSnapshot {
                key: child_key,
                info: ThreadInfo {
                    id: "thread-b".to_string(),
                    title: None,
                    model: None,
                    preview: None,
                    cwd: None,
                    path: None,
                    model_provider: None,
                    parent_thread_id: Some(" thread-a ".to_string()),
                    agent_nickname: Some("assistant".to_string()),
                    agent_role: Some("coder".to_string()),
                    agent_status: Some("running".to_string()),
                    created_at: None,
                    status: ThreadSummaryStatus::Active,
                    updated_at: Some(10),
                },
                model: None,
                reasoning_effort: None,
                items: Vec::new(),
                local_overlay_items: Vec::new(),
                queued_follow_ups: Vec::new(),
                active_turn_id: None,
                context_tokens_used: None,
                model_context_window: None,
                rate_limits: None,
                realtime_session_id: None,
            },
        );

        let expected = agent_directory_version(&session_summaries_from_snapshot(&snapshot));
        assert_eq!(current_agent_directory_version(&snapshot), expected);
    }
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum AppThreadStreamingDeltaKind {
    AssistantText,
    ReasoningText,
    PlanText,
    CommandOutput,
    McpProgress,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum AppStoreUpdateRecord {
    FullResync,
    ServerChanged {
        server_id: String,
    },
    ServerRemoved {
        server_id: String,
    },
    ThreadUpserted {
        thread: AppThreadSnapshot,
        session_summary: AppSessionSummary,
        agent_directory_version: u64,
    },
    ThreadStateUpdated {
        state: AppThreadStateRecord,
        session_summary: AppSessionSummary,
        agent_directory_version: u64,
    },
    ThreadItemUpserted {
        key: ThreadKey,
        item: HydratedConversationItem,
    },
    ThreadCommandExecutionUpdated {
        key: ThreadKey,
        item_id: String,
        status: AppOperationStatus,
        exit_code: Option<i32>,
        duration_ms: Option<i64>,
        process_id: Option<String>,
    },
    ThreadStreamingDelta {
        key: ThreadKey,
        item_id: String,
        kind: AppThreadStreamingDeltaKind,
        text: String,
    },
    ThreadRemoved {
        key: ThreadKey,
        agent_directory_version: u64,
    },
    ActiveThreadChanged {
        key: Option<ThreadKey>,
    },
    PendingApprovalsChanged,
    PendingUserInputsChanged,
    VoiceSessionChanged,
    RealtimeTranscriptUpdated {
        key: ThreadKey,
        update: AppVoiceTranscriptUpdate,
    },
    RealtimeHandoffRequested {
        key: ThreadKey,
        request: AppVoiceHandoffRequest,
    },
    RealtimeSpeechStarted {
        key: ThreadKey,
    },
    RealtimeStarted {
        key: ThreadKey,
        notification: crate::types::generated::ThreadRealtimeStartedNotification,
    },
    RealtimeOutputAudioDelta {
        key: ThreadKey,
        notification: crate::types::generated::ThreadRealtimeOutputAudioDeltaNotification,
    },
    RealtimeError {
        key: ThreadKey,
        notification: crate::types::generated::ThreadRealtimeErrorNotification,
    },
    RealtimeClosed {
        key: ThreadKey,
        notification: crate::types::generated::ThreadRealtimeClosedNotification,
    },
}

impl From<AppUpdate> for AppStoreUpdateRecord {
    fn from(value: AppUpdate) -> Self {
        match value {
            AppUpdate::FullResync => Self::FullResync,
            AppUpdate::ServerChanged { server_id } => Self::ServerChanged { server_id },
            AppUpdate::ServerRemoved { server_id } => Self::ServerRemoved { server_id },
            AppUpdate::ThreadUpserted {
                thread,
                session_summary,
                agent_directory_version,
            } => Self::ThreadUpserted {
                thread,
                session_summary,
                agent_directory_version,
            },
            AppUpdate::ThreadStateUpdated {
                state,
                session_summary,
                agent_directory_version,
            } => Self::ThreadStateUpdated {
                state,
                session_summary,
                agent_directory_version,
            },
            AppUpdate::ThreadItemUpserted { key, item } => Self::ThreadItemUpserted { key, item },
            AppUpdate::ThreadCommandExecutionUpdated {
                key,
                item_id,
                status,
                exit_code,
                duration_ms,
                process_id,
            } => Self::ThreadCommandExecutionUpdated {
                key,
                item_id,
                status,
                exit_code,
                duration_ms,
                process_id,
            },
            AppUpdate::ThreadStreamingDelta {
                key,
                item_id,
                kind,
                text,
            } => Self::ThreadStreamingDelta {
                key,
                item_id,
                kind: kind.into(),
                text,
            },
            AppUpdate::ThreadRemoved {
                key,
                agent_directory_version,
            } => Self::ThreadRemoved {
                key,
                agent_directory_version,
            },
            AppUpdate::ActiveThreadChanged { key } => Self::ActiveThreadChanged { key },
            AppUpdate::PendingApprovalsChanged { .. } => Self::PendingApprovalsChanged,
            AppUpdate::PendingUserInputsChanged { .. } => Self::PendingUserInputsChanged,
            AppUpdate::VoiceSessionChanged => Self::VoiceSessionChanged,
            AppUpdate::RealtimeTranscriptUpdated { key, update } => {
                Self::RealtimeTranscriptUpdated { key, update }
            }
            AppUpdate::RealtimeHandoffRequested { key, request } => {
                Self::RealtimeHandoffRequested { key, request }
            }
            AppUpdate::RealtimeSpeechStarted { key } => Self::RealtimeSpeechStarted { key },
            AppUpdate::RealtimeStarted { key, notification } => {
                Self::RealtimeStarted { key, notification }
            }
            AppUpdate::RealtimeOutputAudioDelta { key, notification } => {
                Self::RealtimeOutputAudioDelta { key, notification }
            }
            AppUpdate::RealtimeError { key, notification } => {
                Self::RealtimeError { key, notification }
            }
            AppUpdate::RealtimeClosed { key, notification } => {
                Self::RealtimeClosed { key, notification }
            }
        }
    }
}

impl From<ThreadStreamingDeltaKind> for AppThreadStreamingDeltaKind {
    fn from(value: ThreadStreamingDeltaKind) -> Self {
        match value {
            ThreadStreamingDeltaKind::AssistantText => Self::AssistantText,
            ThreadStreamingDeltaKind::ReasoningText => Self::ReasoningText,
            ThreadStreamingDeltaKind::PlanText => Self::PlanText,
            ThreadStreamingDeltaKind::CommandOutput => Self::CommandOutput,
            ThreadStreamingDeltaKind::McpProgress => Self::McpProgress,
        }
    }
}
