use serde::{Deserialize, Serialize};
use serde_json::Value;
use url::Url;

use crate::{
    OpenCodeBridgeError, OpenCodeMessage, OpenCodeMessagePart, OpenCodeMessageRole,
    OpenCodeMessageWithParts, OpenCodePatchPart, OpenCodeReasoningPart, OpenCodeSession,
    OpenCodeStepFinishPart, OpenCodeStepStartPart, OpenCodeTextPart, OpenCodeTokenUsage,
    OpenCodeToolPart, OpenCodeToolState,
};

use super::{OpenCodeMappingScope, OpenCodeUnknownPayload, map_error};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OpenCodeConversationRole {
    User,
    Assistant,
    Unknown(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeConversationPath {
    pub cwd: String,
    pub root: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeMappedModelRef {
    pub provider_id: String,
    pub model_id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeMappedError {
    pub name: String,
    pub data: Value,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeTokenUsageSummary {
    pub input: u64,
    pub output: u64,
    pub reasoning: u64,
    pub cache_read: u64,
    pub cache_write: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeConversationMessage {
    pub thread_key: crate::OpenCodeThreadKey,
    pub message_id: String,
    pub role: OpenCodeConversationRole,
    pub parent_message_id: Option<String>,
    pub created_at: u64,
    pub completed_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<OpenCodeConversationPath>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<OpenCodeMappedModelRef>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub finish_reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<OpenCodeMappedError>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub parts: Vec<OpenCodeConversationPart>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeConversationSnapshot {
    pub thread_key: crate::OpenCodeThreadKey,
    pub messages: Vec<OpenCodeConversationMessage>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum OpenCodeConversationDelta {
    MessageUpsert(OpenCodeConversationMessage),
    PartUpsert(OpenCodeMessagePartDelta),
    PartFieldDelta {
        thread_key: crate::OpenCodeThreadKey,
        message_id: String,
        part_id: String,
        field: String,
        delta: String,
    },
    PartRemoved {
        thread_key: crate::OpenCodeThreadKey,
        message_id: String,
        part_id: String,
    },
    SessionDiff {
        thread_key: crate::OpenCodeThreadKey,
        diff: Vec<super::OpenCodeChangedFile>,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeMessagePartDelta {
    pub thread_key: crate::OpenCodeThreadKey,
    pub message_id: String,
    pub part: OpenCodeConversationPart,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text_delta: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum OpenCodeConversationPart {
    Text(OpenCodeStreamText),
    Reasoning(OpenCodeReasoningSection),
    Tool(OpenCodeToolCall),
    File(OpenCodeConversationFileReference),
    Patch(OpenCodePatchSummary),
    StepBoundary(OpenCodeStepBoundary),
    Unknown(OpenCodeUnknownPayload),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeStreamText {
    pub part_id: String,
    pub text: String,
    pub streamable: bool,
    pub synthetic: bool,
    pub ignored: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<u64>,
    pub metadata: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeReasoningSection {
    pub part_id: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<u64>,
    pub metadata: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeConversationFileReference {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub part_id: Option<String>,
    pub mime: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub filename: Option<String>,
    pub url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodePatchSummary {
    pub part_id: String,
    pub hash: String,
    pub files: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OpenCodeStepBoundaryKind {
    Start,
    Finish,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeStepBoundary {
    pub part_id: String,
    pub kind: OpenCodeStepBoundaryKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cost: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tokens: Option<OpenCodeTokenUsageSummary>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeToolCall {
    pub part_id: String,
    pub call_id: String,
    pub tool_name: String,
    pub state: OpenCodeToolCallState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum OpenCodeToolCallState {
    Pending(OpenCodeToolCallStatePending),
    Running(OpenCodeToolCallStateRunning),
    Succeeded(OpenCodeToolCallStateSucceeded),
    Error(OpenCodeToolCallStateError),
    Unknown(OpenCodeUnknownPayload),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeToolCallStatePending {
    pub input: Value,
    pub raw: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeToolCallStateRunning {
    pub input: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeToolCallStateSucceeded {
    pub input: Value,
    pub output: String,
    pub title: String,
    pub metadata: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<OpenCodeConversationFileReference>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeToolCallStateError {
    pub input: Value,
    pub error: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<u64>,
}

pub fn map_conversation_snapshot(
    scope: &OpenCodeMappingScope,
    session: &OpenCodeSession,
    messages: &[OpenCodeMessageWithParts],
) -> Result<OpenCodeConversationSnapshot, OpenCodeBridgeError> {
    let thread_key = crate::OpenCodeThreadKey::new(
        scope.server_id.clone(),
        session.directory.clone(),
        session.id.clone(),
    )?;
    let messages = messages
        .iter()
        .map(|message| {
            if message.info.session_id != session.id {
                return Err(OpenCodeBridgeError::InvalidMappedPayload {
                    operation: "conversation snapshot mapping",
                    message: format!(
                        "message {} belongs to session {} instead of {}",
                        message.info.id, message.info.session_id, session.id
                    ),
                    raw: None,
                });
            }

            map_message(scope, &message.info, &message.parts)
        })
        .collect::<Result<Vec<_>, _>>()?;

    Ok(OpenCodeConversationSnapshot {
        thread_key,
        messages,
    })
}

pub fn map_message_upsert(
    scope: &OpenCodeMappingScope,
    message: &OpenCodeMessage,
) -> Result<OpenCodeConversationMessage, OpenCodeBridgeError> {
    map_message(scope, message, &[])
}

pub fn map_message_part_delta(
    scope: &OpenCodeMappingScope,
    part: &OpenCodeMessagePart,
    delta: Option<&str>,
) -> Result<OpenCodeMessagePartDelta, OpenCodeBridgeError> {
    let session_id = part
        .session_id()
        .ok_or(OpenCodeBridgeError::MissingSessionContext {
            operation: "message part delta mapping",
        })?;
    let message_id = part
        .message_id()
        .ok_or(OpenCodeBridgeError::InvalidMappedPayload {
            operation: "message part delta mapping",
            message: "part missing message id".to_string(),
            raw: None,
        })?;

    Ok(OpenCodeMessagePartDelta {
        thread_key: scope.thread_key(session_id.to_string())?,
        message_id: message_id.to_string(),
        part: map_part(part),
        text_delta: delta.map(ToOwned::to_owned),
    })
}

fn map_message(
    scope: &OpenCodeMappingScope,
    message: &OpenCodeMessage,
    parts: &[OpenCodeMessagePart],
) -> Result<OpenCodeConversationMessage, OpenCodeBridgeError> {
    let thread_key = scope.thread_key(message.session_id.clone())?;
    let parts = parts.iter().map(map_part).collect();

    Ok(OpenCodeConversationMessage {
        thread_key,
        message_id: message.id.clone(),
        role: match &message.role {
            OpenCodeMessageRole::User => OpenCodeConversationRole::User,
            OpenCodeMessageRole::Assistant => OpenCodeConversationRole::Assistant,
            OpenCodeMessageRole::Unknown(role) => OpenCodeConversationRole::Unknown(role.clone()),
        },
        parent_message_id: message.parent_id.clone(),
        created_at: message.time.created,
        completed_at: message.time.completed,
        agent: message.agent.clone(),
        mode: message.mode.clone(),
        path: message.path.as_ref().map(|path| OpenCodeConversationPath {
            cwd: path.cwd.clone(),
            root: path.root.clone(),
        }),
        model: message.model_ref().map(|model| OpenCodeMappedModelRef {
            provider_id: model.provider_id,
            model_id: model.model_id,
        }),
        system: message.system.clone(),
        finish_reason: message.finish.clone(),
        error: message.error.as_ref().map(map_error),
        parts,
    })
}

fn map_part(part: &OpenCodeMessagePart) -> OpenCodeConversationPart {
    match part {
        OpenCodeMessagePart::Text(part) => OpenCodeConversationPart::Text(map_text_part(part)),
        OpenCodeMessagePart::Reasoning(part) => {
            OpenCodeConversationPart::Reasoning(map_reasoning_part(part))
        }
        OpenCodeMessagePart::Tool(part) => OpenCodeConversationPart::Tool(map_tool_part(part)),
        OpenCodeMessagePart::File(part) => OpenCodeConversationPart::File(map_file_reference(
            Some(part.id.clone()),
            part.mime.clone(),
            part.filename.clone(),
            part.url.clone(),
            part.source.clone(),
        )),
        OpenCodeMessagePart::Patch(part) => OpenCodeConversationPart::Patch(map_patch_part(part)),
        OpenCodeMessagePart::StepStart(part) => {
            OpenCodeConversationPart::StepBoundary(map_step_start_part(part))
        }
        OpenCodeMessagePart::StepFinish(part) => {
            OpenCodeConversationPart::StepBoundary(map_step_finish_part(part))
        }
        OpenCodeMessagePart::Unknown(part) => {
            OpenCodeConversationPart::Unknown(OpenCodeUnknownPayload {
                kind: part.part_type.clone(),
                raw: part.raw.clone(),
            })
        }
    }
}

fn map_text_part(part: &OpenCodeTextPart) -> OpenCodeStreamText {
    OpenCodeStreamText {
        part_id: part.id.clone(),
        text: part.text.clone(),
        streamable: part
            .metadata
            .get("stream")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        synthetic: part.synthetic.unwrap_or(false),
        ignored: part.ignored.unwrap_or(false),
        started_at: part
            .time
            .as_ref()
            .and_then(|time| time.start.or(time.created)),
        completed_at: part.time.as_ref().and_then(|time| time.end),
        metadata: part.metadata.clone(),
    }
}

fn map_reasoning_part(part: &OpenCodeReasoningPart) -> OpenCodeReasoningSection {
    OpenCodeReasoningSection {
        part_id: part.id.clone(),
        text: part.text.clone(),
        started_at: part.time.start.or(part.time.created),
        completed_at: part.time.end,
        metadata: part.metadata.clone(),
    }
}

fn map_file_reference(
    part_id: Option<String>,
    mime: String,
    filename: Option<String>,
    url: String,
    source: Option<Value>,
) -> OpenCodeConversationFileReference {
    OpenCodeConversationFileReference {
        part_id,
        mime,
        filename,
        path: source
            .as_ref()
            .and_then(|value| value.get("path"))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or_else(|| file_url_to_path(&url)),
        url,
        source,
    }
}

fn file_url_to_path(url: &str) -> Option<String> {
    Url::parse(url)
        .ok()
        .filter(|parsed| parsed.scheme() == "file")
        .and_then(|parsed| parsed.to_file_path().ok())
        .map(|path| path.to_string_lossy().into_owned())
}

fn map_patch_part(part: &OpenCodePatchPart) -> OpenCodePatchSummary {
    OpenCodePatchSummary {
        part_id: part.id.clone(),
        hash: part.hash.clone(),
        files: part.files.clone(),
    }
}

fn map_step_start_part(part: &OpenCodeStepStartPart) -> OpenCodeStepBoundary {
    OpenCodeStepBoundary {
        part_id: part.id.clone(),
        kind: OpenCodeStepBoundaryKind::Start,
        snapshot: part.snapshot.clone(),
        reason: None,
        cost: None,
        tokens: None,
    }
}

fn map_step_finish_part(part: &OpenCodeStepFinishPart) -> OpenCodeStepBoundary {
    OpenCodeStepBoundary {
        part_id: part.id.clone(),
        kind: OpenCodeStepBoundaryKind::Finish,
        snapshot: part.snapshot.clone(),
        reason: Some(part.reason.clone()),
        cost: Some(part.cost),
        tokens: Some(map_token_usage(&part.tokens)),
    }
}

fn map_tool_part(part: &OpenCodeToolPart) -> OpenCodeToolCall {
    OpenCodeToolCall {
        part_id: part.id.clone(),
        call_id: part.call_id.clone(),
        tool_name: part.tool.clone(),
        state: map_tool_state(&part.state),
        metadata: part.metadata.clone(),
    }
}

fn map_tool_state(state: &OpenCodeToolState) -> OpenCodeToolCallState {
    match state {
        OpenCodeToolState::Pending { input, raw } => {
            OpenCodeToolCallState::Pending(OpenCodeToolCallStatePending {
                input: input.clone(),
                raw: raw.clone(),
            })
        }
        OpenCodeToolState::Running {
            input,
            title,
            metadata,
            time,
        } => OpenCodeToolCallState::Running(OpenCodeToolCallStateRunning {
            input: input.clone(),
            title: title.clone(),
            metadata: metadata.clone(),
            started_at: time.start.or(time.created),
            completed_at: time.end,
        }),
        OpenCodeToolState::Completed {
            input,
            output,
            title,
            metadata,
            time,
            attachments,
        } => OpenCodeToolCallState::Succeeded(OpenCodeToolCallStateSucceeded {
            input: input.clone(),
            output: output.clone(),
            title: title.clone(),
            metadata: metadata.clone(),
            started_at: time.start.or(time.created),
            completed_at: time.end,
            attachments: attachments
                .iter()
                .map(|attachment| {
                    map_file_reference(
                        Some(attachment.id.clone()),
                        attachment.mime.clone(),
                        attachment.filename.clone(),
                        attachment.url.clone(),
                        attachment.source.clone(),
                    )
                })
                .collect(),
        }),
        OpenCodeToolState::Error {
            input,
            error,
            metadata,
            time,
        } => OpenCodeToolCallState::Error(OpenCodeToolCallStateError {
            input: input.clone(),
            error: error.clone(),
            metadata: metadata.clone(),
            started_at: time.start.or(time.created),
            completed_at: time.end,
        }),
        OpenCodeToolState::Unknown { status, raw } => {
            OpenCodeToolCallState::Unknown(OpenCodeUnknownPayload {
                kind: status.clone(),
                raw: raw.clone(),
            })
        }
    }
}

fn map_token_usage(tokens: &OpenCodeTokenUsage) -> OpenCodeTokenUsageSummary {
    OpenCodeTokenUsageSummary {
        input: tokens.input,
        output: tokens.output,
        reasoning: tokens.reasoning,
        cache_read: tokens.cache.read,
        cache_write: tokens.cache.write,
    }
}
