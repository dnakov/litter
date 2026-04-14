mod fixtures;

use opencode_bridge::{
    OpenCodeCapabilities, OpenCodeEvent, OpenCodeGlobalEvent, OpenCodeMessagePart,
    OpenCodeMessageWithParts, OpenCodeProviderAuthMethods, OpenCodeProviderAuthState,
    OpenCodeRequestContext, OpenCodeSession, OpenCodeSessionCreateRequest,
    OpenCodeSessionListQuery, OpenCodeSessionStatus, OpenCodeSessionStatusIndex,
};
use serde_json::from_str;

#[test]
fn deserialize_session_list_preserves_directory() {
    let sessions = from_str::<Vec<OpenCodeSession>>(fixtures::json("session_list.json")).unwrap();

    assert_eq!(sessions.len(), 2);
    assert_eq!(
        sessions[0].directory,
        "/Users/franklin/Development/OpenSource/litter"
    );
    assert_eq!(sessions[1].directory, "/tmp/other-project");
}

#[test]
fn deserialize_session_create_response() {
    let session = from_str::<OpenCodeSession>(fixtures::json("session_created.json")).unwrap();

    assert_eq!(session.id, "sess_created");
    assert_eq!(
        session.directory,
        "/Users/franklin/Development/OpenSource/litter"
    );
    assert_eq!(session.parent_id.as_deref(), Some("sess_root"));
}

#[test]
fn deserialize_session_status_index() {
    let statuses =
        from_str::<OpenCodeSessionStatusIndex>(fixtures::json("session_status.json")).unwrap();

    assert!(matches!(
        statuses.get("sess_created"),
        Some(OpenCodeSessionStatus::Busy)
    ));
    assert!(matches!(
        statuses.get("sess_retry"),
        Some(OpenCodeSessionStatus::Retry { attempt: 2, .. })
    ));
}

#[test]
fn deserialize_message_history_with_known_parts() {
    let messages = from_str::<Vec<OpenCodeMessageWithParts>>(fixtures::json(
        "messages_text_reasoning_tool.json",
    ))
    .unwrap();

    assert_eq!(messages.len(), 2);
    assert_eq!(messages[0].info.session_id, "sess_created");

    let assistant_parts = &messages[1].parts;
    assert!(
        assistant_parts
            .iter()
            .any(|part| matches!(part, OpenCodeMessagePart::Text(_)))
    );
    assert!(
        assistant_parts
            .iter()
            .any(|part| matches!(part, OpenCodeMessagePart::Reasoning(_)))
    );
    assert!(
        assistant_parts
            .iter()
            .any(|part| matches!(part, OpenCodeMessagePart::Tool(_)))
    );
    assert!(
        assistant_parts
            .iter()
            .any(|part| matches!(part, OpenCodeMessagePart::File(_)))
    );
    assert!(
        assistant_parts
            .iter()
            .any(|part| matches!(part, OpenCodeMessagePart::Patch(_)))
    );
    assert!(
        assistant_parts
            .iter()
            .any(|part| matches!(part, OpenCodeMessagePart::StepStart(_)))
    );
    assert!(
        assistant_parts
            .iter()
            .any(|part| matches!(part, OpenCodeMessagePart::StepFinish(_)))
    );
}

#[test]
fn unknown_part_deserializes_and_keeps_raw_payload() {
    let part = from_str::<OpenCodeMessagePart>(fixtures::json("unknown_part.json")).unwrap();

    match part {
        OpenCodeMessagePart::Unknown(unknown) => {
            assert_eq!(unknown.part_type, "compaction");
            assert_eq!(unknown.raw["auto"], true);
        }
        other => panic!("expected unknown part, got {other:?}"),
    }
}

#[test]
fn unknown_event_deserializes_and_keeps_raw_payload() {
    let event = from_str::<OpenCodeEvent>(fixtures::json("unknown_event.json")).unwrap();

    match event {
        OpenCodeEvent::Unknown { event_type, raw } => {
            assert_eq!(event_type, "session.archived");
            assert_eq!(raw["properties"]["reason"], "manual");
        }
        other => panic!("expected unknown event, got {other:?}"),
    }
}

#[test]
fn global_event_envelope_preserves_directory() {
    let event =
        from_str::<OpenCodeGlobalEvent>(fixtures::json("event_global_message_updated.json"))
            .unwrap();

    assert_eq!(
        event.directory.as_deref(),
        Some("/Users/franklin/Development/OpenSource/litter")
    );
    assert_eq!(event.project.as_deref(), Some("litter"));
    assert_eq!(event.workspace.as_deref(), Some("workspace-main"));
    assert!(matches!(
        event.payload,
        OpenCodeEvent::MessageUpdated { .. }
    ));
}

#[test]
fn capabilities_report_directory_scoped_sessions_supported() {
    let capabilities = OpenCodeCapabilities::phase1_defaults();

    assert!(capabilities.supports_directory_scoped_sessions);
    assert!(!capabilities.supports_archive);
    assert!(!capabilities.supports_provider_login);
}

#[test]
fn request_context_requires_directory_for_session_operations() {
    let missing = OpenCodeRequestContext::default();
    assert!(missing.require_directory_for("session prompt").is_err());

    let context =
        OpenCodeRequestContext::new("/Users/franklin/Development/OpenSource/litter").unwrap();
    assert_eq!(
        context.require_directory_for("session prompt").unwrap(),
        "/Users/franklin/Development/OpenSource/litter"
    );

    let list_query = OpenCodeSessionListQuery {
        context: context.clone(),
        roots: Some(true),
        start: None,
        search: None,
        limit: Some(25),
    };
    assert_eq!(
        list_query.require_directory().unwrap(),
        context.directory.as_deref().unwrap()
    );

    let create_request = OpenCodeSessionCreateRequest {
        context,
        parent_id: Some("sess_root".to_string()),
        title: Some("Follow-up".to_string()),
        workspace_id: None,
    };
    assert_eq!(
        create_request.require_directory().unwrap(),
        "/Users/franklin/Development/OpenSource/litter"
    );
}

#[test]
fn provider_catalog_derives_auth_state_from_connected_and_auth_methods() {
    let catalog = serde_json::from_str::<opencode_bridge::OpenCodeProviderCatalog>(fixtures::json(
        "provider_list.json",
    ))
    .unwrap();

    let auth_methods = from_str::<OpenCodeProviderAuthMethods>(
        r#"{"anthropic":[{"type":"api","label":"API key"}]}"#,
    )
    .unwrap();

    assert_eq!(
        catalog.auth_state_for("openai", Some(&auth_methods)),
        OpenCodeProviderAuthState::Connected
    );
    assert_eq!(
        catalog.auth_state_for("anthropic", Some(&auth_methods)),
        OpenCodeProviderAuthState::AuthSupported
    );
    assert_eq!(
        catalog.auth_state_for("local", Some(&auth_methods)),
        OpenCodeProviderAuthState::Unavailable
    );
}
