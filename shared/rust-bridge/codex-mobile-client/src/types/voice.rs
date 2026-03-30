//! Mobile-owned voice/realtime types.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
pub enum AppVoiceSpeaker {
    User,
    Assistant,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
pub enum AppVoiceSessionPhase {
    Connecting,
    Listening,
    Speaking,
    Thinking,
    Handoff,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Record)]
pub struct AppVoiceTranscriptEntry {
    pub item_id: String,
    pub speaker: AppVoiceSpeaker,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Record)]
pub struct AppVoiceTranscriptUpdate {
    pub item_id: String,
    pub speaker: AppVoiceSpeaker,
    pub text: String,
    pub is_final: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Record)]
pub struct AppVoiceHandoffRequest {
    pub handoff_id: String,
    pub input_transcript: String,
    pub active_transcript: String,
    pub server_hint: Option<String>,
    pub fallback_transcript: Option<String>,
}
