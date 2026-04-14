use std::collections::BTreeMap;

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use url::Url;

use crate::error::OpenCodeBridgeError;

pub type OpenCodeSessionStatusIndex = BTreeMap<String, OpenCodeSessionStatus>;
pub type OpenCodeProviderAuthMethods = BTreeMap<String, Vec<OpenCodeProviderAuthMethod>>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenCodeServerConfig {
    pub server_id: String,
    pub display_name: String,
    pub base_url: Url,
    pub host: String,
    pub port: u16,
    pub tls: bool,
    pub basic_auth_username: Option<String>,
    pub basic_auth_password: Option<String>,
    pub known_directories: Vec<OpenCodeDirectoryScope>,
}

impl OpenCodeServerConfig {
    pub fn new(
        server_id: impl Into<String>,
        display_name: impl Into<String>,
        base_url: impl AsRef<str>,
        host: impl Into<String>,
        port: u16,
        tls: bool,
    ) -> Result<Self, OpenCodeBridgeError> {
        Ok(Self {
            server_id: server_id.into(),
            display_name: display_name.into(),
            base_url: Url::parse(base_url.as_ref())?,
            host: host.into(),
            port,
            tls,
            basic_auth_username: None,
            basic_auth_password: None,
            known_directories: Vec::new(),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeDirectoryScope {
    pub directory: String,
}

impl OpenCodeDirectoryScope {
    pub fn new(directory: impl Into<String>) -> Result<Self, OpenCodeBridgeError> {
        let directory = normalize_directory(directory.into(), "directory scope")?;
        Ok(Self { directory })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeThreadKey {
    pub server_id: String,
    pub directory: String,
    pub session_id: String,
}

impl OpenCodeThreadKey {
    pub fn new(
        server_id: impl Into<String>,
        directory: impl Into<String>,
        session_id: impl Into<String>,
    ) -> Result<Self, OpenCodeBridgeError> {
        let directory = normalize_directory(directory.into(), "thread key")?;
        let session_id = session_id.into();
        if session_id.trim().is_empty() {
            return Err(OpenCodeBridgeError::MissingSessionContext {
                operation: "thread key",
            });
        }

        Ok(Self {
            server_id: server_id.into(),
            directory,
            session_id,
        })
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeRequestContext {
    pub directory: Option<String>,
    pub project: Option<String>,
    pub workspace: Option<String>,
}

impl OpenCodeRequestContext {
    pub fn new(directory: impl Into<String>) -> Result<Self, OpenCodeBridgeError> {
        let directory = normalize_directory(directory.into(), "request context")?;
        Ok(Self {
            directory: Some(directory),
            project: None,
            workspace: None,
        })
    }

    pub fn require_directory_for(
        &self,
        operation: &'static str,
    ) -> Result<&str, OpenCodeBridgeError> {
        match self.directory.as_deref() {
            Some(directory) if !directory.trim().is_empty() => Ok(directory),
            Some(_) => Err(OpenCodeBridgeError::EmptyDirectory { operation }),
            None => Err(OpenCodeBridgeError::MissingDirectory { operation }),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeSessionListQuery {
    #[serde(flatten)]
    pub context: OpenCodeRequestContext,
    pub roots: Option<bool>,
    pub start: Option<u64>,
    pub search: Option<String>,
    pub limit: Option<u32>,
}

impl OpenCodeSessionListQuery {
    pub fn require_directory(&self) -> Result<&str, OpenCodeBridgeError> {
        self.context.require_directory_for("session list")
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeSessionCreateRequest {
    #[serde(flatten)]
    pub context: OpenCodeRequestContext,
    #[serde(rename = "parentID", skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(rename = "workspaceID", skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
}

impl OpenCodeSessionCreateRequest {
    pub fn require_directory(&self) -> Result<&str, OpenCodeBridgeError> {
        self.context.require_directory_for("session create")
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeSessionUpdateRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeSessionForkRequest {
    #[serde(rename = "messageID", skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct OpenCodeHealthResponse {
    pub healthy: bool,
    pub version: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct OpenCodeProjectTime {
    pub created: u64,
    pub updated: u64,
    pub initialized: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct OpenCodeProjectIcon {
    pub url: Option<String>,
    #[serde(rename = "override")]
    pub override_name: Option<String>,
    pub color: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct OpenCodeProjectCommands {
    pub start: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeProjectInfo {
    pub id: String,
    pub worktree: String,
    pub vcs: Option<String>,
    pub name: Option<String>,
    pub icon: Option<OpenCodeProjectIcon>,
    pub commands: Option<OpenCodeProjectCommands>,
    pub time: OpenCodeProjectTime,
    #[serde(default)]
    pub sandboxes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct OpenCodePathInfo {
    pub home: String,
    pub state: String,
    pub config: String,
    pub worktree: String,
    pub directory: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeSession {
    pub id: String,
    #[serde(rename = "projectID")]
    pub project_id: String,
    pub directory: String,
    #[serde(rename = "parentID")]
    pub parent_id: Option<String>,
    pub summary: Option<OpenCodeSessionSummary>,
    pub share: Option<OpenCodeSessionShare>,
    pub title: String,
    pub version: String,
    pub time: OpenCodeSessionTime,
    pub revert: Option<OpenCodeSessionRevert>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeSessionShare {
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeSessionRevert {
    #[serde(rename = "messageID")]
    pub message_id: String,
    #[serde(rename = "partID")]
    pub part_id: Option<String>,
    pub snapshot: Option<String>,
    pub diff: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeSessionTime {
    pub created: u64,
    pub updated: u64,
    pub compacting: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeSessionSummary {
    pub additions: u32,
    pub deletions: u32,
    pub files: u32,
    #[serde(default)]
    pub diffs: Vec<OpenCodeFileDiff>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeFileDiff {
    pub file: String,
    pub before: String,
    pub after: String,
    pub additions: u32,
    pub deletions: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub enum OpenCodeSessionStatus {
    Idle,
    Busy,
    Retry {
        attempt: u32,
        message: String,
        next: u64,
    },
    Unknown {
        kind: String,
        raw: Value,
    },
}

impl<'de> Deserialize<'de> for OpenCodeSessionStatus {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = Value::deserialize(deserializer)?;
        let kind = raw
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();

        match kind.as_str() {
            "idle" => Ok(Self::Idle),
            "busy" => Ok(Self::Busy),
            "retry" => {
                #[derive(Deserialize)]
                struct Retry {
                    attempt: u32,
                    message: String,
                    next: u64,
                }

                let retry = serde_json::from_value::<Retry>(raw.clone())
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::Retry {
                    attempt: retry.attempt,
                    message: retry.message,
                    next: retry.next,
                })
            }
            _ => Ok(Self::Unknown { kind, raw }),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum OpenCodeMessageRole {
    User,
    Assistant,
    Unknown(String),
}

impl<'de> Deserialize<'de> for OpenCodeMessageRole {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = String::deserialize(deserializer)?;
        Ok(match raw.as_str() {
            "user" => Self::User,
            "assistant" => Self::Assistant,
            _ => Self::Unknown(raw),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeMessageTime {
    pub created: u64,
    pub completed: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeMessagePath {
    pub cwd: String,
    pub root: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenCodeModelRef {
    #[serde(rename = "providerID")]
    pub provider_id: String,
    #[serde(rename = "modelID")]
    pub model_id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum OpenCodeOutputFormat {
    #[serde(rename = "text")]
    Text,
    #[serde(rename = "json_schema")]
    JsonSchema {
        schema: Value,
        #[serde(rename = "retryCount", default = "default_retry_count")]
        retry_count: u32,
    },
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeTokenCache {
    pub read: u64,
    pub write: u64,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeTokenUsage {
    pub input: u64,
    pub output: u64,
    pub reasoning: u64,
    pub cache: OpenCodeTokenCache,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeMessageError {
    pub name: String,
    #[serde(default = "empty_object")]
    pub data: Value,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeMessage {
    pub id: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    pub role: OpenCodeMessageRole,
    pub time: OpenCodeMessageTime,
    #[serde(rename = "parentID")]
    pub parent_id: Option<String>,
    pub agent: Option<String>,
    pub mode: Option<String>,
    pub path: Option<OpenCodeMessagePath>,
    pub model: Option<OpenCodeModelRef>,
    #[serde(rename = "providerID")]
    pub provider_id: Option<String>,
    #[serde(rename = "modelID")]
    pub model_id: Option<String>,
    pub system: Option<String>,
    pub tools: Option<BTreeMap<String, bool>>,
    pub cost: Option<f64>,
    pub tokens: Option<OpenCodeTokenUsage>,
    pub finish: Option<String>,
    pub error: Option<OpenCodeMessageError>,
    pub summary: Option<Value>,
}

impl OpenCodeMessage {
    pub fn model_ref(&self) -> Option<OpenCodeModelRef> {
        self.model.clone().or_else(|| {
            Some(OpenCodeModelRef {
                provider_id: self.provider_id.clone()?,
                model_id: self.model_id.clone()?,
            })
        })
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeMessageWithParts {
    pub info: OpenCodeMessage,
    #[serde(default)]
    pub parts: Vec<OpenCodeMessagePart>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct OpenCodeMessageList {
    pub items: Vec<OpenCodeMessageWithParts>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum OpenCodePromptPartInput {
    #[serde(rename = "text")]
    Text(OpenCodePromptTextPartInput),
    #[serde(rename = "file")]
    File(OpenCodePromptFilePartInput),
    #[serde(rename = "agent")]
    Agent(OpenCodePromptAgentPartInput),
    #[serde(rename = "subtask")]
    Subtask(OpenCodePromptSubtaskPartInput),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OpenCodePromptTextPartInput {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub synthetic: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ignored: Option<bool>,
    #[serde(default = "empty_object")]
    pub metadata: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OpenCodePromptFilePartInput {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub mime: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub filename: Option<String>,
    pub url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenCodePromptSourceSpan {
    pub value: String,
    pub start: u32,
    pub end: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenCodePromptAgentPartInput {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<OpenCodePromptSourceSpan>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenCodePromptSubtaskPartInput {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub prompt: String,
    pub description: String,
    pub agent: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<OpenCodeModelRef>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodePromptAsyncRequest {
    #[serde(rename = "messageID", skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<OpenCodeModelRef>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub no_reply: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<BTreeMap<String, bool>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub format: Option<OpenCodeOutputFormat>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub variant: Option<String>,
    pub parts: Vec<OpenCodePromptPartInput>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodePartTime {
    pub start: Option<u64>,
    pub end: Option<u64>,
    pub created: Option<u64>,
    pub compacted: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeTextPart {
    pub id: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    #[serde(rename = "messageID")]
    pub message_id: String,
    pub text: String,
    pub synthetic: Option<bool>,
    pub ignored: Option<bool>,
    pub time: Option<OpenCodePartTime>,
    #[serde(default = "empty_object")]
    pub metadata: Value,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeReasoningPart {
    pub id: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    #[serde(rename = "messageID")]
    pub message_id: String,
    pub text: String,
    #[serde(default = "empty_object")]
    pub metadata: Value,
    pub time: OpenCodePartTime,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeFilePart {
    pub id: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    #[serde(rename = "messageID")]
    pub message_id: String,
    pub mime: String,
    pub filename: Option<String>,
    pub url: String,
    pub source: Option<Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum OpenCodeToolState {
    Pending {
        input: Value,
        raw: String,
    },
    Running {
        input: Value,
        title: Option<String>,
        metadata: Option<Value>,
        time: OpenCodePartTime,
    },
    Completed {
        input: Value,
        output: String,
        title: String,
        metadata: Value,
        time: OpenCodePartTime,
        attachments: Vec<OpenCodeFilePart>,
    },
    Error {
        input: Value,
        error: String,
        metadata: Option<Value>,
        time: OpenCodePartTime,
    },
    Unknown {
        status: String,
        raw: Value,
    },
}

impl<'de> Deserialize<'de> for OpenCodeToolState {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = Value::deserialize(deserializer)?;
        let status = raw
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();

        match status.as_str() {
            "pending" => {
                #[derive(Deserialize)]
                struct Pending {
                    #[serde(default = "empty_object")]
                    input: Value,
                    raw: String,
                }

                let pending = serde_json::from_value::<Pending>(raw.clone())
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::Pending {
                    input: pending.input,
                    raw: pending.raw,
                })
            }
            "running" => {
                #[derive(Deserialize)]
                struct Running {
                    #[serde(default = "empty_object")]
                    input: Value,
                    title: Option<String>,
                    metadata: Option<Value>,
                    time: OpenCodePartTime,
                }

                let running = serde_json::from_value::<Running>(raw.clone())
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::Running {
                    input: running.input,
                    title: running.title,
                    metadata: running.metadata,
                    time: running.time,
                })
            }
            "completed" => {
                #[derive(Deserialize)]
                struct Completed {
                    #[serde(default = "empty_object")]
                    input: Value,
                    output: String,
                    title: String,
                    #[serde(default = "empty_object")]
                    metadata: Value,
                    time: OpenCodePartTime,
                    #[serde(default)]
                    attachments: Vec<OpenCodeFilePart>,
                }

                let completed = serde_json::from_value::<Completed>(raw.clone())
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::Completed {
                    input: completed.input,
                    output: completed.output,
                    title: completed.title,
                    metadata: completed.metadata,
                    time: completed.time,
                    attachments: completed.attachments,
                })
            }
            "error" => {
                #[derive(Deserialize)]
                struct Error {
                    #[serde(default = "empty_object")]
                    input: Value,
                    error: String,
                    metadata: Option<Value>,
                    time: OpenCodePartTime,
                }

                let error = serde_json::from_value::<Error>(raw.clone())
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::Error {
                    input: error.input,
                    error: error.error,
                    metadata: error.metadata,
                    time: error.time,
                })
            }
            _ => Ok(Self::Unknown { status, raw }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeToolPart {
    pub id: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    #[serde(rename = "messageID")]
    pub message_id: String,
    #[serde(rename = "callID")]
    pub call_id: String,
    pub tool: String,
    pub state: OpenCodeToolState,
    pub metadata: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodePatchPart {
    pub id: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    #[serde(rename = "messageID")]
    pub message_id: String,
    pub hash: String,
    pub files: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeStepStartPart {
    pub id: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    #[serde(rename = "messageID")]
    pub message_id: String,
    pub snapshot: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeStepFinishPart {
    pub id: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    #[serde(rename = "messageID")]
    pub message_id: String,
    pub reason: String,
    pub snapshot: Option<String>,
    pub cost: f64,
    pub tokens: OpenCodeTokenUsage,
}

#[derive(Debug, Clone, PartialEq)]
pub struct OpenCodeUnknownPart {
    pub id: Option<String>,
    pub session_id: Option<String>,
    pub message_id: Option<String>,
    pub part_type: String,
    pub raw: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub enum OpenCodeMessagePart {
    Text(OpenCodeTextPart),
    Reasoning(OpenCodeReasoningPart),
    Tool(OpenCodeToolPart),
    File(OpenCodeFilePart),
    Patch(OpenCodePatchPart),
    StepStart(OpenCodeStepStartPart),
    StepFinish(OpenCodeStepFinishPart),
    Unknown(OpenCodeUnknownPart),
}

impl OpenCodeMessagePart {
    pub fn part_type(&self) -> &str {
        match self {
            Self::Text(_) => "text",
            Self::Reasoning(_) => "reasoning",
            Self::Tool(_) => "tool",
            Self::File(_) => "file",
            Self::Patch(_) => "patch",
            Self::StepStart(_) => "step-start",
            Self::StepFinish(_) => "step-finish",
            Self::Unknown(part) => &part.part_type,
        }
    }

    pub fn part_id(&self) -> Option<&str> {
        match self {
            Self::Text(part) => Some(&part.id),
            Self::Reasoning(part) => Some(&part.id),
            Self::Tool(part) => Some(&part.id),
            Self::File(part) => Some(&part.id),
            Self::Patch(part) => Some(&part.id),
            Self::StepStart(part) => Some(&part.id),
            Self::StepFinish(part) => Some(&part.id),
            Self::Unknown(part) => part.id.as_deref(),
        }
    }

    pub fn session_id(&self) -> Option<&str> {
        match self {
            Self::Text(part) => Some(&part.session_id),
            Self::Reasoning(part) => Some(&part.session_id),
            Self::Tool(part) => Some(&part.session_id),
            Self::File(part) => Some(&part.session_id),
            Self::Patch(part) => Some(&part.session_id),
            Self::StepStart(part) => Some(&part.session_id),
            Self::StepFinish(part) => Some(&part.session_id),
            Self::Unknown(part) => part.session_id.as_deref(),
        }
    }

    pub fn message_id(&self) -> Option<&str> {
        match self {
            Self::Text(part) => Some(&part.message_id),
            Self::Reasoning(part) => Some(&part.message_id),
            Self::Tool(part) => Some(&part.message_id),
            Self::File(part) => Some(&part.message_id),
            Self::Patch(part) => Some(&part.message_id),
            Self::StepStart(part) => Some(&part.message_id),
            Self::StepFinish(part) => Some(&part.message_id),
            Self::Unknown(part) => part.message_id.as_deref(),
        }
    }
}

impl<'de> Deserialize<'de> for OpenCodeMessagePart {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = Value::deserialize(deserializer)?;
        let part_type = raw
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();

        match part_type.as_str() {
            "text" => serde_json::from_value(raw)
                .map(Self::Text)
                .map_err(serde::de::Error::custom),
            "reasoning" => serde_json::from_value(raw)
                .map(Self::Reasoning)
                .map_err(serde::de::Error::custom),
            "tool" => serde_json::from_value(raw)
                .map(Self::Tool)
                .map_err(serde::de::Error::custom),
            "file" => serde_json::from_value(raw)
                .map(Self::File)
                .map_err(serde::de::Error::custom),
            "patch" => serde_json::from_value(raw)
                .map(Self::Patch)
                .map_err(serde::de::Error::custom),
            "step-start" => serde_json::from_value(raw)
                .map(Self::StepStart)
                .map_err(serde::de::Error::custom),
            "step-finish" => serde_json::from_value(raw)
                .map(Self::StepFinish)
                .map_err(serde::de::Error::custom),
            _ => Ok(Self::Unknown(OpenCodeUnknownPart {
                id: raw.get("id").and_then(Value::as_str).map(ToOwned::to_owned),
                session_id: raw
                    .get("sessionID")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                message_id: raw
                    .get("messageID")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                part_type,
                raw,
            })),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct OpenCodePermissionId(pub String);

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(untagged)]
pub enum OpenCodePermissionPattern {
    One(String),
    Many(Vec<String>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpenCodePermissionResponse {
    Once,
    Always,
    Reject,
    Unknown(String),
}

impl<'de> Deserialize<'de> for OpenCodePermissionResponse {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = String::deserialize(deserializer)?;
        Ok(match raw.as_str() {
            "once" => Self::Once,
            "always" => Self::Always,
            "reject" => Self::Reject,
            _ => Self::Unknown(raw),
        })
    }
}

impl Serialize for OpenCodePermissionResponse {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(match self {
            Self::Once => "once",
            Self::Always => "always",
            Self::Reject => "reject",
            Self::Unknown(value) => value,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenCodePermissionReplyRequest {
    pub response: OpenCodePermissionResponse,
}

#[derive(Debug, Clone, PartialEq)]
pub enum OpenCodePermissionState {
    Pending,
    Replied,
    Unknown(String),
}

impl<'de> Deserialize<'de> for OpenCodePermissionState {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = String::deserialize(deserializer)?;
        Ok(match raw.as_str() {
            "pending" => Self::Pending,
            "replied" => Self::Replied,
            _ => Self::Unknown(raw),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodePermissionTime {
    pub created: u64,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodePermission {
    pub id: OpenCodePermissionId,
    #[serde(rename = "type")]
    pub permission_type: String,
    pub pattern: Option<OpenCodePermissionPattern>,
    #[serde(default)]
    pub patterns: Vec<String>,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    #[serde(rename = "messageID")]
    pub message_id: Option<String>,
    #[serde(rename = "callID")]
    pub call_id: Option<String>,
    pub title: Option<String>,
    pub state: Option<OpenCodePermissionState>,
    #[serde(default = "empty_object")]
    pub metadata: Value,
    pub time: Option<OpenCodePermissionTime>,
    pub permission: Option<String>,
    #[serde(default)]
    pub always: Vec<String>,
    pub tool: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OpenCodeProviderAuthState {
    Connected,
    AuthSupported,
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct OpenCodeProviderAuthMethod {
    #[serde(rename = "type")]
    pub method_type: String,
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeModel {
    pub id: String,
    #[serde(rename = "providerID")]
    pub provider_id: String,
    pub name: String,
    pub status: Option<String>,
    #[serde(default = "empty_object")]
    pub capabilities: Value,
    #[serde(default = "empty_object")]
    pub cost: Value,
    #[serde(default = "empty_object")]
    pub limit: Value,
    #[serde(default = "empty_object")]
    pub options: Value,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeProvider {
    pub id: String,
    pub name: String,
    pub source: Option<String>,
    #[serde(default)]
    pub env: Vec<String>,
    pub key: Option<String>,
    #[serde(default = "empty_object")]
    pub options: Value,
    #[serde(deserialize_with = "deserialize_provider_models")]
    pub models: Vec<OpenCodeModel>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeProviderCatalog {
    pub all: Vec<OpenCodeProvider>,
    #[serde(default)]
    pub default: BTreeMap<String, String>,
    #[serde(default)]
    pub connected: Vec<String>,
}

impl OpenCodeProviderCatalog {
    pub fn auth_state_for(
        &self,
        provider_id: &str,
        auth_methods: Option<&OpenCodeProviderAuthMethods>,
    ) -> OpenCodeProviderAuthState {
        if self.connected.iter().any(|id| id == provider_id) {
            return OpenCodeProviderAuthState::Connected;
        }

        if auth_methods
            .and_then(|methods| methods.get(provider_id))
            .is_some_and(|methods| !methods.is_empty())
        {
            return OpenCodeProviderAuthState::AuthSupported;
        }

        OpenCodeProviderAuthState::Unavailable
    }
}

fn normalize_directory(
    directory: String,
    operation: &'static str,
) -> Result<String, OpenCodeBridgeError> {
    let trimmed = directory.trim();
    if trimmed.is_empty() {
        return Err(OpenCodeBridgeError::EmptyDirectory { operation });
    }
    Ok(trimmed.to_string())
}

fn deserialize_provider_models<'de, D>(deserializer: D) -> Result<Vec<OpenCodeModel>, D::Error>
where
    D: Deserializer<'de>,
{
    let models = BTreeMap::<String, OpenCodeModel>::deserialize(deserializer)?;
    Ok(models.into_values().collect())
}

fn empty_object() -> Value {
    Value::Object(Default::default())
}

fn default_retry_count() -> u32 {
    2
}
