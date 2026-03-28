//! Shared model types: Thread, Turn, ThreadItem, CodexModel, Config, etc.
//!
//! These are mobile-friendly wrappers around upstream Codex protocol types.
//! They use `String` for most enum-like fields and `serde_json::Value` for
//! fields we don't fully type yet, making them resilient to server changes.
//!
//! `From` impls are provided for converting from upstream `v2::Thread` and
//! `v2::Model` types.

use codex_app_server_protocol as upstream;
use serde::{Deserialize, Serialize};

use super::enums::ThreadSummaryStatus;
#[cfg(test)]
use super::generated;

/// Summary information about a thread.
///
/// This is a flattened, mobile-friendly view of the upstream `v2::Thread` type.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct ThreadInfo {
    /// Unique identifier for the thread.
    pub id: String,
    /// User-facing title, if set.
    pub title: Option<String>,
    /// The model used for this thread, if known.
    pub model: Option<String>,
    /// Current status of the thread.
    pub status: ThreadSummaryStatus,
    /// Preview text (usually the first user message).
    pub preview: Option<String>,
    /// Working directory for the thread.
    pub cwd: Option<String>,
    /// Rollout path on the server filesystem.
    pub path: Option<String>,
    /// Model provider (e.g. "openai").
    pub model_provider: Option<String>,
    /// Agent nickname for subagent threads.
    pub agent_nickname: Option<String>,
    /// Agent role for subagent threads.
    pub agent_role: Option<String>,
    /// Parent thread id for spawned/forked threads when known.
    pub parent_thread_id: Option<String>,
    /// Best-effort subagent lifecycle status string.
    pub agent_status: Option<String>,
    /// Unix timestamp (seconds) when the thread was created.
    pub created_at: Option<i64>,
    /// Unix timestamp (seconds) when the thread was last updated.
    pub updated_at: Option<i64>,
}

impl From<upstream::Thread> for ThreadInfo {
    fn from(thread: upstream::Thread) -> Self {
        // Extract agent info from source (SubAgent variant).
        let (agent_nickname, agent_role, parent_thread_id) = match &thread.source {
            upstream::SessionSource::SubAgent(sub) => {
                use codex_protocol::protocol::SubAgentSource;
                match sub {
                    SubAgentSource::ThreadSpawn {
                        parent_thread_id,
                        agent_nickname,
                        agent_role,
                        ..
                    } => (
                        agent_nickname.clone(),
                        agent_role.clone(),
                        Some(parent_thread_id.to_string()),
                    ),
                    _ => (
                        thread.agent_nickname.clone(),
                        thread.agent_role.clone(),
                        None,
                    ),
                }
            }
            _ => (
                thread.agent_nickname.clone(),
                thread.agent_role.clone(),
                None,
            ),
        };

        Self {
            id: thread.id,
            title: thread.name,
            model: None,
            status: ThreadSummaryStatus::from(thread.status),
            preview: if thread.preview.is_empty() {
                None
            } else {
                Some(thread.preview)
            },
            cwd: Some(thread.cwd.to_string_lossy().to_string()),
            path: match thread.path {
                Some(path) => Some(path.to_string_lossy().to_string()),
                None => Some(thread.cwd.to_string_lossy().to_string()),
            },
            model_provider: Some(thread.model_provider),
            agent_nickname,
            agent_role,
            parent_thread_id,
            agent_status: None,
            created_at: Some(thread.created_at),
            updated_at: Some(thread.updated_at),
        }
    }
}

/// Composite key identifying a thread on a specific server.
///
/// Mobile-specific — no upstream equivalent.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "camelCase")]
#[derive(uniffi::Record)]
pub struct ThreadKey {
    pub server_id: String,
    pub thread_id: String,
}

/// Rate limit information from the server.
///
/// Mobile-specific simplified view.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]

pub struct RateLimits {
    /// Number of requests remaining in the current window.
    pub requests_remaining: Option<u64>,
    /// Number of tokens remaining in the current window.
    pub tokens_remaining: Option<u64>,
    /// ISO 8601 timestamp when the rate limit window resets.
    pub reset_at: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::enums::ThreadSummaryStatus;

    #[test]
    fn thread_info_roundtrip() {
        let info = ThreadInfo {
            id: "thr_abc123".to_string(),
            title: Some("My Thread".to_string()),
            model: Some("o4-mini".to_string()),
            status: ThreadSummaryStatus::Idle,
            preview: Some("Hello world".to_string()),
            cwd: Some("/home/user/project".to_string()),
            path: None,
            model_provider: Some("openai".to_string()),
            agent_nickname: None,
            agent_role: None,
            parent_thread_id: None,
            agent_status: None,
            created_at: Some(1700000000),
            updated_at: Some(1700001000),
        };
        let json = serde_json::to_string(&info).unwrap();
        let deserialized: ThreadInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(info, deserialized);
    }

    #[test]
    fn thread_info_minimal() {
        let info = ThreadInfo {
            id: "thr_minimal".to_string(),
            title: None,
            model: None,
            status: ThreadSummaryStatus::NotLoaded,
            preview: None,
            path: None,
            model_provider: None,
            agent_nickname: None,
            agent_role: None,
            parent_thread_id: None,
            agent_status: None,
            cwd: None,
            created_at: None,
            updated_at: None,
        };
        let json = serde_json::to_value(&info).unwrap();
        assert_eq!(json["id"], "thr_minimal");
        assert!(json["title"].is_null());
    }

    #[test]
    fn thread_key_roundtrip() {
        let key = ThreadKey {
            server_id: "srv_1".to_string(),
            thread_id: "thr_abc".to_string(),
        };
        let json = serde_json::to_string(&key).unwrap();
        let deserialized: ThreadKey = serde_json::from_str(&json).unwrap();
        assert_eq!(key, deserialized);
    }

    #[test]
    fn rate_limits_roundtrip() {
        let limits = RateLimits {
            requests_remaining: Some(100),
            tokens_remaining: Some(50000),
            reset_at: Some("2026-03-20T12:00:00Z".to_string()),
        };
        let json = serde_json::to_string(&limits).unwrap();
        let deserialized: RateLimits = serde_json::from_str(&json).unwrap();
        assert_eq!(limits, deserialized);
    }

    #[test]
    fn thread_info_serializes_camel_case() {
        let info = ThreadInfo {
            id: "thr_1".to_string(),
            title: None,
            model: None,
            status: ThreadSummaryStatus::Idle,
            preview: None,
            cwd: None,
            path: None,
            model_provider: None,
            agent_nickname: None,
            agent_role: None,
            parent_thread_id: None,
            agent_status: None,
            created_at: Some(1000),
            updated_at: Some(2000),
        };
        let json = serde_json::to_value(&info).unwrap();
        assert!(json.get("createdAt").is_some());
        assert!(json.get("updatedAt").is_some());
    }

    #[test]
    fn generated_thread_read_response_deserializes_subagent_source_and_active_status() {
        let response: generated::ThreadReadResponse = serde_json::from_value(serde_json::json!({
            "thread": {
                "id": "thread-1",
                "preview": "hi",
                "ephemeral": false,
                "modelProvider": "openai",
                "createdAt": 1,
                "updatedAt": 2,
                "status": {
                    "type": "active",
                    "activeFlags": ["waitingOnApproval"]
                },
                "path": "/tmp/thread",
                "cwd": "/tmp/thread",
                "cliVersion": "1.0.0",
                "source": {
                    "subAgent": {
                        "thread_spawn": {
                            "parent_thread_id": "parent-1",
                            "depth": 2,
                            "agent_nickname": "Scout",
                            "agent_role": "reviewer"
                        }
                    }
                },
                "agentNickname": "Scout",
                "agentRole": "reviewer",
                "gitInfo": null,
                "name": "child",
                "turns": []
            }
        }))
        .expect("thread/read response should remain fully typed");

        match response.thread.status {
            generated::ThreadStatus::Active { active_flags } => {
                assert_eq!(
                    active_flags,
                    vec![generated::ThreadActiveFlag::WaitingOnApproval]
                );
            }
            other => panic!("unexpected thread status: {other:?}"),
        }

        match response.thread.source {
            generated::SessionSource::SubAgent(generated::SubAgentSource::ThreadSpawn {
                parent_thread_id,
                depth,
                agent_nickname,
                agent_role,
                ..
            }) => {
                assert_eq!(parent_thread_id, "parent-1");
                assert_eq!(depth, 2);
                assert_eq!(agent_nickname.as_deref(), Some("Scout"));
                assert_eq!(agent_role.as_deref(), Some("reviewer"));
            }
            other => panic!("unexpected session source: {other:?}"),
        }

        // Convert to upstream Thread (which has the From<Thread> for ThreadInfo impl)
        // by re-deserializing from the same JSON shape, using valid UUIDs for ThreadId fields.
        let upstream_thread: codex_app_server_protocol::Thread =
            serde_json::from_value(serde_json::json!({
                "id": "01234567-89ab-cdef-0123-456789abcdef",
                "preview": "hi",
                "ephemeral": false,
                "modelProvider": "openai",
                "createdAt": 1,
                "updatedAt": 2,
                "status": {
                    "type": "active",
                    "activeFlags": ["waitingOnApproval"]
                },
                "path": "/tmp/thread",
                "cwd": "/tmp/thread",
                "cliVersion": "1.0.0",
                "source": {
                    "subAgent": {
                        "thread_spawn": {
                            "parent_thread_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                            "depth": 2,
                            "agent_nickname": "Scout",
                            "agent_role": "reviewer"
                        }
                    }
                },
                "agentNickname": "Scout",
                "agentRole": "reviewer",
                "gitInfo": null,
                "name": "child",
                "turns": []
            }))
            .expect("upstream Thread should deserialize");
        let info = ThreadInfo::from(upstream_thread);
        assert_eq!(
            info.parent_thread_id.as_deref(),
            Some("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        );
        assert_eq!(info.agent_nickname.as_deref(), Some("Scout"));
        assert_eq!(info.agent_role.as_deref(), Some("reviewer"));
    }

    #[test]
    fn generated_thread_resume_response_deserializes_granular_approval_policy() {
        let response: generated::ThreadResumeResponse = serde_json::from_value(serde_json::json!({
            "thread": {
                "id": "thread-1",
                "preview": "hi",
                "ephemeral": false,
                "modelProvider": "openai",
                "createdAt": 1,
                "updatedAt": 2,
                "status": { "type": "idle" },
                "path": "/tmp/thread",
                "cwd": "/tmp/thread",
                "cliVersion": "1.0.0",
                "source": "cli",
                "agentNickname": null,
                "agentRole": null,
                "gitInfo": null,
                "name": "thread",
                "turns": []
            },
            "model": "gpt-5",
            "modelProvider": "openai",
            "serviceTier": "fast",
            "cwd": "/tmp/thread",
            "approvalPolicy": {
                "granular": {
                    "sandbox_approval": true,
                    "rules": false,
                    "skill_approval": true,
                    "request_permissions": true,
                    "mcp_elicitations": false
                }
            },
            "approvalsReviewer": "user",
            "sandbox": {
                "type": "readOnly",
                "access": {
                    "type": "fullAccess"
                },
                "networkAccess": true
            },
            "reasoningEffort": "medium"
        }))
        .expect("thread/resume response should deserialize typed enums");

        assert_eq!(response.service_tier, Some(generated::ServiceTier::Fast));
        assert_eq!(
            response.reasoning_effort,
            Some(generated::ReasoningEffort::Medium)
        );
        match response.approval_policy {
            generated::AskForApproval::Granular {
                sandbox_approval,
                rules,
                skill_approval,
                request_permissions,
                mcp_elicitations,
            } => {
                assert!(sandbox_approval);
                assert!(!rules);
                assert!(skill_approval);
                assert!(request_permissions);
                assert!(!mcp_elicitations);
            }
            other => panic!("unexpected approval policy: {other:?}"),
        }
    }
}
