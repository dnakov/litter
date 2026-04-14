mod fixtures;

use opencode_bridge::{
    OpenCodeConversationDelta, OpenCodeConversationPart, OpenCodeEvent, OpenCodeMappingScope,
    OpenCodeMessage, OpenCodeMessagePart, OpenCodeMessageWithParts, OpenCodeProviderCatalog,
    OpenCodeSession, OpenCodeSessionStatus, OpenCodeSessionStatusIndex, OpenCodeThreadState,
    map_conversation_snapshot, map_event, map_message_part_delta, map_message_upsert,
    map_model_catalog, map_pending_approval, map_thread_state_update, map_thread_summary,
};
use serde_json::{from_str, json};

fn scope() -> OpenCodeMappingScope {
    OpenCodeMappingScope::new(
        "local-opencode",
        "/Users/franklin/Development/OpenSource/litter",
    )
    .unwrap()
}

#[test]
fn session_and_status_map_to_thread_summary_with_directory_identity() {
    let scope = scope();
    let session = from_str::<OpenCodeSession>(fixtures::json("session_created.json")).unwrap();
    let statuses =
        from_str::<OpenCodeSessionStatusIndex>(fixtures::json("session_status.json")).unwrap();

    let summary = map_thread_summary(&scope, &session, statuses.get(&session.id)).unwrap();

    assert_eq!(summary.thread_key.server_id, "local-opencode");
    assert_eq!(
        summary.thread_key.directory,
        "/Users/franklin/Development/OpenSource/litter"
    );
    assert_eq!(summary.thread_key.session_id, "sess_created");
    assert_eq!(summary.parent_thread_id.as_deref(), Some("sess_root"));
    assert_eq!(summary.state, OpenCodeThreadState::Running);
}

#[test]
fn idle_status_maps_to_idle_thread_state() {
    let update = map_thread_state_update(
        &scope(),
        "sess_created",
        Some(&OpenCodeSessionStatus::Idle),
        None,
    )
    .unwrap();

    assert_eq!(update.state, OpenCodeThreadState::Idle);
    assert_eq!(
        update.thread_key.directory,
        "/Users/franklin/Development/OpenSource/litter"
    );
}

#[test]
fn message_hydration_maps_text_reasoning_tool_file_patch_and_steps() {
    let scope = scope();
    let session = from_str::<OpenCodeSession>(fixtures::json("session_created.json")).unwrap();
    let messages = from_str::<Vec<OpenCodeMessageWithParts>>(fixtures::json(
        "messages_text_reasoning_tool.json",
    ))
    .unwrap();

    let snapshot = map_conversation_snapshot(&scope, &session, &messages).unwrap();

    assert_eq!(snapshot.thread_key.session_id, "sess_created");
    assert_eq!(snapshot.messages.len(), 2);
    assert_eq!(snapshot.messages[0].thread_key.directory, scope.directory);
    assert_eq!(snapshot.messages[1].thread_key.session_id, "sess_created");

    let assistant = &snapshot.messages[1];
    assert!(assistant.parts.iter().any(|part| matches!(
        part,
        OpenCodeConversationPart::Text(text) if text.streamable
    )));
    assert!(
        assistant
            .parts
            .iter()
            .any(|part| matches!(part, OpenCodeConversationPart::Reasoning(_)))
    );
    assert!(
        assistant
            .parts
            .iter()
            .any(|part| matches!(part, OpenCodeConversationPart::Tool(_)))
    );
    assert!(assistant.parts.iter().any(|part| matches!(
        part,
        OpenCodeConversationPart::File(file)
            if file.path.as_deref()
                == Some(
                    "/Users/franklin/Development/OpenSource/litter/shared/rust-bridge/opencode-bridge/src/types.rs"
                )
    )));
    assert!(
        assistant
            .parts
            .iter()
            .any(|part| matches!(part, OpenCodeConversationPart::Patch(_)))
    );
    assert_eq!(
        assistant
            .parts
            .iter()
            .filter(|part| matches!(part, OpenCodeConversationPart::StepBoundary(_)))
            .count(),
        2
    );
}

#[test]
fn message_part_updated_maps_to_part_delta_with_text_append() {
    let event =
        from_str::<OpenCodeEvent>(fixtures::json("message_part_updated_text.json")).unwrap();

    let outputs = map_event(&scope(), &event).unwrap();

    match &outputs[0] {
        opencode_bridge::OpenCodeMappedEvent::ConversationDelta(
            OpenCodeConversationDelta::PartUpsert(delta),
        ) => {
            assert_eq!(delta.thread_key.session_id, "sess_created");
            assert_eq!(delta.thread_key.directory, scope().directory);
            assert_eq!(delta.text_delta.as_deref(), Some(" continues"));
            match &delta.part {
                OpenCodeConversationPart::Text(text) => {
                    assert_eq!(text.text, "Streaming response");
                    assert!(text.streamable);
                }
                other => panic!("expected text part, got {other:?}"),
            }
        }
        other => panic!("expected conversation part upsert, got {other:?}"),
    }
}

#[test]
fn message_part_delta_maps_to_field_delta() {
    let event = from_str::<OpenCodeEvent>(fixtures::json("message_part_delta_text.json")).unwrap();

    let outputs = map_event(&scope(), &event).unwrap();

    match &outputs[0] {
        opencode_bridge::OpenCodeMappedEvent::ConversationDelta(
            OpenCodeConversationDelta::PartFieldDelta {
                thread_key,
                message_id,
                part_id,
                field,
                delta,
            },
        ) => {
            assert_eq!(thread_key.session_id, "sess_created");
            assert_eq!(thread_key.directory, scope().directory);
            assert_eq!(message_id, "msg_assistant_1");
            assert_eq!(part_id, "part_text_2");
            assert_eq!(field, "text");
            assert_eq!(delta, " continues");
        }
        other => panic!("expected conversation part field delta, got {other:?}"),
    }
}

#[test]
fn assistant_error_payload_maps_to_message_error() {
    let raw = json!({
        "id": "msg_assistant_error",
        "sessionID": "sess_created",
        "role": "assistant",
        "time": {
            "created": 1730000411000_u64
        },
        "error": {
            "name": "ProviderError",
            "data": {
                "retryable": true
            }
        }
    });
    let message = serde_json::from_value::<OpenCodeMessage>(raw).unwrap();

    let mapped = map_message_upsert(&scope(), &message).unwrap();

    assert_eq!(mapped.thread_key.session_id, "sess_created");
    assert_eq!(
        mapped.error.as_ref().map(|error| error.name.as_str()),
        Some("ProviderError")
    );
}

#[test]
fn permission_updated_maps_to_pending_approval() {
    let scope = scope();
    let event = from_str::<OpenCodeEvent>(fixtures::json("permission_updated.json")).unwrap();

    let approval = match event {
        OpenCodeEvent::PermissionUpdated { permission } => {
            map_pending_approval(&scope, &permission)
        }
        other => panic!("expected permission.updated fixture, got {other:?}"),
    }
    .unwrap();

    assert_eq!(approval.approval_id, "perm_1");
    assert_eq!(approval.thread_key.server_id, "local-opencode");
    assert_eq!(approval.thread_key.directory, scope.directory);
    assert_eq!(approval.thread_key.session_id, "sess_created");
    assert_eq!(
        approval.patterns,
        vec!["shared/rust-bridge/opencode-bridge/**"]
    );
}

#[test]
fn provider_catalog_maps_connected_providers_only() {
    let catalog =
        from_str::<OpenCodeProviderCatalog>(fixtures::json("provider_list.json")).unwrap();

    let mapped = map_model_catalog(&scope(), &catalog, None);

    assert_eq!(mapped.server_id, "local-opencode");
    assert_eq!(
        mapped.directory,
        "/Users/franklin/Development/OpenSource/litter"
    );
    assert_eq!(mapped.providers.len(), 1);
    assert_eq!(mapped.providers[0].provider_id, "openai");
    assert_eq!(
        mapped.providers[0].default_model_id.as_deref(),
        Some("gpt-5.4")
    );
    assert_eq!(mapped.providers[0].models[0].provider_id, "openai");
    assert_eq!(mapped.providers[0].models[0].model_id, "gpt-5.4");
    assert!(mapped.providers[0].models[0].is_default);
}

#[test]
fn unknown_part_kind_is_preserved_in_delta_mapping() {
    let part = from_str::<OpenCodeMessagePart>(fixtures::json("unknown_part.json")).unwrap();

    let delta = map_message_part_delta(&scope(), &part, None).unwrap();

    assert_eq!(delta.thread_key.session_id, "sess_created");
    match delta.part {
        OpenCodeConversationPart::Unknown(raw) => {
            assert_eq!(raw.kind, "compaction");
            assert_eq!(raw.raw["auto"], true);
        }
        other => panic!("expected unknown payload, got {other:?}"),
    }
}

#[test]
fn unknown_event_kind_is_preserved_in_event_mapping() {
    let event = from_str::<OpenCodeEvent>(fixtures::json("unknown_event.json")).unwrap();

    let outputs = map_event(&scope(), &event).unwrap();

    match &outputs[0] {
        opencode_bridge::OpenCodeMappedEvent::Unknown { scope, payload, .. } => {
            assert_eq!(scope.server_id, "local-opencode");
            assert_eq!(
                scope.directory,
                "/Users/franklin/Development/OpenSource/litter"
            );
            assert_eq!(payload.kind, "session.archived");
            assert_eq!(payload.raw["properties"]["reason"], "manual");
        }
        other => panic!("expected preserved unknown event, got {other:?}"),
    }
}
