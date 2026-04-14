pub fn json(name: &str) -> &'static str {
    match name {
        "health.json" => include_str!("health.json"),
        "project_current.json" => include_str!("project_current.json"),
        "path_info.json" => include_str!("path_info.json"),
        "session_list.json" => include_str!("session_list.json"),
        "session_created.json" => include_str!("session_created.json"),
        "session_status.json" => include_str!("session_status.json"),
        "messages_text_reasoning_tool.json" => include_str!("messages_text_reasoning_tool.json"),
        "message_part_updated_text.json" => include_str!("message_part_updated_text.json"),
        "message_part_delta_text.json" => include_str!("message_part_delta_text.json"),
        "permission_updated.json" => include_str!("permission_updated.json"),
        "provider_list.json" => include_str!("provider_list.json"),
        "event_server_connected.sse.json" => include_str!("event_server_connected.sse.json"),
        "event_global_message_updated.json" => include_str!("event_global_message_updated.json"),
        "unknown_part.json" => include_str!("unknown_part.json"),
        "unknown_event.json" => include_str!("unknown_event.json"),
        other => panic!("unknown fixture: {other}"),
    }
}
