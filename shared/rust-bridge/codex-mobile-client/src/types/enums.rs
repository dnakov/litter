//! Mobile-owned enums that do not come directly from upstream-generated types.

use codex_app_server_protocol as upstream;
use serde::{Deserialize, Serialize};

/// Status of a turn within a thread.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TurnStatus {
    Running,
    Completed,
    Failed,
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turn_status_roundtrip() {
        for status in [
            TurnStatus::Running,
            TurnStatus::Completed,
            TurnStatus::Failed,
        ] {
            let json = serde_json::to_string(&status).unwrap();
            let deserialized: TurnStatus = serde_json::from_str(&json).unwrap();
            assert_eq!(status, deserialized);
        }
    }

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
}
