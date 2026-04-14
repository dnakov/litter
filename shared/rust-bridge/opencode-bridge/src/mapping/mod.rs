use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    OpenCodeBridgeError, OpenCodeEvent, OpenCodeGlobalEvent, OpenCodeMessageError,
    OpenCodePermissionResponse, OpenCodeRequestContext, OpenCodeThreadKey,
};

mod messages;
mod models;
mod permissions;
mod threads;

pub use messages::{
    OpenCodeConversationDelta, OpenCodeConversationFileReference, OpenCodeConversationMessage,
    OpenCodeConversationPart, OpenCodeConversationPath, OpenCodeConversationRole,
    OpenCodeConversationSnapshot, OpenCodeMappedError, OpenCodeMappedModelRef,
    OpenCodeMessagePartDelta, OpenCodePatchSummary, OpenCodeReasoningSection, OpenCodeStepBoundary,
    OpenCodeStepBoundaryKind, OpenCodeStreamText, OpenCodeTokenUsageSummary, OpenCodeToolCall,
    OpenCodeToolCallState, OpenCodeToolCallStateError, OpenCodeToolCallStatePending,
    OpenCodeToolCallStateRunning, OpenCodeToolCallStateSucceeded, map_conversation_snapshot,
    map_message_part_delta, map_message_upsert,
};
pub use models::{
    OpenCodeModelCatalog, OpenCodeModelProjection, OpenCodeProviderProjection, map_model_catalog,
};
pub use permissions::{OpenCodeApprovalState, OpenCodePendingApproval, map_pending_approval};
pub use threads::{
    OpenCodeChangedFile, OpenCodeRetryState, OpenCodeThreadState, OpenCodeThreadStateUpdate,
    OpenCodeThreadSummary, map_thread_state_update, map_thread_summaries, map_thread_summary,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeMappingScope {
    pub server_id: String,
    pub directory: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
}

impl OpenCodeMappingScope {
    pub fn new(
        server_id: impl Into<String>,
        directory: impl Into<String>,
    ) -> Result<Self, OpenCodeBridgeError> {
        let directory = normalize_directory(directory.into(), "mapping scope")?;
        Ok(Self {
            server_id: server_id.into(),
            directory,
            project: None,
            workspace: None,
        })
    }

    pub fn from_request_context(
        server_id: impl Into<String>,
        context: &OpenCodeRequestContext,
        operation: &'static str,
    ) -> Result<Self, OpenCodeBridgeError> {
        let directory = context
            .directory
            .as_deref()
            .ok_or(OpenCodeBridgeError::MissingDirectoryContext { operation })?;
        let mut scope = Self::new(server_id, directory)?;
        scope.project = context.project.clone();
        scope.workspace = context.workspace.clone();
        Ok(scope)
    }

    pub fn from_global_event(
        server_id: impl Into<String>,
        event: &OpenCodeGlobalEvent,
    ) -> Result<Self, OpenCodeBridgeError> {
        let directory =
            event
                .directory
                .as_deref()
                .ok_or(OpenCodeBridgeError::MissingDirectoryContext {
                    operation: "global event mapping",
                })?;
        let mut scope = Self::new(server_id, directory)?;
        scope.project = event.project.clone();
        scope.workspace = event.workspace.clone();
        Ok(scope)
    }

    pub fn thread_key(
        &self,
        session_id: impl Into<String>,
    ) -> Result<OpenCodeThreadKey, OpenCodeBridgeError> {
        OpenCodeThreadKey::new(
            self.server_id.clone(),
            self.directory.clone(),
            session_id.into(),
        )
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeUnknownPayload {
    pub kind: String,
    pub raw: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum OpenCodeMappedEvent {
    ThreadSummaryUpsert(OpenCodeThreadSummary),
    ThreadDeleted {
        thread_key: OpenCodeThreadKey,
    },
    ThreadStateUpdated(OpenCodeThreadStateUpdate),
    ConversationDelta(OpenCodeConversationDelta),
    ApprovalUpsert(OpenCodePendingApproval),
    ApprovalResolved {
        thread_key: OpenCodeThreadKey,
        approval_id: String,
        response: OpenCodePermissionResponse,
    },
    Unknown {
        scope: OpenCodeMappingScope,
        session_id: Option<String>,
        payload: OpenCodeUnknownPayload,
    },
}

pub fn map_event(
    scope: &OpenCodeMappingScope,
    event: &OpenCodeEvent,
) -> Result<Vec<OpenCodeMappedEvent>, OpenCodeBridgeError> {
    match event {
        OpenCodeEvent::ServerConnected | OpenCodeEvent::ServerHeartbeat => Ok(Vec::new()),
        OpenCodeEvent::MessageUpdated { info } => Ok(vec![OpenCodeMappedEvent::ConversationDelta(
            OpenCodeConversationDelta::MessageUpsert(map_message_upsert(scope, info)?),
        )]),
        OpenCodeEvent::MessagePartUpdated { part, delta } => {
            Ok(vec![OpenCodeMappedEvent::ConversationDelta(
                OpenCodeConversationDelta::PartUpsert(map_message_part_delta(
                    scope,
                    part,
                    delta.as_deref(),
                )?),
            )])
        }
        OpenCodeEvent::MessagePartDelta {
            session_id,
            message_id,
            part_id,
            field,
            delta,
        } => Ok(vec![OpenCodeMappedEvent::ConversationDelta(
            OpenCodeConversationDelta::PartFieldDelta {
                thread_key: scope.thread_key(session_id.clone())?,
                message_id: message_id.clone(),
                part_id: part_id.clone(),
                field: field.clone(),
                delta: delta.clone(),
            },
        )]),
        OpenCodeEvent::MessagePartRemoved {
            session_id,
            message_id,
            part_id,
        } => Ok(vec![OpenCodeMappedEvent::ConversationDelta(
            OpenCodeConversationDelta::PartRemoved {
                thread_key: scope.thread_key(session_id.clone())?,
                message_id: message_id.clone(),
                part_id: part_id.clone(),
            },
        )]),
        OpenCodeEvent::PermissionUpdated { permission } => {
            Ok(vec![OpenCodeMappedEvent::ApprovalUpsert(
                map_pending_approval(scope, permission)?,
            )])
        }
        OpenCodeEvent::PermissionReplied {
            session_id,
            permission_id,
            response,
        } => Ok(vec![OpenCodeMappedEvent::ApprovalResolved {
            thread_key: scope.thread_key(session_id.clone())?,
            approval_id: permission_id.0.clone(),
            response: response.clone(),
        }]),
        OpenCodeEvent::SessionCreated { info } | OpenCodeEvent::SessionUpdated { info } => {
            Ok(vec![OpenCodeMappedEvent::ThreadSummaryUpsert(
                map_thread_summary(scope, info, None)?,
            )])
        }
        OpenCodeEvent::SessionDeleted { info } => Ok(vec![OpenCodeMappedEvent::ThreadDeleted {
            thread_key: OpenCodeThreadKey::new(
                scope.server_id.clone(),
                resolve_directory(
                    Some(info.directory.as_str()),
                    Some(scope.directory.as_str()),
                )?,
                info.id.clone(),
            )?,
        }]),
        OpenCodeEvent::SessionStatus { session_id, status } => {
            Ok(vec![OpenCodeMappedEvent::ThreadStateUpdated(
                map_thread_state_update(scope, session_id, Some(status), None)?,
            )])
        }
        OpenCodeEvent::SessionIdle { session_id } => {
            Ok(vec![OpenCodeMappedEvent::ThreadStateUpdated(
                map_thread_state_update(scope, session_id, None, None)?,
            )])
        }
        OpenCodeEvent::SessionDiff { session_id, diff } => {
            Ok(vec![OpenCodeMappedEvent::ConversationDelta(
                OpenCodeConversationDelta::SessionDiff {
                    thread_key: scope.thread_key(session_id.clone())?,
                    diff: diff.iter().map(OpenCodeChangedFile::from).collect(),
                },
            )])
        }
        OpenCodeEvent::SessionError { session_id, error } => {
            let session_id =
                session_id
                    .as_deref()
                    .ok_or(OpenCodeBridgeError::MissingSessionContext {
                        operation: "session.error mapping",
                    })?;
            Ok(vec![OpenCodeMappedEvent::ThreadStateUpdated(
                map_thread_state_update(scope, session_id, None, error.as_ref())?,
            )])
        }
        OpenCodeEvent::Unknown { event_type, raw } => Ok(vec![OpenCodeMappedEvent::Unknown {
            scope: scope.clone(),
            session_id: raw
                .get("properties")
                .and_then(|properties| properties.get("sessionID"))
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            payload: OpenCodeUnknownPayload {
                kind: event_type.clone(),
                raw: raw.clone(),
            },
        }]),
    }
}

pub fn map_global_event(
    server_id: impl Into<String>,
    event: &OpenCodeGlobalEvent,
) -> Result<Vec<OpenCodeMappedEvent>, OpenCodeBridgeError> {
    let scope = OpenCodeMappingScope::from_global_event(server_id, event)?;
    map_event(&scope, &event.payload)
}

pub(crate) fn map_error(error: &OpenCodeMessageError) -> OpenCodeMappedError {
    OpenCodeMappedError {
        name: error.name.clone(),
        data: error.data.clone(),
    }
}

pub(crate) fn normalize_directory(
    directory: impl Into<String>,
    operation: &'static str,
) -> Result<String, OpenCodeBridgeError> {
    let directory = directory.into();
    let trimmed = directory.trim();
    if trimmed.is_empty() {
        return Err(OpenCodeBridgeError::MissingDirectoryContext { operation });
    }
    Ok(trimmed.to_string())
}

pub(crate) fn resolve_directory(
    preferred: Option<&str>,
    fallback: Option<&str>,
) -> Result<String, OpenCodeBridgeError> {
    preferred
        .or(fallback)
        .ok_or(OpenCodeBridgeError::MissingDirectoryContext {
            operation: "mapping",
        })
        .and_then(|directory| normalize_directory(directory, "mapping"))
}
