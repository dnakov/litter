use serde::{Deserialize, Serialize};

/// Top-level discriminated union for IPC messages.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum Envelope {
    Request(Request),
    Response(Response),
    Broadcast(Broadcast),
    ClientDiscoveryRequest(ClientDiscoveryRequest),
    ClientDiscoveryResponse(ClientDiscoveryResponse),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub request_id: String,
    pub source_client_id: String,
    pub version: u32,
    pub method: String,
    pub params: serde_json::Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_client_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "resultType", rename_all = "kebab-case")]
pub enum Response {
    #[serde(rename_all = "camelCase")]
    Success {
        request_id: String,
        method: String,
        handled_by_client_id: String,
        result: serde_json::Value,
    },
    #[serde(rename_all = "camelCase")]
    Error { request_id: String, error: String },
}

impl Response {
    pub fn request_id(&self) -> &str {
        match self {
            Response::Success { request_id, .. } => request_id,
            Response::Error { request_id, .. } => request_id,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Broadcast {
    pub method: String,
    pub source_client_id: String,
    pub version: u32,
    pub params: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientDiscoveryRequest {
    pub request_id: String,
    pub request: Request,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientDiscoveryResponse {
    pub request_id: String,
    pub response: DiscoveryAnswer,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveryAnswer {
    pub can_handle: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn roundtrip_request_envelope() {
        let json_str = r#"{"type":"request","requestId":"uuid","sourceClientId":"client-id","version":1,"method":"thread-follower-start-turn","params":{}}"#;
        let envelope: Envelope = serde_json::from_str(json_str).unwrap();
        assert!(matches!(envelope, Envelope::Request(_)));
        if let Envelope::Request(ref req) = envelope {
            assert_eq!(req.request_id, "uuid");
            assert_eq!(req.source_client_id, "client-id");
            assert_eq!(req.version, 1);
            assert_eq!(req.method, "thread-follower-start-turn");
            assert!(req.target_client_id.is_none());
        }
        // Roundtrip
        let serialized = serde_json::to_string(&envelope).unwrap();
        let reparsed: serde_json::Value = serde_json::from_str(&serialized).unwrap();
        let expected: serde_json::Value = serde_json::from_str(json_str).unwrap();
        assert_eq!(reparsed, expected);
    }

    #[test]
    fn roundtrip_success_response_envelope() {
        let json_str = r#"{"type":"response","requestId":"uuid","resultType":"success","method":"thread-follower-start-turn","handledByClientId":"client-id","result":{}}"#;
        let envelope: Envelope = serde_json::from_str(json_str).unwrap();
        assert!(matches!(
            envelope,
            Envelope::Response(Response::Success { .. })
        ));
        if let Envelope::Response(ref resp) = envelope {
            assert_eq!(resp.request_id(), "uuid");
        }
        let serialized = serde_json::to_string(&envelope).unwrap();
        let reparsed: serde_json::Value = serde_json::from_str(&serialized).unwrap();
        let expected: serde_json::Value = serde_json::from_str(json_str).unwrap();
        assert_eq!(reparsed, expected);
    }

    #[test]
    fn roundtrip_error_response_envelope() {
        let json_str = r#"{"type":"response","requestId":"uuid","resultType":"error","error":"no-client-found"}"#;
        let envelope: Envelope = serde_json::from_str(json_str).unwrap();
        assert!(matches!(
            envelope,
            Envelope::Response(Response::Error { .. })
        ));
        if let Envelope::Response(ref resp) = envelope {
            assert_eq!(resp.request_id(), "uuid");
            if let Response::Error { error, .. } = resp {
                assert_eq!(error, "no-client-found");
            }
        }
        let serialized = serde_json::to_string(&envelope).unwrap();
        let reparsed: serde_json::Value = serde_json::from_str(&serialized).unwrap();
        let expected: serde_json::Value = serde_json::from_str(json_str).unwrap();
        assert_eq!(reparsed, expected);
    }

    #[test]
    fn roundtrip_broadcast_envelope() {
        let json_str = r#"{"type":"broadcast","method":"client-status-changed","sourceClientId":"client-id","version":0,"params":{"clientId":"c1","clientType":"desktop","status":"connected"}}"#;
        let envelope: Envelope = serde_json::from_str(json_str).unwrap();
        assert!(matches!(envelope, Envelope::Broadcast(_)));
        if let Envelope::Broadcast(ref bc) = envelope {
            assert_eq!(bc.method, "client-status-changed");
            assert_eq!(bc.source_client_id, "client-id");
            assert_eq!(bc.version, 0);
            assert_eq!(bc.params["clientId"], "c1");
        }
        let serialized = serde_json::to_string(&envelope).unwrap();
        let reparsed: serde_json::Value = serde_json::from_str(&serialized).unwrap();
        let expected: serde_json::Value = serde_json::from_str(json_str).unwrap();
        assert_eq!(reparsed, expected);
    }

    #[test]
    fn roundtrip_client_discovery_request_envelope() {
        let inner_request = json!({
            "requestId": "req-1",
            "sourceClientId": "src",
            "version": 1,
            "method": "some-method",
            "params": {}
        });
        let json_val = json!({
            "type": "client-discovery-request",
            "requestId": "disc-1",
            "request": inner_request,
        });
        let json_str = serde_json::to_string(&json_val).unwrap();
        let envelope: Envelope = serde_json::from_str(&json_str).unwrap();
        assert!(matches!(envelope, Envelope::ClientDiscoveryRequest(_)));
        if let Envelope::ClientDiscoveryRequest(ref cdr) = envelope {
            assert_eq!(cdr.request_id, "disc-1");
            assert_eq!(cdr.request.method, "some-method");
        }
        let serialized = serde_json::to_string(&envelope).unwrap();
        let reparsed: serde_json::Value = serde_json::from_str(&serialized).unwrap();
        assert_eq!(reparsed, json_val);
    }

    #[test]
    fn roundtrip_client_discovery_response_envelope() {
        let json_val = json!({
            "type": "client-discovery-response",
            "requestId": "disc-1",
            "response": {
                "canHandle": true
            }
        });
        let json_str = serde_json::to_string(&json_val).unwrap();
        let envelope: Envelope = serde_json::from_str(&json_str).unwrap();
        assert!(matches!(envelope, Envelope::ClientDiscoveryResponse(_)));
        if let Envelope::ClientDiscoveryResponse(ref cdr) = envelope {
            assert_eq!(cdr.request_id, "disc-1");
            assert!(cdr.response.can_handle);
        }
        let serialized = serde_json::to_string(&envelope).unwrap();
        let reparsed: serde_json::Value = serde_json::from_str(&serialized).unwrap();
        assert_eq!(reparsed, json_val);
    }

    #[test]
    fn request_with_target_client_id() {
        let json_str = r#"{"type":"request","requestId":"uuid","sourceClientId":"src","version":1,"method":"m","params":{},"targetClientId":"target"}"#;
        let envelope: Envelope = serde_json::from_str(json_str).unwrap();
        if let Envelope::Request(ref req) = envelope {
            assert_eq!(req.target_client_id.as_deref(), Some("target"));
        } else {
            panic!("expected Request");
        }
    }

    #[test]
    fn request_without_target_client_id_omits_field() {
        let req = Request {
            request_id: "r".into(),
            source_client_id: "s".into(),
            version: 1,
            method: "m".into(),
            params: json!({}),
            target_client_id: None,
        };
        let envelope = Envelope::Request(req);
        let serialized = serde_json::to_string(&envelope).unwrap();
        assert!(!serialized.contains("targetClientId"));
    }
}
