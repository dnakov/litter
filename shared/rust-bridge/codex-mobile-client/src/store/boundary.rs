use std::hash::{Hash, Hasher};

use crate::conversation_uniffi::HydratedConversationItem;
use crate::types::{PendingApproval, PendingUserInputRequest, ThreadInfo, ThreadKey};
use crate::uniffi_shared::{
    AppSubagentStatus, AppVoiceHandoffRequest, AppVoiceSessionPhase, AppVoiceTranscriptEntry,
    AppVoiceTranscriptUpdate,
};

use super::snapshot::{
    AppSnapshot, ServerConnectionProgressSnapshot, ServerConnectionStepKind,
    ServerConnectionStepSnapshot, ServerConnectionStepState, ServerHealthSnapshot,
};
use super::updates::AppUpdate;

#[derive(Debug, Clone, uniffi::Enum)]
pub enum AppServerConnectionStepKind {
    ConnectingToSsh,
    FindingCodex,
    InstallingCodex,
    StartingAppServer,
    OpeningTunnel,
    Connected,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum AppServerConnectionStepState {
    Pending,
    InProgress,
    Completed,
    Failed,
    AwaitingUserInput,
    Cancelled,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppServerConnectionStep {
    pub kind: AppServerConnectionStepKind,
    pub state: AppServerConnectionStepState,
    pub detail: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppServerConnectionProgress {
    pub steps: Vec<AppServerConnectionStep>,
    pub pending_install: bool,
    pub terminal_message: Option<String>,
}

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
    pub connection_progress: Option<AppServerConnectionProgress>,
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
    pub active_turn_id: Option<String>,
    pub context_tokens_used: Option<u64>,
    pub model_context_window: Option<u64>,
    pub rate_limits_json: Option<String>,
    pub realtime_session_id: Option<String>,
}

impl TryFrom<super::snapshot::ThreadSnapshot> for AppThreadSnapshot {
    type Error = String;

    fn try_from(thread: super::snapshot::ThreadSnapshot) -> Result<Self, Self::Error> {
        let hydrated_conversation_items =
            merged_hydrated_items(thread.items, thread.local_overlay_items);
        Ok(Self {
            key: thread.key,
            info: thread.info,
            model: thread.model,
            reasoning_effort: thread.reasoning_effort,
            hydrated_conversation_items,
            active_turn_id: thread.active_turn_id,
            context_tokens_used: thread.context_tokens_used,
            model_context_window: thread.model_context_window,
            rate_limits_json: thread
                .rate_limits
                .map(|limits| serde_json::to_string(&limits))
                .transpose()
                .map_err(|error| format!("serialize rate limits: {error}"))?,
            realtime_session_id: thread.realtime_session_id,
        })
    }
}

fn merged_hydrated_items(
    items: Vec<crate::conversation::ConversationItem>,
    local_overlay_items: Vec<crate::conversation::ConversationItem>,
) -> Vec<HydratedConversationItem> {
    let mut merged = items;
    for overlay in local_overlay_items {
        if merged
            .iter()
            .all(|existing| !same_overlay_semantics(&overlay, existing))
        {
            merged.push(overlay);
        }
    }
    merged.into_iter().map(Into::into).collect()
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
pub struct AppVoiceSessionSnapshot {
    pub active_thread: Option<ThreadKey>,
    pub session_id: Option<String>,
    pub phase: Option<AppVoiceSessionPhase>,
    pub last_error: Option<String>,
    pub transcript_entries: Vec<AppVoiceTranscriptEntry>,
    pub handoff_thread_key: Option<ThreadKey>,
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
    pub voice_session: AppVoiceSessionSnapshot,
}

impl TryFrom<AppSnapshot> for AppSnapshotRecord {
    type Error = String;

    fn try_from(snapshot: AppSnapshot) -> Result<Self, Self::Error> {
        let mut session_summaries = snapshot
            .threads
            .values()
            .map(|thread| {
                let server = snapshot.servers.get(&thread.key.server_id);
                let preview = thread.info.preview.clone().unwrap_or_default();
                let title = {
                    let explicit_title = thread.info.title.clone().unwrap_or_default();
                    let trimmed_title = explicit_title.trim();
                    if !trimmed_title.is_empty() {
                        trimmed_title.to_string()
                    } else {
                        let trimmed_preview = preview.trim();
                        if !trimmed_preview.is_empty() {
                            trimmed_preview.to_string()
                        } else {
                            "Untitled session".to_string()
                        }
                    }
                };
                let parent_thread_id = thread.info.parent_thread_id.clone().and_then(|value| {
                    let trimmed = value.trim().to_string();
                    (!trimmed.is_empty()).then_some(trimmed)
                });
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
                    preview,
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
            })
            .collect::<Vec<_>>();
        session_summaries.sort_by(|lhs, rhs| {
            rhs.updated_at
                .cmp(&lhs.updated_at)
                .then_with(|| lhs.key.server_id.cmp(&rhs.key.server_id))
                .then_with(|| lhs.key.thread_id.cmp(&rhs.key.thread_id))
        });
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
                connection_progress: server.connection_progress.map(Into::into),
            })
            .collect::<Vec<_>>();
        servers.sort_by(|lhs, rhs| lhs.server_id.cmp(&rhs.server_id));

        let mut threads = snapshot
            .threads
            .into_values()
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
            voice_session: AppVoiceSessionSnapshot {
                active_thread: snapshot.voice_session.active_thread,
                session_id: snapshot.voice_session.session_id,
                phase: snapshot.voice_session.phase,
                last_error: snapshot.voice_session.last_error,
                transcript_entries: snapshot.voice_session.transcript_entries,
                handoff_thread_key: snapshot.voice_session.handoff_thread_key,
            },
        })
    }
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

impl From<ServerConnectionStepKind> for AppServerConnectionStepKind {
    fn from(value: ServerConnectionStepKind) -> Self {
        match value {
            ServerConnectionStepKind::ConnectingToSsh => Self::ConnectingToSsh,
            ServerConnectionStepKind::FindingCodex => Self::FindingCodex,
            ServerConnectionStepKind::InstallingCodex => Self::InstallingCodex,
            ServerConnectionStepKind::StartingAppServer => Self::StartingAppServer,
            ServerConnectionStepKind::OpeningTunnel => Self::OpeningTunnel,
            ServerConnectionStepKind::Connected => Self::Connected,
        }
    }
}

impl From<ServerConnectionStepState> for AppServerConnectionStepState {
    fn from(value: ServerConnectionStepState) -> Self {
        match value {
            ServerConnectionStepState::Pending => Self::Pending,
            ServerConnectionStepState::InProgress => Self::InProgress,
            ServerConnectionStepState::Completed => Self::Completed,
            ServerConnectionStepState::Failed => Self::Failed,
            ServerConnectionStepState::AwaitingUserInput => Self::AwaitingUserInput,
            ServerConnectionStepState::Cancelled => Self::Cancelled,
        }
    }
}

impl From<ServerConnectionStepSnapshot> for AppServerConnectionStep {
    fn from(value: ServerConnectionStepSnapshot) -> Self {
        Self {
            kind: value.kind.into(),
            state: value.state.into(),
            detail: value.detail,
        }
    }
}

impl From<ServerConnectionProgressSnapshot> for AppServerConnectionProgress {
    fn from(value: ServerConnectionProgressSnapshot) -> Self {
        Self {
            steps: value.steps.into_iter().map(Into::into).collect(),
            pending_install: value.pending_install,
            terminal_message: value.terminal_message,
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

#[derive(Debug, Clone, uniffi::Enum)]
pub enum AppStoreUpdateRecord {
    FullResync,
    ServerChanged {
        server_id: String,
    },
    ServerRemoved {
        server_id: String,
    },
    ThreadChanged {
        key: ThreadKey,
    },
    ThreadRemoved {
        key: ThreadKey,
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
            AppUpdate::ThreadChanged { key } => Self::ThreadChanged { key },
            AppUpdate::ThreadRemoved { key } => Self::ThreadRemoved { key },
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
