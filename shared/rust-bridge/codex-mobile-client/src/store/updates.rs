use crate::conversation_uniffi::HydratedConversationItem;
use crate::types::{PendingApproval, PendingUserInputRequest, ThreadKey, generated};
use crate::uniffi_shared::{AppOperationStatus, AppVoiceHandoffRequest, AppVoiceTranscriptUpdate};

use super::boundary::{AppSessionSummary, AppThreadSnapshot, AppThreadStateRecord};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ThreadStreamingDeltaKind {
    AssistantText,
    ReasoningText,
    PlanText,
    CommandOutput,
    McpProgress,
}

#[derive(Debug, Clone)]
pub enum AppUpdate {
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
        notification: generated::ThreadRealtimeStartedNotification,
    },
    RealtimeOutputAudioDelta {
        key: ThreadKey,
        notification: generated::ThreadRealtimeOutputAudioDeltaNotification,
    },
    RealtimeError {
        key: ThreadKey,
        notification: generated::ThreadRealtimeErrorNotification,
    },
    RealtimeClosed {
        key: ThreadKey,
        notification: generated::ThreadRealtimeClosedNotification,
    },
}
