use std::hash::{Hash, Hasher};

use crate::conversation_uniffi::HydratedConversationItem;
use crate::session::connection::{
    AppServerBackendKind, AppServerConnectionPath, AppServerTransportKind,
};
use crate::types::AppSubagentStatus;
use crate::types::{
    AppModeKind, AppPlanImplementationPromptSnapshot, AppPlanProgressSnapshot, PendingApproval,
    PendingUserInputRequest, ThreadInfo, ThreadKey,
};

use super::snapshot::{
    AppConnectionProgressSnapshot, AppQueuedFollowUpPreview, AppServerModelCatalogState,
    AppServerModelCatalogSummary, AppServerStatusKind, AppSnapshot, AppVoiceSessionSnapshot,
    ServerHealthSnapshot, ServerIpcStateSnapshot, ServerSnapshot, ThreadSnapshot,
};

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppServerSnapshot {
    pub server_id: String,
    pub display_name: String,
    pub host: String,
    pub port: u16,
    pub backend_kind: AppServerBackendKind,
    pub transport_kind: AppServerTransportKind,
    pub connection_path: AppServerConnectionPath,
    pub status_kind: AppServerStatusKind,
    pub wake_mac: Option<String>,
    pub is_local: bool,
    pub supports_ipc: bool,
    pub has_ipc: bool,
    pub health: AppServerHealth,
    pub transport_state: AppServerTransportState,
    pub ipc_state: AppServerIpcState,
    pub capabilities: AppServerCapabilities,
    pub account: Option<crate::types::Account>,
    pub requires_openai_auth: bool,
    pub rate_limits: Option<crate::types::RateLimitSnapshot>,
    pub known_directories: Vec<String>,
    pub last_used_directory_hint: Option<String>,
    pub model_catalog: AppServerModelCatalogSummary,
    pub available_models: Option<Vec<crate::types::ModelInfo>>,
    pub connection_progress: Option<AppConnectionProgressSnapshot>,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum AppServerHealth {
    Disconnected,
    Connecting,
    Connected,
    Unresponsive,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppServerTransportState {
    Disconnected,
    Connecting,
    Connected,
    Unresponsive,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppServerIpcState {
    Unsupported,
    Disconnected,
    Ready,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppServerCapabilities {
    pub can_use_transport_actions: bool,
    pub can_browse_directories: bool,
    pub can_start_threads: bool,
    pub can_resume_threads: bool,
    pub can_use_ipc: bool,
    pub can_resume_via_ipc: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppThreadSnapshot {
    pub key: ThreadKey,
    pub info: ThreadInfo,
    pub collaboration_mode: AppModeKind,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub effective_approval_policy: Option<crate::types::AppAskForApproval>,
    pub effective_sandbox_policy: Option<crate::types::AppSandboxPolicy>,
    pub hydrated_conversation_items: Vec<HydratedConversationItem>,
    pub queued_follow_ups: Vec<AppQueuedFollowUpPreview>,
    pub active_turn_id: Option<String>,
    pub active_plan_progress: Option<AppPlanProgressSnapshot>,
    pub pending_plan_implementation_prompt: Option<AppPlanImplementationPromptSnapshot>,
    pub context_tokens_used: Option<u64>,
    pub model_context_window: Option<u64>,
    pub rate_limits: Option<crate::types::RateLimits>,
    pub realtime_session_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AppThreadStateRecord {
    pub key: ThreadKey,
    pub info: ThreadInfo,
    pub collaboration_mode: AppModeKind,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub effective_approval_policy: Option<crate::types::AppAskForApproval>,
    pub effective_sandbox_policy: Option<crate::types::AppSandboxPolicy>,
    pub queued_follow_ups: Vec<AppQueuedFollowUpPreview>,
    pub active_turn_id: Option<String>,
    pub active_plan_progress: Option<AppPlanProgressSnapshot>,
    pub pending_plan_implementation_prompt: Option<AppPlanImplementationPromptSnapshot>,
    pub context_tokens_used: Option<u64>,
    pub model_context_window: Option<u64>,
    pub rate_limits: Option<crate::types::RateLimits>,
    pub realtime_session_id: Option<String>,
}

fn merged_hydrated_items(
    items: &[crate::conversation_uniffi::HydratedConversationItem],
    local_overlay_items: &[crate::conversation_uniffi::HydratedConversationItem],
) -> Vec<HydratedConversationItem> {
    let mut merged = Vec::with_capacity(items.len() + local_overlay_items.len());
    merged.extend(items.iter().cloned().map(Into::into));

    let mut selected_overlays: Vec<&crate::conversation_uniffi::HydratedConversationItem> =
        Vec::new();
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
    lhs: &crate::conversation_uniffi::HydratedConversationItem,
    rhs: &crate::conversation_uniffi::HydratedConversationItem,
) -> bool {
    if lhs.id == rhs.id {
        return true;
    }

    match (&lhs.content, &rhs.content) {
        (
            crate::conversation_uniffi::HydratedConversationItemContent::UserInputResponse(
                lhs_data,
            ),
            crate::conversation_uniffi::HydratedConversationItemContent::UserInputResponse(
                rhs_data,
            ),
        ) => lhs.source_turn_id == rhs.source_turn_id && lhs_data == rhs_data,
        (
            crate::conversation_uniffi::HydratedConversationItemContent::User(lhs_data),
            crate::conversation_uniffi::HydratedConversationItemContent::User(rhs_data),
        ) => {
            lhs.id.starts_with("local-user-message:")
                && lhs_data == rhs_data
                && (
                    // Both bound to the same turn.
                    (lhs.source_turn_id.is_some() && lhs.source_turn_id == rhs.source_turn_id)
                    // Real item arrived via ItemStarted/ItemCompleted without a
                    // turn_id; the overlay is bound so content match is enough.
                    || (lhs.source_turn_id.is_some() && rhs.source_turn_id.is_none())
                )
        }
        _ => false,
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
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
    pub voice_session: AppVoiceSessionSnapshot,
}

impl TryFrom<AppSnapshot> for AppSnapshotRecord {
    type Error = String;

    fn try_from(snapshot: AppSnapshot) -> Result<Self, Self::Error> {
        let session_summaries = session_summaries_from_snapshot(&snapshot);
        let agent_directory_version = agent_directory_version(&session_summaries);

        let mut servers = snapshot
            .servers
            .values()
            .cloned()
            .map(|server| {
                let transport_state = AppServerTransportState::from(server.health.clone());
                let ipc_state = AppServerIpcState::from(server.ipc_state());
                let can_use_transport_actions =
                    transport_state == AppServerTransportState::Connected;
                let can_use_ipc =
                    can_use_transport_actions && ipc_state == AppServerIpcState::Ready;

                let last_used_directory_hint =
                    last_used_directory_hint_for_server(&snapshot, server.server_id.as_str());
                let model_catalog = model_catalog_summary(&server);
                let status_kind = status_kind_for_server(&server);

                AppServerSnapshot {
                    server_id: server.server_id,
                    display_name: server.display_name,
                    host: server.host,
                    port: server.port,
                    backend_kind: server.backend_kind,
                    transport_kind: server.transport_kind,
                    connection_path: server.connection_path,
                    status_kind,
                    wake_mac: server.wake_mac,
                    is_local: server.is_local,
                    supports_ipc: server.supports_ipc,
                    has_ipc: server.has_ipc,
                    health: server.health.into(),
                    transport_state,
                    ipc_state,
                    capabilities: AppServerCapabilities {
                        can_use_transport_actions,
                        can_browse_directories: can_use_transport_actions
                            && server.backend_kind == AppServerBackendKind::Codex,
                        can_start_threads: can_use_transport_actions,
                        can_resume_threads: can_use_transport_actions,
                        can_use_ipc,
                        can_resume_via_ipc: can_use_ipc,
                    },
                    account: server.account,
                    requires_openai_auth: server.requires_openai_auth,
                    rate_limits: server.rate_limits,
                    known_directories: server.known_directories,
                    last_used_directory_hint,
                    model_catalog,
                    available_models: server.available_models,
                    connection_progress: server.connection_progress,
                }
            })
            .collect::<Vec<_>>();
        servers.sort_by(|lhs, rhs| lhs.server_id.cmp(&rhs.server_id));

        let mut threads = snapshot
            .threads
            .values()
            .map(|thread| app_thread_snapshot_from_state(&snapshot, thread))
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

fn status_kind_for_server(server: &ServerSnapshot) -> AppServerStatusKind {
    if server.connection_progress.is_some() {
        return AppServerStatusKind::Reconnecting;
    }

    match server.health {
        ServerHealthSnapshot::Connected => {
            if server.backend_kind == AppServerBackendKind::Codex
                && !server.is_local
                && server.account.is_none()
            {
                AppServerStatusKind::AuthRequired
            } else {
                AppServerStatusKind::Connected
            }
        }
        ServerHealthSnapshot::Connecting => AppServerStatusKind::Reconnecting,
        ServerHealthSnapshot::Disconnected => AppServerStatusKind::Disconnected,
        ServerHealthSnapshot::Unresponsive => AppServerStatusKind::Unresponsive,
        ServerHealthSnapshot::Unknown(_) => AppServerStatusKind::Unknown,
    }
}

fn model_catalog_summary(server: &ServerSnapshot) -> AppServerModelCatalogSummary {
    let default_model = server
        .available_models
        .as_ref()
        .and_then(|models| models.iter().find(|model| model.is_default));
    let state = if server.health != ServerHealthSnapshot::Connected {
        AppServerModelCatalogState::Unavailable
    } else if server.available_models.is_some() {
        AppServerModelCatalogState::Loaded
    } else if server.connection_progress.is_some() {
        AppServerModelCatalogState::Loading
    } else {
        AppServerModelCatalogState::Idle
    };

    AppServerModelCatalogSummary {
        state,
        available_model_count: server
            .available_models
            .as_ref()
            .map(|models| models.len() as u32)
            .unwrap_or(0),
        default_model_id: default_model.map(|model| model.id.clone()),
        default_model_display_name: default_model.map(|model| model.display_name.clone()),
    }
}

fn last_used_directory_hint_for_server(snapshot: &AppSnapshot, server_id: &str) -> Option<String> {
    snapshot
        .threads
        .values()
        .filter(|thread| thread.key.server_id == server_id)
        .filter_map(|thread| {
            let updated_at = thread.info.updated_at.unwrap_or(0);
            let cwd = thread
                .info
                .cwd
                .as_ref()
                .map(|cwd| cwd.trim().to_string())
                .filter(|cwd| !cwd.is_empty())?;
            Some((updated_at, cwd))
        })
        .max_by_key(|(updated_at, _)| *updated_at)
        .map(|(_, cwd)| cwd)
}

fn app_thread_snapshot_from_state(
    snapshot: &AppSnapshot,
    thread: &ThreadSnapshot,
) -> Result<AppThreadSnapshot, String> {
    let hydrated_conversation_items =
        merged_hydrated_items(&thread.items, &thread.local_overlay_items);
    Ok(AppThreadSnapshot {
        key: thread.key.clone(),
        info: thread.info.clone(),
        collaboration_mode: thread.collaboration_mode,
        model: thread.model.clone(),
        reasoning_effort: thread.reasoning_effort.clone(),
        effective_approval_policy: thread.effective_approval_policy.clone(),
        effective_sandbox_policy: thread.effective_sandbox_policy.clone(),
        hydrated_conversation_items,
        queued_follow_ups: thread
            .queued_follow_ups
            .iter()
            .map(|preview| AppQueuedFollowUpPreview {
                id: preview.id.clone(),
                kind: preview.kind,
                text: preview.text.clone(),
            })
            .collect(),
        active_turn_id: thread.active_turn_id.clone(),
        active_plan_progress: thread.active_plan_progress.clone(),
        pending_plan_implementation_prompt: plan_implementation_prompt_for_thread(snapshot, thread),
        context_tokens_used: thread.context_tokens_used,
        model_context_window: thread.model_context_window,
        rate_limits: thread.rate_limits.clone(),
        realtime_session_id: thread.realtime_session_id.clone(),
    })
}

fn app_thread_state_record_from_state(
    snapshot: &AppSnapshot,
    thread: &ThreadSnapshot,
) -> Result<AppThreadStateRecord, String> {
    Ok(AppThreadStateRecord {
        key: thread.key.clone(),
        info: thread.info.clone(),
        collaboration_mode: thread.collaboration_mode,
        model: thread.model.clone(),
        reasoning_effort: thread.reasoning_effort.clone(),
        effective_approval_policy: thread.effective_approval_policy.clone(),
        effective_sandbox_policy: thread.effective_sandbox_policy.clone(),
        queued_follow_ups: thread
            .queued_follow_ups
            .iter()
            .map(|preview| AppQueuedFollowUpPreview {
                id: preview.id.clone(),
                kind: preview.kind,
                text: preview.text.clone(),
            })
            .collect(),
        active_turn_id: thread.active_turn_id.clone(),
        active_plan_progress: thread.active_plan_progress.clone(),
        pending_plan_implementation_prompt: plan_implementation_prompt_for_thread(snapshot, thread),
        context_tokens_used: thread.context_tokens_used,
        model_context_window: thread.model_context_window,
        rate_limits: thread.rate_limits.clone(),
        realtime_session_id: thread.realtime_session_id.clone(),
    })
}

fn plan_implementation_prompt_for_thread(
    snapshot: &AppSnapshot,
    thread: &ThreadSnapshot,
) -> Option<AppPlanImplementationPromptSnapshot> {
    let source_turn_id = thread.pending_plan_implementation_turn_id.clone()?;
    if thread.active_turn_id.is_some()
        || !thread.queued_follow_ups.is_empty()
        || snapshot.pending_approvals.iter().any(|approval| {
            approval.server_id == thread.key.server_id
                && approval.thread_id.as_deref() == Some(thread.key.thread_id.as_str())
        })
        || snapshot.pending_user_inputs.iter().any(|request| {
            request.server_id == thread.key.server_id && request.thread_id == thread.key.thread_id
        })
    {
        return None;
    }
    Some(AppPlanImplementationPromptSnapshot { source_turn_id })
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

pub(crate) fn project_thread_snapshot(
    snapshot: &AppSnapshot,
    key: &ThreadKey,
) -> Result<Option<AppThreadSnapshot>, String> {
    let Some(thread) = snapshot.threads.get(key) else {
        return Ok(None);
    };
    app_thread_snapshot_from_state(snapshot, thread).map(Some)
}

pub(crate) fn project_thread_update(
    snapshot: &AppSnapshot,
    key: &ThreadKey,
) -> Result<Option<(AppThreadSnapshot, AppSessionSummary, u64)>, String> {
    let Some(thread) = snapshot.threads.get(key) else {
        return Ok(None);
    };
    let thread_snapshot = app_thread_snapshot_from_state(snapshot, thread)?;
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
    let thread_state = app_thread_state_record_from_state(snapshot, thread)?;
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

impl From<ServerHealthSnapshot> for AppServerTransportState {
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

impl From<ServerIpcStateSnapshot> for AppServerIpcState {
    fn from(value: ServerIpcStateSnapshot) -> Self {
        match value {
            ServerIpcStateSnapshot::Unsupported => Self::Unsupported,
            ServerIpcStateSnapshot::Disconnected => Self::Disconnected,
            ServerIpcStateSnapshot::Ready => Self::Ready,
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
        agent_directory_version, app_session_summary, app_thread_snapshot_from_state,
        current_agent_directory_version, session_summaries_from_snapshot,
    };
    use crate::store::{AppSnapshot, ThreadSnapshot};
    use crate::types::{
        AppModeKind, AppPlanImplementationPromptSnapshot, PendingUserInputRequest, ThreadInfo,
        ThreadKey, ThreadSummaryStatus,
    };

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
                collaboration_mode: AppModeKind::Default,
                model: None,
                reasoning_effort: None,
                effective_approval_policy: None,
                effective_sandbox_policy: None,
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
            },
        );

        let expected = agent_directory_version(&session_summaries_from_snapshot(&snapshot));
        assert_eq!(current_agent_directory_version(&snapshot), expected);
    }

    #[test]
    fn app_session_summary_keeps_title_distinct_from_preview() {
        let summary = app_session_summary(
            &ThreadSnapshot::from_info(
                "srv",
                ThreadInfo {
                    id: "thread-a".to_string(),
                    title: None,
                    model: None,
                    preview: Some("First user message".to_string()),
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
            ),
            None,
        );

        assert_eq!(summary.title, "First user message");
        assert_eq!(summary.preview, "First user message");
    }

    #[test]
    fn plan_prompt_projection_hides_when_blocked_and_reappears() {
        let mut snapshot = AppSnapshot::default();
        let thread = ThreadSnapshot {
            pending_plan_implementation_turn_id: Some("turn-1".to_string()),
            ..ThreadSnapshot::from_info(
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
            )
        };
        let key = thread.key.clone();
        snapshot.threads.insert(key.clone(), thread);

        let visible =
            app_thread_snapshot_from_state(&snapshot, snapshot.threads.get(&key).unwrap())
                .unwrap()
                .pending_plan_implementation_prompt;
        assert_eq!(
            visible,
            Some(AppPlanImplementationPromptSnapshot {
                source_turn_id: "turn-1".to_string()
            })
        );

        snapshot.pending_user_inputs.push(PendingUserInputRequest {
            id: "req-1".to_string(),
            server_id: "srv".to_string(),
            thread_id: "thread-a".to_string(),
            turn_id: "turn-2".to_string(),
            item_id: "item-2".to_string(),
            questions: Vec::new(),
            requester_agent_nickname: None,
            requester_agent_role: None,
        });
        let hidden = app_thread_snapshot_from_state(&snapshot, snapshot.threads.get(&key).unwrap())
            .unwrap()
            .pending_plan_implementation_prompt;
        assert_eq!(hidden, None);
    }

    #[test]
    fn app_thread_snapshot_hides_duplicate_local_user_overlay_once_turn_bound() {
        let mut snapshot = AppSnapshot::default();
        let mut thread = ThreadSnapshot::from_info(
            "srv",
            ThreadInfo {
                id: "thread-a".to_string(),
                title: Some("Thread".to_string()),
                model: None,
                preview: Some("hello".to_string()),
                cwd: None,
                path: None,
                model_provider: None,
                agent_nickname: None,
                agent_role: None,
                parent_thread_id: None,
                agent_status: None,
                created_at: None,
                status: ThreadSummaryStatus::Active,
                updated_at: Some(20),
            },
        );
        thread
            .items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "server-user-item".to_string(),
                content: crate::conversation_uniffi::HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "hello".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            });
        thread
            .local_overlay_items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "local-user-message:1".to_string(),
                content: crate::conversation_uniffi::HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "hello".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            });
        let key = thread.key.clone();
        snapshot.threads.insert(key.clone(), thread);

        let projected =
            app_thread_snapshot_from_state(&snapshot, snapshot.threads.get(&key).unwrap()).unwrap();

        assert_eq!(projected.hydrated_conversation_items.len(), 1);
        assert_eq!(
            projected.hydrated_conversation_items[0].id,
            "server-user-item"
        );
    }

    #[test]
    fn merged_hydrated_items_filters_overlay_when_real_item_has_no_turn_id() {
        let mut snapshot = AppSnapshot::default();
        let mut thread = ThreadSnapshot::from_info(
            "srv",
            ThreadInfo {
                id: "thread".to_string(),
                title: None,
                model: None,
                preview: None,
                cwd: None,
                path: None,
                model_provider: None,
                agent_nickname: None,
                agent_role: None,
                parent_thread_id: None,
                agent_status: None,
                created_at: None,
                status: ThreadSummaryStatus::Idle,
                updated_at: None,
            },
        );
        // Real item from ItemStarted (no source_turn_id).
        thread
            .items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "server-user-item".to_string(),
                content: crate::conversation_uniffi::HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "hello".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: None,
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            });
        // Bound overlay for the same message.
        thread
            .local_overlay_items
            .push(crate::conversation_uniffi::HydratedConversationItem {
                id: "local-user-message:1".to_string(),
                content: crate::conversation_uniffi::HydratedConversationItemContent::User(
                    crate::conversation_uniffi::HydratedUserMessageData {
                        text: "hello".to_string(),
                        image_data_uris: Vec::new(),
                    },
                ),
                source_turn_id: Some("turn-1".to_string()),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: true,
            });
        let key = thread.key.clone();
        snapshot.threads.insert(key.clone(), thread);

        let projected =
            app_thread_snapshot_from_state(&snapshot, snapshot.threads.get(&key).unwrap()).unwrap();

        assert_eq!(projected.hydrated_conversation_items.len(), 1);
        assert_eq!(
            projected.hydrated_conversation_items[0].id,
            "server-user-item"
        );
    }
}
