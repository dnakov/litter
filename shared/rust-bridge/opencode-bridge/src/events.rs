use serde::{Deserialize, Deserializer};
use serde_json::Value;

use crate::types::{
    OpenCodeFileDiff, OpenCodeMessage, OpenCodeMessageError, OpenCodeMessagePart,
    OpenCodePermission, OpenCodePermissionId, OpenCodePermissionResponse, OpenCodeSession,
    OpenCodeSessionStatus,
};

#[derive(Debug, Clone, PartialEq)]
pub enum OpenCodeEvent {
    ServerConnected,
    ServerHeartbeat,
    MessageUpdated {
        info: OpenCodeMessage,
    },
    MessagePartUpdated {
        part: OpenCodeMessagePart,
        delta: Option<String>,
    },
    MessagePartDelta {
        session_id: String,
        message_id: String,
        part_id: String,
        field: String,
        delta: String,
    },
    MessagePartRemoved {
        session_id: String,
        message_id: String,
        part_id: String,
    },
    PermissionUpdated {
        permission: OpenCodePermission,
    },
    PermissionReplied {
        session_id: String,
        permission_id: OpenCodePermissionId,
        response: OpenCodePermissionResponse,
    },
    SessionCreated {
        info: OpenCodeSession,
    },
    SessionUpdated {
        info: OpenCodeSession,
    },
    SessionDeleted {
        info: OpenCodeSession,
    },
    SessionStatus {
        session_id: String,
        status: OpenCodeSessionStatus,
    },
    SessionIdle {
        session_id: String,
    },
    SessionDiff {
        session_id: String,
        diff: Vec<OpenCodeFileDiff>,
    },
    SessionError {
        session_id: Option<String>,
        error: Option<OpenCodeMessageError>,
    },
    Unknown {
        event_type: String,
        raw: Value,
    },
}

impl<'de> Deserialize<'de> for OpenCodeEvent {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = Value::deserialize(deserializer)?;
        let event_type = raw
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();
        let properties = raw.get("properties").cloned().unwrap_or(Value::Null);

        match event_type.as_str() {
            "server.connected" => Ok(Self::ServerConnected),
            "server.heartbeat" => Ok(Self::ServerHeartbeat),
            "message.updated" => {
                #[derive(Deserialize)]
                struct Payload {
                    info: OpenCodeMessage,
                }

                let payload = serde_json::from_value::<Payload>(properties)
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::MessageUpdated { info: payload.info })
            }
            "message.part.updated" => {
                #[derive(Deserialize)]
                struct Payload {
                    part: OpenCodeMessagePart,
                    delta: Option<String>,
                }

                let payload = serde_json::from_value::<Payload>(properties)
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::MessagePartUpdated {
                    part: payload.part,
                    delta: payload.delta,
                })
            }
            "message.part.delta" => {
                #[derive(Deserialize)]
                struct Payload {
                    #[serde(rename = "sessionID")]
                    session_id: String,
                    #[serde(rename = "messageID")]
                    message_id: String,
                    #[serde(rename = "partID")]
                    part_id: String,
                    field: String,
                    delta: String,
                }

                let payload = serde_json::from_value::<Payload>(properties)
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::MessagePartDelta {
                    session_id: payload.session_id,
                    message_id: payload.message_id,
                    part_id: payload.part_id,
                    field: payload.field,
                    delta: payload.delta,
                })
            }
            "message.part.removed" => {
                #[derive(Deserialize)]
                struct Payload {
                    #[serde(rename = "sessionID")]
                    session_id: String,
                    #[serde(rename = "messageID")]
                    message_id: String,
                    #[serde(rename = "partID")]
                    part_id: String,
                }

                let payload = serde_json::from_value::<Payload>(properties)
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::MessagePartRemoved {
                    session_id: payload.session_id,
                    message_id: payload.message_id,
                    part_id: payload.part_id,
                })
            }
            "permission.updated" | "permission.asked" => {
                let permission = serde_json::from_value::<OpenCodePermission>(properties)
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::PermissionUpdated { permission })
            }
            "permission.replied" => {
                #[derive(Deserialize)]
                struct Payload {
                    #[serde(rename = "sessionID")]
                    session_id: String,
                    #[serde(rename = "permissionID")]
                    permission_id: Option<OpenCodePermissionId>,
                    #[serde(rename = "requestID")]
                    request_id: Option<OpenCodePermissionId>,
                    response: Option<OpenCodePermissionResponse>,
                    reply: Option<OpenCodePermissionResponse>,
                }

                let payload = serde_json::from_value::<Payload>(properties)
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::PermissionReplied {
                    session_id: payload.session_id,
                    permission_id: payload.permission_id.or(payload.request_id).ok_or_else(
                        || serde::de::Error::custom("permission.replied missing permission id"),
                    )?,
                    response: payload.response.or(payload.reply).ok_or_else(|| {
                        serde::de::Error::custom("permission.replied missing response")
                    })?,
                })
            }
            "session.created" => {
                let info =
                    deserialize_session_info(properties).map_err(serde::de::Error::custom)?;
                Ok(Self::SessionCreated { info })
            }
            "session.updated" => {
                let info =
                    deserialize_session_info(properties).map_err(serde::de::Error::custom)?;
                Ok(Self::SessionUpdated { info })
            }
            "session.deleted" => {
                let info =
                    deserialize_session_info(properties).map_err(serde::de::Error::custom)?;
                Ok(Self::SessionDeleted { info })
            }
            "session.status" => {
                #[derive(Deserialize)]
                struct Payload {
                    #[serde(rename = "sessionID")]
                    session_id: String,
                    status: OpenCodeSessionStatus,
                }

                let payload = serde_json::from_value::<Payload>(properties)
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::SessionStatus {
                    session_id: payload.session_id,
                    status: payload.status,
                })
            }
            "session.idle" => {
                #[derive(Deserialize)]
                struct Payload {
                    #[serde(rename = "sessionID")]
                    session_id: String,
                }

                let payload = serde_json::from_value::<Payload>(properties)
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::SessionIdle {
                    session_id: payload.session_id,
                })
            }
            "session.diff" => {
                #[derive(Deserialize)]
                struct Payload {
                    #[serde(rename = "sessionID")]
                    session_id: String,
                    diff: Vec<OpenCodeFileDiff>,
                }

                let payload = serde_json::from_value::<Payload>(properties)
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::SessionDiff {
                    session_id: payload.session_id,
                    diff: payload.diff,
                })
            }
            "session.error" => {
                #[derive(Deserialize)]
                struct Payload {
                    #[serde(rename = "sessionID")]
                    session_id: Option<String>,
                    error: Option<OpenCodeMessageError>,
                }

                let payload = serde_json::from_value::<Payload>(properties)
                    .map_err(serde::de::Error::custom)?;
                Ok(Self::SessionError {
                    session_id: payload.session_id,
                    error: payload.error,
                })
            }
            _ => Ok(Self::Unknown { event_type, raw }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OpenCodeGlobalEvent {
    pub directory: Option<String>,
    pub project: Option<String>,
    pub workspace: Option<String>,
    pub payload: OpenCodeEvent,
}

fn deserialize_session_event<E, F>(properties: Value, build: F) -> Result<E, serde_json::Error>
where
    F: FnOnce(OpenCodeSession) -> E,
{
    #[derive(Deserialize)]
    struct Payload {
        info: OpenCodeSession,
    }

    serde_json::from_value::<Payload>(properties).map(|payload| build(payload.info))
}

fn deserialize_session_info(properties: Value) -> Result<OpenCodeSession, serde_json::Error> {
    deserialize_session_event(properties, |info| info)
}
