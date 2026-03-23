//! UniFFI-exported state surface for the canonical Rust app store.

use crate::MobileClient;
use crate::ffi::ClientError;
use crate::ffi::shared::{blocking_async, shared_mobile_client, shared_runtime};
use crate::store::{AppSnapshotRecord, AppStoreUpdateRecord, AppUpdate};
use crate::types::generated;
use crate::types::models::ThreadKey;
use std::sync::Arc;

#[derive(uniffi::Object)]
pub struct AppStore {
    pub(crate) inner: Arc<MobileClient>,
    pub(crate) rt: Arc<tokio::runtime::Runtime>,
}

#[derive(uniffi::Object)]
pub struct AppStoreSubscription {
    pub(crate) rx: std::sync::Mutex<Option<tokio::sync::broadcast::Receiver<AppUpdate>>>,
}

#[cfg(test)]
mod tests {
    use crate::types::generated;
    use codex_app_server_protocol as upstream;
    use serde_json::json;

    fn convert_generated_thread_item(
        item: generated::ThreadItem,
    ) -> Result<upstream::ThreadItem, super::ClientError> {
        crate::rpc::convert_generated_field(item).map_err(Into::into)
    }

    #[test]
    fn generated_thread_item_parses_mcp_arguments_json() {
        let item = generated::ThreadItem::McpToolCall {
            id: "mcp-1".into(),
            server: "filesystem".into(),
            tool: "read_file".into(),
            status: generated::McpToolCallStatus::Completed,
            arguments: serde_json::from_value(json!({"path": "/tmp/file.txt"}))
                .expect("json value should convert"),
            result: None,
            error: None,
            duration_ms: Some(42),
        };

        let upstream_item =
            convert_generated_thread_item(item).expect("mcp tool item should convert");
        let upstream::ThreadItem::McpToolCall { arguments, .. } = upstream_item else {
            panic!("expected mcp tool call");
        };
        assert_eq!(
            arguments.get("path").and_then(|value| value.as_str()),
            Some("/tmp/file.txt")
        );
    }

    #[test]
    fn generated_thread_item_parses_collab_agent_states_json() {
        let item = generated::ThreadItem::CollabAgentToolCall {
            id: "collab-1".into(),
            tool: generated::CollabAgentTool::SpawnAgent,
            status: generated::CollabAgentToolCallStatus::Completed,
            sender_thread_id: "parent-thread".into(),
            receiver_thread_ids: vec!["sub-thread-1".into()],
            prompt: Some("Review the changes".into()),
            model: None,
            reasoning_effort: None,
            agents_states: vec![generated::ThreadItemAgentsStatesEntry {
                key: "sub-thread-1".into(),
                value: generated::CollabAgentState {
                    status: generated::CollabAgentStatus::Running,
                    message: Some("Working".into()),
                },
            }],
        };

        let upstream_item =
            convert_generated_thread_item(item).expect("collab agent item should convert");
        let upstream::ThreadItem::CollabAgentToolCall { agents_states, .. } = upstream_item else {
            panic!("expected collab agent tool call");
        };
        let state = agents_states
            .get("sub-thread-1")
            .expect("collab state should be present");
        assert_eq!(state.status, upstream::CollabAgentStatus::Running);
        assert_eq!(state.message.as_deref(), Some("Working"));
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl AppStore {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: shared_mobile_client(),
            rt: shared_runtime(),
        }
    }

    pub async fn snapshot(&self) -> Result<AppSnapshotRecord, ClientError> {
        AppSnapshotRecord::try_from(self.inner.app_snapshot()).map_err(ClientError::Serialization)
    }

    pub fn subscribe_updates(&self) -> AppStoreSubscription {
        AppStoreSubscription {
            rx: std::sync::Mutex::new(Some(self.inner.subscribe_app_updates())),
        }
    }

    pub async fn edit_message(
        &self,
        key: ThreadKey,
        selected_turn_index: u32,
    ) -> Result<String, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.edit_message(&key, selected_turn_index)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn fork_thread_from_message(
        &self,
        key: ThreadKey,
        selected_turn_index: u32,
        params: generated::ThreadForkParams,
    ) -> Result<ThreadKey, ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.fork_thread_from_message(
                &key,
                selected_turn_index,
                params.cwd,
                params.model,
                params.approval_policy,
                params.sandbox,
                params.developer_instructions,
                params.persist_extended_history,
            )
            .await
            .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn respond_to_approval(
        &self,
        request_id: String,
        decision: crate::types::ApprovalDecisionValue,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.respond_to_approval(&request_id, decision)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn respond_to_user_input(
        &self,
        request_id: String,
        answers: Vec<crate::types::PendingUserInputAnswer>,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.respond_to_user_input(&request_id, answers)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub fn set_active_thread(&self, key: Option<ThreadKey>) {
        self.inner.set_active_thread(key);
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl AppStoreSubscription {
    pub async fn next_update(&self) -> Result<AppStoreUpdateRecord, ClientError> {
        let mut rx = {
            self.rx
                .lock()
                .unwrap()
                .take()
                .ok_or(ClientError::EventClosed(
                    "no app-store subscriber".to_string(),
                ))?
        };
        let result = loop {
            match rx.recv().await {
                Ok(update) => break Ok(update.into()),
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    break Err(ClientError::EventClosed("closed".to_string()));
                }
            }
        };
        *self.rx.lock().unwrap() = Some(rx);
        result
    }
}
