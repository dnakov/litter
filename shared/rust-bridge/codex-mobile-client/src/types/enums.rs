//! Mobile-owned enums that do not come directly from upstream protocol types.

use codex_app_server_protocol as upstream;
use serde::{Deserialize, Serialize};

/// Summary status of a thread for mobile thread lists and local state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum ThreadSummaryStatus {
    NotLoaded,
    Idle,
    Active,
    SystemError,
}

impl From<upstream::ThreadStatus> for ThreadSummaryStatus {
    fn from(value: upstream::ThreadStatus) -> Self {
        match value {
            upstream::ThreadStatus::NotLoaded => ThreadSummaryStatus::NotLoaded,
            upstream::ThreadStatus::Idle => ThreadSummaryStatus::Idle,
            upstream::ThreadStatus::Active { .. } => ThreadSummaryStatus::Active,
            upstream::ThreadStatus::SystemError => ThreadSummaryStatus::SystemError,
        }
    }
}

/// Kind of approval being requested from the user.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum ApprovalKind {
    Command,
    FileChange,
    Permissions,
    McpElicitation,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Enum)]
pub enum ApprovalDecisionValue {
    Accept,
    AcceptForSession,
    Decline,
    Cancel,
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thread_status_roundtrip() {
        for status in [
            ThreadSummaryStatus::NotLoaded,
            ThreadSummaryStatus::Idle,
            ThreadSummaryStatus::Active,
            ThreadSummaryStatus::SystemError,
        ] {
            let json = serde_json::to_string(&status).unwrap();
            let deserialized: ThreadSummaryStatus = serde_json::from_str(&json).unwrap();
            assert_eq!(status, deserialized);
        }
    }

    #[test]
    fn approval_kind_roundtrip() {
        for kind in [
            ApprovalKind::Command,
            ApprovalKind::FileChange,
            ApprovalKind::Permissions,
            ApprovalKind::McpElicitation,
        ] {
            let json = serde_json::to_string(&kind).unwrap();
            let deserialized: ApprovalKind = serde_json::from_str(&json).unwrap();
            assert_eq!(kind, deserialized);
        }
    }

    #[test]
    fn thread_status_serializes_camel_case() {
        assert_eq!(
            serde_json::to_value(&ThreadSummaryStatus::NotLoaded).unwrap(),
            serde_json::json!("notLoaded")
        );
        assert_eq!(
            serde_json::to_value(&ThreadSummaryStatus::SystemError).unwrap(),
            serde_json::json!("systemError")
        );
    }

    #[test]
    fn thread_status_from_upstream() {
        let mobile: ThreadSummaryStatus = upstream::ThreadStatus::Idle.into();
        assert_eq!(mobile, ThreadSummaryStatus::Idle);

        let mobile: ThreadSummaryStatus = upstream::ThreadStatus::Active {
            active_flags: vec![],
        }
        .into();
        assert_eq!(mobile, ThreadSummaryStatus::Active);
    }

    #[test]
    fn operation_status_normalizes_aliases() {
        assert_eq!(
            AppOperationStatus::from_raw("pending"),
            AppOperationStatus::Pending
        );
        assert_eq!(
            AppOperationStatus::from_raw("in_progress"),
            AppOperationStatus::InProgress
        );
        assert_eq!(
            AppOperationStatus::from_raw("done"),
            AppOperationStatus::Completed
        );
        assert_eq!(
            AppOperationStatus::from_raw("denied"),
            AppOperationStatus::Failed
        );
        assert_eq!(
            AppOperationStatus::from_raw("rejected"),
            AppOperationStatus::Declined
        );
    }

    #[test]
    fn subagent_status_normalizes_aliases() {
        assert_eq!(
            AppSubagentStatus::from_raw("PendingInit"),
            AppSubagentStatus::PendingInit
        );
        assert_eq!(
            AppSubagentStatus::from_raw("in_progress"),
            AppSubagentStatus::Running
        );
        assert_eq!(
            AppSubagentStatus::from_raw("done"),
            AppSubagentStatus::Completed
        );
        assert_eq!(
            AppSubagentStatus::from_raw("failed"),
            AppSubagentStatus::Errored
        );
        assert_eq!(
            AppSubagentStatus::from_raw("notFound"),
            AppSubagentStatus::Unknown
        );
    }
}
