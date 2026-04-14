use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    OpenCodeBridgeError, OpenCodePermission, OpenCodePermissionPattern, OpenCodePermissionState,
};

use super::OpenCodeMappingScope;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OpenCodeApprovalState {
    Pending,
    Replied,
    Unknown(String),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodePendingApproval {
    pub approval_id: String,
    pub thread_key: crate::OpenCodeThreadKey,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
    pub title: String,
    pub permission_type: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub patterns: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub always_patterns: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<u64>,
    pub state: OpenCodeApprovalState,
    pub metadata: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool: Option<Value>,
}

pub fn map_pending_approval(
    scope: &OpenCodeMappingScope,
    permission: &OpenCodePermission,
) -> Result<OpenCodePendingApproval, OpenCodeBridgeError> {
    Ok(OpenCodePendingApproval {
        approval_id: permission.id.0.clone(),
        thread_key: scope.thread_key(permission.session_id.clone())?,
        message_id: permission.message_id.clone(),
        call_id: permission.call_id.clone(),
        title: permission
            .title
            .clone()
            .unwrap_or_else(|| permission.permission_type.clone()),
        permission_type: permission.permission_type.clone(),
        patterns: flatten_patterns(permission),
        always_patterns: permission.always.clone(),
        created_at: permission.time.as_ref().map(|time| time.created),
        state: match &permission.state {
            Some(OpenCodePermissionState::Pending) => OpenCodeApprovalState::Pending,
            Some(OpenCodePermissionState::Replied) => OpenCodeApprovalState::Replied,
            Some(OpenCodePermissionState::Unknown(state)) => {
                OpenCodeApprovalState::Unknown(state.clone())
            }
            None => OpenCodeApprovalState::Pending,
        },
        metadata: permission.metadata.clone(),
        tool: permission.tool.clone(),
    })
}

fn flatten_patterns(permission: &OpenCodePermission) -> Vec<String> {
    let mut patterns = Vec::new();

    if let Some(pattern) = &permission.pattern {
        match pattern {
            OpenCodePermissionPattern::One(pattern) => patterns.push(pattern.clone()),
            OpenCodePermissionPattern::Many(values) => patterns.extend(values.clone()),
        }
    }

    patterns.extend(permission.patterns.clone());
    patterns.sort();
    patterns.dedup();
    patterns
}
