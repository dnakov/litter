use crate::types::{PendingApproval, PendingUserInputRequest, ThreadKey, generated};
use crate::uniffi_shared::{AppVoiceHandoffRequest, AppVoiceTranscriptUpdate};

#[derive(Debug, Clone)]
pub enum AppUpdate {
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
