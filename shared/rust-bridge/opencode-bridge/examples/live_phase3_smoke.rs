use std::{
    env,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use opencode_bridge::{
    OpenCodeBridgeError, OpenCodeClient, OpenCodeEvent, OpenCodeEventStreamClient,
    OpenCodeRequestContext, OpenCodeServerConfig, OpenCodeSessionCreateRequest,
    OpenCodeSessionListQuery, OpenCodeSessionUpdateRequest, OpenCodeStreamEvent,
};
use tokio::time::timeout;
use url::Url;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mode = env::var("OPENCODE_PHASE3_MODE").unwrap_or_else(|_| "smoke".to_string());
    let base_url =
        env::var("OPENCODE_BASE_URL").unwrap_or_else(|_| "http://127.0.0.1:4096".to_string());
    let directory = env::var("OPENCODE_DIRECTORY")
        .unwrap_or_else(|_| "/Users/franklin/Development/OpenSource/litter".to_string());
    let event_limit = env::var("OPENCODE_EVENT_LIMIT")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(8);
    let event_timeout = env::var("OPENCODE_EVENT_TIMEOUT_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(10_000);

    let mut server = server_config(&base_url)?;
    server.basic_auth_username = env::var("OPENCODE_SERVER_USERNAME").ok();
    server.basic_auth_password = env::var("OPENCODE_SERVER_PASSWORD").ok();
    let rest = OpenCodeClient::new(server.clone())?;
    let stream = OpenCodeEventStreamClient::new(server)?;
    let context = OpenCodeRequestContext::new(directory.clone())?;
    let mut handle = stream.connect_directory(context.clone())?;

    match mode.as_str() {
        "observe" => {
            observe_mode(
                &mut handle,
                event_limit,
                Duration::from_millis(event_timeout),
            )
            .await?
        }
        "smoke" => smoke_mode(&rest, &context, &mut handle).await?,
        other => return Err(format!("unsupported OPENCODE_PHASE3_MODE: {other}").into()),
    }

    handle.close();
    Ok(())
}

async fn smoke_mode(
    rest: &OpenCodeClient,
    context: &OpenCodeRequestContext,
    handle: &mut opencode_bridge::OpenCodeStreamHandle,
) -> Result<(), Box<dyn std::error::Error>> {
    let ready = next_event(handle, Duration::from_secs(10)).await?;
    println!("stream: {ready:?}");

    let sessions_before = rest
        .list_sessions(&OpenCodeSessionListQuery {
            context: context.clone(),
            roots: Some(true),
            start: None,
            search: None,
            limit: Some(20),
        })
        .await?;
    println!("rest: sessions before={}", sessions_before.len());

    let title = format!("Phase 3 SSE live smoke {}", unique_suffix());
    let created = rest
        .create_session(&OpenCodeSessionCreateRequest {
            context: context.clone(),
            parent_id: None,
            title: Some(title.clone()),
            workspace_id: None,
        })
        .await?;
    println!(
        "rest: created session id={} title={} directory={}",
        created.id, created.title, created.directory
    );

    let created_event =
        wait_for_session_event(handle, Duration::from_secs(10), |event| match event {
            OpenCodeStreamEvent::Event {
                event: OpenCodeEvent::SessionCreated { info },
                ..
            } if info.id == created.id => {
                Some(format!("stream: observed session.created {}", info.id))
            }
            _ => None,
        })
        .await?;
    println!("{created_event}");

    let renamed_title = format!("{title} renamed");
    let renamed = rest
        .rename_session(
            &created.id,
            context,
            &OpenCodeSessionUpdateRequest {
                title: Some(renamed_title.clone()),
            },
        )
        .await?;
    println!(
        "rest: renamed session id={} title={}",
        renamed.id, renamed.title
    );

    let renamed_event =
        wait_for_session_event(handle, Duration::from_secs(10), |event| match event {
            OpenCodeStreamEvent::Event {
                event: OpenCodeEvent::SessionUpdated { info },
                ..
            } if info.id == created.id && info.title == renamed_title => Some(format!(
                "stream: observed session.updated {} -> {}",
                info.id, info.title
            )),
            _ => None,
        })
        .await?;
    println!("{renamed_event}");

    Ok(())
}

async fn observe_mode(
    handle: &mut opencode_bridge::OpenCodeStreamHandle,
    event_limit: usize,
    timeout_duration: Duration,
) -> Result<(), Box<dyn std::error::Error>> {
    for index in 0..event_limit {
        let event = next_event(handle, timeout_duration).await?;
        println!("event[{index}]: {event:?}");
    }
    Ok(())
}

async fn next_event(
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

async fn wait_for_session_event<F>(
    handle: &mut opencode_bridge::OpenCodeStreamHandle,
    timeout_duration: Duration,
    matcher: F,
) -> Result<String, Box<dyn std::error::Error>>
where
    F: Fn(OpenCodeStreamEvent) -> Option<String>,
{
    let deadline = tokio::time::Instant::now() + timeout_duration;

    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let event = next_event(handle, remaining).await?;
        if let Some(message) = matcher(event.clone()) {
            return Ok(message);
        }
        println!("stream: skipping event {event:?}");
    }
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
