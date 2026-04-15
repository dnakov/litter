//! Conversation restoration / thread hydration.
//!
//! Converts upstream `Vec<Turn>` (from `thread/resume`, `thread/fork`, etc.)
//! into `Vec<HydratedConversationItem>` — a flat, UI-ready model that both
//! iOS and Android render directly via UniFFI.

use std::path::Path;
use std::path::PathBuf;

use crate::conversation_uniffi::*;
use crate::parser::{
    parse_code_review_message, CodeReviewCodeLocation, CodeReviewFinding, CodeReviewLineRange,
    CodeReviewPayload,
};
use crate::types::{AppMessagePhase, AppOperationStatus, AppSubagentStatus};
use codex_app_server_protocol::{
    CollabAgentStatus, CollabAgentTool, CollabAgentToolCallStatus, CommandAction,
    CommandExecutionStatus, DynamicToolCallOutputContentItem, DynamicToolCallStatus,
    FileUpdateChange, McpToolCallStatus, PatchApplyStatus, PatchChangeKind, ThreadItem, Turn,
    UserInput,
};
use codex_shell_command::parse_command::extract_shell_command;
use serde::Serialize;

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
// Core conversion: Vec<Turn> -> Vec<HydratedConversationItem>
// ---------------------------------------------------------------------------

/// Convert a list of upstream [`Turn`] values into a flat list of
/// [`HydratedConversationItem`] suitable for UI rendering.
pub fn hydrate_turns(turns: &[Turn], opts: &HydrationOptions) -> Vec<HydratedConversationItem> {
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

/// Convert a single upstream [`ThreadItem`] into a [`HydratedConversationItem`].
pub fn hydrate_thread_item(
    item: &ThreadItem,
    source_turn_id: Option<&str>,
    source_turn_index: Option<usize>,
    opts: &HydrationOptions,
) -> Option<HydratedConversationItem> {
    convert_thread_item(item, item.id(), source_turn_id, source_turn_index, opts)
}

fn hydrate_message_phase(
    phase: Option<codex_protocol::models::MessagePhase>,
) -> Option<AppMessagePhase> {
    phase.map(|phase| match phase {
        codex_protocol::models::MessagePhase::Commentary => AppMessagePhase::Commentary,
        codex_protocol::models::MessagePhase::FinalAnswer => AppMessagePhase::FinalAnswer,
    })
}

fn hydrate_code_review_line_range(range: &CodeReviewLineRange) -> HydratedCodeReviewLineRangeData {
    HydratedCodeReviewLineRangeData {
        start: range.start,
        end: range.end,
    }
}

fn hydrate_code_review_location(
    location: &CodeReviewCodeLocation,
) -> HydratedCodeReviewCodeLocationData {
    HydratedCodeReviewCodeLocationData {
        absolute_file_path: location.absolute_file_path.clone(),
        line_range: location
            .line_range
            .as_ref()
            .map(hydrate_code_review_line_range),
    }
}

fn hydrate_code_review_finding(finding: &CodeReviewFinding) -> HydratedCodeReviewFindingData {
    HydratedCodeReviewFindingData {
        title: finding.title.clone(),
        body: finding.body.clone(),
        confidence_score: finding.confidence_score,
        priority: finding.priority,
        code_location: finding
            .code_location
            .as_ref()
            .map(hydrate_code_review_location),
    }
}

fn hydrate_code_review_payload(review: &CodeReviewPayload) -> HydratedCodeReviewData {
    HydratedCodeReviewData {
        findings: review
            .findings
            .iter()
            .map(hydrate_code_review_finding)
            .collect(),
        overall_correctness: review.overall_correctness.clone(),
        overall_explanation: review.overall_explanation.clone(),
        overall_confidence_score: review.overall_confidence_score,
    }
}

fn display_command(command: &str) -> String {
    let trimmed = command.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    let Some(argv) = shlex::split(trimmed) else {
        return trimmed.to_string();
    };

    if let Some((_, script)) = extract_shell_command(&argv) {
        return script.trim().to_string();
    }

    if let Some(script) = extract_cmd_command(&argv) {
        return script.trim().to_string();
    }

    trimmed.to_string()
}

fn extract_cmd_command(command: &[String]) -> Option<&str> {
    let [shell, flag, script] = command else {
        return None;
    };

    if !flag.eq_ignore_ascii_case("/c") || !is_cmd_shell(shell) {
        return None;
    }

    Some(script.as_str())
}

fn is_cmd_shell(shell: &str) -> bool {
    Path::new(shell)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .is_some_and(|stem| stem.eq_ignore_ascii_case("cmd"))
}

fn convert_thread_item(
    item: &ThreadItem,
    item_id: &str,
    source_turn_id: Option<&str>,
    source_turn_index: Option<usize>,
    opts: &HydrationOptions,
) -> Option<HydratedConversationItem> {
    let (content, is_boundary) = match item {
        ThreadItem::UserMessage { content, .. } => {
            let (text, images) = render_user_input(content);
            if text.is_empty() && images.is_empty() {
                return None;
            }
            (
                HydratedConversationItemContent::User(HydratedUserMessageData {
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
            let content = if let Some(review) = parse_code_review_message(trimmed) {
                HydratedConversationItemContent::CodeReview(hydrate_code_review_payload(&review))
            } else {
                HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                    text: trimmed.to_string(),
                    agent_nickname: opts.default_agent_nickname.clone(),
                    agent_role: opts.default_agent_role.clone(),
                    phase: hydrate_message_phase(phase.clone()),
                })
            };
            (content, false)
        }
        ThreadItem::Plan { text, .. } => {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return None;
            }
            (
                HydratedConversationItemContent::ProposedPlan(HydratedProposedPlanData {
                    content: trimmed.to_string(),
                }),
                false,
            )
        }
        ThreadItem::Reasoning {
            summary, content, ..
        } => (
            HydratedConversationItemContent::Reasoning(HydratedReasoningData {
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
                HydratedConversationItemContent::CommandExecution(HydratedCommandExecutionData {
                    command: display_command(command),
                    cwd: cwd.display().to_string(),
                    status: convert_command_status(status),
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
            HydratedConversationItemContent::FileChange(HydratedFileChangeData {
                status: convert_patch_status(status),
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
                    .map(stringify_json_value)
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join("\n")
            });
            let structured_json = result
                .as_ref()
                .and_then(|r| r.structured_content.as_ref())
                .and_then(pretty_json);
            (
                HydratedConversationItemContent::McpToolCall(HydratedMcpToolCallData {
                    server: server.clone(),
                    tool: tool.clone(),
                    status: convert_mcp_status(status),
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
                return Some(HydratedConversationItem {
                    id: item_id.to_string(),
                    content: HydratedConversationItemContent::Widget(widget),
                    source_turn_id: source_turn_id.map(String::from),
                    source_turn_index: source_turn_index.map(|i| i as u32),
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
                HydratedConversationItemContent::DynamicToolCall(HydratedDynamicToolCallData {
                    tool: tool.clone(),
                    status: convert_dynamic_status(status),
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
            let targets: Vec<String> = receiver_thread_ids.clone();
            let mut states: Vec<HydratedMultiAgentStateData> = agents_states
                .iter()
                .map(|(key, value)| HydratedMultiAgentStateData {
                    target_id: key.clone(),
                    status: convert_collab_agent_status(&value.status),
                    message: value.message.clone(),
                })
                .collect();
            states.sort_by(|a, b| a.target_id.cmp(&b.target_id));
            (
                HydratedConversationItemContent::MultiAgentAction(HydratedMultiAgentActionData {
                    tool: convert_collab_tool(tool),
                    status: convert_collab_status(status),
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
                HydratedConversationItemContent::WebSearch(HydratedWebSearchData {
                    query: query.clone(),
                    action_json,
                    is_in_progress: false,
                }),
                false,
            )
        }
        ThreadItem::ImageView { path, .. } => (
            HydratedConversationItemContent::Note(HydratedNoteData {
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
                HydratedConversationItemContent::Note(HydratedNoteData {
                    title: "Image Generation".to_string(),
                    body,
                }),
                false,
            )
        }
        ThreadItem::EnteredReviewMode { review, .. } => (
            HydratedConversationItemContent::Divider(HydratedDividerData::ReviewEntered {
                review: review.clone(),
            }),
            false,
        ),
        ThreadItem::ExitedReviewMode { review, .. } => (
            HydratedConversationItemContent::Divider(HydratedDividerData::ReviewExited {
                review: review.clone(),
            }),
            false,
        ),
        ThreadItem::ContextCompaction { .. } => (
            HydratedConversationItemContent::Divider(HydratedDividerData::ContextCompaction {
                is_complete: true,
            }),
            false,
        ),
        ThreadItem::HookPrompt { .. } => return None,
    };

    Some(HydratedConversationItem {
        id: item_id.to_string(),
        content,
        source_turn_id: source_turn_id.map(String::from),
        source_turn_index: source_turn_index.map(|i| i as u32),
        timestamp: None,
        is_from_user_turn_boundary: is_boundary,
    })
}

// ---------------------------------------------------------------------------
// Public helpers for live item construction
// ---------------------------------------------------------------------------

pub fn make_turn_diff_item(
    turn_id: &str,
    diff: String,
    source_turn_id: Option<&str>,
) -> HydratedConversationItem {
    HydratedConversationItem {
        id: format!("turn-diff-{turn_id}"),
        content: HydratedConversationItemContent::TurnDiff(HydratedTurnDiffData { diff }),
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
) -> HydratedConversationItem {
    HydratedConversationItem {
        id: format!("model-rerouted-{turn_id}"),
        content: HydratedConversationItemContent::Divider(HydratedDividerData::ModelRerouted {
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

pub fn make_error_item(id: String, message: String, code: Option<i64>) -> HydratedConversationItem {
    HydratedConversationItem {
        id,
        content: HydratedConversationItemContent::Error(HydratedErrorData {
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

// ---------------------------------------------------------------------------
// Upstream enum → typed enum conversions (no string round-trip)
// ---------------------------------------------------------------------------

fn convert_command_status(status: &CommandExecutionStatus) -> AppOperationStatus {
    match status {
        CommandExecutionStatus::InProgress => AppOperationStatus::InProgress,
        CommandExecutionStatus::Completed => AppOperationStatus::Completed,
        CommandExecutionStatus::Failed => AppOperationStatus::Failed,
        CommandExecutionStatus::Declined => AppOperationStatus::Declined,
    }
}

fn convert_patch_status(status: &PatchApplyStatus) -> AppOperationStatus {
    match status {
        PatchApplyStatus::InProgress => AppOperationStatus::InProgress,
        PatchApplyStatus::Completed => AppOperationStatus::Completed,
        PatchApplyStatus::Failed => AppOperationStatus::Failed,
        PatchApplyStatus::Declined => AppOperationStatus::Declined,
    }
}

fn convert_mcp_status(status: &McpToolCallStatus) -> AppOperationStatus {
    match status {
        McpToolCallStatus::InProgress => AppOperationStatus::InProgress,
        McpToolCallStatus::Completed => AppOperationStatus::Completed,
        McpToolCallStatus::Failed => AppOperationStatus::Failed,
    }
}

fn convert_dynamic_status(status: &DynamicToolCallStatus) -> AppOperationStatus {
    match status {
        DynamicToolCallStatus::InProgress => AppOperationStatus::InProgress,
        DynamicToolCallStatus::Completed => AppOperationStatus::Completed,
        DynamicToolCallStatus::Failed => AppOperationStatus::Failed,
    }
}

fn convert_collab_tool(tool: &CollabAgentTool) -> String {
    match tool {
        CollabAgentTool::SpawnAgent => "spawnAgent".to_string(),
        CollabAgentTool::SendInput => "sendInput".to_string(),
        CollabAgentTool::ResumeAgent => "resumeAgent".to_string(),
        CollabAgentTool::Wait => "wait".to_string(),
        CollabAgentTool::CloseAgent => "closeAgent".to_string(),
    }
}

fn convert_collab_status(status: &CollabAgentToolCallStatus) -> AppOperationStatus {
    match status {
        CollabAgentToolCallStatus::InProgress => AppOperationStatus::InProgress,
        CollabAgentToolCallStatus::Completed => AppOperationStatus::Completed,
        CollabAgentToolCallStatus::Failed => AppOperationStatus::Failed,
    }
}

fn convert_collab_agent_status(status: &CollabAgentStatus) -> AppSubagentStatus {
    match status {
        CollabAgentStatus::PendingInit => AppSubagentStatus::PendingInit,
        CollabAgentStatus::Running => AppSubagentStatus::Running,
        CollabAgentStatus::Interrupted => AppSubagentStatus::Interrupted,
        CollabAgentStatus::Completed => AppSubagentStatus::Completed,
        CollabAgentStatus::Errored => AppSubagentStatus::Errored,
        CollabAgentStatus::Shutdown => AppSubagentStatus::Shutdown,
        CollabAgentStatus::NotFound => AppSubagentStatus::Unknown,
    }
}

fn convert_command_action(action: &CommandAction) -> HydratedCommandActionData {
    match action {
        CommandAction::Read {
            command,
            name,
            path,
        } => HydratedCommandActionData {
            kind: HydratedCommandActionKind::Read,
            command: command.clone(),
            name: Some(name.clone()),
            path: Some(path.display().to_string()),
            query: None,
        },
        CommandAction::Search {
            command,
            query,
            path,
        } => HydratedCommandActionData {
            kind: HydratedCommandActionKind::Search,
            command: command.clone(),
            name: None,
            path: path.clone(),
            query: query.clone(),
        },
        CommandAction::ListFiles { command, path } => HydratedCommandActionData {
            kind: HydratedCommandActionKind::ListFiles,
            command: command.clone(),
            name: None,
            path: path.clone(),
            query: None,
        },
        CommandAction::Unknown { command } => HydratedCommandActionData {
            kind: HydratedCommandActionKind::Unknown,
            command: command.clone(),
            name: None,
            path: None,
            query: None,
        },
    }
}

fn convert_file_change(change: &FileUpdateChange) -> HydratedFileChangeEntryData {
    let (additions, deletions) = diff_stats(&change.diff);
    let kind = match &change.kind {
        PatchChangeKind::Add => "add",
        PatchChangeKind::Delete => "delete",
        PatchChangeKind::Update { .. } => "update",
    };
    HydratedFileChangeEntryData {
        path: change.path.clone(),
        kind: kind.to_string(),
        diff: change.diff.clone(),
        additions,
        deletions,
    }
}

fn diff_stats(diff: &str) -> (u32, u32) {
    let mut additions = 0;
    let mut deletions = 0;
    for line in diff.lines() {
        if line.starts_with('+') && !line.starts_with("+++") {
            additions += 1;
        } else if line.starts_with('-') && !line.starts_with("---") {
            deletions += 1;
        }
    }
    (additions, deletions)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
) -> Option<HydratedWidgetData> {
    if !tool.eq_ignore_ascii_case("show_widget") {
        return None;
    }

    let status_label = match status {
        DynamicToolCallStatus::InProgress => "inProgress",
        DynamicToolCallStatus::Completed => "completed",
        DynamicToolCallStatus::Failed => "failed",
    };
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

    Some(HydratedWidgetData {
        title,
        widget_html,
        width,
        height,
        status: status_label.to_string(),
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
            HydratedConversationItemContent::User(data) => {
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
            HydratedConversationItemContent::Assistant(data) => {
                assert_eq!(data.text, "Response text");
                assert_eq!(data.agent_nickname.as_deref(), Some("bob"));
                assert_eq!(data.agent_role.as_deref(), Some("coder"));
                assert_eq!(data.phase, None);
            }
            _ => panic!("expected Assistant content"),
        }
    }

    #[test]
    fn test_agent_message_code_review_hydrates_as_code_review() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::AgentMessage {
                id: "a1".into(),
                text: serde_json::json!({
                    "findings": [
                        {
                            "title": "[P1] Fall back to turn/start when IPC queue sync fails",
                            "body": "A queued follow-up can get stuck indefinitely.",
                            "confidence_score": 0.97,
                            "priority": 1,
                            "code_location": {
                                "absolute_file_path": "/Users/sigkitten/dev/litter/shared/rust-bridge/codex-mobile-client/src/mobile_client_impl.rs",
                                "line_range": { "start": 799, "end": 815 }
                            }
                        }
                    ],
                    "overall_correctness": "incorrect",
                    "overall_explanation": "There are blocking issues.",
                    "overall_confidence_score": 0.92
                })
                .to_string(),
                phase: Some(codex_protocol::models::MessagePhase::FinalAnswer),
                memory_citation: None,
            }],
        )];

        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        match &items[0].content {
            HydratedConversationItemContent::CodeReview(data) => {
                assert_eq!(data.findings.len(), 1);
                assert_eq!(
                    data.findings[0].title,
                    "Fall back to turn/start when IPC queue sync fails"
                );
                assert_eq!(data.findings[0].priority, Some(1));
                assert_eq!(data.overall_correctness.as_deref(), Some("incorrect"));
            }
            _ => panic!("expected CodeReview content"),
        }
    }

    #[test]
    fn test_diff_stats_ignores_headers() {
        let diff = "\
diff --git a/parser.rs b/parser.rs\n\
--- a/parser.rs\n\
+++ b/parser.rs\n\
@@ -1,3 +1,4 @@\n\
 line one\n\
-line two\n\
+line two updated\n\
+line three\n";

        assert_eq!(diff_stats(diff), (2, 1));
    }

    #[test]
    fn test_agent_message_markdown_stays_assistant() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::AgentMessage {
                id: "a1".into(),
                text: "Here is a regular markdown answer.".into(),
                phase: Some(codex_protocol::models::MessagePhase::FinalAnswer),
                memory_citation: None,
            }],
        )];

        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        assert!(matches!(
            &items[0].content,
            HydratedConversationItemContent::Assistant(data)
            if data.text == "Here is a regular markdown answer."
        ));
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
            HydratedConversationItemContent::CommandExecution(data) => {
                assert_eq!(data.command, "ls -la");
                assert_eq!(data.cwd, "/tmp");
                assert_eq!(data.status, AppOperationStatus::Completed);
                assert_eq!(data.exit_code, Some(0));
                assert_eq!(data.actions.len(), 1);
                assert!(matches!(
                    data.actions[0].kind,
                    HydratedCommandActionKind::Read
                ));
            }
            _ => panic!("expected CommandExecution content"),
        }
    }

    #[test]
    fn test_display_command_strips_known_shell_wrappers() {
        assert_eq!(display_command("/bin/zsh -lc 'ls -la'"), "ls -la");
        assert_eq!(display_command("/bin/bash -c 'echo hi'"), "echo hi");
        assert_eq!(display_command("/bin/sh -lc 'pwd'"), "pwd");
        assert_eq!(
            display_command("pwsh -NoProfile -Command 'Get-ChildItem'"),
            "Get-ChildItem"
        );
        assert_eq!(
            display_command("powershell.exe -Command 'Write-Host hi'"),
            "Write-Host hi"
        );
        assert_eq!(display_command("cmd.exe /c dir"), "dir");
        assert_eq!(display_command("plain command"), "plain command");
    }

    #[test]
    fn test_command_execution_strips_shell_wrapper_for_display() {
        let turns = vec![make_turn(
            "t1",
            vec![ThreadItem::CommandExecution {
                id: "c1".into(),
                command: "/bin/zsh -lc 'npm test'".into(),
                cwd: PathBuf::from("/tmp"),
                process_id: None,
                source: Default::default(),
                status: CommandExecutionStatus::InProgress,
                command_actions: vec![],
                aggregated_output: None,
                exit_code: None,
                duration_ms: None,
            }],
        )];

        let items = hydrate_turns(&turns, &HydrationOptions::default());
        assert_eq!(items.len(), 1);
        match &items[0].content {
            HydratedConversationItemContent::CommandExecution(data) => {
                assert_eq!(data.command, "npm test");
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
            HydratedConversationItemContent::Divider(HydratedDividerData::ContextCompaction {
                is_complete,
            }) => {
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
        assert!(matches!(
            &items[0].content,
            HydratedConversationItemContent::Divider(HydratedDividerData::ReviewEntered { review })
            if review == "safety"
        ));
        assert!(matches!(
            &items[1].content,
            HydratedConversationItemContent::Divider(HydratedDividerData::ReviewExited { review })
            if review == "safety"
        ));
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
            HydratedConversationItemContent::McpToolCall(_)
        ));
        assert!(matches!(
            items[1].content,
            HydratedConversationItemContent::Widget(_)
        ));
        assert!(matches!(
            items[2].content,
            HydratedConversationItemContent::MultiAgentAction(_)
        ));
        assert!(matches!(
            items[3].content,
            HydratedConversationItemContent::WebSearch(_)
        ));
    }
}
