use std::collections::HashMap;

use crate::conversation::ConversationItem;
use crate::types::{
    PendingApproval, PendingUserInputRequest, RateLimits, ThreadInfo, ThreadKey, generated,
};
use crate::uniffi_shared::{AppVoiceSessionPhase, AppVoiceTranscriptEntry};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ServerConnectionStepKind {
    ConnectingToSsh,
    FindingCodex,
    InstallingCodex,
    StartingAppServer,
    OpeningTunnel,
    Connected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ServerConnectionStepState {
    Pending,
    InProgress,
    Completed,
    Failed,
    AwaitingUserInput,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ServerConnectionStepSnapshot {
    pub kind: ServerConnectionStepKind,
    pub state: ServerConnectionStepState,
    pub detail: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ServerConnectionProgressSnapshot {
    pub steps: Vec<ServerConnectionStepSnapshot>,
    pub pending_install: bool,
    pub terminal_message: Option<String>,
}

impl ServerConnectionProgressSnapshot {
    pub fn ssh_bootstrap() -> Self {
        Self {
            steps: vec![
                ServerConnectionStepSnapshot {
                    kind: ServerConnectionStepKind::ConnectingToSsh,
                    state: ServerConnectionStepState::InProgress,
                    detail: None,
                },
                ServerConnectionStepSnapshot {
                    kind: ServerConnectionStepKind::FindingCodex,
                    state: ServerConnectionStepState::Pending,
                    detail: None,
                },
                ServerConnectionStepSnapshot {
                    kind: ServerConnectionStepKind::InstallingCodex,
                    state: ServerConnectionStepState::Pending,
                    detail: None,
                },
                ServerConnectionStepSnapshot {
                    kind: ServerConnectionStepKind::StartingAppServer,
                    state: ServerConnectionStepState::Pending,
                    detail: None,
                },
                ServerConnectionStepSnapshot {
                    kind: ServerConnectionStepKind::OpeningTunnel,
                    state: ServerConnectionStepState::Pending,
                    detail: None,
                },
                ServerConnectionStepSnapshot {
                    kind: ServerConnectionStepKind::Connected,
                    state: ServerConnectionStepState::Pending,
                    detail: None,
                },
            ],
            pending_install: false,
            terminal_message: None,
        }
    }

    pub fn update_step(
        &mut self,
        kind: ServerConnectionStepKind,
        state: ServerConnectionStepState,
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

#[derive(Debug, Clone)]
pub struct ServerSnapshot {
    pub server_id: String,
    pub display_name: String,
    pub host: String,
    pub port: u16,
    pub is_local: bool,
    pub has_ipc: bool,
    pub health: ServerHealthSnapshot,
    pub account: Option<generated::Account>,
    pub requires_openai_auth: bool,
    pub rate_limits: Option<generated::RateLimitSnapshot>,
    pub available_models: Option<Vec<generated::Model>>,
    pub connection_progress: Option<ServerConnectionProgressSnapshot>,
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct VoiceSessionSnapshot {
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
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub items: Vec<ConversationItem>,
    pub local_overlay_items: Vec<ConversationItem>,
    pub queued_follow_ups: Vec<QueuedFollowUpPreview>,
    pub active_turn_id: Option<String>,
    pub context_tokens_used: Option<u64>,
    pub model_context_window: Option<u64>,
    pub rate_limits: Option<RateLimits>,
    pub realtime_session_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct QueuedFollowUpPreview {
    pub id: String,
    pub text: String,
}

impl ThreadSnapshot {
    pub fn from_info(server_id: &str, info: ThreadInfo) -> Self {
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: info.id.clone(),
        };
        Self {
            key,
            model: info.model.clone(),
            info,
            reasoning_effort: None,
            items: Vec::new(),
            local_overlay_items: Vec::new(),
            queued_follow_ups: Vec::new(),
            active_turn_id: None,
            context_tokens_used: None,
            model_context_window: None,
            rate_limits: None,
            realtime_session_id: None,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct AppSnapshot {
    pub servers: HashMap<String, ServerSnapshot>,
    pub threads: HashMap<ThreadKey, ThreadSnapshot>,
    pub active_thread: Option<ThreadKey>,
    pub pending_approvals: Vec<PendingApproval>,
    pub pending_user_inputs: Vec<PendingUserInputRequest>,
    pub voice_session: VoiceSessionSnapshot,
}
