//! Conversation restoration / thread hydration.
//!
//! Converts upstream `Vec<Turn>` (from `thread/resume`, `thread/fork`, etc.)
//! into `Vec<ConversationItem>` — a flat, UI-ready model that both iOS and
//! Android can decode from JSON without platform-specific mapping logic.

use std::path::PathBuf;

use crate::types::generated::MessagePhase;
use codex_app_server_protocol::{
    CollabAgentStatus, CollabAgentTool, CollabAgentToolCallStatus, CommandAction,
    CommandExecutionStatus, DynamicToolCallOutputContentItem, DynamicToolCallStatus,
    FileUpdateChange, McpToolCallStatus, PatchApplyStatus, PatchChangeKind, ThreadItem, Turn,
    UserInput,
};
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Output types — serialised to JSON for Swift / Kotlin decoding
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConversationItem {
    pub id: String,
    pub content: ConversationItemContent,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_turn_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_turn_index: Option<usize>,
    /// Seconds since Unix epoch. Populated from turn metadata when available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<f64>,
    #[serde(default)]
    pub is_from_user_turn_boundary: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ConversationItemContent {
    User(UserMessageData),
    Assistant(AssistantMessageData),
    Reasoning(ReasoningData),
    TodoList(TodoListData),
    ProposedPlan(ProposedPlanData),
    CommandExecution(CommandExecutionData),
    FileChange(FileChangeData),
    TurnDiff(TurnDiffData),
    McpToolCall(McpToolCallData),
    DynamicToolCall(DynamicToolCallData),
    MultiAgentAction(MultiAgentActionData),
    WebSearch(WebSearchData),
    Widget(WidgetData),
    UserInputResponse(UserInputResponseData),
    Divider(DividerData),
    Error(ErrorData),
    Note(NoteData),
}

// -- Leaf data types --------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UserMessageData {
    pub text: String,
    /// Base64 data-URI images extracted from the user content.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub image_data_uris: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AssistantMessageData {
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_nickname: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_role: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub phase: Option<MessagePhase>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ReasoningData {
    pub summary: Vec<String>,
    pub content: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TodoListData {
    pub steps: Vec<PlanStep>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PlanStep {
    pub step: String,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProposedPlanData {
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CommandExecutionData {
    pub command: String,
    pub cwd: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process_id: Option<String>,
    pub actions: Vec<CommandActionData>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CommandActionData {
    pub kind: String,
    pub command: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FileChangeEntryData {
    pub path: String,
    pub kind: String,
    pub diff: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FileChangeData {
    pub status: String,
    pub changes: Vec<FileChangeEntryData>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TurnDiffData {
    pub diff: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct McpToolCallData {
    pub server: String,
    pub tool: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub arguments_json: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content_summary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub structured_content_json: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub raw_output_json: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub progress_messages: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DynamicToolCallData {
    pub tool: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub success: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub arguments_json: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content_summary: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MultiAgentStateData {
    pub target_id: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MultiAgentActionData {
    pub tool: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    pub targets: Vec<String>,
    pub receiver_thread_ids: Vec<String>,
    pub agent_states: Vec<MultiAgentStateData>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WebSearchData {
    pub query: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action_json: Option<String>,
    pub is_in_progress: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WidgetData {
    pub title: String,
    pub widget_html: String,
    pub width: f64,
    pub height: f64,
    pub status: String,
    pub is_finalized: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UserInputResponseOptionData {
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UserInputResponseQuestionData {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    pub question: String,
    pub answer: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<UserInputResponseOptionData>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UserInputResponseData {
    pub questions: Vec<UserInputResponseQuestionData>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DividerData {
    ContextCompaction {
        is_complete: bool,
    },
    ModelRerouted {
        from_model: Option<String>,
        to_model: String,
        reason: Option<String>,
    },
    ReviewEntered {
        review: String,
    },
    ReviewExited {
        review: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NoteData {
    pub title: String,
    pub body: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ErrorData {
    pub title: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
}

// ---------------------------------------------------------------------------
// Conversion options
// ---------------------------------------------------------------------------

/// Optional metadata passed by the caller to enrich agent attribution.
#[derive(Debug, Clone, Default)]
pub struct HydrationOptions {
    pub default_agent_nickname: Option<String>,
    pub default_agent_role: Option<String>,
}

// ---------------------------------------------------------------------------
// Core conversion: Vec<Turn> -> Vec<ConversationItem>
// ---------------------------------------------------------------------------

/// Convert a list of upstream [`Turn`] values into a flat list of
/// [`ConversationItem`] suitable for UI rendering.
///
/// This is the Rust equivalent of `ServerManager.restoredMessages(from:)`.
pub fn hydrate_turns(turns: &[Turn], opts: &HydrationOptions) -> Vec<ConversationItem> {
    let mut items = Vec::with_capacity(turns.len() * 3);
    for (turn_index, turn) in turns.iter().enumerate() {
        for thread_item in &turn.items {
            if let Some(conv) =
                hydrate_thread_item(thread_item, Some(&turn.id), Some(turn_index), opts)
            {
                items.push(conv);
            }
        }
    }
    items
}

/// Convert a single upstream [`ThreadItem`] into a hydrated [`ConversationItem`].
///
/// This is used for live `item/started` / `item/completed` notifications where
/// the UI receives one item at a time instead of a full turn transcript.
pub fn hydrate_thread_item(
    item: &ThreadItem,
    source_turn_id: Option<&str>,
    source_turn_index: Option<usize>,
    opts: &HydrationOptions,
) -> Option<ConversationItem> {
    convert_thread_item(item, item.id(), source_turn_id, source_turn_index, opts)
}

fn hydrate_message_phase(
    phase: Option<codex_protocol::models::MessagePhase>,
) -> Option<MessagePhase> {
    phase.map(|phase| match phase {
        codex_protocol::models::MessagePhase::Commentary => MessagePhase::Commentary,
        codex_protocol::models::MessagePhase::FinalAnswer => MessagePhase::FinalAnswer,
    })
}

/// Convert a single [`ThreadItem`] into a [`ConversationItem`].
///
/// Returns `None` for items that should be suppressed (empty text, etc.).
/// This is the Rust equivalent of `ServerManager.conversationItem(from:)`.
fn convert_thread_item(
    item: &ThreadItem,
    item_id: &str,
    source_turn_id: Option<&str>,
    source_turn_index: Option<usize>,
    opts: &HydrationOptions,
) -> Option<ConversationItem> {
    let (content, is_boundary) = match item {
        ThreadItem::UserMessage { content, .. } => {
            let (text, images) = render_user_input(content);
            if text.is_empty() && images.is_empty() {
                return None;
            }
            (
                ConversationItemContent::User(UserMessageData {
                    text,
                    image_data_uris: images,
                }),
                true,
            )
        }
        ThreadItem::AgentMessage { text, phase, .. } => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return None;
            }
            (
                ConversationItemContent::Assistant(AssistantMessageData {
                    text: trimmed.to_string(),
                    agent_nickname: opts.default_agent_nickname.clone(),
                    agent_role: opts.default_agent_role.clone(),
                    phase: hydrate_message_phase(phase.clone()),
                }),
                false,
            )
        }
        ThreadItem::Plan { text, .. } => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return None;
            }
            (
                ConversationItemContent::ProposedPlan(ProposedPlanData {
                    content: trimmed.to_string(),
                }),
                false,
            )
        }
        ThreadItem::Reasoning {
            summary, content, ..
        } => (
            ConversationItemContent::Reasoning(ReasoningData {
                summary: summary.clone(),
                content: content.clone(),
            }),
            false,
        ),
        ThreadItem::CommandExecution {
            command,
            cwd,
            status,
            command_actions,
            aggregated_output,
            exit_code,
            duration_ms,
            process_id,
            ..
        } => {
            let actions = command_actions.iter().map(convert_command_action).collect();
            (
                ConversationItemContent::CommandExecution(CommandExecutionData {
                    command: command.clone(),
                    cwd: cwd.display().to_string(),
                    status: format_command_status(status),
                    output: aggregated_output.clone(),
                    exit_code: *exit_code,
                    duration_ms: *duration_ms,
                    process_id: process_id.clone(),
                    actions,
                }),
                false,
            )
        }
        ThreadItem::FileChange {
            changes, status, ..
        } => (
            ConversationItemContent::FileChange(FileChangeData {
                status: format_patch_status(status),
                changes: changes.iter().map(convert_file_change).collect(),
            }),
            false,
        ),
        ThreadItem::McpToolCall {
            server,
            tool,
            status,
            arguments,
            result,
            error,
            duration_ms,
            ..
        } => {
            let raw_output_json = result.as_ref().and_then(|r| {
                let obj = serde_json::json!({
                    "content": r.content,
                    "structuredContent": r.structured_content,
                });
                pretty_json(&obj)
            });
            let content_summary = result.as_ref().map(|r| {
                r.content
                    .iter()
                    .map(|v| stringify_json_value(v))
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join("\n")
            });
            let structured_json = result
                .as_ref()
                .and_then(|r| r.structured_content.as_ref())
                .and_then(pretty_json);
            (
                ConversationItemContent::McpToolCall(McpToolCallData {
                    server: server.clone(),
                    tool: tool.clone(),
                    status: format_mcp_status(status),
                    duration_ms: *duration_ms,
                    arguments_json: pretty_json(arguments),
                    content_summary,
                    structured_content_json: structured_json,
                    raw_output_json,
                    error_message: error.as_ref().map(|e| e.message.clone()),
                    progress_messages: Vec::new(),
                }),
                false,
            )
        }
        ThreadItem::DynamicToolCall {
            tool,
            arguments,
            status,
            content_items,
            success,
            duration_ms,
            ..
        } => {
            if let Some(widget) = widget_data_from_dynamic_tool_call(
                tool,
                arguments,
                status,
                content_items.as_deref(),
            ) {
                return Some(ConversationItem {
                    id: item_id.to_string(),
                    content: ConversationItemContent::Widget(widget),
                    source_turn_id: source_turn_id.map(String::from),
                    source_turn_index,
                    timestamp: None,
                    is_from_user_turn_boundary: false,
                });
            }
            let content_summary = content_items.as_ref().map(|items| {
                items
                    .iter()
                    .map(|item| match item {
                        DynamicToolCallOutputContentItem::InputText { text } => text.clone(),
                        DynamicToolCallOutputContentItem::InputImage { image_url } => {
                            format!("[image: {}]", image_url)
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("\n")
            });
            (
                ConversationItemContent::DynamicToolCall(DynamicToolCallData {
                    tool: tool.clone(),
                    status: format_dynamic_status(status),
                    duration_ms: *duration_ms,
                    success: *success,
                    arguments_json: pretty_json(arguments),
                    content_summary,
                }),
                false,
            )
        }
        ThreadItem::CollabAgentToolCall {
            tool,
            status,
            receiver_thread_ids,
            prompt,
            agents_states,
            ..
        } => {
            // Build target labels from receiver thread IDs (simplified — no directory lookup).
            let targets: Vec<String> = receiver_thread_ids.clone();
            let mut states: Vec<MultiAgentStateData> = agents_states
                .iter()
                .map(|(key, value)| MultiAgentStateData {
                    target_id: key.clone(),
                    status: format_collab_agent_status(&value.status),
                    message: value.message.clone(),
                })
                .collect();
            states.sort_by(|a, b| a.target_id.cmp(&b.target_id));
            (
                ConversationItemContent::MultiAgentAction(MultiAgentActionData {
                    tool: format_collab_tool(tool),
                    status: format_collab_status(status),
                    prompt: prompt.clone(),
                    targets,
                    receiver_thread_ids: receiver_thread_ids.clone(),
                    agent_states: states,
                }),
                false,
            )
        }
        ThreadItem::WebSearch { query, action, .. } => {
            let action_json = action
                .as_ref()
                .and_then(|a| serde_json::to_value(a).ok().and_then(|v| pretty_json(&v)));
            (
                ConversationItemContent::WebSearch(WebSearchData {
                    query: query.clone(),
                    action_json,
                    is_in_progress: false,
                }),
                false,
            )
        }
        ThreadItem::ImageView { path, .. } => (
            ConversationItemContent::Note(NoteData {
                title: "Image View".to_string(),
                body: format!("Path: {path}"),
            }),
            false,
        ),
        ThreadItem::ImageGeneration {
            status,
            revised_prompt,
            result,
            ..
        } => {
            let body = if let Some(prompt) = revised_prompt {
                format!("Status: {status}\nPrompt: {prompt}\nResult: {result}")
            } else {
                format!("Status: {status}\nResult: {result}")
            };
            (
                ConversationItemContent::Note(NoteData {
                    title: "Image Generation".to_string(),
                    body,
                }),
                false,
            )
        }
        ThreadItem::EnteredReviewMode { review, .. } => (
            ConversationItemContent::Divider(DividerData::ReviewEntered {
                review: review.clone(),
            }),
            false,
        ),
        ThreadItem::ExitedReviewMode { review, .. } => (
            ConversationItemContent::Divider(DividerData::ReviewExited {
                review: review.clone(),
            }),
            false,
        ),
        ThreadItem::ContextCompaction { .. } => (
            ConversationItemContent::Divider(DividerData::ContextCompaction { is_complete: true }),
            false,
        ),
        ThreadItem::HookPrompt { .. } => return None,
    };

    Some(ConversationItem {
        id: item_id.to_string(),
        content,
        source_turn_id: source_turn_id.map(String::from),
        source_turn_index,
        timestamp: None,
        is_from_user_turn_boundary: is_boundary,
    })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Extract plain text and image data-URIs from user input content.
fn render_user_input(inputs: &[UserInput]) -> (String, Vec<String>) {
    let mut text_parts = Vec::new();
    let mut images = Vec::new();
    for input in inputs {
        match input {
            UserInput::Text { text, .. } => {
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    text_parts.push(trimmed.to_string());
                }
            }
            UserInput::Image { url } => {
                images.push(url.clone());
            }
            UserInput::LocalImage { path } => {
                images.push(format!("file://{}", path.display()));
            }
            UserInput::Skill { name, path } => {
                if !name.is_empty() && path != &PathBuf::new() {
                    text_parts.push(format!("[Skill] {} ({})", name, path.display()));
                } else if !name.is_empty() {
                    text_parts.push(format!("[Skill] {name}"));
                } else if path != &PathBuf::new() {
                    text_parts.push(format!("[Skill] {}", path.display()));
                }
            }
            UserInput::Mention { name, path } => {
                if !name.is_empty() && !path.is_empty() {
                    text_parts.push(format!("[Mention] {name} ({path})"));
                } else if !name.is_empty() {
                    text_parts.push(format!("[Mention] {name}"));
                } else if !path.is_empty() {
                    text_parts.push(format!("[Mention] {path}"));
                }
            }
        }
    }
    (text_parts.join("\n"), images)
}

fn widget_data_from_dynamic_tool_call(
    tool: &str,
    arguments: &serde_json::Value,
    status: &DynamicToolCallStatus,
    content_items: Option<&[DynamicToolCallOutputContentItem]>,
) -> Option<WidgetData> {
    if !tool.eq_ignore_ascii_case("show_widget") {
        return None;
    }

    let status_label = format_dynamic_status(status);
    let is_finalized = !matches!(status, DynamicToolCallStatus::InProgress);
    let object = arguments.as_object()?;
    let widget_html = object
        .get("widget_code")
        .or_else(|| object.get("widgetCode"))
        .and_then(|value| value.as_str())
        .map(ToString::to_string)
        .or_else(|| {
            content_items.and_then(|items| {
                items.iter().find_map(|item| match item {
                    DynamicToolCallOutputContentItem::InputText { text } => Some(text.clone()),
                    DynamicToolCallOutputContentItem::InputImage { .. } => None,
                })
            })
        })?;
    let title = object
        .get("title")
        .and_then(|value| value.as_str())
        .unwrap_or("Widget")
        .to_string();
    let width = json_number_field(object, &["width"]).unwrap_or(800.0);
    let height = json_number_field(object, &["height"]).unwrap_or(600.0);

    Some(WidgetData {
        title,
        widget_html,
        width,
        height,
        status: status_label,
        is_finalized,
    })
}

fn json_number_field(
    object: &serde_json::Map<String, serde_json::Value>,
    keys: &[&str],
) -> Option<f64> {
    keys.iter().find_map(|key| {
        object.get(*key).and_then(|value| match value {
            serde_json::Value::Number(number) => number.as_f64(),
            serde_json::Value::String(text) => text.parse::<f64>().ok(),
            _ => None,
        })
    })
}

fn convert_command_action(action: &CommandAction) -> CommandActionData {
    match action {
        CommandAction::Read {
            command,
            name,
            path,
        } => CommandActionData {
            kind: "read".to_string(),
            command: command.clone(),
            name: Some(name.clone()),
            path: Some(path.display().to_string()),
            query: None,
        },
        CommandAction::Search {
            command,
            query,
            path,
        } => CommandActionData {
            kind: "search".to_string(),
            command: command.clone(),
            name: None,
            path: path.clone(),
            query: query.clone(),
        },
        CommandAction::ListFiles { command, path } => CommandActionData {
            kind: "listFiles".to_string(),
            command: command.clone(),
            name: None,
            path: path.clone(),
            query: None,
        },
        CommandAction::Unknown { command } => CommandActionData {
            kind: "unknown".to_string(),
            command: command.clone(),
            name: None,
            path: None,
            query: None,
        },
    }
}

pub fn make_turn_diff_item(
    turn_id: &str,
    diff: String,
    source_turn_id: Option<&str>,
) -> ConversationItem {
    ConversationItem {
        id: format!("turn-diff-{turn_id}"),
        content: ConversationItemContent::TurnDiff(TurnDiffData { diff }),
        source_turn_id: source_turn_id
            .map(String::from)
            .or_else(|| Some(turn_id.to_string())),
        source_turn_index: None,
        timestamp: None,
        is_from_user_turn_boundary: false,
    }
}

pub fn make_model_rerouted_item(
    turn_id: &str,
    from_model: Option<String>,
    to_model: String,
    reason: Option<String>,
    source_turn_id: Option<&str>,
) -> ConversationItem {
    ConversationItem {
        id: format!("model-rerouted-{turn_id}"),
        content: ConversationItemContent::Divider(DividerData::ModelRerouted {
            from_model,
            to_model,
            reason,
        }),
        source_turn_id: source_turn_id
            .map(String::from)
            .or_else(|| Some(turn_id.to_string())),
        source_turn_index: None,
        timestamp: None,
        is_from_user_turn_boundary: false,
    }
}

pub fn make_error_item(id: String, message: String, code: Option<i64>) -> ConversationItem {
    ConversationItem {
        id,
        content: ConversationItemContent::Error(ErrorData {
            title: "Error".to_string(),
            message,
            details: code.map(|value| format!("Code: {value}")),
        }),
        source_turn_id: None,
        source_turn_index: None,
        timestamp: None,
        is_from_user_turn_boundary: false,
    }
}

fn convert_file_change(change: &FileUpdateChange) -> FileChangeEntryData {
    let kind = match &change.kind {
        PatchChangeKind::Add => "add",
        PatchChangeKind::Delete => "delete",
        PatchChangeKind::Update { .. } => "update",
    };
    FileChangeEntryData {
        path: change.path.clone(),
        kind: kind.to_string(),
        diff: change.diff.clone(),
    }
}

fn format_command_status(status: &CommandExecutionStatus) -> String {
    match status {
        CommandExecutionStatus::InProgress => "inProgress".to_string(),
        CommandExecutionStatus::Completed => "completed".to_string(),
        CommandExecutionStatus::Failed => "failed".to_string(),
        CommandExecutionStatus::Declined => "declined".to_string(),
    }
}

fn format_patch_status(status: &PatchApplyStatus) -> String {
    match status {
        PatchApplyStatus::InProgress => "inProgress".to_string(),
        PatchApplyStatus::Completed => "completed".to_string(),
        PatchApplyStatus::Failed => "failed".to_string(),
        PatchApplyStatus::Declined => "declined".to_string(),
    }
}

fn format_mcp_status(status: &McpToolCallStatus) -> String {
    match status {
        McpToolCallStatus::InProgress => "inProgress".to_string(),
        McpToolCallStatus::Completed => "completed".to_string(),
        McpToolCallStatus::Failed => "failed".to_string(),
    }
}

fn format_dynamic_status(status: &DynamicToolCallStatus) -> String {
    match status {
        DynamicToolCallStatus::InProgress => "inProgress".to_string(),
        DynamicToolCallStatus::Completed => "completed".to_string(),
        DynamicToolCallStatus::Failed => "failed".to_string(),
    }
}

fn format_collab_tool(tool: &CollabAgentTool) -> String {
    match tool {
        CollabAgentTool::SpawnAgent => "spawnAgent".to_string(),
        CollabAgentTool::SendInput => "sendInput".to_string(),
        CollabAgentTool::ResumeAgent => "resumeAgent".to_string(),
        CollabAgentTool::Wait => "wait".to_string(),
        CollabAgentTool::CloseAgent => "closeAgent".to_string(),
    }
}

fn format_collab_status(status: &CollabAgentToolCallStatus) -> String {
    match status {
        CollabAgentToolCallStatus::InProgress => "inProgress".to_string(),
        CollabAgentToolCallStatus::Completed => "completed".to_string(),
        CollabAgentToolCallStatus::Failed => "failed".to_string(),
    }
}

fn format_collab_agent_status(status: &CollabAgentStatus) -> String {
    match status {
        CollabAgentStatus::PendingInit => "pendingInit".to_string(),
        CollabAgentStatus::Running => "running".to_string(),
        CollabAgentStatus::Interrupted => "interrupted".to_string(),
        CollabAgentStatus::Completed => "completed".to_string(),
        CollabAgentStatus::Errored => "errored".to_string(),
        CollabAgentStatus::Shutdown => "shutdown".to_string(),
        CollabAgentStatus::NotFound => "notFound".to_string(),
    }
}

fn pretty_json(value: &impl Serialize) -> Option<String> {
    let s = serde_json::to_string_pretty(value).ok()?;
    if s == "null" {
        return None;
    }
    Some(s.trim_end_matches('\n').to_string())
}

fn stringify_json_value(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(s) => s.trim().to_string(),
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::Bool(b) => b.to_string(),
        serde_json::Value::Null => String::new(),
        other => serde_json::to_string_pretty(other)
            .unwrap_or_default()
            .trim()
            .to_string(),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use codex_app_server_protocol::TurnStatus;
    use std::collections::HashMap;

    fn make_turn(id: &str, items: Vec<ThreadItem>) -> Turn {
        Turn {
            id: id.to_string(),
            items,
            status: TurnStatus::Completed,
            error: None,
        }
    }

    #[test]
    fn test_user_message_text() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::UserMessage {
                id: "u1".into(),
                content: vec![UserInput::Text {
                    text: "  Hello world  ".into(),
                    text_elements: vec![],
                }],
            }],
        )];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "u1");
        assert!(items[0].is_from_user_turn_boundary);
        match &items[0].content {
            ConversationItemContent::User(data) => {
                assert_eq!(data.text, "Hello world");
                assert!(data.image_data_uris.is_empty());
            }
            _ => panic!("expected User content"),
        }
    }

    #[test]
    fn test_empty_user_message_skipped() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::UserMessage {
                id: "u1".into(),
                content: vec![UserInput::Text {
                    text: "   ".into(),
                    text_elements: vec![],
                }],
            }],
        )];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert!(items.is_empty());
    }

    #[test]
    fn test_agent_message() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::AgentMessage {
                id: "a1".into(),
                text: " Response text ".into(),
                phase: None,
                memory_citation: None,
            }],
        )];
        let opts = HydrationOptions {
            default_agent_nickname: Some("bob".into()),
            default_agent_role: Some("coder".into()),
        };
        let items = hydrate_turns(&turns, &opts);
        assert_eq!(items.len(), 1);
        assert!(!items[0].is_from_user_turn_boundary);
        match &items[0].content {
            ConversationItemContent::Assistant(data) => {
                assert_eq!(data.text, "Response text");
                assert_eq!(data.agent_nickname.as_deref(), Some("bob"));
                assert_eq!(data.agent_role.as_deref(), Some("coder"));
                assert_eq!(data.phase, None);
            }
            _ => panic!("expected Assistant content"),
        }
    }

    #[test]
    fn test_empty_agent_message_skipped() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::AgentMessage {
                id: "a1".into(),
                text: "  \n  ".into(),
                phase: None,
                memory_citation: None,
            }],
        )];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert!(items.is_empty());
    }

    #[test]
    fn test_reasoning() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::Reasoning {
                id: "r1".into(),
                summary: vec!["Thinking...".into()],
                content: vec!["detailed reasoning".into()],
            }],
        )];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        match &items[0].content {
            ConversationItemContent::Reasoning(data) => {
                assert_eq!(data.summary, vec!["Thinking..."]);
                assert_eq!(data.content, vec!["detailed reasoning"]);
            }
            _ => panic!("expected Reasoning content"),
        }
    }

    #[test]
    fn test_command_execution() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::CommandExecution {
                id: "c1".into(),
                command: "ls -la".into(),
                cwd: PathBuf::from("/tmp"),
                process_id: Some("p1".into()),
                source: Default::default(),
                status: CommandExecutionStatus::Completed,
                command_actions: vec![CommandAction::Read {
                    command: "cat foo.rs".into(),
                    name: "foo.rs".into(),
                    path: PathBuf::from("/src/foo.rs"),
                }],
                aggregated_output: Some("file contents".into()),
                exit_code: Some(0),
                duration_ms: Some(123),
            }],
        )];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        match &items[0].content {
            ConversationItemContent::CommandExecution(data) => {
                assert_eq!(data.command, "ls -la");
                assert_eq!(data.cwd, "/tmp");
                assert_eq!(data.status, "completed");
                assert_eq!(data.exit_code, Some(0));
                assert_eq!(data.actions.len(), 1);
                assert_eq!(data.actions[0].kind, "read");
            }
            _ => panic!("expected CommandExecution content"),
        }
    }

    #[test]
    fn test_context_compaction() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::ContextCompaction { id: "cc1".into() }],
        )];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        match &items[0].content {
            ConversationItemContent::Divider(DividerData::ContextCompaction { is_complete }) => {
                assert!(*is_complete);
            }
            _ => panic!("expected ContextCompaction divider"),
        }
    }

    #[test]
    fn test_review_mode() {
        let turns = vec![make_turn(
            "t1",
            vec![
                ThreadItem::EnteredReviewMode {
                    id: "er1".into(),
                    review: "safety".into(),
                },
                ThreadItem::ExitedReviewMode {
                    id: "xr1".into(),
                    review: "safety".into(),
                },
            ],
        )];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 2);
        match &items[0].content {
            ConversationItemContent::Divider(DividerData::ReviewEntered { review }) => {
                assert_eq!(review, "safety");
            }
            _ => panic!("expected ReviewEntered divider"),
        }
        match &items[1].content {
            ConversationItemContent::Divider(DividerData::ReviewExited { review }) => {
                assert_eq!(review, "safety");
            }
            _ => panic!("expected ReviewExited divider"),
        }
    }

    #[test]
    fn test_multi_turn_indexing() {
        let turns = vec![
            make_turn(
                "t1",
                vec![ThreadItem::UserMessage {
                    id: "u1".into(),
                    content: vec![UserInput::Text {
                        text: "Hello".into(),
                        text_elements: vec![],
                    }],
                }],
            ),
            make_turn(
                "t2",
                vec![ThreadItem::AgentMessage {
                    id: "a1".into(),
                    text: "World".into(),
                    phase: None,
                    memory_citation: None,
                }],
            ),
        ];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].source_turn_id.as_deref(), Some("t1"));
        assert_eq!(items[0].source_turn_index, Some(0));
        assert_eq!(items[1].source_turn_id.as_deref(), Some("t2"));
        assert_eq!(items[1].source_turn_index, Some(1));
    }

    #[test]
    fn test_image_view() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::ImageView {
                id: "iv1".into(),
                path: "/tmp/img.png".into(),
            }],
        )];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        match &items[0].content {
            ConversationItemContent::Note(data) => {
                assert_eq!(data.title, "Image View");
                assert!(data.body.contains("/tmp/img.png"));
            }
            _ => panic!("expected Note content"),
        }
    }

    #[test]
    fn test_plan() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::Plan {
                id: "p1".into(),
                text: "  Build the thing  ".into(),
            }],
        )];
        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        match &items[0].content {
            ConversationItemContent::ProposedPlan(data) => {
                assert_eq!(data.content, "Build the thing");
            }
            _ => panic!("expected ProposedPlan content"),
        }
    }

    #[test]
    fn test_serialization_roundtrip() {
        let item = ConversationItem {
            id: "test-1".into(),
            content: ConversationItemContent::Assistant(AssistantMessageData {
                text: "Hello".into(),
                agent_nickname: None,
                agent_role: None,
                phase: Some(MessagePhase::Commentary),
            }),
            source_turn_id: Some("t1".into()),
            source_turn_index: Some(0),
            timestamp: Some(1234567890.0),
            is_from_user_turn_boundary: false,
        };
        let json = serde_json::to_string(&item).unwrap();
        let decoded: ConversationItem = serde_json::from_str(&json).unwrap();
        assert_eq!(item, decoded);
    }

    #[test]
    fn test_tool_and_subagent_items_hydrate() {
        let mut agent_states = HashMap::new();
        agent_states.insert(
            "sub-thread-1".to_string(),
            codex_app_server_protocol::CollabAgentState {
                status: CollabAgentStatus::Running,
                message: Some("Working".into()),
            },
        );

        let turns = vec![make_turn(
            "t-tools",
            vec![
                ThreadItem::McpToolCall {
                    id: "mcp-1".into(),
                    server: "filesystem".into(),
                    tool: "read_file".into(),
                    status: McpToolCallStatus::Completed,
                    arguments: serde_json::json!({ "path": "/tmp/file.txt" }),
                    result: Some(codex_app_server_protocol::McpToolCallResult {
                        content: vec![serde_json::json!("contents")],
                        structured_content: None,
                    }),
                    error: None,
                    duration_ms: Some(250),
                },
                ThreadItem::DynamicToolCall {
                    id: "dyn-1".into(),
                    tool: "show_widget".into(),
                    arguments: serde_json::json!({
                        "title": "Widget",
                        "widget_code": "<svg></svg>",
                        "width": 640,
                        "height": 360
                    }),
                    status: DynamicToolCallStatus::Completed,
                    content_items: Some(vec![DynamicToolCallOutputContentItem::InputText {
                        text: "rendered".into(),
                    }]),
                    success: Some(true),
                    duration_ms: Some(120),
                },
                ThreadItem::CollabAgentToolCall {
                    id: "collab-1".into(),
                    tool: CollabAgentTool::SpawnAgent,
                    status: CollabAgentToolCallStatus::Completed,
                    sender_thread_id: "parent-thread".into(),
                    receiver_thread_ids: vec!["sub-thread-1".into()],
                    prompt: Some("Review the changes".into()),
                    model: None,
                    reasoning_effort: None,
                    agents_states: agent_states,
                },
                ThreadItem::WebSearch {
                    id: "web-1".into(),
                    query: "swiftui subagent cards".into(),
                    action: None,
                },
            ],
        )];

        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 4);

        assert!(matches!(
            items[0].content,
            ConversationItemContent::McpToolCall(_)
        ));
        assert!(matches!(
            items[1].content,
            ConversationItemContent::Widget(_)
        ));
        assert!(matches!(
            items[2].content,
            ConversationItemContent::MultiAgentAction(_)
        ));
        assert!(matches!(
            items[3].content,
            ConversationItemContent::WebSearch(_)
        ));
    }
}
