use std::collections::HashMap;
use std::time::Instant;

use codex_app_server_protocol as upstream;

use crate::conversation_uniffi::HydratedConversationItem;
use crate::session::connection::{
    AppServerBackendKind, AppServerConnectionPath, AppServerTransportKind,
};
use crate::types::{
    Account, AppModeKind, AppPlanProgressSnapshot, ModelInfo, PendingApproval, PendingApprovalKey,
    PendingApprovalSeed, PendingUserInputRequest, RateLimitSnapshot, RateLimits, ThreadInfo,
    ThreadKey,
};
use crate::types::{AppVoiceSessionPhase, AppVoiceTranscriptEntry};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppConnectionStepKind {
    ConnectingToSsh,
    FindingCodex,
    InstallingCodex,
    StartingAppServer,
    OpeningTunnel,
    Connected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppConnectionStepState {
    Pending,
    InProgress,
    Completed,
    Failed,
    AwaitingUserInput,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppConnectionStepSnapshot {
    pub kind: AppConnectionStepKind,
    pub state: AppConnectionStepState,
    pub detail: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppConnectionProgressSnapshot {
    pub steps: Vec<AppConnectionStepSnapshot>,
    pub pending_install: bool,
    pub terminal_message: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppServerStatusKind {
    Connected,
    Reconnecting,
    AuthRequired,
    Disconnected,
    Unresponsive,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppServerModelCatalogState {
    Unavailable,
    Idle,
    Loading,
    Loaded,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppServerModelCatalogSummary {
    pub state: AppServerModelCatalogState,
    pub available_model_count: u32,
    pub default_model_id: Option<String>,
    pub default_model_display_name: Option<String>,
}

impl AppConnectionProgressSnapshot {
    pub fn ssh_bootstrap() -> Self {
        Self {
            steps: vec![
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::ConnectingToSsh,
                    state: AppConnectionStepState::InProgress,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::FindingCodex,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::InstallingCodex,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::StartingAppServer,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::OpeningTunnel,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
                AppConnectionStepSnapshot {
                    kind: AppConnectionStepKind::Connected,
                    state: AppConnectionStepState::Pending,
                    detail: None,
                },
            ],
            pending_install: false,
            terminal_message: None,
        }
    }

    pub fn update_step(
        &mut self,
        kind: AppConnectionStepKind,
        state: AppConnectionStepState,
        detail: Option<String>,
    ) {
        if let Some(step) = self.steps.iter_mut().find(|step| step.kind == kind) {
            step.state = state;
            step.detail = detail;
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerHealthSnapshot {
    Disconnected,
    Connecting,
    Connected,
    Unresponsive,
    Unknown(String),
}

impl ServerHealthSnapshot {
    pub fn from_wire(health: &str) -> Self {
        match health {
            "disconnected" => Self::Disconnected,
            "connecting" => Self::Connecting,
            "connected" => Self::Connected,
            "unresponsive" => Self::Unresponsive,
            other => Self::Unknown(other.to_string()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerIpcStateSnapshot {
    Unsupported,
    Disconnected,
    Ready,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerTransportAuthority {
    IpcPrimary,
    DirectOnly,
    Recovering,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppLifecyclePhaseSnapshot {
    Active,
    Inactive,
    Background,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerMutatingCommandKind {
    StartTurn,
    SetQueuedFollowUpsState,
    SteerQueuedFollowUp,
    DeleteQueuedFollowUp,
    ApprovalResponse,
    UserInputResponse,
    CollaborationModeSync,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServerMutatingCommandRoute {
    Ipc,
    Direct,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IpcFailureClassification {
    FollowerCommandTimeoutWhileIpcHealthy,
    IpcConnectionLost,
    LifecycleInterrupted,
    ServerTransportUnhealthy,
    UnknownTimeout,
}

#[derive(Debug, Clone)]
pub struct PendingServerMutatingCommand {
    pub kind: ServerMutatingCommandKind,
    pub thread_id: String,
    pub local_request_id: String,
    pub started_at: Instant,
    pub route: ServerMutatingCommandRoute,
    pub lifecycle_phase_at_send: AppLifecyclePhaseSnapshot,
}

#[derive(Debug, Clone)]
pub struct ServerTransportDiagnostics {
    pub authority: ServerTransportAuthority,
    pub actual_ipc_connected: bool,
    pub last_ipc_broadcast_at: Option<Instant>,
    pub last_ipc_mutation_ok_at: Option<Instant>,
    pub last_direct_request_ok_at: Option<Instant>,
    pub last_lifecycle_phase: AppLifecyclePhaseSnapshot,
    pub last_lifecycle_transition_at: Option<Instant>,
    pub last_resumed_at: Option<Instant>,
    pub pending_mutation: Option<PendingServerMutatingCommand>,
    pub last_ipc_failure: Option<IpcFailureClassification>,
}

impl Default for ServerTransportDiagnostics {
    fn default() -> Self {
        Self {
            authority: ServerTransportAuthority::DirectOnly,
            actual_ipc_connected: false,
            last_ipc_broadcast_at: None,
            last_ipc_mutation_ok_at: None,
            last_direct_request_ok_at: None,
            last_lifecycle_phase: AppLifecyclePhaseSnapshot::Active,
            last_lifecycle_transition_at: None,
            last_resumed_at: None,
            pending_mutation: None,
            last_ipc_failure: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ServerSnapshot {
    pub server_id: String,
    pub display_name: String,
    pub host: String,
    pub port: u16,
    pub backend_kind: AppServerBackendKind,
    pub transport_kind: AppServerTransportKind,
    pub connection_path: AppServerConnectionPath,
    pub wake_mac: Option<String>,
    pub is_local: bool,
    pub supports_ipc: bool,
    pub has_ipc: bool,
    pub health: ServerHealthSnapshot,
    pub account: Option<Account>,
    pub requires_openai_auth: bool,
    pub rate_limits: Option<RateLimitSnapshot>,
    pub available_models: Option<Vec<ModelInfo>>,
    pub connection_progress: Option<AppConnectionProgressSnapshot>,
    pub known_directories: Vec<String>,
    pub transport: ServerTransportDiagnostics,
}

impl ServerSnapshot {
    pub fn ipc_state(&self) -> ServerIpcStateSnapshot {
        if self.is_local || !self.supports_ipc {
            ServerIpcStateSnapshot::Unsupported
        } else if self.has_ipc {
            ServerIpcStateSnapshot::Ready
        } else {
            ServerIpcStateSnapshot::Disconnected
        }
    }
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct AppVoiceSessionSnapshot {
    pub active_thread: Option<ThreadKey>,
    pub session_id: Option<String>,
    pub phase: Option<AppVoiceSessionPhase>,
    pub last_error: Option<String>,
    pub transcript_entries: Vec<AppVoiceTranscriptEntry>,
    pub handoff_thread_key: Option<ThreadKey>,
}

#[derive(Debug, Clone)]
pub struct ThreadSnapshot {
    pub key: ThreadKey,
    pub info: ThreadInfo,
    pub collaboration_mode: AppModeKind,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub effective_approval_policy: Option<crate::types::AppAskForApproval>,
    pub effective_sandbox_policy: Option<crate::types::AppSandboxPolicy>,
    pub items: Vec<HydratedConversationItem>,
    pub local_overlay_items: Vec<HydratedConversationItem>,
    pub queued_follow_ups: Vec<AppQueuedFollowUpPreview>,
    pub(crate) queued_follow_up_drafts: Vec<QueuedFollowUpDraft>,
    pub active_turn_id: Option<String>,
    pub context_tokens_used: Option<u64>,
    pub model_context_window: Option<u64>,
    pub rate_limits: Option<RateLimits>,
    pub realtime_session_id: Option<String>,
    pub active_plan_progress: Option<AppPlanProgressSnapshot>,
    pub(crate) pending_plan_implementation_turn_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppQueuedFollowUpPreview {
    pub id: String,
    pub kind: AppQueuedFollowUpKind,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppQueuedFollowUpKind {
    Message,
    PendingSteer,
    RetryingSteer,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct QueuedFollowUpDraft {
    pub preview: AppQueuedFollowUpPreview,
    pub inputs: Vec<upstream::UserInput>,
    pub source_message_json: Option<serde_json::Value>,
}

impl ThreadSnapshot {
    pub fn from_info(server_id: &str, info: ThreadInfo) -> Self {
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: info.id.clone(),
        };
        Self {
            key,
            collaboration_mode: AppModeKind::Default,
            model: info.model.clone(),
            info,
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
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct AppSnapshot {
    pub servers: HashMap<String, ServerSnapshot>,
    pub threads: HashMap<ThreadKey, ThreadSnapshot>,
    pub active_thread: Option<ThreadKey>,
    pub pending_approvals: Vec<PendingApproval>,
    pub(crate) pending_approval_seeds: HashMap<PendingApprovalKey, PendingApprovalSeed>,
    pub pending_user_inputs: Vec<PendingUserInputRequest>,
    pub voice_session: AppVoiceSessionSnapshot,
}
