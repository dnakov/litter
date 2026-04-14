use serde::{Deserialize, Serialize};

use crate::{
    OpenCodeBridgeError, OpenCodeFileDiff, OpenCodeMessageError, OpenCodeSession,
    OpenCodeSessionStatus,
};

use super::{OpenCodeMappedError, OpenCodeMappingScope, resolve_directory};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OpenCodeThreadState {
    Idle,
    Running,
    Retrying,
    Error,
    Unknown(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeRetryState {
    pub attempt: u32,
    pub message: String,
    pub next_at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeChangedFile {
    pub path: String,
    pub before: String,
    pub after: String,
    pub additions: u32,
    pub deletions: u32,
}

impl From<&OpenCodeFileDiff> for OpenCodeChangedFile {
    fn from(value: &OpenCodeFileDiff) -> Self {
        Self {
            path: value.file.clone(),
            before: value.before.clone(),
            after: value.after.clone(),
            additions: value.additions,
            deletions: value.deletions,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeThreadSummary {
    pub thread_key: crate::OpenCodeThreadKey,
    pub title: String,
    pub cwd: String,
    pub parent_thread_id: Option<String>,
    pub created_at: u64,
    pub updated_at: u64,
    pub state: OpenCodeThreadState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry: Option<OpenCodeRetryState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub changed_files: Vec<OpenCodeChangedFile>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeThreadStateUpdate {
    pub thread_key: crate::OpenCodeThreadKey,
    pub state: OpenCodeThreadState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry: Option<OpenCodeRetryState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<OpenCodeMappedError>,
}

pub fn map_thread_summary(
    scope: &OpenCodeMappingScope,
    session: &OpenCodeSession,
    status: Option<&OpenCodeSessionStatus>,
) -> Result<OpenCodeThreadSummary, OpenCodeBridgeError> {
    let directory = resolve_directory(
        Some(session.directory.as_str()),
        Some(scope.directory.as_str()),
    )?;
    let thread_key = crate::OpenCodeThreadKey::new(
        scope.server_id.clone(),
        directory.clone(),
        session.id.clone(),
    )?;
    let (state, retry) = map_status(status.unwrap_or(&OpenCodeSessionStatus::Idle));

    Ok(OpenCodeThreadSummary {
        thread_key,
        title: session.title.clone(),
        cwd: directory,
        parent_thread_id: session.parent_id.clone(),
        created_at: session.time.created,
        updated_at: session.time.updated,
        state,
        retry,
        project_id: Some(session.project_id.clone()),
        version: Some(session.version.clone()),
        changed_files: session
            .summary
            .as_ref()
            .map(|summary| {
                summary
                    .diffs
                    .iter()
                    .map(OpenCodeChangedFile::from)
                    .collect()
            })
            .unwrap_or_default(),
    })
}

pub fn map_thread_summaries(
    scope: &OpenCodeMappingScope,
    sessions: &[OpenCodeSession],
    statuses: &crate::OpenCodeSessionStatusIndex,
) -> Result<Vec<OpenCodeThreadSummary>, OpenCodeBridgeError> {
    sessions
        .iter()
        .map(|session| map_thread_summary(scope, session, statuses.get(&session.id)))
        .collect()
}

pub fn map_thread_state_update(
    scope: &OpenCodeMappingScope,
    session_id: &str,
    status: Option<&OpenCodeSessionStatus>,
    error: Option<&OpenCodeMessageError>,
) -> Result<OpenCodeThreadStateUpdate, OpenCodeBridgeError> {
    let thread_key = scope.thread_key(session_id.to_string())?;
    let (state, retry) = if error.is_some() {
        (OpenCodeThreadState::Error, None)
    } else {
        map_status(status.unwrap_or(&OpenCodeSessionStatus::Idle))
    };

    Ok(OpenCodeThreadStateUpdate {
        thread_key,
        state,
        retry,
        error: error.map(super::map_error),
    })
}

fn map_status(status: &OpenCodeSessionStatus) -> (OpenCodeThreadState, Option<OpenCodeRetryState>) {
    match status {
        OpenCodeSessionStatus::Idle => (OpenCodeThreadState::Idle, None),
        OpenCodeSessionStatus::Busy => (OpenCodeThreadState::Running, None),
        OpenCodeSessionStatus::Retry {
            attempt,
            message,
            next,
        } => (
            OpenCodeThreadState::Retrying,
            Some(OpenCodeRetryState {
                attempt: *attempt,
                message: message.clone(),
                next_at: *next,
            }),
        ),
        OpenCodeSessionStatus::Unknown { kind, .. } => {
            (OpenCodeThreadState::Unknown(kind.clone()), None)
        }
    }
}
