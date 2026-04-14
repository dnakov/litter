use std::{
    collections::hash_map::DefaultHasher,
    hash::{Hash, Hasher},
    io,
    time::Duration,
};

use reqwest::{Method, StatusCode, Url};
use tokio::{sync::mpsc, task::JoinHandle, time::sleep};

use crate::{
    OpenCodeBridgeError, OpenCodeEvent, OpenCodeRequestContext, OpenCodeServerConfig,
    sse::SseParser,
};

const DIRECTORY_EVENT_ENDPOINT: &str = "event.directory";
const DIRECTORY_EVENT_PATH: &str = "/event";
const DIRECTORY_HEADER: &str = "x-opencode-directory";
const WORKSPACE_HEADER: &str = "x-opencode-workspace";

#[derive(Debug, Clone)]
pub struct OpenCodeEventStreamClient {
    config: OpenCodeServerConfig,
    http: reqwest::Client,
    stream_config: OpenCodeStreamConfig,
}

impl OpenCodeEventStreamClient {
    pub fn new(config: OpenCodeServerConfig) -> Result<Self, OpenCodeBridgeError> {
        Self::with_stream_config(config, OpenCodeStreamConfig::default())
    }

    pub fn with_stream_config(
        config: OpenCodeServerConfig,
        stream_config: OpenCodeStreamConfig,
    ) -> Result<Self, OpenCodeBridgeError> {
        let http = reqwest::Client::builder()
            .connect_timeout(stream_config.connect_timeout)
            .build()
            .map_err(|source| {
                OpenCodeBridgeError::sse_connect_transport(DIRECTORY_EVENT_ENDPOINT, source)
            })?;

        Ok(Self {
            config,
            http,
            stream_config,
        })
    }

    pub fn config(&self) -> &OpenCodeServerConfig {
        &self.config
    }

    pub fn stream_config(&self) -> &OpenCodeStreamConfig {
        &self.stream_config
    }

    pub fn connect_directory(
        &self,
        context: OpenCodeRequestContext,
    ) -> Result<OpenCodeStreamHandle, OpenCodeBridgeError> {
        let directory = context
            .require_directory_for("event stream connect")?
            .to_string();
        let (sender, receiver) = mpsc::channel(self.stream_config.channel_capacity);
        let task = tokio::spawn(run_directory_stream(
            self.config.clone(),
            self.http.clone(),
            self.stream_config.clone(),
            context,
            sender,
        ));

        Ok(OpenCodeStreamHandle {
            directory,
            receiver,
            task: Some(task),
        })
    }
}

#[derive(Debug, Clone)]
pub struct OpenCodeStreamConfig {
    pub connect_timeout: Duration,
    pub channel_capacity: usize,
    pub reconnect_policy: OpenCodeReconnectPolicy,
}

impl Default for OpenCodeStreamConfig {
    fn default() -> Self {
        Self {
            connect_timeout: Duration::from_secs(10),
            channel_capacity: 64,
            reconnect_policy: OpenCodeReconnectPolicy::default(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenCodeReconnectPolicy {
    pub initial_delay: Duration,
    pub backoff_factor: u32,
    pub max_delay: Duration,
    pub jitter_max: Duration,
}

impl Default for OpenCodeReconnectPolicy {
    fn default() -> Self {
        Self {
            initial_delay: Duration::from_millis(250),
            backoff_factor: 2,
            max_delay: Duration::from_secs(5),
            jitter_max: Duration::from_millis(125),
        }
    }
}

#[derive(Debug)]
pub struct OpenCodeStreamHandle {
    directory: String,
    receiver: mpsc::Receiver<Result<OpenCodeStreamEvent, OpenCodeBridgeError>>,
    task: Option<JoinHandle<()>>,
}

impl OpenCodeStreamHandle {
    pub fn directory(&self) -> &str {
        &self.directory
    }

    pub async fn next(&mut self) -> Option<Result<OpenCodeStreamEvent, OpenCodeBridgeError>> {
        self.receiver.recv().await
    }

    pub fn close(&mut self) {
        self.receiver.close();
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

impl Drop for OpenCodeStreamHandle {
    fn drop(&mut self) {
        self.close();
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum OpenCodeStreamEvent {
    Ready {
        directory: String,
    },
    Event {
        directory: String,
        event: OpenCodeEvent,
    },
    Disconnected {
        directory: String,
        cause: OpenCodeDisconnectCause,
    },
    Reconnecting {
        directory: String,
        attempt: u32,
        delay_ms: u64,
    },
    Resynced {
        directory: String,
        hints: Vec<OpenCodeRefreshHint>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenCodeDisconnectCause {
    pub retryable: bool,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpenCodeRefreshHint {
    SessionList,
    SessionStatus,
    OpenSessionMessages,
}

async fn run_directory_stream(
    config: OpenCodeServerConfig,
    http: reqwest::Client,
    stream_config: OpenCodeStreamConfig,
    context: OpenCodeRequestContext,
    sender: mpsc::Sender<Result<OpenCodeStreamEvent, OpenCodeBridgeError>>,
) {
    let directory = match context
        .require_directory_for("event stream connect")
        .map(str::to_owned)
    {
        Ok(directory) => directory,
        Err(error) => {
            let _ = sender.send(Err(error)).await;
            return;
        }
    };

    let mut ready_once = false;
    let mut reconnect_attempt = 0u32;

    loop {
        let response = match open_directory_stream(&config, &http, &context).await {
            Ok(response) => response,
            Err(error) if error.retryable() => {
                let delay = backoff_delay(
                    &stream_config.reconnect_policy,
                    &directory,
                    reconnect_attempt,
                );
                if !emit_reconnecting(
                    &sender,
                    &directory,
                    reconnect_attempt.saturating_add(1),
                    delay,
                )
                .await
                {
                    return;
                }
                reconnect_attempt = reconnect_attempt.saturating_add(1);
                continue;
            }
            Err(error) => {
                let _ = sender.send(Err(error)).await;
                return;
            }
        };

        let mut parser = SseParser::default();
        let mut response = response;

        loop {
            let next_chunk = match response.chunk().await {
                Ok(Some(chunk)) => {
                    let payloads = match parser.push(&chunk, DIRECTORY_EVENT_ENDPOINT) {
                        Ok(payloads) => payloads,
                        Err(error) => {
                            let _ = sender.send(Err(error)).await;
                            continue;
                        }
                    };
                    if !handle_payloads(
                        &sender,
                        &directory,
                        payloads,
                        &mut ready_once,
                        &mut reconnect_attempt,
                    )
                    .await
                    {
                        return;
                    }
                    continue;
                }
                Ok(None) => match parser.finish(DIRECTORY_EVENT_ENDPOINT) {
                    Ok(payloads) => {
                        if !handle_payloads(
                            &sender,
                            &directory,
                            payloads,
                            &mut ready_once,
                            &mut reconnect_attempt,
                        )
                        .await
                        {
                            return;
                        }

                        OpenCodeBridgeError::sse_read(
                            DIRECTORY_EVENT_ENDPOINT,
                            true,
                            io::Error::new(io::ErrorKind::UnexpectedEof, "sse stream ended"),
                        )
                    }
                    Err(error) => error,
                },
                Err(source) => {
                    OpenCodeBridgeError::sse_read_transport(DIRECTORY_EVENT_ENDPOINT, source)
                }
            };

            if sender
                .send(Ok(OpenCodeStreamEvent::Disconnected {
                    directory: directory.clone(),
                    cause: OpenCodeDisconnectCause {
                        retryable: next_chunk.retryable(),
                        message: next_chunk.to_string(),
                    },
                }))
                .await
                .is_err()
            {
                return;
            }

            if !next_chunk.retryable() {
                let _ = sender.send(Err(next_chunk)).await;
                return;
            }

            let delay = backoff_delay(
                &stream_config.reconnect_policy,
                &directory,
                reconnect_attempt,
            );
            if !emit_reconnecting(
                &sender,
                &directory,
                reconnect_attempt.saturating_add(1),
                delay,
            )
            .await
            {
                return;
            }
            reconnect_attempt = reconnect_attempt.saturating_add(1);
            break;
        }
    }
}

async fn handle_payloads(
    sender: &mpsc::Sender<Result<OpenCodeStreamEvent, OpenCodeBridgeError>>,
    directory: &str,
    payloads: Vec<String>,
    ready_once: &mut bool,
    reconnect_attempt: &mut u32,
) -> bool {
    for payload in payloads {
        let event = match serde_json::from_str::<OpenCodeEvent>(&payload) {
            Ok(event) => event,
            Err(source) => {
                if sender
                    .send(Err(OpenCodeBridgeError::invalid_event(
                        DIRECTORY_EVENT_ENDPOINT,
                        payload,
                        source,
                    )))
                    .await
                    .is_err()
                {
                    return false;
                }
                continue;
            }
        };

        match event {
            OpenCodeEvent::ServerConnected => {
                let is_reconnect = *ready_once;
                *ready_once = true;
                *reconnect_attempt = 0;

                if sender
                    .send(Ok(OpenCodeStreamEvent::Ready {
                        directory: directory.to_string(),
                    }))
                    .await
                    .is_err()
                {
                    return false;
                }

                if is_reconnect
                    && sender
                        .send(Ok(OpenCodeStreamEvent::Resynced {
                            directory: directory.to_string(),
                            hints: vec![
                                OpenCodeRefreshHint::SessionList,
                                OpenCodeRefreshHint::SessionStatus,
                                OpenCodeRefreshHint::OpenSessionMessages,
                            ],
                        }))
                        .await
                        .is_err()
                {
                    return false;
                }
            }
            OpenCodeEvent::ServerHeartbeat => {}
            event => {
                if sender
                    .send(Ok(OpenCodeStreamEvent::Event {
                        directory: directory.to_string(),
                        event,
                    }))
                    .await
                    .is_err()
                {
                    return false;
                }
            }
        }
    }

    true
}

async fn emit_reconnecting(
    sender: &mpsc::Sender<Result<OpenCodeStreamEvent, OpenCodeBridgeError>>,
    directory: &str,
    attempt: u32,
    delay: Duration,
) -> bool {
    if sender
        .send(Ok(OpenCodeStreamEvent::Reconnecting {
            directory: directory.to_string(),
            attempt,
            delay_ms: duration_to_millis(delay),
        }))
        .await
        .is_err()
    {
        return false;
    }

    sleep(delay).await;
    true
}

async fn open_directory_stream(
    config: &OpenCodeServerConfig,
    http: &reqwest::Client,
    context: &OpenCodeRequestContext,
) -> Result<reqwest::Response, OpenCodeBridgeError> {
    let directory = context.require_directory_for("event stream connect")?;
    let url = endpoint_url(config, DIRECTORY_EVENT_PATH)?;
    let mut builder = http
        .request(Method::GET, url)
        .query(context)
        .header(DIRECTORY_HEADER, directory)
        .header(reqwest::header::ACCEPT, "text/event-stream");

    if let Some(workspace) = context.workspace.as_deref() {
        builder = builder.header(WORKSPACE_HEADER, workspace);
    }

    if let Some(password) = config.basic_auth_password.as_deref() {
        let username = config.basic_auth_username.as_deref().unwrap_or("opencode");
        builder = builder.basic_auth(username, Some(password));
    }

    let response = builder.send().await.map_err(|source| {
        OpenCodeBridgeError::sse_connect_transport(DIRECTORY_EVENT_ENDPOINT, source)
    })?;

    if response.status().is_success() {
        return Ok(response);
    }

    Err(normalize_connect_status(response).await)
}

fn endpoint_url(config: &OpenCodeServerConfig, path: &str) -> Result<Url, OpenCodeBridgeError> {
    let mut url = config.base_url.clone();
    let base_path = url.path().trim_end_matches('/');
    let full_path = if base_path.is_empty() {
        format!("/{}", path.trim_start_matches('/'))
    } else {
        format!("{base_path}/{}", path.trim_start_matches('/'))
    };
    url.set_path(&full_path);
    Ok(url)
}

async fn normalize_connect_status(response: reqwest::Response) -> OpenCodeBridgeError {
    let status = response.status();
    let body = response
        .text()
        .await
        .ok()
        .map(|body| truncate_for_error(&body));
    let message = body
        .as_deref()
        .and_then(extract_error_message)
        .unwrap_or_else(|| format!("request failed with status {status}"));

    OpenCodeBridgeError::HttpStatus {
        endpoint: DIRECTORY_EVENT_ENDPOINT,
        status,
        retryable: matches!(
            status,
            StatusCode::REQUEST_TIMEOUT
                | StatusCode::TOO_EARLY
                | StatusCode::TOO_MANY_REQUESTS
                | StatusCode::INTERNAL_SERVER_ERROR
                | StatusCode::BAD_GATEWAY
                | StatusCode::SERVICE_UNAVAILABLE
                | StatusCode::GATEWAY_TIMEOUT
        ),
        message,
        body,
    }
}

fn extract_error_message(body: &str) -> Option<String> {
    let parsed = serde_json::from_str::<serde_json::Value>(body).ok()?;
    let direct = parsed.get("message").and_then(serde_json::Value::as_str);
    let nested = parsed
        .get("error")
        .and_then(|value| value.get("message"))
        .and_then(serde_json::Value::as_str);
    let named = parsed.get("name").and_then(serde_json::Value::as_str);

    direct.or(nested).or(named).map(truncate_for_error)
}

fn truncate_for_error(input: &str) -> String {
    const MAX_LEN: usize = 2_048;
    if input.len() <= MAX_LEN {
        return input.to_string();
    }

    let mut truncated = input[..MAX_LEN].to_string();
    truncated.push_str("...");
    truncated
}

fn backoff_delay(
    policy: &OpenCodeReconnectPolicy,
    directory: &str,
    attempt_index: u32,
) -> Duration {
    let multiplier = policy.backoff_factor.saturating_pow(attempt_index.min(16));
    let base_ms = duration_to_millis(policy.initial_delay)
        .saturating_mul(multiplier as u64)
        .min(duration_to_millis(policy.max_delay));
    let jitter_ms = jitter_for_attempt(
        directory,
        attempt_index,
        duration_to_millis(policy.jitter_max),
    );
    let max_ms = duration_to_millis(policy.max_delay);

    Duration::from_millis(base_ms.saturating_add(jitter_ms).min(max_ms))
}

fn jitter_for_attempt(directory: &str, attempt_index: u32, jitter_max_ms: u64) -> u64 {
    if jitter_max_ms == 0 {
        return 0;
    }

    let mut hasher = DefaultHasher::new();
    directory.hash(&mut hasher);
    attempt_index.hash(&mut hasher);
    hasher.finish() % jitter_max_ms.saturating_add(1)
}

fn duration_to_millis(duration: Duration) -> u64 {
    duration.as_millis().try_into().unwrap_or(u64::MAX)
}
