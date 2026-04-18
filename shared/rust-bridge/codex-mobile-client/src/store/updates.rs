use crate::conversation_uniffi::HydratedConversationItem;
use crate::types::{AppVoiceHandoffRequest, AppVoiceTranscriptUpdate};
use crate::types::{PendingApproval, PendingUserInputRequest, ThreadKey};

use super::boundary::{AppSessionSummary, AppThreadSnapshot, AppThreadStateRecord};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ThreadStreamingDeltaKind {
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
    ThreadMetadataChanged {
        state: AppThreadStateRecord,
        session_summary: AppSessionSummary,
        agent_directory_version: u64,
    },
    ThreadItemChanged {
        key: ThreadKey,
        item: HydratedConversationItem,
        /// Per-item derivation (`last_response_preview`, `last_tool_label`,
        /// `stats`, etc.) computed at the point of the mutation. Lets
        /// platform listeners patch their local `AppSessionSummary` without
        /// another FFI roundtrip or a full snapshot rebuild, so the home
        /// dashboard's zoom-2 meta line stays in sync with streaming items.
        session_summary: AppSessionSummary,
    },
    ThreadStreamingDelta {
        key: ThreadKey,
        item_id: String,
        kind: ThreadStreamingDeltaKind,
        text: String,
    },
    ThreadRemoved {
        key: ThreadKey,
        agent_directory_version: u64,
    },
    ActiveThreadChanged {
        key: Option<ThreadKey>,
    },
    PendingApprovalsChanged {
        approvals: Vec<PendingApproval>,
    },
    PendingUserInputsChanged {
        requests: Vec<PendingUserInputRequest>,
    },
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
        notification: crate::types::AppRealtimeStartedNotification,
    },
    RealtimeOutputAudioDelta {
        key: ThreadKey,
        notification: crate::types::AppRealtimeOutputAudioDeltaNotification,
    },
    RealtimeError {
        key: ThreadKey,
        notification: crate::types::AppRealtimeErrorNotification,
    },
    RealtimeClosed {
        key: ThreadKey,
        notification: crate::types::AppRealtimeClosedNotification,
    },
}
