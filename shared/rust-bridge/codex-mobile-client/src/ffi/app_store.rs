//! UniFFI-exported state surface for the canonical Rust app store.

use crate::MobileClient;
use crate::ffi::ClientError;
use crate::ffi::shared::{blocking_async, shared_mobile_client, shared_runtime};
use crate::store::{AppSnapshotRecord, AppStoreUpdateRecord, AppThreadSnapshot};
use crate::types::{AppForkThreadFromMessageRequest, AppModeKind, AppStartTurnRequest, ThreadKey};
use std::collections::VecDeque;
use std::sync::Arc;

#[derive(uniffi::Object)]
pub struct AppStore {
    pub(crate) inner: Arc<MobileClient>,
    pub(crate) rt: Arc<tokio::runtime::Runtime>,
}

#[derive(uniffi::Object)]
pub struct AppStoreSubscription {
    pub(crate) state: std::sync::Mutex<Option<AppStoreSubscriptionState>>,
}

pub(crate) struct AppStoreSubscriptionState {
    pub(crate) rx: tokio::sync::broadcast::Receiver<AppStoreUpdateRecord>,
    pub(crate) buffered: VecDeque<AppStoreUpdateRecord>,
}

const MAX_COALESCED_STREAMING_TEXT_BYTES: usize = 8 * 1024;

#[cfg(test)]
mod tests {
    use super::{AppStoreSubscription, AppStoreSubscriptionState};
    use crate::store::{AppStoreReducer, AppStoreUpdateRecord, ThreadStreamingDeltaKind};
    use crate::types::ThreadKey;
    use codex_app_server_protocol as upstream;
    use serde_json::json;
    use std::collections::{HashMap, VecDeque};

    #[test]
    fn thread_item_parses_mcp_arguments_json() {
        let item = upstream::ThreadItem::McpToolCall {
            id: "mcp-1".into(),
            server: "filesystem".into(),
            tool: "read_file".into(),
            status: upstream::McpToolCallStatus::Completed,
            arguments: serde_json::from_value(json!({"path": "/tmp/file.txt"}))
                .expect("json value should convert"),
            result: None,
            error: None,
            duration_ms: Some(42),
        };

        let upstream::ThreadItem::McpToolCall { arguments, .. } = item else {
            panic!("expected mcp tool call");
        };
        assert_eq!(
            arguments.get("path").and_then(|value| value.as_str()),
            Some("/tmp/file.txt")
        );
    }

    #[test]
    fn thread_item_parses_collab_agent_states_json() {
        let item = upstream::ThreadItem::CollabAgentToolCall {
            id: "collab-1".into(),
            tool: upstream::CollabAgentTool::SpawnAgent,
            status: upstream::CollabAgentToolCallStatus::Completed,
            sender_thread_id: "parent-thread".into(),
            receiver_thread_ids: vec!["sub-thread-1".into()],
            prompt: Some("Review the changes".into()),
            model: None,
            reasoning_effort: None,
            agents_states: HashMap::from([(
                "sub-thread-1".into(),
                upstream::CollabAgentState {
                    status: upstream::CollabAgentStatus::Running,
                    message: Some("Working".into()),
                },
            )]),
        };

        let upstream::ThreadItem::CollabAgentToolCall { agents_states, .. } = item else {
            panic!("expected collab agent tool call");
        };
        let state = agents_states
            .get("sub-thread-1")
            .expect("collab state should be present");
        assert_eq!(state.status, upstream::CollabAgentStatus::Running);
        assert_eq!(state.message.as_deref(), Some("Working"));
    }

    #[test]
    fn app_store_subscription_returns_full_resync_when_updates_lag() {
        let reducer = AppStoreReducer::new();
        let subscription = AppStoreSubscription {
            state: std::sync::Mutex::new(Some(AppStoreSubscriptionState {
                rx: reducer.subscribe(),
                buffered: VecDeque::new(),
            })),
        };

        // AppStoreReducer keeps a 1024-event broadcast buffer to absorb normal
        // streaming bursts. Exceed it decisively so this test still exercises
        // the lagged subscriber fallback to FullResync.
        for _ in 0..2048 {
            reducer.set_active_thread(Some(ThreadKey {
                server_id: "srv".to_string(),
                thread_id: "thread-1".to_string(),
            }));
        }

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        let update = runtime
            .block_on(subscription.next_update())
            .expect("next update should succeed");
        assert!(matches!(update, AppStoreUpdateRecord::FullResync));
    }

    #[test]
    fn app_store_subscription_coalesces_contiguous_streaming_deltas() {
        let reducer = AppStoreReducer::new();
        let key = ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        };
        let subscription = AppStoreSubscription {
            state: std::sync::Mutex::new(Some(AppStoreSubscriptionState {
                rx: reducer.subscribe(),
                buffered: VecDeque::new(),
            })),
        };

        reducer.emit_thread_streaming_delta(
            &key,
            "assistant-1",
            ThreadStreamingDeltaKind::AssistantText,
            "hel",
        );
        reducer.emit_thread_streaming_delta(
            &key,
            "assistant-1",
            ThreadStreamingDeltaKind::AssistantText,
            "lo",
        );
        reducer.emit_thread_streaming_delta(
            &key,
            "assistant-1",
            ThreadStreamingDeltaKind::AssistantText,
            " world",
        );

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        let update = runtime
            .block_on(subscription.next_update())
            .expect("next update should succeed");

        assert!(matches!(
            update,
            AppStoreUpdateRecord::ThreadStreamingDelta {
                key: emitted_key,
                item_id,
                kind: crate::store::ThreadStreamingDeltaKind::AssistantText,
                text,
            } if emitted_key == key && item_id == "assistant-1" && text == "hello world"
        ));
    }

    #[test]
    fn app_store_subscription_coalesces_refresh_only_updates_into_full_resync() {
        let reducer = AppStoreReducer::new();
        let subscription = AppStoreSubscription {
            state: std::sync::Mutex::new(Some(AppStoreSubscriptionState {
                rx: reducer.subscribe(),
                buffered: VecDeque::new(),
            })),
        };

        reducer.update_server_health("srv", crate::store::ServerHealthSnapshot::Connected);
        reducer.replace_pending_approvals(Vec::new());
        reducer.set_voice_handoff_thread(None);

        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        let update = runtime
            .block_on(subscription.next_update())
            .expect("next update should succeed");

        assert!(matches!(update, AppStoreUpdateRecord::FullResync));
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

    pub async fn thread_snapshot(
        &self,
        key: ThreadKey,
    ) -> Result<Option<AppThreadSnapshot>, ClientError> {
        crate::store::project_thread_snapshot(&self.inner.app_snapshot(), &key)
            .map_err(ClientError::Serialization)
    }

    pub async fn start_turn(
        &self,
        key: ThreadKey,
        params: AppStartTurnRequest,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            let params = params.try_into().map_err(|error: crate::RpcClientError| {
                ClientError::Serialization(error.to_string())
            })?;
            c.start_turn(&key.server_id, params)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn set_thread_collaboration_mode(
        &self,
        key: ThreadKey,
        mode: AppModeKind,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.set_thread_collaboration_mode(&key, mode)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub fn dismiss_plan_implementation_prompt(&self, key: ThreadKey) {
        self.inner.dismiss_plan_implementation_prompt(&key);
    }

    pub async fn implement_plan(&self, key: ThreadKey) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.implement_plan(&key)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn steer_queued_follow_up(
        &self,
        key: ThreadKey,
        preview_id: String,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.steer_queued_follow_up(&key, &preview_id)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn delete_queued_follow_up(
        &self,
        key: ThreadKey,
        preview_id: String,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.delete_queued_follow_up(&key, &preview_id)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub async fn external_resume_thread(
        &self,
        key: ThreadKey,
        host_id: Option<String>,
    ) -> Result<(), ClientError> {
        blocking_async!(self.rt, self.inner, |c| {
            c.external_resume_thread(&key.server_id, &key.thread_id, host_id)
                .await
                .map_err(|e| ClientError::Rpc(e.to_string()))
        })
    }

    pub fn subscribe_updates(&self) -> AppStoreSubscription {
        AppStoreSubscription {
            state: std::sync::Mutex::new(Some(AppStoreSubscriptionState {
                rx: self.inner.subscribe_app_updates(),
                buffered: VecDeque::new(),
            })),
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
        params: AppForkThreadFromMessageRequest,
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

    pub fn rename_server(&self, server_id: String, display_name: String) {
        self.inner.app_store.rename_server(&server_id, display_name);
    }

    pub fn set_voice_handoff_thread(&self, key: Option<ThreadKey>) {
        self.inner.set_voice_handoff_thread(key);
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl AppStoreSubscription {
    pub async fn next_update(&self) -> Result<AppStoreUpdateRecord, ClientError> {
        let mut state = {
            self.state
                .lock()
                .unwrap()
                .take()
                .ok_or(ClientError::EventClosed(
                    "no app-store subscriber".to_string(),
                ))?
        };
        let result = loop {
            match receive_next_update(&mut state).await {
                Ok(update) => break Ok(update.into()),
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                    break Ok(AppStoreUpdateRecord::FullResync);
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    break Err(ClientError::EventClosed("closed".to_string()));
                }
            }
        };
        *self.state.lock().unwrap() = Some(state);
        result
    }
}

async fn receive_next_update(
    state: &mut AppStoreSubscriptionState,
) -> Result<AppStoreUpdateRecord, tokio::sync::broadcast::error::RecvError> {
    let first = if let Some(update) = state.buffered.pop_front() {
        update
    } else {
        state.rx.recv().await?
    };

    coalesce_ready_updates(state, first)
}

fn coalesce_ready_updates(
    state: &mut AppStoreSubscriptionState,
    mut update: AppStoreUpdateRecord,
) -> Result<AppStoreUpdateRecord, tokio::sync::broadcast::error::RecvError> {
    loop {
        let next = if let Some(update) = state.buffered.pop_front() {
            Some(update)
        } else {
            match state.rx.try_recv() {
                Ok(update) => Some(update),
                Err(tokio::sync::broadcast::error::TryRecvError::Empty) => None,
                Err(tokio::sync::broadcast::error::TryRecvError::Lagged(skipped)) => {
                    return Err(tokio::sync::broadcast::error::RecvError::Lagged(skipped));
                }
                Err(tokio::sync::broadcast::error::TryRecvError::Closed) => None,
            }
        };

        let Some(next) = next else {
            return Ok(update);
        };

        if let Err(next) = merge_app_update(&mut update, next) {
            state.buffered.push_front(next);
            return Ok(update);
        }
    }
}

fn merge_app_update(
    current: &mut AppStoreUpdateRecord,
    next: AppStoreUpdateRecord,
) -> Result<(), AppStoreUpdateRecord> {
    if matches!(current, AppStoreUpdateRecord::FullResync) {
        return Ok(());
    }
    if matches!(next, AppStoreUpdateRecord::FullResync) {
        *current = AppStoreUpdateRecord::FullResync;
        return Ok(());
    }
    if triggers_snapshot_refresh(current) && triggers_snapshot_refresh(&next) {
        *current = AppStoreUpdateRecord::FullResync;
        return Ok(());
    }

    match (current, next) {
        (
            AppStoreUpdateRecord::ThreadStreamingDelta {
                key,
                item_id,
                kind,
                text,
            },
            AppStoreUpdateRecord::ThreadStreamingDelta {
                key: next_key,
                item_id: next_item_id,
                kind: next_kind,
                text: next_text,
            },
        ) if *key == next_key
            && *item_id == next_item_id
            && *kind == next_kind
            && text.len().saturating_add(next_text.len()) <= MAX_COALESCED_STREAMING_TEXT_BYTES =>
        {
            text.push_str(&next_text);
            Ok(())
        }
        (
            AppStoreUpdateRecord::ThreadMetadataChanged {
                state,
                session_summary,
                agent_directory_version,
            },
            AppStoreUpdateRecord::ThreadMetadataChanged {
                state: next_state,
                session_summary: next_summary,
                agent_directory_version: next_version,
            },
        ) if state.key == next_state.key => {
            *state = next_state;
            *session_summary = next_summary;
            *agent_directory_version = next_version;
            Ok(())
        }
        (
            AppStoreUpdateRecord::ThreadItemChanged { key, item },
            AppStoreUpdateRecord::ThreadItemChanged {
                key: next_key,
                item: next_item,
            },
        ) if *key == next_key && item.id == next_item.id => {
            *item = next_item;
            Ok(())
        }
        (
            AppStoreUpdateRecord::ThreadUpserted {
                thread,
                session_summary,
                agent_directory_version,
            },
            AppStoreUpdateRecord::ThreadUpserted {
                thread: next_thread,
                session_summary: next_summary,
                agent_directory_version: next_version,
            },
        ) if thread.key == next_thread.key => {
            *thread = next_thread;
            *session_summary = next_summary;
            *agent_directory_version = next_version;
            Ok(())
        }
        (
            AppStoreUpdateRecord::ActiveThreadChanged { key },
            AppStoreUpdateRecord::ActiveThreadChanged { key: next_key },
        ) => {
            *key = next_key;
            Ok(())
        }
        (_current, next) => Err(next),
    }
}

fn triggers_snapshot_refresh(update: &AppStoreUpdateRecord) -> bool {
    matches!(
        update,
        AppStoreUpdateRecord::ServerChanged { .. }
            | AppStoreUpdateRecord::ServerRemoved { .. }
            | AppStoreUpdateRecord::PendingApprovalsChanged { .. }
            | AppStoreUpdateRecord::PendingUserInputsChanged { .. }
            | AppStoreUpdateRecord::VoiceSessionChanged
            | AppStoreUpdateRecord::RealtimeStarted { .. }
            | AppStoreUpdateRecord::RealtimeError { .. }
            | AppStoreUpdateRecord::RealtimeClosed { .. }
    )
}
