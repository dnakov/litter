use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Commands (serialize, stdin → pi)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PiCommand {
    Prompt {
        message: String,
        #[serde(skip_serializing_if = "Vec::is_empty")]
        images: Vec<PiImage>,
        #[serde(skip_serializing_if = "Option::is_none")]
        streaming_behavior: Option<StreamingBehavior>,
    },
    Steer {
        message: String,
    },
    FollowUp {
        message: String,
    },
    Abort,
    NewSession,
    GetState,
    GetMessages,
    SetModel {
        provider: String,
        model_id: String,
    },
    GetAvailableModels,
    SetThinkingLevel {
        level: String,
    },
    Compact,
    SetAutoCompaction {
        enabled: bool,
    },
    Bash {
        command: String,
    },
    Fork {
        entry_id: String,
    },
    SwitchSession {
        session_path: String,
    },
    SetSessionName {
        name: String,
    },
    GetCommands,
    ExtensionUiResponse {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        value: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        confirmed: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        cancelled: Option<bool>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PiImage {
    pub data: String,
    pub mime_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StreamingBehavior {
    Steer,
    FollowUp,
}

// ---------------------------------------------------------------------------
// Events (deserialize, stdout from pi)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PiEvent {
    AgentEvent {
        event: PiAgentEvent,
    },
    ExtensionUiRequest {
        id: String,
        method: String,
        #[serde(default)]
        title: Option<String>,
        #[serde(default)]
        options: Option<Vec<serde_json::Value>>,
        #[serde(default)]
        message: Option<String>,
        #[serde(flatten)]
        extra: serde_json::Map<String, serde_json::Value>,
    },
    Response {
        command: String,
        success: bool,
        #[serde(default)]
        data: Option<serde_json::Value>,
        #[serde(default)]
        error: Option<String>,
    },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PiAgentEvent {
    AgentStart,
    AgentEnd {
        #[serde(default)]
        messages: Vec<serde_json::Value>,
    },
    TurnStart,
    TurnEnd {
        #[serde(default)]
        message: Option<serde_json::Value>,
        #[serde(default)]
        tool_results: Vec<serde_json::Value>,
    },
    MessageStart {
        message: serde_json::Value,
    },
    MessageUpdate {
        message: serde_json::Value,
        assistant_message_event: PiAssistantMessageEvent,
    },
    MessageEnd {
        message: serde_json::Value,
    },
    ToolExecutionStart {
        tool_call_id: String,
        tool_name: String,
        args: serde_json::Value,
    },
    ToolExecutionUpdate {
        tool_call_id: String,
        tool_name: String,
        #[serde(default)]
        partial_result: Option<serde_json::Value>,
    },
    ToolExecutionEnd {
        tool_call_id: String,
        tool_name: String,
        result: serde_json::Value,
        #[serde(default)]
        is_error: bool,
    },
    QueueUpdate {
        #[serde(default)]
        steering: Vec<String>,
        #[serde(default)]
        follow_up: Vec<String>,
    },
    CompactionStart,
    CompactionEnd,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PiAssistantMessageEvent {
    TextDelta {
        content_index: u32,
        delta: String,
    },
    ThinkingDelta {
        content_index: u32,
        delta: String,
    },
    Done {
        reason: String,
        message: serde_json::Value,
    },
    Error {
        reason: String,
    },
    #[serde(other)]
    Unknown,
}

// ---------------------------------------------------------------------------
// Auxiliary types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Deserialize)]
pub struct PiModel {
    pub id: String,
    pub name: String,
    pub provider: String,
    #[serde(default)]
    pub reasoning: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PiSessionState {
    #[serde(default)]
    pub session_path: Option<String>,
    #[serde(default)]
    pub session_name: Option<String>,
    #[serde(default)]
    pub model: Option<serde_json::Value>,
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serialize_prompt_command() {
        let cmd = PiCommand::Prompt {
            message: "hello".into(),
            images: vec![],
            streaming_behavior: None,
        };
        let json = serde_json::to_string(&cmd).unwrap();
        assert_eq!(json, r#"{"type":"prompt","message":"hello"}"#);
    }

    #[test]
    fn serialize_prompt_with_images() {
        let cmd = PiCommand::Prompt {
            message: "see this".into(),
            images: vec![PiImage {
                data: "base64data".into(),
                mime_type: "image/png".into(),
            }],
            streaming_behavior: Some(StreamingBehavior::Steer),
        };
        let json = serde_json::to_string(&cmd).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["type"], "prompt");
        assert_eq!(v["images"][0]["data"], "base64data");
        assert_eq!(v["streaming_behavior"], "steer");
    }

    #[test]
    fn serialize_abort_command() {
        let cmd = PiCommand::Abort;
        let json = serde_json::to_string(&cmd).unwrap();
        assert_eq!(json, r#"{"type":"abort"}"#);
    }

    #[test]
    fn serialize_set_model_command() {
        let cmd = PiCommand::SetModel {
            provider: "anthropic".into(),
            model_id: "claude-sonnet-4-6".into(),
        };
        let json = serde_json::to_string(&cmd).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["type"], "set_model");
        assert_eq!(v["provider"], "anthropic");
        assert_eq!(v["model_id"], "claude-sonnet-4-6");
    }

    #[test]
    fn serialize_extension_ui_response() {
        let cmd = PiCommand::ExtensionUiResponse {
            id: "req-1".into(),
            value: None,
            confirmed: Some(true),
            cancelled: None,
        };
        let json = serde_json::to_string(&cmd).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["type"], "extension_ui_response");
        assert_eq!(v["confirmed"], true);
        assert!(v.get("value").is_none());
        assert!(v.get("cancelled").is_none());
    }

    #[test]
    fn deserialize_agent_event_turn_start() {
        let json = r#"{"type":"agent_event","event":{"type":"turn_start"}}"#;
        let event: PiEvent = serde_json::from_str(json).unwrap();
        match event {
            PiEvent::AgentEvent {
                event: PiAgentEvent::TurnStart,
            } => {}
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn deserialize_agent_event_text_delta() {
        let json = r#"{
            "type": "agent_event",
            "event": {
                "type": "message_update",
                "message": {"role": "assistant"},
                "assistant_message_event": {
                    "type": "text_delta",
                    "content_index": 0,
                    "delta": "Hello"
                }
            }
        }"#;
        let event: PiEvent = serde_json::from_str(json).unwrap();
        match event {
            PiEvent::AgentEvent {
                event:
                    PiAgentEvent::MessageUpdate {
                        assistant_message_event: PiAssistantMessageEvent::TextDelta { delta, .. },
                        ..
                    },
            } => assert_eq!(delta, "Hello"),
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn deserialize_agent_event_tool_execution_end() {
        let json = r#"{
            "type": "agent_event",
            "event": {
                "type": "tool_execution_end",
                "tool_call_id": "tc-1",
                "tool_name": "bash",
                "result": {"stdout": "ok"},
                "is_error": false
            }
        }"#;
        let event: PiEvent = serde_json::from_str(json).unwrap();
        match event {
            PiEvent::AgentEvent {
                event:
                    PiAgentEvent::ToolExecutionEnd {
                        tool_call_id,
                        tool_name,
                        is_error,
                        ..
                    },
            } => {
                assert_eq!(tool_call_id, "tc-1");
                assert_eq!(tool_name, "bash");
                assert!(!is_error);
            }
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn deserialize_extension_ui_request() {
        let json = r#"{
            "type": "extension_ui_request",
            "id": "req-42",
            "method": "confirm",
            "title": "Allow bash?",
            "message": "Run: ls -la"
        }"#;
        let event: PiEvent = serde_json::from_str(json).unwrap();
        match event {
            PiEvent::ExtensionUiRequest {
                id,
                method,
                title,
                message,
                ..
            } => {
                assert_eq!(id, "req-42");
                assert_eq!(method, "confirm");
                assert_eq!(title.as_deref(), Some("Allow bash?"));
                assert_eq!(message.as_deref(), Some("Run: ls -la"));
            }
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn deserialize_response_success() {
        let json = r#"{
            "type": "response",
            "command": "get_state",
            "success": true,
            "data": {"session_path": "/tmp/session"}
        }"#;
        let event: PiEvent = serde_json::from_str(json).unwrap();
        match event {
            PiEvent::Response {
                command,
                success,
                data,
                error,
            } => {
                assert_eq!(command, "get_state");
                assert!(success);
                assert!(data.is_some());
                assert!(error.is_none());
            }
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn deserialize_response_error() {
        let json = r#"{
            "type": "response",
            "command": "set_model",
            "success": false,
            "error": "unknown model"
        }"#;
        let event: PiEvent = serde_json::from_str(json).unwrap();
        match event {
            PiEvent::Response {
                success, error, ..
            } => {
                assert!(!success);
                assert_eq!(error.as_deref(), Some("unknown model"));
            }
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn deserialize_thinking_delta() {
        let json = r#"{
            "type": "agent_event",
            "event": {
                "type": "message_update",
                "message": {"role": "assistant"},
                "assistant_message_event": {
                    "type": "thinking_delta",
                    "content_index": 1,
                    "delta": "Let me think..."
                }
            }
        }"#;
        let event: PiEvent = serde_json::from_str(json).unwrap();
        match event {
            PiEvent::AgentEvent {
                event:
                    PiAgentEvent::MessageUpdate {
                        assistant_message_event:
                            PiAssistantMessageEvent::ThinkingDelta {
                                content_index,
                                delta,
                            },
                        ..
                    },
            } => {
                assert_eq!(content_index, 1);
                assert_eq!(delta, "Let me think...");
            }
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn deserialize_unknown_assistant_event() {
        let json = r#"{
            "type": "agent_event",
            "event": {
                "type": "message_update",
                "message": {"role": "assistant"},
                "assistant_message_event": {
                    "type": "some_future_event",
                    "foo": "bar"
                }
            }
        }"#;
        let event: PiEvent = serde_json::from_str(json).unwrap();
        match event {
            PiEvent::AgentEvent {
                event:
                    PiAgentEvent::MessageUpdate {
                        assistant_message_event: PiAssistantMessageEvent::Unknown,
                        ..
                    },
            } => {}
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn deserialize_agent_end() {
        let json = r#"{
            "type": "agent_event",
            "event": {
                "type": "agent_end",
                "messages": [{"role": "assistant", "content": "done"}]
            }
        }"#;
        let event: PiEvent = serde_json::from_str(json).unwrap();
        match event {
            PiEvent::AgentEvent {
                event: PiAgentEvent::AgentEnd { messages },
            } => assert_eq!(messages.len(), 1),
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn deserialize_pi_model() {
        let json = r#"{
            "id": "claude-sonnet-4-6",
            "name": "Claude Sonnet 4.6",
            "provider": "anthropic",
            "reasoning": true
        }"#;
        let model: PiModel = serde_json::from_str(json).unwrap();
        assert_eq!(model.id, "claude-sonnet-4-6");
        assert!(model.reasoning);
    }

    #[test]
    fn deserialize_pi_session_state() {
        let json = r#"{
            "session_path": "/home/user/.pi/sessions/abc",
            "session_name": "my session",
            "model": {"id": "claude-sonnet-4-6", "provider": "anthropic"},
            "some_unknown_field": 42
        }"#;
        let state: PiSessionState = serde_json::from_str(json).unwrap();
        assert_eq!(state.session_path.as_deref(), Some("/home/user/.pi/sessions/abc"));
        assert_eq!(state.session_name.as_deref(), Some("my session"));
        assert!(state.extra.contains_key("some_unknown_field"));
    }

    #[test]
    fn serialize_all_simple_commands() {
        // Verify all unit-variant commands serialize correctly
        let commands = vec![
            (PiCommand::Abort, "abort"),
            (PiCommand::NewSession, "new_session"),
            (PiCommand::GetState, "get_state"),
            (PiCommand::GetMessages, "get_messages"),
            (PiCommand::GetAvailableModels, "get_available_models"),
            (PiCommand::Compact, "compact"),
            (PiCommand::GetCommands, "get_commands"),
        ];
        for (cmd, expected_type) in commands {
            let json = serde_json::to_string(&cmd).unwrap();
            let v: serde_json::Value = serde_json::from_str(&json).unwrap();
            assert_eq!(v["type"], expected_type, "failed for {expected_type}");
        }
    }
}
