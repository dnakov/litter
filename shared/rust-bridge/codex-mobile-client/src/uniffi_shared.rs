use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
pub enum AppOperationStatus {
    Unknown,
    Pending,
    InProgress,
    Completed,
    Failed,
    Declined,
}

impl AppOperationStatus {
    pub fn from_raw(raw: &str) -> Self {
        let trimmed = raw.trim();
        match trimmed {
            "pending" | "Pending" => Self::Pending,
            "inProgress" | "InProgress" => Self::InProgress,
            "completed" | "Completed" => Self::Completed,
            "failed" | "Failed" => Self::Failed,
            "declined" | "Declined" => Self::Declined,
            _ => {
                let normalized = trimmed.to_ascii_lowercase().replace(['_', ' '], "");
                match normalized.as_str() {
                    "pending" | "queued" => Self::Pending,
                    "inprogress" | "running" | "active" | "progress" => Self::InProgress,
                    "completed" | "complete" | "done" | "success" | "ok" | "succeeded" => {
                        Self::Completed
                    }
                    "failed" | "fail" | "error" | "errored" | "denied" => Self::Failed,
                    "declined" | "rejected" => Self::Declined,
                    _ => Self::Unknown,
                }
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
pub enum AppSubagentStatus {
    Unknown,
    PendingInit,
    Running,
    Interrupted,
    Completed,
    Errored,
    Shutdown,
}

impl AppSubagentStatus {
    pub fn from_raw(raw: &str) -> Self {
        let trimmed = raw.trim();
        match trimmed {
            "pendingInit" | "PendingInit" => Self::PendingInit,
            "running" | "Running" => Self::Running,
            "interrupted" | "Interrupted" => Self::Interrupted,
            "completed" | "Completed" => Self::Completed,
            "errored" | "Errored" => Self::Errored,
            "shutdown" | "Shutdown" => Self::Shutdown,
            "notFound" | "NotFound" => Self::Unknown,
            _ => {
                let normalized = trimmed.to_ascii_lowercase().replace('_', "");
                match normalized.as_str() {
                    "pendinginit" | "pending" => Self::PendingInit,
                    "running" | "inprogress" | "active" | "thinking" => Self::Running,
                    "interrupted" => Self::Interrupted,
                    "completed" | "complete" | "done" | "idle" => Self::Completed,
                    "errored" | "error" | "failed" => Self::Errored,
                    "shutdown" => Self::Shutdown,
                    _ => Self::Unknown,
                }
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
pub enum AppVoiceSpeaker {
    User,
    Assistant,
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

#[cfg(test)]
mod tests {
    use super::{AppOperationStatus, AppSubagentStatus};

    #[test]
    fn operation_status_normalizes_aliases() {
        assert_eq!(AppOperationStatus::from_raw("pending"), AppOperationStatus::Pending);
        assert_eq!(
            AppOperationStatus::from_raw("in_progress"),
            AppOperationStatus::InProgress
        );
        assert_eq!(AppOperationStatus::from_raw("done"), AppOperationStatus::Completed);
        assert_eq!(AppOperationStatus::from_raw("denied"), AppOperationStatus::Failed);
        assert_eq!(
            AppOperationStatus::from_raw("rejected"),
            AppOperationStatus::Declined
        );
    }

    #[test]
    fn subagent_status_normalizes_aliases() {
        assert_eq!(AppSubagentStatus::from_raw("PendingInit"), AppSubagentStatus::PendingInit);
        assert_eq!(AppSubagentStatus::from_raw("in_progress"), AppSubagentStatus::Running);
        assert_eq!(AppSubagentStatus::from_raw("done"), AppSubagentStatus::Completed);
        assert_eq!(AppSubagentStatus::from_raw("failed"), AppSubagentStatus::Errored);
        assert_eq!(AppSubagentStatus::from_raw("notFound"), AppSubagentStatus::Unknown);
    }
}
