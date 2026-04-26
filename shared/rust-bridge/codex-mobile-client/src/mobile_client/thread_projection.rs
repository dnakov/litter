use super::*;

pub fn thread_info_from_upstream_thread(thread: upstream::Thread) -> Option<ThreadInfo> {
    thread_info_from_upstream_thread_list_item(thread, None, None)
}

pub(super) fn thread_info_from_upstream_thread_list_item(
    thread: upstream::Thread,
    model: Option<String>,
    _reasoning_effort: Option<String>,
) -> Option<ThreadInfo> {
    let mut info = ThreadInfo::from(thread);
    info.model = model;
    Some(info)
}

pub fn thread_snapshot_from_upstream_thread_with_overrides(
    server_id: &str,
    thread: upstream::Thread,
    model: Option<String>,
    reasoning_effort: Option<String>,
    effective_approval_policy: Option<crate::types::AppAskForApproval>,
    effective_sandbox_policy: Option<crate::types::AppSandboxPolicy>,
) -> Result<ThreadSnapshot, String> {
    Ok(thread_snapshot_from_upstream_thread_state(
        server_id,
        thread,
        model,
        reasoning_effort,
        effective_approval_policy,
        effective_sandbox_policy,
        None,
    ))
}

pub fn copy_thread_runtime_fields(source: &ThreadSnapshot, target: &mut ThreadSnapshot) {
    target.collaboration_mode = source.collaboration_mode;
    if target.model.is_none() {
        target.model = source.model.clone();
    }
    if target.reasoning_effort.is_none() {
        target.reasoning_effort = source.reasoning_effort.clone();
    }
    if target.queued_follow_ups.is_empty() {
        target.queued_follow_ups = source.queued_follow_ups.clone();
    }
    if target.queued_follow_up_drafts.is_empty() {
        target.queued_follow_up_drafts = source.queued_follow_up_drafts.clone();
    }
    target.context_tokens_used = source.context_tokens_used;
    target.model_context_window = source.model_context_window;
    target.rate_limits = source.rate_limits.clone();
    target.realtime_session_id = source.realtime_session_id.clone();
    if target.active_plan_progress.is_none() {
        target.active_plan_progress = source.active_plan_progress.clone();
    }
    if target.pending_plan_implementation_turn_id.is_none() {
        target.pending_plan_implementation_turn_id =
            source.pending_plan_implementation_turn_id.clone();
    }
    target.is_resumed = target.is_resumed || source.is_resumed;
}

#[cfg(test)]
pub(super) fn queued_follow_up_preview_from_inputs(
    inputs: &[upstream::UserInput],
    kind: AppQueuedFollowUpKind,
) -> Option<AppQueuedFollowUpPreview> {
    queued_follow_up_draft_from_inputs(inputs, kind).map(|draft| draft.preview)
}

pub(super) fn queued_follow_up_draft_from_inputs(
    inputs: &[upstream::UserInput],
    kind: AppQueuedFollowUpKind,
) -> Option<crate::store::QueuedFollowUpDraft> {
    let text = queued_follow_up_text_from_inputs(inputs)?;

    Some(crate::store::QueuedFollowUpDraft {
        preview: AppQueuedFollowUpPreview {
            id: uuid::Uuid::new_v4().to_string(),
            kind,
            text,
        },
        inputs: inputs.to_vec(),
        source_message_json: queued_follow_up_message_json_from_inputs(inputs),
    })
}

pub(super) fn queued_follow_up_text_from_inputs(inputs: &[upstream::UserInput]) -> Option<String> {
    let mut text_parts: Vec<String> = Vec::new();
    let mut attachment_count = 0usize;

    for input in inputs {
        match input {
            upstream::UserInput::Text { text, .. } => {
                let trimmed = text.trim();
                if !trimmed.is_empty() {
                    text_parts.push(trimmed.to_string());
                }
            }
            upstream::UserInput::Image { .. } | upstream::UserInput::LocalImage { .. } => {
                attachment_count += 1;
            }
            upstream::UserInput::Skill { .. } | upstream::UserInput::Mention { .. } => {}
        }
    }

    if !text_parts.is_empty() {
        Some(text_parts.join("\n"))
    } else {
        attachment_summary(attachment_count)
    }
}

pub(super) fn queued_follow_up_drafts_from_message_values(
    messages: &[serde_json::Value],
) -> Vec<crate::store::QueuedFollowUpDraft> {
    build_queued_follow_up_drafts(
        messages.iter().enumerate(),
        AppQueuedFollowUpKind::Message,
        "ipc-message",
    )
}

pub(super) fn queued_follow_up_drafts_from_conversation_json(
    conversation_state: &serde_json::Value,
) -> Vec<crate::store::QueuedFollowUpDraft> {
    conversation_state
        .get("inputState")
        .or_else(|| conversation_state.get("input_state"))
        .map(queued_follow_up_drafts_from_input_state)
        .unwrap_or_default()
}

pub(super) fn queued_follow_up_drafts_from_input_state(
    input_state: &serde_json::Value,
) -> Vec<crate::store::QueuedFollowUpDraft> {
    let mut drafts = Vec::new();
    let sections = [
        (
            input_state
                .get("pending_steers")
                .or_else(|| input_state.get("pendingSteers")),
            AppQueuedFollowUpKind::PendingSteer,
            "pending-steer",
        ),
        (
            input_state
                .get("rejected_steers_queue")
                .or_else(|| input_state.get("rejectedSteersQueue"))
                .or_else(|| input_state.get("rejectedSteers")),
            AppQueuedFollowUpKind::RetryingSteer,
            "rejected-steer",
        ),
        (
            input_state
                .get("queued_user_messages")
                .or_else(|| input_state.get("queuedUserMessages"))
                .or_else(|| input_state.get("queued_messages"))
                .or_else(|| input_state.get("queuedMessages")),
            AppQueuedFollowUpKind::Message,
            "queued-message",
        ),
    ];

    for (section_value, fallback_kind, id_scope) in sections {
        let Some(messages) = section_value.and_then(serde_json::Value::as_array) else {
            continue;
        };
        drafts.extend(build_queued_follow_up_drafts(
            messages.iter().enumerate(),
            fallback_kind,
            id_scope,
        ));
    }

    drafts
}

pub(super) fn build_queued_follow_up_drafts<'a>(
    messages: impl IntoIterator<Item = (usize, &'a serde_json::Value)>,
    fallback_kind: AppQueuedFollowUpKind,
    id_scope: &str,
) -> Vec<crate::store::QueuedFollowUpDraft> {
    messages
        .into_iter()
        .filter_map(|(index, message)| {
            let text = queued_follow_up_text_from_json_value(message)?;
            let kind = queued_follow_up_kind_from_json_value(message).unwrap_or(fallback_kind);
            Some(crate::store::QueuedFollowUpDraft {
                preview: AppQueuedFollowUpPreview {
                    id: stable_follow_up_preview_id(id_scope, index, &text),
                    kind,
                    text,
                },
                inputs: queued_follow_up_inputs_from_json_value(message),
                source_message_json: Some(message.clone()),
            })
        })
        .collect()
}

pub(super) fn queued_follow_up_kind_from_json_value(
    value: &serde_json::Value,
) -> Option<AppQueuedFollowUpKind> {
    let object = value.as_object()?;
    let raw_kind = object
        .get("kind")
        .or_else(|| object.get("category"))
        .or_else(|| object.get("queueKind"))
        .or_else(|| object.get("queue_kind"))
        .and_then(serde_json::Value::as_str)?
        .trim()
        .to_ascii_lowercase();

    match raw_kind.as_str() {
        "pending_steer" | "pending-steer" | "pendingsteer" | "steer" => {
            Some(AppQueuedFollowUpKind::PendingSteer)
        }
        "rejected_steer" | "rejected-steer" | "rejectedsteer" | "retrying_steer"
        | "retrying-steer" | "retryingsteer" => Some(AppQueuedFollowUpKind::RetryingSteer),
        "queued" | "queued_follow_up" | "queued-follow-up" | "queuedfollowup" => {
            Some(AppQueuedFollowUpKind::Message)
        }
        _ => None,
    }
}

pub(super) fn queued_follow_up_text_from_json_value(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(text) => {
            let trimmed = text.trim();
            (!trimmed.is_empty()).then(|| trimmed.to_string())
        }
        serde_json::Value::Object(object) => {
            if let Some(nested) = object
                .get("userMessage")
                .or_else(|| object.get("user_message"))
            {
                return queued_follow_up_text_from_json_value(nested);
            }

            if let Some(text) = string_field(object, &["text", "message", "summary"]) {
                return Some(text);
            }

            let attachment_count = array_field_len(object, &["localImages", "local_images"])
                + array_field_len(object, &["remoteImageUrls", "remote_image_urls"])
                + array_field_len(object, &["images", "imageUrls", "image_urls"]);

            attachment_summary(attachment_count)
        }
        _ => None,
    }
}

pub(super) fn queued_follow_up_inputs_from_json_value(
    value: &serde_json::Value,
) -> Vec<upstream::UserInput> {
    let Some(object) = value.as_object() else {
        return Vec::new();
    };

    let message = object
        .get("userMessage")
        .or_else(|| object.get("user_message"))
        .and_then(serde_json::Value::as_object)
        .unwrap_or(object);

    let mut inputs = Vec::new();

    let text_elements = message
        .get("textElements")
        .or_else(|| message.get("text_elements"))
        .cloned()
        .and_then(|value| serde_json::from_value::<Vec<upstream::TextElement>>(value).ok())
        .unwrap_or_default();

    if let Some(text) = string_field(message, &["text", "message", "summary"]) {
        inputs.push(upstream::UserInput::Text {
            text,
            text_elements,
        });
    }

    let remote_images = message
        .get("remoteImageUrls")
        .or_else(|| message.get("remote_image_urls"))
        .or_else(|| message.get("images"))
        .or_else(|| message.get("imageUrls"))
        .or_else(|| message.get("image_urls"))
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_str)
        .map(|url| upstream::UserInput::Image {
            url: url.to_string(),
        });
    inputs.extend(remote_images);

    let local_images = message
        .get("localImages")
        .or_else(|| message.get("local_images"))
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_object)
        .filter_map(|image| {
            image
                .get("path")
                .and_then(serde_json::Value::as_str)
                .map(std::path::PathBuf::from)
        })
        .map(|path| upstream::UserInput::LocalImage { path });
    inputs.extend(local_images);

    let mentions = message
        .get("mentionBindings")
        .or_else(|| message.get("mention_bindings"))
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_object)
        .filter_map(|binding| {
            let name = binding
                .get("mention")
                .or_else(|| binding.get("name"))
                .and_then(serde_json::Value::as_str)?;
            let path = binding.get("path").and_then(serde_json::Value::as_str)?;
            Some(upstream::UserInput::Mention {
                name: name.to_string(),
                path: path.to_string(),
            })
        });
    inputs.extend(mentions);

    let skills = message
        .get("skillBindings")
        .or_else(|| message.get("skill_bindings"))
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_object)
        .filter_map(|binding| {
            let name = binding
                .get("name")
                .or_else(|| binding.get("skill"))
                .and_then(serde_json::Value::as_str)?;
            let path = binding.get("path").and_then(serde_json::Value::as_str)?;
            Some(upstream::UserInput::Skill {
                name: name.to_string(),
                path: std::path::PathBuf::from(path),
            })
        });
    inputs.extend(skills);

    inputs
}

pub(super) fn queued_follow_up_message_json_from_inputs(
    inputs: &[upstream::UserInput],
) -> Option<serde_json::Value> {
    let mut text = None;
    let mut text_elements = Vec::new();
    let mut remote_image_urls = Vec::new();
    let mut local_images = Vec::new();
    let mut mention_bindings = Vec::new();
    let mut skill_bindings = Vec::new();

    for input in inputs {
        match input {
            upstream::UserInput::Text {
                text: current_text,
                text_elements: current_elements,
            } => {
                let trimmed = current_text.trim();
                if !trimmed.is_empty() {
                    text = Some(trimmed.to_string());
                }
                text_elements = current_elements.clone();
            }
            upstream::UserInput::Image { url } => {
                remote_image_urls.push(url.clone());
            }
            upstream::UserInput::LocalImage { path } => {
                let placeholder = format!("[Image #{}]", local_images.len() + 1);
                local_images.push(serde_json::json!({
                    "placeholder": placeholder,
                    "path": path,
                }));
            }
            upstream::UserInput::Mention { name, path } => {
                mention_bindings.push(serde_json::json!({
                    "mention": name,
                    "path": path,
                }));
            }
            upstream::UserInput::Skill { name, path } => {
                skill_bindings.push(serde_json::json!({
                    "name": name,
                    "path": path,
                }));
            }
        }
    }

    if text.is_none()
        && text_elements.is_empty()
        && remote_image_urls.is_empty()
        && local_images.is_empty()
        && mention_bindings.is_empty()
        && skill_bindings.is_empty()
    {
        return None;
    }

    Some(serde_json::json!({
        "text": text.unwrap_or_default(),
        "textElements": text_elements,
        "remoteImageUrls": remote_image_urls,
        "localImages": local_images,
        "mentionBindings": mention_bindings,
        "skillBindings": skill_bindings,
    }))
}

pub(super) fn queued_follow_up_state_json_from_drafts(
    drafts: &[crate::store::QueuedFollowUpDraft],
) -> serde_json::Value {
    let mut pending_steers = Vec::new();
    let mut rejected_steers_queue = Vec::new();
    let mut queued_user_messages = Vec::new();

    for draft in drafts {
        let Some(message_json) = draft
            .source_message_json
            .clone()
            .or_else(|| queued_follow_up_message_json_from_inputs(&draft.inputs))
        else {
            continue;
        };

        match draft.preview.kind {
            AppQueuedFollowUpKind::PendingSteer => pending_steers.push(message_json),
            AppQueuedFollowUpKind::RetryingSteer => rejected_steers_queue.push(message_json),
            AppQueuedFollowUpKind::Message => queued_user_messages.push(message_json),
        }
    }

    serde_json::json!({
        "pendingSteers": pending_steers,
        "rejectedSteersQueue": rejected_steers_queue,
        "queuedUserMessages": queued_user_messages,
    })
}

pub(super) fn string_field(
    object: &serde_json::Map<String, serde_json::Value>,
    keys: &[&str],
) -> Option<String> {
    keys.iter()
        .filter_map(|key| object.get(*key))
        .find_map(|value| match value {
            serde_json::Value::String(text) => {
                let trimmed = text.trim();
                (!trimmed.is_empty()).then(|| trimmed.to_string())
            }
            serde_json::Value::Array(values) => {
                let joined = values
                    .iter()
                    .filter_map(serde_json::Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .collect::<Vec<_>>()
                    .join("\n");
                (!joined.is_empty()).then_some(joined)
            }
            _ => None,
        })
}

pub(super) fn array_field_len(
    object: &serde_json::Map<String, serde_json::Value>,
    keys: &[&str],
) -> usize {
    keys.iter()
        .filter_map(|key| object.get(*key))
        .find_map(|value| value.as_array().map(Vec::len))
        .unwrap_or(0)
}

pub(super) fn attachment_summary(attachment_count: usize) -> Option<String> {
    match attachment_count {
        0 => None,
        1 => Some("1 image attachment".to_string()),
        count => Some(format!("{count} image attachments")),
    }
}

pub(super) fn stable_follow_up_preview_id(scope: &str, index: usize, text: &str) -> String {
    let mut hasher = DefaultHasher::new();
    scope.hash(&mut hasher);
    index.hash(&mut hasher);
    text.hash(&mut hasher);
    format!("{scope}-{index}-{:016x}", hasher.finish())
}

pub(super) fn remote_oauth_callback_port(auth_url: &str) -> Result<u16, RpcError> {
    let parsed = Url::parse(auth_url).map_err(|error| {
        RpcError::Deserialization(format!("invalid auth URL for remote OAuth: {error}"))
    })?;
    let redirect_uri = parsed
        .query_pairs()
        .find(|(key, _)| key == "redirect_uri")
        .map(|(_, value)| value.into_owned())
        .ok_or_else(|| {
            RpcError::Deserialization("missing redirect_uri in remote OAuth auth URL".to_string())
        })?;
    let redirect = Url::parse(&redirect_uri).map_err(|error| {
        RpcError::Deserialization(format!(
            "invalid redirect_uri in remote OAuth auth URL: {error}"
        ))
    })?;
    let host = redirect.host_str().unwrap_or_default();
    if host != "localhost" && host != "127.0.0.1" {
        return Err(RpcError::Deserialization(format!(
            "unsupported remote OAuth callback host: {host}"
        )));
    }
    redirect.port_or_known_default().ok_or_else(|| {
        RpcError::Deserialization("missing callback port in remote OAuth redirect_uri".to_string())
    })
}

pub(super) fn ensure_thread_is_editable(snapshot: &ThreadSnapshot) -> Result<(), RpcError> {
    if snapshot.items.is_empty() {
        return Err(RpcError::Deserialization(
            "thread has no conversation items".to_string(),
        ));
    }
    Ok(())
}

pub(super) fn rollback_depth_for_turn(
    snapshot: &ThreadSnapshot,
    selected_turn_index: usize,
) -> Result<u32, RpcError> {
    let user_turn_indices = snapshot
        .items
        .iter()
        .enumerate()
        .filter_map(|(idx, item)| {
            matches!(
                item.content,
                crate::conversation_uniffi::HydratedConversationItemContent::User(_)
            )
            .then_some(idx)
        })
        .collect::<Vec<_>>();
    let item_index = *user_turn_indices.get(selected_turn_index).ok_or_else(|| {
        RpcError::Deserialization(format!("unknown user turn index {}", selected_turn_index))
    })?;
    let turns_after = snapshot.items.len().saturating_sub(item_index + 1);
    u32::try_from(turns_after)
        .map_err(|_| RpcError::Deserialization("rollback depth overflow".to_string()))
}

pub(super) fn user_boundary_text_for_turn(
    snapshot: &ThreadSnapshot,
    selected_turn_index: usize,
) -> Result<String, RpcError> {
    let item = snapshot
        .items
        .iter()
        .filter(|item| {
            matches!(
                item.content,
                crate::conversation_uniffi::HydratedConversationItemContent::User(_)
            )
        })
        .nth(selected_turn_index)
        .ok_or_else(|| {
            RpcError::Deserialization(format!("unknown user turn index {}", selected_turn_index))
        })?;
    match &item.content {
        crate::conversation_uniffi::HydratedConversationItemContent::User(data) => {
            Ok(data.text.clone())
        }
        _ => Err(RpcError::Deserialization(
            "selected turn has no editable text".to_string(),
        )),
    }
}

pub fn reasoning_effort_string(value: crate::types::ReasoningEffort) -> String {
    match value {
        crate::types::ReasoningEffort::None => "none".to_string(),
        crate::types::ReasoningEffort::Minimal => "minimal".to_string(),
        crate::types::ReasoningEffort::Low => "low".to_string(),
        crate::types::ReasoningEffort::Medium => "medium".to_string(),
        crate::types::ReasoningEffort::High => "high".to_string(),
        crate::types::ReasoningEffort::XHigh => "xhigh".to_string(),
    }
}

pub fn reasoning_effort_from_string(value: &str) -> Option<crate::types::ReasoningEffort> {
    match value.trim().to_ascii_lowercase().as_str() {
        "none" => Some(crate::types::ReasoningEffort::None),
        "minimal" => Some(crate::types::ReasoningEffort::Minimal),
        "low" => Some(crate::types::ReasoningEffort::Low),
        "medium" => Some(crate::types::ReasoningEffort::Medium),
        "high" => Some(crate::types::ReasoningEffort::High),
        "xhigh" => Some(crate::types::ReasoningEffort::XHigh),
        _ => None,
    }
}

pub(super) fn core_reasoning_effort_from_mobile(
    value: crate::types::ReasoningEffort,
) -> codex_protocol::openai_models::ReasoningEffort {
    match value {
        crate::types::ReasoningEffort::None => codex_protocol::openai_models::ReasoningEffort::None,
        crate::types::ReasoningEffort::Minimal => {
            codex_protocol::openai_models::ReasoningEffort::Minimal
        }
        crate::types::ReasoningEffort::Low => codex_protocol::openai_models::ReasoningEffort::Low,
        crate::types::ReasoningEffort::Medium => {
            codex_protocol::openai_models::ReasoningEffort::Medium
        }
        crate::types::ReasoningEffort::High => codex_protocol::openai_models::ReasoningEffort::High,
        crate::types::ReasoningEffort::XHigh => {
            codex_protocol::openai_models::ReasoningEffort::XHigh
        }
    }
}

pub(super) fn collaboration_mode_from_thread(
    thread: &ThreadSnapshot,
    mode: AppModeKind,
    model_override: Option<String>,
    effort_override: Option<codex_protocol::openai_models::ReasoningEffort>,
) -> Option<codex_protocol::config_types::CollaborationMode> {
    let model = model_override
        .or_else(|| thread.model.clone())
        .or_else(|| thread.info.model.clone())?;
    let reasoning_effort = effort_override.or_else(|| {
        thread
            .reasoning_effort
            .as_deref()
            .and_then(reasoning_effort_from_string)
            .map(core_reasoning_effort_from_mobile)
    });
    Some(codex_protocol::config_types::CollaborationMode {
        mode: match mode {
            AppModeKind::Default => codex_protocol::config_types::ModeKind::Default,
            AppModeKind::Plan => codex_protocol::config_types::ModeKind::Plan,
        },
        settings: codex_protocol::config_types::Settings {
            model,
            reasoning_effort,
            developer_instructions: None,
        },
    })
}

pub(super) fn map_rpc_client_error(error: crate::RpcClientError) -> RpcError {
    match error {
        crate::RpcClientError::Rpc(message) | crate::RpcClientError::Serialization(message) => {
            RpcError::Deserialization(message)
        }
    }
}

pub(super) fn map_ssh_transport_error(error: crate::ssh::SshError) -> TransportError {
    TransportError::ConnectionFailed(error.to_string())
}

pub(super) async fn refresh_thread_list_from_app_server(
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: &str,
) -> Result<(), RpcError> {
    let mut cursor = None;
    let mut incoming_ids = HashSet::new();

    loop {
        let response = request_thread_list_page(&session, cursor).await?;
        let page = thread_list_page_to_thread_infos(response.data, &mut incoming_ids);
        app_store.upsert_thread_list_page(server_id, &page);

        let Some(next_cursor) = response.next_cursor else {
            break;
        };
        cursor = Some(next_cursor);
    }

    app_store.finalize_thread_list_sync(server_id, &incoming_ids);
    Ok(())
}

pub(super) async fn refresh_account_from_app_server(
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    server_id: &str,
) -> Result<(), RpcError> {
    let response = session
        .request("account/read", serde_json::json!({ "refreshToken": false }))
        .await?;
    if !session_is_current(&sessions, server_id, &session) {
        return Ok(());
    }
    let response =
        serde_json::from_value::<upstream::GetAccountResponse>(response).map_err(|error| {
            RpcError::Deserialization(format!("deserialize account/read response: {error}"))
        })?;
    app_store.update_server_account(
        server_id,
        response.account.map(Into::into),
        response.requires_openai_auth,
    );
    Ok(())
}

async fn request_thread_list_page(
    session: &ServerSession,
    cursor: Option<String>,
) -> Result<upstream::ThreadListResponse, RpcError> {
    let params = match cursor {
        Some(cursor) => serde_json::json!({ "cursor": cursor }),
        None => serde_json::json!({}),
    };
    let response = session.request("thread/list", params).await?;
    serde_json::from_value::<upstream::ThreadListResponse>(response)
        .map_err(|error| RpcError::Deserialization(format!("deserialize thread/list: {error}")))
}

fn thread_list_page_to_thread_infos(
    data: Vec<upstream::Thread>,
    incoming_ids: &mut HashSet<String>,
) -> Vec<ThreadInfo> {
    let mut threads = Vec::new();
    for thread in data {
        let Some(info) = thread_info_from_upstream_thread(thread) else {
            continue;
        };
        incoming_ids.insert(info.id.clone());
        threads.push(info);
    }
    threads
}

pub(super) fn session_is_current(
    sessions: &Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    server_id: &str,
    session: &Arc<ServerSession>,
) -> bool {
    match sessions.read() {
        Ok(guard) => guard
            .get(server_id)
            .map(|current| Arc::ptr_eq(current, session))
            .unwrap_or(false),
        Err(error) => error
            .into_inner()
            .get(server_id)
            .map(|current| Arc::ptr_eq(current, session))
            .unwrap_or(false),
    }
}

pub(super) async fn read_thread_response_from_app_server(
    session: Arc<ServerSession>,
    thread_id: &str,
    include_turns: bool,
) -> Result<upstream::ThreadReadResponse, RpcError> {
    let response = session
        .request(
            "thread/read",
            serde_json::json!({ "threadId": thread_id, "includeTurns": include_turns }),
        )
        .await?;
    serde_json::from_value::<upstream::ThreadReadResponse>(response).map_err(|error| {
        RpcError::Deserialization(format!("deserialize thread/read response: {error}"))
    })
}

pub(super) fn upsert_thread_snapshot_from_app_server_read_response(
    app_store: &AppStoreReducer,
    server_id: &str,
    response: upstream::ThreadReadResponse,
) -> Result<(), RpcError> {
    let turns = response.thread.turns.clone();
    let thread_id = response.thread.id.clone();
    let existing = app_store
        .snapshot()
        .threads
        .get(&ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        })
        .cloned();
    let mut snapshot = thread_snapshot_from_upstream_thread_with_overrides(
        server_id,
        response.thread,
        None,
        None,
        response.approval_policy.map(Into::into),
        response.sandbox.map(Into::into),
    )
    .map_err(RpcError::Deserialization)?;
    if let Some(existing) = existing.as_ref() {
        copy_thread_runtime_fields(existing, &mut snapshot);
    }
    reconcile_active_turn(existing.as_ref(), &mut snapshot, &turns);
    app_store.upsert_thread_snapshot(snapshot);
    Ok(())
}

pub(super) async fn recover_ipc_stream_cache_from_app_server(
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: &str,
    thread_id: &str,
) -> Result<serde_json::Value, RpcError> {
    let key = ThreadKey {
        server_id: server_id.to_string(),
        thread_id: thread_id.to_string(),
    };
    let app_snapshot = app_store.snapshot();
    let existing_thread = app_snapshot.threads.get(&key).cloned();
    let pending_approvals = app_snapshot
        .pending_approvals
        .iter()
        .filter(|approval| {
            approval.server_id == server_id && approval.thread_id.as_deref() == Some(thread_id)
        })
        .cloned()
        .collect::<Vec<_>>();
    let pending_user_inputs = app_snapshot
        .pending_user_inputs
        .iter()
        .filter(|request| request.server_id == server_id && request.thread_id == thread_id)
        .cloned()
        .collect::<Vec<_>>();
    drop(app_snapshot);

    let response = read_thread_response_from_app_server(session, thread_id, true).await?;
    let thread = response.thread.clone();
    upsert_thread_snapshot_from_app_server_read_response(&app_store, server_id, response)?;

    let mut conversation_state = seed_conversation_state_from_thread(&thread);
    hydrate_seeded_ipc_conversation_state(
        &app_store,
        &mut conversation_state,
        existing_thread.as_ref(),
        &pending_approvals,
        &pending_user_inputs,
    );
    Ok(conversation_state)
}

pub(super) fn upstream_thread_status_from_summary_status(
    status: ThreadSummaryStatus,
) -> upstream::ThreadStatus {
    match status {
        ThreadSummaryStatus::NotLoaded | ThreadSummaryStatus::Idle => upstream::ThreadStatus::Idle,
        ThreadSummaryStatus::Active => upstream::ThreadStatus::Active {
            active_flags: Vec::new(),
        },
        ThreadSummaryStatus::SystemError => upstream::ThreadStatus::SystemError,
    }
}

pub(super) fn thread_snapshot_from_upstream_thread(
    server_id: &str,
    thread: upstream::Thread,
) -> ThreadSnapshot {
    thread_snapshot_from_upstream_thread_state(server_id, thread, None, None, None, None, None)
}

pub(super) fn thread_snapshot_from_upstream_thread_state(
    server_id: &str,
    thread: upstream::Thread,
    model: Option<String>,
    reasoning_effort: Option<String>,
    effective_approval_policy: Option<crate::types::AppAskForApproval>,
    effective_sandbox_policy: Option<crate::types::AppSandboxPolicy>,
    active_turn_id: Option<String>,
) -> ThreadSnapshot {
    let info = ThreadInfo::from(thread.clone());
    let items = crate::conversation::hydrate_turns(&thread.turns, &Default::default());
    let mut snapshot = ThreadSnapshot::from_info(server_id, info);
    snapshot.items = items;
    snapshot.model = model;
    snapshot.reasoning_effort = reasoning_effort;
    snapshot.effective_approval_policy = effective_approval_policy;
    snapshot.effective_sandbox_policy = effective_sandbox_policy;
    snapshot.active_turn_id = active_turn_id.or_else(|| active_turn_id_from_turns(&thread.turns));
    snapshot
}

pub(super) fn active_turn_id_from_turns(turns: &[upstream::Turn]) -> Option<String> {
    turns
        .iter()
        .rev()
        .find(|turn| matches!(turn.status, upstream::TurnStatus::InProgress))
        .map(|turn| turn.id.clone())
}

/// Decide active-turn state for a freshly-rebuilt thread snapshot, given the
/// caller's existing snapshot (if any) and the upstream turn list the rebuild
/// was derived from.
///
/// Rules:
/// - If `target` already shows an InProgress turn, trust it.
/// - Otherwise, if existing has an active turn:
///   - With no turn list available (e.g. include_turns=false), preserve local
///     state — we have no evidence the turn ended.
///   - With a turn list, preserve only if our local id appears as InProgress
///     (defensive); otherwise honor the rebuild and clear.
/// - `info.status` is derived from the resolved `active_turn_id`: Active iff
///   Some, otherwise the upstream-supplied value is left untouched.
pub fn reconcile_active_turn(
    existing: Option<&ThreadSnapshot>,
    target: &mut ThreadSnapshot,
    upstream_turns: &[upstream::Turn],
) {
    if target.active_turn_id.is_some() {
        target.info.status = ThreadSummaryStatus::Active;
        return;
    }
    let Some(local_id) = existing.and_then(|t| t.active_turn_id.clone()) else {
        return;
    };
    let preserve = if upstream_turns.is_empty() {
        true
    } else {
        upstream_turns
            .iter()
            .any(|t| t.id == local_id && matches!(t.status, upstream::TurnStatus::InProgress))
    };
    if preserve {
        target.active_turn_id = Some(local_id);
        target.info.status = ThreadSummaryStatus::Active;
    }
}

pub(super) struct ThreadProjection {
    pub(super) snapshot: ThreadSnapshot,
    pub(super) pending_approvals: Vec<PendingApprovalWithSeed>,
    pub(super) pending_user_inputs: Vec<PendingUserInputRequest>,
}

pub(super) fn thread_projection_from_conversation_json(
    server_id: &str,
    conversation_id: &str,
    conversation_state: &serde_json::Value,
) -> Result<ThreadProjection, String> {
    project_conversation_state(conversation_id, conversation_state)
        .map(|projection| {
            let mut snapshot = thread_snapshot_from_upstream_thread_state(
                server_id,
                projection.thread,
                projection.latest_model,
                projection.latest_reasoning_effort,
                None,
                None,
                projection.active_turn_id,
            );
            snapshot.queued_follow_up_drafts =
                queued_follow_up_drafts_from_conversation_json(conversation_state);
            snapshot.queued_follow_ups = snapshot
                .queued_follow_up_drafts
                .iter()
                .map(|draft| draft.preview.clone())
                .collect();
            ThreadProjection {
                snapshot,
                pending_approvals: projection
                    .pending_approvals
                    .into_iter()
                    .map(|approval| pending_approval_from_ipc_projection(server_id, approval))
                    .collect(),
                pending_user_inputs: projection
                    .pending_user_inputs
                    .into_iter()
                    .map(|request| pending_user_input_from_ipc_projection(server_id, request))
                    .collect(),
            }
        })
        .or_else(|ipc_error| {
            let thread: upstream::Thread = serde_json::from_value(conversation_state.clone())
                .map_err(|error| {
                    format!(
                        "deserialize desktop conversation_state: {ipc_error}; deserialize upstream thread: {error}"
                    )
                })?;
            Ok(ThreadProjection {
                snapshot: thread_snapshot_from_upstream_thread(server_id, thread),
                pending_approvals: Vec::new(),
                pending_user_inputs: Vec::new(),
            })
        })
}

pub(super) fn pending_approval_from_ipc_projection(
    server_id: &str,
    approval: ProjectedApprovalRequest,
) -> PendingApprovalWithSeed {
    let request_id = approval.id.clone();
    let public_approval = PendingApproval {
        id: approval.id,
        server_id: server_id.to_string(),
        kind: match approval.kind {
            ProjectedApprovalKind::Command => crate::types::ApprovalKind::Command,
            ProjectedApprovalKind::FileChange => crate::types::ApprovalKind::FileChange,
            ProjectedApprovalKind::Permissions => crate::types::ApprovalKind::Permissions,
        },
        thread_id: approval.thread_id,
        turn_id: approval.turn_id,
        item_id: approval.item_id,
        command: approval.command,
        path: approval.path,
        grant_root: approval.grant_root,
        cwd: approval.cwd,
        reason: approval.reason,
    };
    PendingApprovalWithSeed {
        approval: public_approval,
        seed: PendingApprovalSeed {
            request_id: upstream::RequestId::String(request_id),
            raw_params: approval.raw_params,
        },
    }
}

pub(super) fn pending_user_input_from_ipc_projection(
    server_id: &str,
    request: ProjectedUserInputRequest,
) -> PendingUserInputRequest {
    PendingUserInputRequest {
        id: request.id,
        server_id: server_id.to_string(),
        thread_id: request.thread_id,
        turn_id: request.turn_id,
        item_id: request.item_id,
        questions: crate::session::events::sanitize_pending_user_input_questions(
            request
                .questions
                .into_iter()
                .map(|question| crate::types::PendingUserInputQuestion {
                    id: question.id,
                    header: question.header,
                    question: question.question,
                    is_other_allowed: question.is_other_allowed,
                    is_secret: question.is_secret,
                    options: question
                        .options
                        .into_iter()
                        .map(|option| crate::types::PendingUserInputOption {
                            label: option.label,
                            description: option.description,
                        })
                        .collect(),
                })
                .collect(),
        ),
        requester_agent_nickname: request.requester_agent_nickname,
        requester_agent_role: request.requester_agent_role,
    }
}

pub(super) fn sync_ipc_thread_requests(
    app_store: &AppStoreReducer,
    server_id: &str,
    thread_id: &str,
    pending_approvals: Vec<PendingApprovalWithSeed>,
    pending_user_inputs: Vec<PendingUserInputRequest>,
) {
    let snapshot = app_store.snapshot();

    let mut merged_approvals = snapshot
        .pending_approvals
        .into_iter()
        .filter(|approval| {
            !(approval.server_id == server_id && approval.thread_id.as_deref() == Some(thread_id))
        })
        .map(|approval| PendingApprovalWithSeed {
            seed: app_store
                .pending_approval_seed(&approval.server_id, &approval.id)
                .unwrap_or(PendingApprovalSeed {
                    request_id: fallback_server_request_id(&approval.id),
                    raw_params: seed_ipc_approval_request_params(&approval)
                        .unwrap_or(serde_json::Value::Null),
                }),
            approval,
        })
        .collect::<Vec<_>>();
    merged_approvals.extend(pending_approvals);
    app_store.replace_pending_approvals_with_seeds(merged_approvals);

    let mut merged_user_inputs = snapshot
        .pending_user_inputs
        .into_iter()
        .filter(|request| !(request.server_id == server_id && request.thread_id == thread_id))
        .collect::<Vec<_>>();
    merged_user_inputs.extend(pending_user_inputs);
    app_store.replace_pending_user_inputs(merged_user_inputs);
}

pub(super) fn hydrate_seeded_ipc_conversation_state(
    app_store: &AppStoreReducer,
    conversation_state: &mut serde_json::Value,
    existing_thread: Option<&ThreadSnapshot>,
    pending_approvals: &[PendingApproval],
    pending_user_inputs: &[PendingUserInputRequest],
) {
    let Some(object) = conversation_state.as_object_mut() else {
        return;
    };

    if let Some(thread) = existing_thread {
        if let Some(model) = thread.model.as_ref() {
            object.insert(
                "latestModel".to_string(),
                serde_json::Value::String(model.clone()),
            );
        }
        if let Some(reasoning_effort) = thread.reasoning_effort.as_ref() {
            object.insert(
                "latestReasoningEffort".to_string(),
                serde_json::Value::String(reasoning_effort.clone()),
            );
        }
    }

    if !object.contains_key("agentNickname")
        && let Some(agent_nickname) = pending_user_inputs
            .iter()
            .find_map(|request| request.requester_agent_nickname.clone())
    {
        object.insert(
            "agentNickname".to_string(),
            serde_json::Value::String(agent_nickname),
        );
    }

    if !object.contains_key("agentRole")
        && let Some(agent_role) = pending_user_inputs
            .iter()
            .find_map(|request| request.requester_agent_role.clone())
    {
        object.insert(
            "agentRole".to_string(),
            serde_json::Value::String(agent_role),
        );
    }

    let requests = pending_approvals
        .iter()
        .filter_map(|approval| {
            seed_ipc_approval_request(
                approval,
                app_store
                    .pending_approval_seed(&approval.server_id, &approval.id)
                    .as_ref(),
            )
        })
        .chain(pending_user_inputs.iter().map(seed_ipc_user_input_request))
        .collect::<Vec<_>>();
    if !requests.is_empty() {
        object.insert("requests".to_string(), serde_json::Value::Array(requests));
    }
}

pub(super) fn seed_ipc_approval_request(
    approval: &PendingApproval,
    seed: Option<&PendingApprovalSeed>,
) -> Option<serde_json::Value> {
    if matches!(approval.kind, crate::types::ApprovalKind::McpElicitation) {
        return None;
    }

    let params = seed
        .map(|seed| seed.raw_params.clone())
        .or_else(|| seed_ipc_approval_request_params(approval))?;

    Some(serde_json::json!({
        "id": approval.id,
        "method": approval_method(&approval.kind),
        "params": params,
    }))
}

pub(super) fn approval_method(kind: &crate::types::ApprovalKind) -> &'static str {
    match kind {
        crate::types::ApprovalKind::Command => "item/commandExecution/requestApproval",
        crate::types::ApprovalKind::FileChange => "item/fileChange/requestApproval",
        crate::types::ApprovalKind::Permissions => "item/permissions/requestApproval",
        crate::types::ApprovalKind::McpElicitation => "mcpServer/elicitation/request",
    }
}

pub(super) fn seed_ipc_approval_request_params(
    approval: &PendingApproval,
) -> Option<serde_json::Value> {
    let thread_id = approval.thread_id.clone()?;
    let turn_id = approval.turn_id.clone()?;
    let item_id = approval.item_id.clone()?;

    match approval.kind {
        crate::types::ApprovalKind::Command => Some(serde_json::json!({
            "threadId": thread_id,
            "turnId": turn_id,
            "itemId": item_id,
            "command": approval.command,
            "cwd": approval.cwd,
            "reason": approval.reason,
        })),
        crate::types::ApprovalKind::FileChange => Some(serde_json::json!({
            "threadId": thread_id,
            "turnId": turn_id,
            "itemId": item_id,
            "grantRoot": approval.grant_root,
            "reason": approval.reason,
        })),
        crate::types::ApprovalKind::Permissions => Some(serde_json::json!({
            "threadId": thread_id,
            "turnId": turn_id,
            "itemId": item_id,
            "reason": approval.reason,
        })),
        crate::types::ApprovalKind::McpElicitation => None,
    }
}

pub(super) fn seed_ipc_user_input_request(request: &PendingUserInputRequest) -> serde_json::Value {
    serde_json::json!({
        "id": request.id,
        "method": "item/tool/requestUserInput",
        "params": {
            "threadId": request.thread_id,
            "turnId": request.turn_id,
            "itemId": request.item_id,
            "questions": request.questions.iter().map(|question| {
                serde_json::json!({
                    "id": question.id,
                    "header": question.header.clone().unwrap_or_default(),
                    "question": question.question,
                    "isOther": question.is_other_allowed,
                    "isSecret": question.is_secret,
                    "options": if question.options.is_empty() {
                        serde_json::Value::Null
                    } else {
                        serde_json::Value::Array(
                            question.options.iter().map(|option| {
                                serde_json::json!({
                                    "label": option.label,
                                    "description": option.description.clone().unwrap_or_default(),
                                })
                            }).collect()
                        )
                    },
                })
            }).collect::<Vec<_>>(),
        },
    })
}

pub(super) enum PendingIpcStreamRecovery {
    Recovered {
        thread_id: String,
        conversation_state: serde_json::Value,
    },
    Failed {
        thread_id: String,
        error: String,
    },
}

pub(super) fn queue_ipc_thread_stream_recovery(
    pending_thread_events: &mut HashMap<String, VecDeque<ThreadStreamStateChangedParams>>,
    recovering_threads: &mut HashSet<String>,
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: &str,
    params: ThreadStreamStateChangedParams,
    reason: &str,
    recovery_tx: &mpsc::UnboundedSender<PendingIpcStreamRecovery>,
) {
    let thread_id = params.conversation_id.clone();
    let queue = pending_thread_events.entry(thread_id.clone()).or_default();
    queue.push_back(params);
    let queued_events = queue.len();

    if !recovering_threads.insert(thread_id.clone()) {
        return;
    }

    debug!(
        "IPC: starting async cache recovery server={} thread={} reason={} queued_events={}",
        server_id, thread_id, reason, queued_events
    );
    spawn_ipc_thread_stream_recovery(
        session,
        app_store,
        server_id.to_string(),
        thread_id,
        recovery_tx.clone(),
    );
}

pub(super) fn spawn_ipc_thread_stream_recovery(
    session: Arc<ServerSession>,
    app_store: Arc<AppStoreReducer>,
    server_id: String,
    thread_id: String,
    recovery_tx: mpsc::UnboundedSender<PendingIpcStreamRecovery>,
) {
    MobileClient::spawn_detached(async move {
        let recovery = match recover_ipc_stream_cache_from_app_server(
            session, app_store, &server_id, &thread_id,
        )
        .await
        {
            Ok(conversation_state) => PendingIpcStreamRecovery::Recovered {
                thread_id,
                conversation_state,
            },
            Err(error) => PendingIpcStreamRecovery::Failed {
                thread_id,
                error: error.to_string(),
            },
        };
        let _ = recovery_tx.send(recovery);
    });
}

pub(super) async fn send_ipc_approval_response(
    ipc_client: &IpcClient,
    approval: &PendingApproval,
    thread_id: &str,
    decision: ApprovalDecisionValue,
) -> Result<bool, IpcError> {
    tracing::info!(
        "IPC out: approval_response thread={} request_id={} kind={:?} decision={:?}",
        thread_id,
        approval.id,
        approval.kind,
        decision
    );
    match approval.kind {
        crate::types::ApprovalKind::Command => {
            ipc_client
                .command_approval_decision(ThreadFollowerCommandApprovalDecisionParams {
                    conversation_id: thread_id.to_string(),
                    request_id: approval.id.clone(),
                    decision: match decision {
                        ApprovalDecisionValue::Accept => CommandExecutionApprovalDecision::Accept,
                        ApprovalDecisionValue::AcceptForSession => {
                            CommandExecutionApprovalDecision::AcceptForSession
                        }
                        ApprovalDecisionValue::Decline => CommandExecutionApprovalDecision::Decline,
                        ApprovalDecisionValue::Cancel => CommandExecutionApprovalDecision::Cancel,
                    },
                })
                .await?;
            Ok(true)
        }
        crate::types::ApprovalKind::FileChange => {
            ipc_client
                .file_approval_decision(ThreadFollowerFileApprovalDecisionParams {
                    conversation_id: thread_id.to_string(),
                    request_id: approval.id.clone(),
                    decision: match decision {
                        ApprovalDecisionValue::Accept => FileChangeApprovalDecision::Accept,
                        ApprovalDecisionValue::AcceptForSession => {
                            FileChangeApprovalDecision::AcceptForSession
                        }
                        ApprovalDecisionValue::Decline => FileChangeApprovalDecision::Decline,
                        ApprovalDecisionValue::Cancel => FileChangeApprovalDecision::Cancel,
                    },
                })
                .await?;
            Ok(true)
        }
        crate::types::ApprovalKind::Permissions | crate::types::ApprovalKind::McpElicitation => {
            Ok(false)
        }
    }
}

pub(super) async fn send_ipc_user_input_response(
    ipc_client: &IpcClient,
    thread_id: &str,
    request_id: &str,
    answers: Vec<PendingUserInputAnswer>,
) -> Result<bool, IpcError> {
    let response = upstream::ToolRequestUserInputResponse {
        answers: answers
            .into_iter()
            .map(|answer| {
                (
                    answer.question_id,
                    upstream::ToolRequestUserInputAnswer {
                        answers: answer.answers,
                    },
                )
            })
            .collect::<HashMap<_, _>>(),
    };
    tracing::info!(
        "IPC out: submit_user_input thread={} request_id={}",
        thread_id,
        request_id
    );
    ipc_client
        .submit_user_input(ThreadFollowerSubmitUserInputParams {
            conversation_id: thread_id.to_string(),
            request_id: request_id.to_string(),
            response,
        })
        .await?;
    Ok(true)
}

pub(super) fn approval_response_json(
    approval: &PendingApproval,
    seed: Option<&PendingApprovalSeed>,
    decision: ApprovalDecisionValue,
) -> Result<serde_json::Value, RpcError> {
    match approval.kind {
        crate::types::ApprovalKind::Command => {
            serde_json::to_value(upstream::CommandExecutionRequestApprovalResponse {
                decision: match decision {
                    ApprovalDecisionValue::Accept => {
                        upstream::CommandExecutionApprovalDecision::Accept
                    }
                    ApprovalDecisionValue::AcceptForSession => {
                        upstream::CommandExecutionApprovalDecision::AcceptForSession
                    }
                    ApprovalDecisionValue::Decline => {
                        upstream::CommandExecutionApprovalDecision::Decline
                    }
                    ApprovalDecisionValue::Cancel => {
                        upstream::CommandExecutionApprovalDecision::Cancel
                    }
                },
            })
        }
        crate::types::ApprovalKind::FileChange => {
            serde_json::to_value(upstream::FileChangeRequestApprovalResponse {
                decision: match decision {
                    ApprovalDecisionValue::Accept => upstream::FileChangeApprovalDecision::Accept,
                    ApprovalDecisionValue::AcceptForSession => {
                        upstream::FileChangeApprovalDecision::AcceptForSession
                    }
                    ApprovalDecisionValue::Decline => upstream::FileChangeApprovalDecision::Decline,
                    ApprovalDecisionValue::Cancel => upstream::FileChangeApprovalDecision::Cancel,
                },
            })
        }
        crate::types::ApprovalKind::Permissions | crate::types::ApprovalKind::McpElicitation => {
            let requested_permissions = seed
                .map(|seed| seed.raw_params.clone())
                .and_then(|value: serde_json::Value| value.get("permissions").cloned())
                .and_then(|value| {
                    serde_json::from_value::<upstream::GrantedPermissionProfile>(value).ok()
                })
                .unwrap_or(upstream::GrantedPermissionProfile {
                    network: None,
                    file_system: None,
                });
            serde_json::to_value(upstream::PermissionsRequestApprovalResponse {
                permissions: match decision {
                    ApprovalDecisionValue::Accept | ApprovalDecisionValue::AcceptForSession => {
                        requested_permissions
                    }
                    ApprovalDecisionValue::Decline | ApprovalDecisionValue::Cancel => {
                        upstream::GrantedPermissionProfile {
                            network: None,
                            file_system: None,
                        }
                    }
                },
                scope: match decision {
                    ApprovalDecisionValue::AcceptForSession => {
                        upstream::PermissionGrantScope::Session
                    }
                    _ => upstream::PermissionGrantScope::Turn,
                },
                strict_auto_review: None,
            })
        }
    }
    .map_err(|e| RpcError::Deserialization(format!("serialize approval response: {e}")))
}

pub(super) fn approval_request_id(
    approval: &PendingApproval,
    seed: Option<&PendingApprovalSeed>,
) -> upstream::RequestId {
    seed.map(|seed| seed.request_id.clone())
        .unwrap_or_else(|| fallback_server_request_id(&approval.id))
}

pub(super) fn fallback_server_request_id(id: &str) -> upstream::RequestId {
    id.parse::<i64>()
        .map(upstream::RequestId::Integer)
        .unwrap_or_else(|_| upstream::RequestId::String(id.to_string()))
}

pub(super) fn server_request_id_json(id: upstream::RequestId) -> serde_json::Value {
    match id {
        upstream::RequestId::Integer(value) => serde_json::Value::Number(value.into()),
        upstream::RequestId::String(value) => serde_json::Value::String(value),
    }
}
