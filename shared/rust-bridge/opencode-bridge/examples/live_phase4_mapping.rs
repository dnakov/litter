use std::{
    env,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use opencode_bridge::{
    OpenCodeBridgeError, OpenCodeClient, OpenCodeConversationDelta, OpenCodeEventStreamClient,
    OpenCodeMappedEvent, OpenCodeMappingScope, OpenCodePromptAsyncRequest, OpenCodePromptPartInput,
    OpenCodePromptTextPartInput, OpenCodeRequestContext, OpenCodeServerConfig,
    OpenCodeSessionCreateRequest, OpenCodeSessionListQuery, OpenCodeStreamEvent,
    map_conversation_snapshot, map_event, map_model_catalog, map_thread_summaries,
};
use tokio::time::{Instant, timeout};
use url::Url;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let base_url =
        env::var("OPENCODE_BASE_URL").unwrap_or_else(|_| "http://127.0.0.1:4187".to_string());
    let directory = env::var("OPENCODE_DIRECTORY")
        .unwrap_or_else(|_| "/Users/franklin/Development/OpenSource/litter".to_string());
    let prompt = env::var("OPENCODE_PHASE4_PROMPT").unwrap_or_else(|_| {
        "Reply with exactly one short sentence saying Phase 4 mapping smoke passed. Do not call tools."
            .to_string()
    });

    let mut server = server_config(&base_url)?;
    server.basic_auth_username = env::var("OPENCODE_SERVER_USERNAME").ok();
    server.basic_auth_password = env::var("OPENCODE_SERVER_PASSWORD").ok();

    let client = OpenCodeClient::new(server.clone())?;
    let stream = OpenCodeEventStreamClient::new(server.clone())?;
    let context = OpenCodeRequestContext::new(directory.clone())?;
    let scope = OpenCodeMappingScope::from_request_context(
        server.server_id.clone(),
        &context,
        "live phase4 mapping",
    )?;

    let health = client.get_health().await?;
    println!(
        "health: healthy={} version={}",
        health.healthy, health.version
    );

    let sessions = client
        .list_sessions(&OpenCodeSessionListQuery {
            context: context.clone(),
            roots: Some(true),
            start: None,
            search: None,
            limit: Some(20),
        })
        .await?;
    let statuses = client.get_session_status(&context).await?;
    let thread_summaries = map_thread_summaries(&scope, &sessions, &statuses)?;
    println!(
        "mapped thread summaries: count={} first={:?}",
        thread_summaries.len(),
        thread_summaries.first().map(|summary| &summary.thread_key)
    );

    let providers = client.list_providers(&context).await?;
    let provider_auth = client.list_provider_auth_methods(&context).await?;
    let model_catalog = map_model_catalog(&scope, &providers, Some(&provider_auth));
    println!(
        "mapped model catalog: connected_providers={} ids={:?}",
        model_catalog.providers.len(),
        model_catalog
            .providers
            .iter()
            .map(|provider| provider.provider_id.clone())
            .collect::<Vec<_>>()
    );

    let mut handle = stream.connect_directory(context.clone())?;
    let ready = next_stream_event(&mut handle, Duration::from_secs(10)).await?;
    println!("stream ready: {ready:?}");

    let title = format!("Phase 4 mapping smoke {}", unique_suffix());
    let created = client
        .create_session(&OpenCodeSessionCreateRequest {
            context: context.clone(),
            parent_id: None,
            title: Some(title.clone()),
            workspace_id: None,
        })
        .await?;
    println!(
        "created session: id={} directory={} title={}",
        created.id, created.directory, created.title
    );

    let created_mapped = wait_for_mapped_event(&mut handle, Duration::from_secs(10), |event| {
        matches!(
            event,
            OpenCodeMappedEvent::ThreadSummaryUpsert(summary)
                if summary.thread_key.session_id == created.id
        )
    })
    .await?;
    println!("mapped created event: {created_mapped:?}");

    client
        .prompt_async(
            &created.id,
            &context,
            &OpenCodePromptAsyncRequest {
                message_id: None,
                model: None,
                agent: None,
                no_reply: None,
                tools: None,
                format: None,
                system: None,
                variant: None,
                parts: vec![OpenCodePromptPartInput::Text(OpenCodePromptTextPartInput {
                    id: None,
                    text: prompt,
                    synthetic: None,
                    ignored: None,
                    metadata: serde_json::Value::Object(Default::default()),
                })],
            },
        )
        .await?;
    println!("prompt_async: sent");

    let mapped_live =
        collect_mapped_events(&mut handle, Duration::from_secs(20), &scope, &created.id).await?;
    println!("mapped live events for session {}:", created.id);
    for event in &mapped_live {
        println!("  {event:?}");
    }

    let messages = client
        .list_messages(&created.id, &context, Some(50), None)
        .await?;
    let snapshot = map_conversation_snapshot(&scope, &created, &messages.items)?;
    let assistant_text = snapshot
        .messages
        .iter()
        .filter(|message| {
            matches!(
                message.role,
                opencode_bridge::OpenCodeConversationRole::Assistant
            )
        })
        .flat_map(|message| &message.parts)
        .filter_map(|part| match part {
            opencode_bridge::OpenCodeConversationPart::Text(text) => Some(text.text.clone()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("");

    println!(
        "mapped hydration snapshot: thread={} messages={} assistant_text={:?}",
        snapshot.thread_key.session_id,
        snapshot.messages.len(),
        assistant_text
    );

    handle.close();
    Ok(())
}

async fn next_stream_event(
    handle: &mut opencode_bridge::OpenCodeStreamHandle,
    timeout_duration: Duration,
) -> Result<OpenCodeStreamEvent, Box<dyn std::error::Error>> {
    match timeout(timeout_duration, handle.next()).await {
        Ok(Some(Ok(event))) => Ok(event),
        Ok(Some(Err(error))) => Err(format!("stream error: {error}").into()),
        Ok(None) => Err("stream ended".into()),
        Err(_) => Err(format!("timed out after {} ms", timeout_duration.as_millis()).into()),
    }
}

async fn wait_for_mapped_event<F>(
    handle: &mut opencode_bridge::OpenCodeStreamHandle,
    timeout_duration: Duration,
    matcher: F,
) -> Result<OpenCodeMappedEvent, Box<dyn std::error::Error>>
where
    F: Fn(&OpenCodeMappedEvent) -> bool,
{
    let deadline = Instant::now() + timeout_duration;

    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let event = next_stream_event(handle, remaining).await?;
        if let OpenCodeStreamEvent::Event { directory, event } = event {
            let scope = OpenCodeMappingScope::new("local-opencode", directory)?;
            for mapped in map_event(&scope, &event)? {
                if matcher(&mapped) {
                    return Ok(mapped);
                }
            }
        }
    }
}

async fn collect_mapped_events(
    handle: &mut opencode_bridge::OpenCodeStreamHandle,
    timeout_duration: Duration,
    scope: &OpenCodeMappingScope,
    session_id: &str,
) -> Result<Vec<OpenCodeMappedEvent>, Box<dyn std::error::Error>> {
    let deadline = Instant::now() + timeout_duration;
    let mut mapped = Vec::new();
    let mut saw_idle = false;

    while Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let event = match next_stream_event(handle, remaining).await {
            Ok(event) => event,
            Err(error) if error.to_string().contains("timed out") => break,
            Err(error) => return Err(error),
        };

        if let OpenCodeStreamEvent::Event { event, .. } = event {
            for item in map_event(scope, &event)? {
                let belongs_to_session = match &item {
                    OpenCodeMappedEvent::ThreadSummaryUpsert(summary) => {
                        summary.thread_key.session_id == session_id
                    }
                    OpenCodeMappedEvent::ThreadDeleted { thread_key }
                    | OpenCodeMappedEvent::ApprovalResolved { thread_key, .. } => {
                        thread_key.session_id == session_id
                    }
                    OpenCodeMappedEvent::ThreadStateUpdated(update) => {
                        if update.thread_key.session_id == session_id
                            && update.state == opencode_bridge::OpenCodeThreadState::Idle
                        {
                            saw_idle = true;
                        }
                        update.thread_key.session_id == session_id
                    }
                    OpenCodeMappedEvent::ConversationDelta(delta) => match delta {
                        OpenCodeConversationDelta::MessageUpsert(message) => {
                            message.thread_key.session_id == session_id
                        }
                        OpenCodeConversationDelta::PartUpsert(part) => {
                            part.thread_key.session_id == session_id
                        }
                        OpenCodeConversationDelta::PartFieldDelta { thread_key, .. } => {
                            thread_key.session_id == session_id
                        }
                        OpenCodeConversationDelta::PartRemoved { thread_key, .. }
                        | OpenCodeConversationDelta::SessionDiff { thread_key, .. } => {
                            thread_key.session_id == session_id
                        }
                    },
                    OpenCodeMappedEvent::ApprovalUpsert(approval) => {
                        approval.thread_key.session_id == session_id
                    }
                    OpenCodeMappedEvent::Unknown {
                        session_id: current,
                        ..
                    } => current.as_deref() == Some(session_id),
                };

                if belongs_to_session {
                    mapped.push(item);
                }
            }
        }

        if saw_idle {
            break;
        }
    }

    Ok(mapped)
}

fn server_config(base_url: &str) -> Result<OpenCodeServerConfig, OpenCodeBridgeError> {
    let url = Url::parse(base_url)?;
    let host = url.host_str().unwrap_or("127.0.0.1").to_string();
    let port = url.port_or_known_default().unwrap_or(80);
    let tls = url.scheme() == "https";

    OpenCodeServerConfig::new(
        "local-opencode",
        "Local OpenCode",
        base_url,
        host,
        port,
        tls,
    )
}

fn unique_suffix() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_else(|_| Duration::from_secs(0))
        .as_millis()
}
