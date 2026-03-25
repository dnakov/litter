use serde::{Deserialize, Serialize};

use crate::protocol::envelope::{Broadcast, Request};
use crate::protocol::method::Method;

// Re-exports from upstream crates.
pub use codex_app_server_protocol::{
    CommandExecutionApprovalDecision, FileChangeApprovalDecision,
    McpServerElicitationRequestResponse, ToolRequestUserInputResponse, TurnStartParams, UserInput,
};
pub use codex_protocol::config_types::CollaborationMode;
pub use codex_protocol::openai_models::ReasoningEffort;

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InitializeParams {
    pub client_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InitializeResult {
    pub client_id: String,
}

// ---------------------------------------------------------------------------
// Broadcast param types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ClientStatus {
    Connected,
    Disconnected,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientStatusChangedParams {
    pub client_id: String,
    pub client_type: String,
    pub status: ClientStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum StreamChange {
    Snapshot {
        #[serde(rename = "conversationState")]
        conversation_state: serde_json::Value,
    },
    Patches {
        patches: Vec<ImmerPatch>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImmerPatch {
    pub op: ImmerOp,
    pub path: Vec<ImmerPathSegment>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ImmerOp {
    Add,
    Remove,
    Replace,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ImmerPathSegment {
    Index(usize),
    Key(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadStreamStateChangedParams {
    pub conversation_id: String,
    pub change: StreamChange,
    pub version: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadArchivedParams {
    pub host_id: String,
    pub conversation_id: String,
    pub cwd: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadUnarchivedParams {
    pub host_id: String,
    pub conversation_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadQueuedFollowupsChangedParams {
    pub conversation_id: String,
    pub messages: Vec<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryCacheInvalidateParams {
    pub query_key: Vec<serde_json::Value>,
}

// ---------------------------------------------------------------------------
// Follower request param types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadFollowerStartTurnParams {
    pub conversation_id: String,
    pub turn_start_params: TurnStartParams,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadFollowerSteerTurnParams {
    pub conversation_id: String,
    pub input: Vec<UserInput>,
    pub attachments: Vec<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub restore_message: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadFollowerInterruptTurnParams {
    pub conversation_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadFollowerSetModelAndReasoningParams {
    pub conversation_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<ReasoningEffort>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadFollowerSetCollaborationModeParams {
    pub conversation_id: String,
    pub collaboration_mode: CollaborationMode,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadFollowerEditLastUserTurnParams {
    pub conversation_id: String,
    pub turn_id: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_mode: Option<CollaborationMode>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadFollowerCommandApprovalDecisionParams {
    pub conversation_id: String,
    pub request_id: String,
    pub decision: CommandExecutionApprovalDecision,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadFollowerFileApprovalDecisionParams {
    pub conversation_id: String,
    pub request_id: String,
    pub decision: FileChangeApprovalDecision,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadFollowerSubmitUserInputParams {
    pub conversation_id: String,
    pub request_id: String,
    pub response: ToolRequestUserInputResponse,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadFollowerSubmitMcpServerElicitationResponseParams {
    pub conversation_id: String,
    pub request_id: String,
    pub response: McpServerElicitationRequestResponse,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadFollowerSetQueuedFollowUpsStateParams {
    pub conversation_id: String,
    pub state: serde_json::Value,
}

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OkResult {
    pub ok: bool,
}

// ---------------------------------------------------------------------------
// Typed dispatch enums
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub enum TypedBroadcast {
    ClientStatusChanged(ClientStatusChangedParams),
    ThreadStreamStateChanged(ThreadStreamStateChangedParams),
    ThreadArchived(ThreadArchivedParams),
    ThreadUnarchived(ThreadUnarchivedParams),
    ThreadQueuedFollowupsChanged(ThreadQueuedFollowupsChangedParams),
    QueryCacheInvalidate(QueryCacheInvalidateParams),
    Unknown {
        method: String,
        params: serde_json::Value,
    },
}

impl TypedBroadcast {
    pub fn from_broadcast(b: &Broadcast) -> Self {
        match Method::from_wire(&b.method) {
            Some(Method::ClientStatusChanged) => {
                match serde_json::from_value(b.params.clone()) {
                    Ok(p) => TypedBroadcast::ClientStatusChanged(p),
                    Err(_) => TypedBroadcast::Unknown {
                        method: b.method.clone(),
                        params: b.params.clone(),
                    },
                }
            }
            Some(Method::ThreadStreamStateChanged) => {
                match serde_json::from_value(b.params.clone()) {
                    Ok(p) => TypedBroadcast::ThreadStreamStateChanged(p),
                    Err(_) => TypedBroadcast::Unknown {
                        method: b.method.clone(),
                        params: b.params.clone(),
                    },
                }
            }
            Some(Method::ThreadArchived) => match serde_json::from_value(b.params.clone()) {
                Ok(p) => TypedBroadcast::ThreadArchived(p),
                Err(_) => TypedBroadcast::Unknown {
                    method: b.method.clone(),
                    params: b.params.clone(),
                },
            },
            Some(Method::ThreadUnarchived) => match serde_json::from_value(b.params.clone()) {
                Ok(p) => TypedBroadcast::ThreadUnarchived(p),
                Err(_) => TypedBroadcast::Unknown {
                    method: b.method.clone(),
                    params: b.params.clone(),
                },
            },
            Some(Method::ThreadQueuedFollowupsChanged) => {
                match serde_json::from_value(b.params.clone()) {
                    Ok(p) => TypedBroadcast::ThreadQueuedFollowupsChanged(p),
                    Err(_) => TypedBroadcast::Unknown {
                        method: b.method.clone(),
                        params: b.params.clone(),
                    },
                }
            }
            Some(Method::QueryCacheInvalidate) => {
                match serde_json::from_value(b.params.clone()) {
                    Ok(p) => TypedBroadcast::QueryCacheInvalidate(p),
                    Err(_) => TypedBroadcast::Unknown {
                        method: b.method.clone(),
                        params: b.params.clone(),
                    },
                }
            }
            _ => TypedBroadcast::Unknown {
                method: b.method.clone(),
                params: b.params.clone(),
            },
        }
    }
}

#[derive(Debug, Clone)]
pub enum TypedRequest {
    StartTurn(ThreadFollowerStartTurnParams),
    SteerTurn(ThreadFollowerSteerTurnParams),
    InterruptTurn(ThreadFollowerInterruptTurnParams),
    SetModelAndReasoning(ThreadFollowerSetModelAndReasoningParams),
    SetCollaborationMode(ThreadFollowerSetCollaborationModeParams),
    EditLastUserTurn(ThreadFollowerEditLastUserTurnParams),
    CommandApprovalDecision(ThreadFollowerCommandApprovalDecisionParams),
    FileApprovalDecision(ThreadFollowerFileApprovalDecisionParams),
    SubmitUserInput(ThreadFollowerSubmitUserInputParams),
    SubmitMcpServerElicitationResponse(ThreadFollowerSubmitMcpServerElicitationResponseParams),
    SetQueuedFollowUpsState(ThreadFollowerSetQueuedFollowUpsStateParams),
    Unknown {
        method: String,
        params: serde_json::Value,
    },
}

impl TypedRequest {
    pub fn from_request(r: &Request) -> Self {
        match Method::from_wire(&r.method) {
            Some(Method::ThreadFollowerStartTurn) => {
                match serde_json::from_value(r.params.clone()) {
                    Ok(p) => TypedRequest::StartTurn(p),
                    Err(_) => TypedRequest::Unknown {
                        method: r.method.clone(),
                        params: r.params.clone(),
                    },
                }
            }
            Some(Method::ThreadFollowerSteerTurn) => {
                match serde_json::from_value(r.params.clone()) {
                    Ok(p) => TypedRequest::SteerTurn(p),
                    Err(_) => TypedRequest::Unknown {
                        method: r.method.clone(),
                        params: r.params.clone(),
                    },
                }
            }
            Some(Method::ThreadFollowerInterruptTurn) => {
                match serde_json::from_value(r.params.clone()) {
                    Ok(p) => TypedRequest::InterruptTurn(p),
                    Err(_) => TypedRequest::Unknown {
                        method: r.method.clone(),
                        params: r.params.clone(),
                    },
                }
            }
            Some(Method::ThreadFollowerSetModelAndReasoning) => {
                match serde_json::from_value(r.params.clone()) {
                    Ok(p) => TypedRequest::SetModelAndReasoning(p),
                    Err(_) => TypedRequest::Unknown {
                        method: r.method.clone(),
                        params: r.params.clone(),
                    },
                }
            }
            Some(Method::ThreadFollowerSetCollaborationMode) => {
                match serde_json::from_value(r.params.clone()) {
                    Ok(p) => TypedRequest::SetCollaborationMode(p),
                    Err(_) => TypedRequest::Unknown {
                        method: r.method.clone(),
                        params: r.params.clone(),
                    },
                }
            }
            Some(Method::ThreadFollowerEditLastUserTurn) => {
                match serde_json::from_value(r.params.clone()) {
                    Ok(p) => TypedRequest::EditLastUserTurn(p),
                    Err(_) => TypedRequest::Unknown {
                        method: r.method.clone(),
                        params: r.params.clone(),
                    },
                }
            }
            Some(Method::ThreadFollowerCommandApprovalDecision) => {
                match serde_json::from_value(r.params.clone()) {
                    Ok(p) => TypedRequest::CommandApprovalDecision(p),
                    Err(_) => TypedRequest::Unknown {
                        method: r.method.clone(),
                        params: r.params.clone(),
                    },
                }
            }
            Some(Method::ThreadFollowerFileApprovalDecision) => {
                match serde_json::from_value(r.params.clone()) {
                    Ok(p) => TypedRequest::FileApprovalDecision(p),
                    Err(_) => TypedRequest::Unknown {
                        method: r.method.clone(),
                        params: r.params.clone(),
                    },
                }
            }
            Some(Method::ThreadFollowerSubmitUserInput) => {
                match serde_json::from_value(r.params.clone()) {
                    Ok(p) => TypedRequest::SubmitUserInput(p),
                    Err(_) => TypedRequest::Unknown {
                        method: r.method.clone(),
                        params: r.params.clone(),
                    },
                }
            }
            Some(Method::ThreadFollowerSubmitMcpServerElicitationResponse) => {
                match serde_json::from_value(r.params.clone()) {
                    Ok(p) => TypedRequest::SubmitMcpServerElicitationResponse(p),
                    Err(_) => TypedRequest::Unknown {
                        method: r.method.clone(),
                        params: r.params.clone(),
                    },
                }
            }
            Some(Method::ThreadFollowerSetQueuedFollowUpsState) => {
                match serde_json::from_value(r.params.clone()) {
                    Ok(p) => TypedRequest::SetQueuedFollowUpsState(p),
                    Err(_) => TypedRequest::Unknown {
                        method: r.method.clone(),
                        params: r.params.clone(),
                    },
                }
            }
            _ => TypedRequest::Unknown {
                method: r.method.clone(),
                params: r.params.clone(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn deserialize_client_status_changed_params() {
        let j = json!({
            "clientId": "c1",
            "clientType": "desktop",
            "status": "connected"
        });
        let p: ClientStatusChangedParams = serde_json::from_value(j).unwrap();
        assert_eq!(p.client_id, "c1");
        assert_eq!(p.client_type, "desktop");
        assert!(matches!(p.status, ClientStatus::Connected));
    }

    #[test]
    fn deserialize_stream_state_snapshot() {
        let j = json!({
            "conversationId": "conv-1",
            "change": {
                "type": "snapshot",
                "conversationState": {"key": "value"}
            },
            "version": 5
        });
        let p: ThreadStreamStateChangedParams = serde_json::from_value(j).unwrap();
        assert_eq!(p.conversation_id, "conv-1");
        assert_eq!(p.version, 5);
        assert!(matches!(p.change, StreamChange::Snapshot { .. }));
    }

    #[test]
    fn deserialize_stream_state_patches() {
        let j = json!({
            "conversationId": "conv-1",
            "change": {
                "type": "patches",
                "patches": [
                    {
                        "op": "replace",
                        "path": ["items", 0, "text"],
                        "value": "hello"
                    },
                    {
                        "op": "add",
                        "path": ["items", 1],
                        "value": {"id": "new"}
                    },
                    {
                        "op": "remove",
                        "path": ["items", 2]
                    }
                ]
            },
            "version": 6
        });
        let p: ThreadStreamStateChangedParams = serde_json::from_value(j).unwrap();
        if let StreamChange::Patches { patches } = &p.change {
            assert_eq!(patches.len(), 3);
            assert!(matches!(patches[0].op, ImmerOp::Replace));
            // Check mixed path segments
            assert!(matches!(&patches[0].path[0], ImmerPathSegment::Key(k) if k == "items"));
            assert!(matches!(patches[0].path[1], ImmerPathSegment::Index(0)));
            assert!(matches!(&patches[0].path[2], ImmerPathSegment::Key(k) if k == "text"));
            assert!(patches[0].value.is_some());
            assert!(matches!(patches[2].op, ImmerOp::Remove));
            assert!(patches[2].value.is_none());
        } else {
            panic!("expected Patches");
        }
    }

    #[test]
    fn deserialize_interrupt_turn_params() {
        let j = json!({"conversationId": "conv-1"});
        let p: ThreadFollowerInterruptTurnParams = serde_json::from_value(j).unwrap();
        assert_eq!(p.conversation_id, "conv-1");
    }

    #[test]
    fn roundtrip_ok_result() {
        let r = OkResult { ok: true };
        let j = serde_json::to_value(&r).unwrap();
        assert_eq!(j, json!({"ok": true}));
        let r2: OkResult = serde_json::from_value(j).unwrap();
        assert!(r2.ok);
    }

    #[test]
    fn typed_broadcast_dispatches_known_methods() {
        let b = Broadcast {
            method: "client-status-changed".into(),
            source_client_id: "src".into(),
            version: 0,
            params: json!({
                "clientId": "c1",
                "clientType": "desktop",
                "status": "disconnected"
            }),
        };
        let tb = TypedBroadcast::from_broadcast(&b);
        assert!(matches!(tb, TypedBroadcast::ClientStatusChanged(_)));

        let b2 = Broadcast {
            method: "thread-archived".into(),
            source_client_id: "src".into(),
            version: 2,
            params: json!({
                "hostId": "h1",
                "conversationId": "conv-1",
                "cwd": "/tmp"
            }),
        };
        let tb2 = TypedBroadcast::from_broadcast(&b2);
        assert!(matches!(tb2, TypedBroadcast::ThreadArchived(_)));
    }

    #[test]
    fn typed_request_dispatches_known_methods() {
        let r = Request {
            request_id: "r1".into(),
            source_client_id: "src".into(),
            version: 1,
            method: "thread-follower-interrupt-turn".into(),
            params: json!({"conversationId": "conv-1"}),
            target_client_id: None,
        };
        let tr = TypedRequest::from_request(&r);
        assert!(matches!(tr, TypedRequest::InterruptTurn(_)));
    }

    #[test]
    fn unknown_method_produces_unknown_variant() {
        let b = Broadcast {
            method: "some-future-method".into(),
            source_client_id: "src".into(),
            version: 0,
            params: json!({"foo": "bar"}),
        };
        let tb = TypedBroadcast::from_broadcast(&b);
        assert!(matches!(tb, TypedBroadcast::Unknown { .. }));

        let r = Request {
            request_id: "r1".into(),
            source_client_id: "src".into(),
            version: 1,
            method: "some-future-method".into(),
            params: json!({"foo": "bar"}),
            target_client_id: None,
        };
        let tr = TypedRequest::from_request(&r);
        assert!(matches!(tr, TypedRequest::Unknown { .. }));
    }

    #[test]
    fn malformed_params_falls_back_to_unknown() {
        let b = Broadcast {
            method: "client-status-changed".into(),
            source_client_id: "src".into(),
            version: 0,
            params: json!("not-an-object"),
        };
        let tb = TypedBroadcast::from_broadcast(&b);
        assert!(matches!(tb, TypedBroadcast::Unknown { .. }));
    }
}
