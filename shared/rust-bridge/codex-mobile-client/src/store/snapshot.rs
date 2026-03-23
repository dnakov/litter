use std::collections::HashMap;

use crate::conversation::ConversationItem;
use crate::types::{
    PendingApproval, PendingUserInputRequest, RateLimits, ThreadInfo, ThreadKey, generated,
};

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
    pub health: ServerHealthSnapshot,
    pub account: Option<generated::Account>,
    pub requires_openai_auth: bool,
    pub rate_limits: Option<generated::RateLimitSnapshot>,
    pub available_models: Option<Vec<generated::Model>>,
}

#[derive(Debug, Clone, Default)]
pub struct VoiceSessionSnapshot {
    pub active_thread: Option<ThreadKey>,
    pub session_id: Option<String>,
    pub phase: Option<String>,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ThreadSnapshot {
    pub key: ThreadKey,
    pub info: ThreadInfo,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub items: Vec<ConversationItem>,
    pub active_turn_id: Option<String>,
    pub context_tokens_used: Option<u64>,
    pub model_context_window: Option<u64>,
    pub rate_limits: Option<RateLimits>,
    pub realtime_session_id: Option<String>,
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
