//! Translates pi-mono events into `codex_app_server_protocol` types
//! that can be fed into the existing reducer/store pipeline.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use codex_app_server_protocol::{
    CommandExecutionStatus, ItemCompletedNotification, ItemStartedNotification,
    ThreadStatusChangedNotification, ThreadStatus,
};

use crate::protocol::{PiAgentEvent, PiAssistantMessageEvent, PiEvent, PiModel};

/// Intermediate event produced by the mapper, ready for conversion to `UiEvent`
/// in the session layer.
#[derive(Debug, Clone)]
pub enum MappedEvent {
    TurnStarted {
        turn_id: String,
    },
    TurnCompleted {
        turn_id: String,
    },
    ItemStarted {
        notification: ItemStartedNotification,
    },
    ItemCompleted {
        notification: ItemCompletedNotification,
    },
    MessageDelta {
        item_id: String,
        delta: String,
    },
    ReasoningDelta {
        item_id: String,
        delta: String,
    },
    CommandOutputDelta {
        item_id: String,
        delta: String,
    },
    ThreadStatusChanged {
        notification: ThreadStatusChangedNotification,
    },
    ApprovalRequested {
        id: String,
        method: String,
        title: Option<String>,
        message: Option<String>,
        options: Option<Vec<serde_json::Value>>,
        extra: serde_json::Map<String, serde_json::Value>,
    },
}

pub struct PiMonoEventMapper {
    thread_id: String,
    next_item_id: AtomicU64,
    next_turn_id: AtomicU64,
    active_turn_id: Mutex<Option<String>>,
    /// Maps tool_call_id → item_id for correlating tool updates/end with their start.
    active_items: Mutex<HashMap<String, String>>,
    /// Current active message item_id (for text/thinking deltas).
    active_message_id: Mutex<Option<String>>,
}

impl PiMonoEventMapper {
    pub fn new(thread_id: String) -> Self {
        Self {
            thread_id,
            next_item_id: AtomicU64::new(1),
            next_turn_id: AtomicU64::new(1),
            active_turn_id: Mutex::new(None),
            active_items: Mutex::new(HashMap::new()),
            active_message_id: Mutex::new(None),
        }
    }

    fn next_item_id(&self) -> String {
        let n = self.next_item_id.fetch_add(1, Ordering::Relaxed);
        format!("pi-item-{n}")
    }

    fn next_turn_id(&self) -> String {
        let n = self.next_turn_id.fetch_add(1, Ordering::Relaxed);
        format!("pi-turn-{n}")
    }

    fn current_turn_id(&self) -> String {
        self.active_turn_id
            .lock()
            .unwrap()
            .clone()
            .unwrap_or_else(|| "pi-turn-0".to_string())
    }

    /// Map a top-level PiEvent into zero or more MappedEvents.
    pub fn map_event(&self, event: &PiEvent) -> Vec<MappedEvent> {
        match event {
            PiEvent::AgentEvent { event } => self.map_agent_event(event),
            PiEvent::ExtensionUiRequest {
                id,
                method,
                title,
                message,
                options,
                extra,
            } => {
                vec![MappedEvent::ApprovalRequested {
                    id: id.clone(),
                    method: method.clone(),
                    title: title.clone(),
                    message: message.clone(),
                    options: options.clone(),
                    extra: extra.clone(),
                }]
            }
            PiEvent::Response { .. } => vec![],
        }
    }

    fn map_agent_event(&self, event: &PiAgentEvent) -> Vec<MappedEvent> {
        match event {
            PiAgentEvent::TurnStart => {
                let turn_id = self.next_turn_id();
                *self.active_turn_id.lock().unwrap() = Some(turn_id.clone());
                vec![MappedEvent::TurnStarted { turn_id }]
            }

            PiAgentEvent::TurnEnd { .. } => {
                let turn_id = self.current_turn_id();
                vec![MappedEvent::TurnCompleted { turn_id }]
            }

            PiAgentEvent::MessageStart { message } => {
                let role = message
                    .get("role")
                    .and_then(|r| r.as_str())
                    .unwrap_or("assistant");
                if role != "assistant" {
                    return vec![];
                }
                let item_id = self.next_item_id();
                *self.active_message_id.lock().unwrap() = Some(item_id.clone());
                vec![MappedEvent::ItemStarted {
                    notification: ItemStartedNotification {
                        thread_id: self.thread_id.clone(),
                        turn_id: self.current_turn_id(),
                        item: codex_app_server_protocol::ThreadItem::AgentMessage {
                            id: item_id,
                            text: String::new(),
                            phase: None,
                            memory_citation: None,
                        },
                    },
                }]
            }

            PiAgentEvent::MessageUpdate {
                assistant_message_event,
                ..
            } => {
                let item_id = match self.active_message_id.lock().unwrap().clone() {
                    Some(id) => id,
                    None => return vec![],
                };
                match assistant_message_event {
                    PiAssistantMessageEvent::TextDelta { delta, .. } => {
                        vec![MappedEvent::MessageDelta {
                            item_id,
                            delta: delta.clone(),
                        }]
                    }
                    PiAssistantMessageEvent::ThinkingDelta { delta, .. } => {
                        vec![MappedEvent::ReasoningDelta {
                            item_id,
                            delta: delta.clone(),
                        }]
                    }
                    PiAssistantMessageEvent::Done { .. }
                    | PiAssistantMessageEvent::Error { .. }
                    | PiAssistantMessageEvent::Unknown => vec![],
                }
            }

            PiAgentEvent::MessageEnd { message } => {
                let item_id = self.active_message_id.lock().unwrap().take();
                let item_id = match item_id {
                    Some(id) => id,
                    None => return vec![],
                };
                let text = extract_text_from_message(message);
                vec![MappedEvent::ItemCompleted {
                    notification: ItemCompletedNotification {
                        thread_id: self.thread_id.clone(),
                        turn_id: self.current_turn_id(),
                        item: codex_app_server_protocol::ThreadItem::AgentMessage {
                            id: item_id,
                            text,
                            phase: None,
                            memory_citation: None,
                        },
                    },
                }]
            }

            PiAgentEvent::ToolExecutionStart {
                tool_call_id,
                tool_name,
                args,
            } => {
                let item_id = self.next_item_id();
                self.active_items
                    .lock()
                    .unwrap()
                    .insert(tool_call_id.clone(), item_id.clone());

                let command = if tool_name == "bash" {
                    args.get("command")
                        .and_then(|c| c.as_str())
                        .unwrap_or(tool_name)
                        .to_string()
                } else {
                    format!("{tool_name} {}", summarize_tool_args(tool_name, args))
                };

                let cwd = args
                    .get("cwd")
                    .and_then(|c| c.as_str())
                    .unwrap_or(".")
                    .to_string();

                vec![MappedEvent::ItemStarted {
                    notification: ItemStartedNotification {
                        thread_id: self.thread_id.clone(),
                        turn_id: self.current_turn_id(),
                        item: codex_app_server_protocol::ThreadItem::CommandExecution {
                            id: item_id,
                            command,
                            cwd: PathBuf::from(cwd),
                            process_id: None,
                            source: Default::default(),
                            status: CommandExecutionStatus::InProgress,
                            command_actions: vec![],
                            aggregated_output: None,
                            exit_code: None,
                            duration_ms: None,
                        },
                    },
                }]
            }

            PiAgentEvent::ToolExecutionUpdate {
                tool_call_id,
                partial_result,
                ..
            } => {
                let item_id = match self.active_items.lock().unwrap().get(tool_call_id) {
                    Some(id) => id.clone(),
                    None => return vec![],
                };
                let delta = partial_result
                    .as_ref()
                    .map(|v| {
                        v.as_str()
                            .map(|s| s.to_string())
                            .unwrap_or_else(|| v.to_string())
                    })
                    .unwrap_or_default();
                if delta.is_empty() {
                    return vec![];
                }
                vec![MappedEvent::CommandOutputDelta { item_id, delta }]
            }

            PiAgentEvent::ToolExecutionEnd {
                tool_call_id,
                tool_name,
                result,
                is_error,
            } => {
                let item_id = self
                    .active_items
                    .lock()
                    .unwrap()
                    .remove(tool_call_id)
                    .unwrap_or_else(|| self.next_item_id());

                let status = if *is_error {
                    CommandExecutionStatus::Failed
                } else {
                    CommandExecutionStatus::Completed
                };

                let output = result
                    .as_str()
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| result.to_string());

                vec![MappedEvent::ItemCompleted {
                    notification: ItemCompletedNotification {
                        thread_id: self.thread_id.clone(),
                        turn_id: self.current_turn_id(),
                        item: codex_app_server_protocol::ThreadItem::CommandExecution {
                            id: item_id,
                            command: tool_name.clone(),
                            cwd: PathBuf::from("."),
                            process_id: None,
                            source: Default::default(),
                            status,
                            command_actions: vec![],
                            aggregated_output: Some(output),
                            exit_code: if *is_error { Some(1) } else { Some(0) },
                            duration_ms: None,
                        },
                    },
                }]
            }

            PiAgentEvent::AgentStart => vec![],

            PiAgentEvent::AgentEnd { .. } => {
                vec![MappedEvent::ThreadStatusChanged {
                    notification: ThreadStatusChangedNotification {
                        thread_id: self.thread_id.clone(),
                        status: ThreadStatus::Idle,
                    },
                }]
            }

            PiAgentEvent::QueueUpdate { .. }
            | PiAgentEvent::CompactionStart
            | PiAgentEvent::CompactionEnd => vec![],
        }
    }

    /// Convert pi-mono messages (from GetMessages) into ThreadItems for hydration.
    pub fn pi_messages_to_thread_items(
        &self,
        messages: &[serde_json::Value],
    ) -> Vec<codex_app_server_protocol::ThreadItem> {
        let mut items = Vec::new();
        for msg in messages {
            let role = msg.get("role").and_then(|r| r.as_str()).unwrap_or("");
            match role {
                "assistant" => {
                    let text = extract_text_from_message(msg);
                    let item_id = self.next_item_id();
                    items.push(codex_app_server_protocol::ThreadItem::AgentMessage {
                        id: item_id,
                        text,
                        phase: None,
                        memory_citation: None,
                    });
                }
                "user" => {
                    let text = extract_text_from_message(msg);
                    let item_id = self.next_item_id();
                    items.push(codex_app_server_protocol::ThreadItem::UserMessage {
                        id: item_id,
                        content: vec![codex_app_server_protocol::UserInput::Text {
                            text,
                            text_elements: vec![],
                        }],
                    });
                }
                _ => {} // skip system, tool, etc.
            }
        }
        items
    }

    /// Map pi-mono models to the upstream `ModelInfo`-compatible shape.
    /// Returns a list of (id, model, display_name, provider, reasoning).
    pub fn pi_models_to_model_tuples(
        models: &[PiModel],
    ) -> Vec<PiModelTuple> {
        models
            .iter()
            .map(|m| PiModelTuple {
                id: format!("{}/{}", m.provider, m.id),
                model_id: m.id.clone(),
                display_name: m.name.clone(),
                provider: m.provider.clone(),
                reasoning: m.reasoning,
            })
            .collect()
    }
}

/// Simplified model representation for conversion to `ModelInfo` in the consumer.
#[derive(Debug, Clone)]
pub struct PiModelTuple {
    pub id: String,
    pub model_id: String,
    pub display_name: String,
    pub provider: String,
    pub reasoning: bool,
}

/// Extract text content from a pi-mono message JSON value.
fn extract_text_from_message(message: &serde_json::Value) -> String {
    // Try "content" as string first
    if let Some(text) = message.get("content").and_then(|c| c.as_str()) {
        return text.to_string();
    }
    // Try "content" as array of content blocks
    if let Some(blocks) = message.get("content").and_then(|c| c.as_array()) {
        let mut text = String::new();
        for block in blocks {
            if let Some(block_type) = block.get("type").and_then(|t| t.as_str()) {
                match block_type {
                    "text" => {
                        if let Some(t) = block.get("text").and_then(|t| t.as_str()) {
                            text.push_str(t);
                        }
                    }
                    "thinking" => {
                        // Skip thinking blocks in main text extraction
                    }
                    _ => {}
                }
            }
        }
        return text;
    }
    // Try "text" directly
    if let Some(text) = message.get("text").and_then(|t| t.as_str()) {
        return text.to_string();
    }
    String::new()
}

/// Summarize tool arguments for display in the command field.
fn summarize_tool_args(tool_name: &str, args: &serde_json::Value) -> String {
    match tool_name {
        "read" | "Read" => args
            .get("path")
            .or_else(|| args.get("file_path"))
            .and_then(|p| p.as_str())
            .unwrap_or("")
            .to_string(),
        "write" | "Write" | "edit" | "Edit" => args
            .get("path")
            .or_else(|| args.get("file_path"))
            .and_then(|p| p.as_str())
            .unwrap_or("")
            .to_string(),
        _ => {
            let s = args.to_string();
            if s.len() > 100 {
                format!("{}...", &s[..97])
            } else {
                s
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::*;

    fn make_mapper() -> PiMonoEventMapper {
        PiMonoEventMapper::new("pi-test-thread".to_string())
    }

    #[test]
    fn turn_start_emits_turn_started() {
        let mapper = make_mapper();
        let events = mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::TurnStart,
        });
        assert_eq!(events.len(), 1);
        match &events[0] {
            MappedEvent::TurnStarted { turn_id } => {
                assert_eq!(turn_id, "pi-turn-1");
            }
            other => panic!("expected TurnStarted, got {other:?}"),
        }
    }

    #[test]
    fn turn_end_emits_turn_completed() {
        let mapper = make_mapper();
        // Start a turn first
        mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::TurnStart,
        });
        let events = mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::TurnEnd {
                message: None,
                tool_results: vec![],
            },
        });
        assert_eq!(events.len(), 1);
        match &events[0] {
            MappedEvent::TurnCompleted { turn_id } => {
                assert_eq!(turn_id, "pi-turn-1");
            }
            other => panic!("expected TurnCompleted, got {other:?}"),
        }
    }

    #[test]
    fn message_lifecycle() {
        let mapper = make_mapper();
        mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::TurnStart,
        });

        // MessageStart
        let events = mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::MessageStart {
                message: serde_json::json!({"role": "assistant"}),
            },
        });
        assert_eq!(events.len(), 1);
        let item_id = match &events[0] {
            MappedEvent::ItemStarted { notification } => match &notification.item {
                codex_app_server_protocol::ThreadItem::AgentMessage { id, text, .. } => {
                    assert!(text.is_empty());
                    id.clone()
                }
                other => panic!("expected AgentMessage, got {other:?}"),
            },
            other => panic!("expected ItemStarted, got {other:?}"),
        };

        // TextDelta
        let events = mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::MessageUpdate {
                message: serde_json::json!({"role": "assistant"}),
                assistant_message_event: PiAssistantMessageEvent::TextDelta {
                    content_index: 0,
                    delta: "Hello".to_string(),
                },
            },
        });
        assert_eq!(events.len(), 1);
        match &events[0] {
            MappedEvent::MessageDelta { item_id: id, delta } => {
                assert_eq!(id, &item_id);
                assert_eq!(delta, "Hello");
            }
            other => panic!("expected MessageDelta, got {other:?}"),
        }

        // MessageEnd
        let events = mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::MessageEnd {
                message: serde_json::json!({"role": "assistant", "content": "Hello world"}),
            },
        });
        assert_eq!(events.len(), 1);
        match &events[0] {
            MappedEvent::ItemCompleted { notification } => match &notification.item {
                codex_app_server_protocol::ThreadItem::AgentMessage { id, text, .. } => {
                    assert_eq!(id, &item_id);
                    assert_eq!(text, "Hello world");
                }
                other => panic!("expected AgentMessage, got {other:?}"),
            },
            other => panic!("expected ItemCompleted, got {other:?}"),
        }
    }

    #[test]
    fn tool_execution_lifecycle() {
        let mapper = make_mapper();
        mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::TurnStart,
        });

        // ToolExecutionStart (bash)
        let events = mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::ToolExecutionStart {
                tool_call_id: "tc-1".to_string(),
                tool_name: "bash".to_string(),
                args: serde_json::json!({"command": "ls -la", "cwd": "/tmp"}),
            },
        });
        assert_eq!(events.len(), 1);
        let item_id = match &events[0] {
            MappedEvent::ItemStarted { notification } => match &notification.item {
                codex_app_server_protocol::ThreadItem::CommandExecution {
                    id,
                    command,
                    cwd,
                    status,
                    ..
                } => {
                    assert_eq!(command, "ls -la");
                    assert_eq!(cwd, &PathBuf::from("/tmp"));
                    assert_eq!(status, &CommandExecutionStatus::InProgress);
                    id.clone()
                }
                other => panic!("expected CommandExecution, got {other:?}"),
            },
            other => panic!("expected ItemStarted, got {other:?}"),
        };

        // ToolExecutionUpdate
        let events = mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::ToolExecutionUpdate {
                tool_call_id: "tc-1".to_string(),
                tool_name: "bash".to_string(),
                partial_result: Some(serde_json::json!("file1.txt\nfile2.txt")),
            },
        });
        assert_eq!(events.len(), 1);
        match &events[0] {
            MappedEvent::CommandOutputDelta { item_id: id, delta } => {
                assert_eq!(id, &item_id);
                assert_eq!(delta, "file1.txt\nfile2.txt");
            }
            other => panic!("expected CommandOutputDelta, got {other:?}"),
        }

        // ToolExecutionEnd
        let events = mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::ToolExecutionEnd {
                tool_call_id: "tc-1".to_string(),
                tool_name: "bash".to_string(),
                result: serde_json::json!("file1.txt\nfile2.txt"),
                is_error: false,
            },
        });
        assert_eq!(events.len(), 1);
        match &events[0] {
            MappedEvent::ItemCompleted { notification } => match &notification.item {
                codex_app_server_protocol::ThreadItem::CommandExecution {
                    id,
                    status,
                    exit_code,
                    aggregated_output,
                    ..
                } => {
                    assert_eq!(id, &item_id);
                    assert_eq!(status, &CommandExecutionStatus::Completed);
                    assert_eq!(exit_code, &Some(0));
                    assert_eq!(
                        aggregated_output.as_deref(),
                        Some("file1.txt\nfile2.txt")
                    );
                }
                other => panic!("expected CommandExecution, got {other:?}"),
            },
            other => panic!("expected ItemCompleted, got {other:?}"),
        }
    }

    #[test]
    fn tool_execution_error() {
        let mapper = make_mapper();
        mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::TurnStart,
        });
        mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::ToolExecutionStart {
                tool_call_id: "tc-2".to_string(),
                tool_name: "bash".to_string(),
                args: serde_json::json!({"command": "false"}),
            },
        });
        let events = mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::ToolExecutionEnd {
                tool_call_id: "tc-2".to_string(),
                tool_name: "bash".to_string(),
                result: serde_json::json!("command failed"),
                is_error: true,
            },
        });
        match &events[0] {
            MappedEvent::ItemCompleted { notification } => match &notification.item {
                codex_app_server_protocol::ThreadItem::CommandExecution {
                    status,
                    exit_code,
                    ..
                } => {
                    assert_eq!(status, &CommandExecutionStatus::Failed);
                    assert_eq!(exit_code, &Some(1));
                }
                other => panic!("expected CommandExecution, got {other:?}"),
            },
            other => panic!("expected ItemCompleted, got {other:?}"),
        }
    }

    #[test]
    fn agent_end_emits_idle_status() {
        let mapper = make_mapper();
        let events = mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::AgentEnd { messages: vec![] },
        });
        assert_eq!(events.len(), 1);
        match &events[0] {
            MappedEvent::ThreadStatusChanged { notification } => {
                assert_eq!(notification.status, ThreadStatus::Idle);
            }
            other => panic!("expected ThreadStatusChanged, got {other:?}"),
        }
    }

    #[test]
    fn extension_ui_request_maps_to_approval() {
        let mapper = make_mapper();
        let events = mapper.map_event(&PiEvent::ExtensionUiRequest {
            id: "req-1".to_string(),
            method: "confirm".to_string(),
            title: Some("Allow bash?".to_string()),
            message: Some("Run: ls".to_string()),
            options: None,
            extra: serde_json::Map::new(),
        });
        assert_eq!(events.len(), 1);
        match &events[0] {
            MappedEvent::ApprovalRequested {
                id,
                method,
                title,
                message,
                ..
            } => {
                assert_eq!(id, "req-1");
                assert_eq!(method, "confirm");
                assert_eq!(title.as_deref(), Some("Allow bash?"));
                assert_eq!(message.as_deref(), Some("Run: ls"));
            }
            other => panic!("expected ApprovalRequested, got {other:?}"),
        }
    }

    #[test]
    fn response_events_are_ignored() {
        let mapper = make_mapper();
        let events = mapper.map_event(&PiEvent::Response {
            command: "get_state".to_string(),
            success: true,
            data: None,
            error: None,
        });
        assert!(events.is_empty());
    }

    #[test]
    fn thinking_delta() {
        let mapper = make_mapper();
        mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::TurnStart,
        });
        mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::MessageStart {
                message: serde_json::json!({"role": "assistant"}),
            },
        });
        let events = mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::MessageUpdate {
                message: serde_json::json!({"role": "assistant"}),
                assistant_message_event: PiAssistantMessageEvent::ThinkingDelta {
                    content_index: 0,
                    delta: "hmm...".to_string(),
                },
            },
        });
        assert_eq!(events.len(), 1);
        match &events[0] {
            MappedEvent::ReasoningDelta { delta, .. } => {
                assert_eq!(delta, "hmm...");
            }
            other => panic!("expected ReasoningDelta, got {other:?}"),
        }
    }

    #[test]
    fn pi_messages_to_thread_items_basic() {
        let mapper = make_mapper();
        let messages = vec![
            serde_json::json!({"role": "user", "content": "Hello"}),
            serde_json::json!({"role": "assistant", "content": "Hi there!"}),
        ];
        let items = mapper.pi_messages_to_thread_items(&messages);
        assert_eq!(items.len(), 2);
        match &items[0] {
            codex_app_server_protocol::ThreadItem::UserMessage { content, .. } => {
                match &content[0] {
                    codex_app_server_protocol::UserInput::Text { text, .. } => {
                        assert_eq!(text, "Hello");
                    }
                    other => panic!("expected Text, got {other:?}"),
                }
            }
            other => panic!("expected UserMessage, got {other:?}"),
        }
        match &items[1] {
            codex_app_server_protocol::ThreadItem::AgentMessage { text, .. } => {
                assert_eq!(text, "Hi there!");
            }
            other => panic!("expected AgentMessage, got {other:?}"),
        }
    }

    #[test]
    fn pi_messages_content_blocks() {
        let mapper = make_mapper();
        let messages = vec![serde_json::json!({
            "role": "assistant",
            "content": [
                {"type": "thinking", "text": "let me think"},
                {"type": "text", "text": "Here is my answer"}
            ]
        })];
        let items = mapper.pi_messages_to_thread_items(&messages);
        assert_eq!(items.len(), 1);
        match &items[0] {
            codex_app_server_protocol::ThreadItem::AgentMessage { text, .. } => {
                assert_eq!(text, "Here is my answer");
            }
            other => panic!("expected AgentMessage, got {other:?}"),
        }
    }

    #[test]
    fn pi_models_to_model_tuples_basic() {
        let models = vec![
            PiModel {
                id: "claude-sonnet-4-6".to_string(),
                name: "Claude Sonnet 4.6".to_string(),
                provider: "anthropic".to_string(),
                reasoning: true,
            },
            PiModel {
                id: "gpt-4o".to_string(),
                name: "GPT-4o".to_string(),
                provider: "openai".to_string(),
                reasoning: false,
            },
        ];
        let tuples = PiMonoEventMapper::pi_models_to_model_tuples(&models);
        assert_eq!(tuples.len(), 2);
        assert_eq!(tuples[0].id, "anthropic/claude-sonnet-4-6");
        assert_eq!(tuples[0].model_id, "claude-sonnet-4-6");
        assert!(tuples[0].reasoning);
        assert_eq!(tuples[1].id, "openai/gpt-4o");
        assert!(!tuples[1].reasoning);
    }

    #[test]
    fn read_tool_summarizes_path() {
        let mapper = make_mapper();
        mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::TurnStart,
        });
        let events = mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::ToolExecutionStart {
                tool_call_id: "tc-3".to_string(),
                tool_name: "read".to_string(),
                args: serde_json::json!({"file_path": "/src/main.rs"}),
            },
        });
        match &events[0] {
            MappedEvent::ItemStarted { notification } => match &notification.item {
                codex_app_server_protocol::ThreadItem::CommandExecution { command, .. } => {
                    assert_eq!(command, "read /src/main.rs");
                }
                other => panic!("expected CommandExecution, got {other:?}"),
            },
            other => panic!("expected ItemStarted, got {other:?}"),
        }
    }

    #[test]
    fn non_assistant_message_start_ignored() {
        let mapper = make_mapper();
        mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::TurnStart,
        });
        let events = mapper.map_event(&PiEvent::AgentEvent {
            event: PiAgentEvent::MessageStart {
                message: serde_json::json!({"role": "system"}),
            },
        });
        assert!(events.is_empty());
    }

    #[test]
    fn item_ids_are_unique() {
        let mapper = make_mapper();
        let id1 = mapper.next_item_id();
        let id2 = mapper.next_item_id();
        let id3 = mapper.next_item_id();
        assert_ne!(id1, id2);
        assert_ne!(id2, id3);
    }
}
