mod fixtures;

use std::{
    collections::{BTreeMap, VecDeque},
    sync::{Arc, Mutex},
    time::Duration,
};

use opencode_bridge::{
    OpenCodeBridgeError, OpenCodeEvent, OpenCodeEventStreamClient, OpenCodeReconnectPolicy,
    OpenCodeRefreshHint, OpenCodeRequestContext, OpenCodeServerConfig, OpenCodeStreamConfig,
    OpenCodeStreamEvent,
};
use serde_json::Value;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
    task::JoinHandle,
    time::timeout,
};
use url::Url;

#[tokio::test]
async fn missing_directory_is_rejected_before_any_request() {
    let server = TestServer::spawn(vec![ResponsePlan::sse(sse_record(fixtures::json(
        "event_server_connected.sse.json",
    )))])
    .await;
    let client = server.stream_client(None);

    let error = client
        .connect_directory(OpenCodeRequestContext::default())
        .unwrap_err();

    assert!(matches!(
        error,
        OpenCodeBridgeError::MissingDirectory {
            operation: "event stream connect"
        }
    ));
    assert!(server.requests().is_empty());
}

#[tokio::test]
async fn stream_applies_basic_auth_when_password_is_configured() {
    let server = TestServer::spawn(vec![
        ResponsePlan::sse(sse_record(fixtures::json(
            "event_server_connected.sse.json",
        )))
        .with_linger(Duration::from_millis(250)),
    ])
    .await;
    let mut config = OpenCodeServerConfig::new(
        "server-1",
        "OpenCode",
        server.base_url.as_str(),
        "127.0.0.1",
        server.base_url.port().unwrap(),
        false,
    )
    .unwrap();
    config.basic_auth_username = Some("alice".to_string());
    config.basic_auth_password = Some("secret".to_string());
    let client = OpenCodeEventStreamClient::new(config).unwrap();
    let mut handle = client.connect_directory(context()).unwrap();

    let _ = handle.next().await.unwrap().unwrap();

    assert_eq!(
        server
            .only_request()
            .headers
            .get("authorization")
            .map(String::as_str),
        Some("Basic YWxpY2U6c2VjcmV0")
    );

    handle.close();
}

#[tokio::test]
async fn directory_stream_emits_ready_and_domain_events_while_ignoring_heartbeat() {
    let mut payload = String::new();
    payload.push_str(&sse_record(fixtures::json(
        "event_server_connected.sse.json",
    )));
    payload.push_str(": keepalive\n");
    payload.push('\n');
    payload.push_str(&sse_record(
        r#"{"type":"server.heartbeat","properties":{"ts":1730000415000}}"#,
    ));
    payload.push_str(&multiline_sse_record(message_updated_payload()));

    let server = TestServer::spawn(vec![
        ResponsePlan::sse(payload).with_linger(Duration::from_millis(250)),
    ])
    .await;
    let client = server.stream_client(None);
    let mut handle = client.connect_directory(context()).unwrap();

    assert_eq!(
        handle.next().await.unwrap().unwrap(),
        OpenCodeStreamEvent::Ready {
            directory: directory().to_string(),
        }
    );

    match handle.next().await.unwrap().unwrap() {
        OpenCodeStreamEvent::Event {
            directory: event_directory,
            event,
        } => {
            assert_eq!(event_directory, directory());
            match event {
                OpenCodeEvent::MessageUpdated { info } => {
                    assert_eq!(info.id, "msg_assistant_1");
                    assert_eq!(info.session_id, "sess_created");
                }
                other => panic!("expected message.updated event, got {other:?}"),
            }
        }
        other => panic!("expected domain event, got {other:?}"),
    }

    assert!(
        timeout(Duration::from_millis(75), handle.next())
            .await
            .is_err()
    );

    let request = server.only_request();
    assert_eq!(request.path, "/event");
    assert_eq!(
        request.query.get("directory").map(String::as_str),
        Some(directory())
    );
    assert_eq!(
        request
            .headers
            .get("x-opencode-directory")
            .map(String::as_str),
        Some(directory())
    );

    handle.close();
}

#[tokio::test]
async fn message_part_updated_decodes_delta() {
    let server = TestServer::spawn(vec![
        ResponsePlan::sse(format!(
            "{}{}",
            sse_record(fixtures::json("event_server_connected.sse.json")),
            sse_record(fixtures::json("message_part_updated_text.json")),
        ))
        .with_linger(Duration::from_millis(250)),
    ])
    .await;
    let client = server.stream_client(None);
    let mut handle = client.connect_directory(context()).unwrap();

    let _ = handle.next().await.unwrap().unwrap();

    match handle.next().await.unwrap().unwrap() {
        OpenCodeStreamEvent::Event { event, .. } => match event {
            OpenCodeEvent::MessagePartUpdated { part, delta } => {
                assert_eq!(part.part_type(), "text");
                assert_eq!(delta.as_deref(), Some(" continues"));
            }
            other => panic!("expected message.part.updated, got {other:?}"),
        },
        other => panic!("expected event, got {other:?}"),
    }

    handle.close();
}

#[tokio::test]
async fn permission_updated_decodes_typed_event() {
    let server = TestServer::spawn(vec![
        ResponsePlan::sse(format!(
            "{}{}",
            sse_record(fixtures::json("event_server_connected.sse.json")),
            sse_record(fixtures::json("permission_updated.json")),
        ))
        .with_linger(Duration::from_millis(250)),
    ])
    .await;
    let client = server.stream_client(None);
    let mut handle = client.connect_directory(context()).unwrap();

    let _ = handle.next().await.unwrap().unwrap();

    match handle.next().await.unwrap().unwrap() {
        OpenCodeStreamEvent::Event { event, .. } => match event {
            OpenCodeEvent::PermissionUpdated { permission } => {
                assert_eq!(permission.id.0, "perm_1");
                assert_eq!(permission.session_id, "sess_created");
            }
            other => panic!("expected permission.updated, got {other:?}"),
        },
        other => panic!("expected event, got {other:?}"),
    }

    handle.close();
}

#[tokio::test]
async fn malformed_json_becomes_invalid_event_error() {
    let server = TestServer::spawn(vec![
        ResponsePlan::sse(format!(
            "{}{}",
            sse_record(fixtures::json("event_server_connected.sse.json")),
            sse_record(r#"{"type":"message.updated","properties":{"info":"broken"}}"#),
        ))
        .with_linger(Duration::from_millis(250)),
    ])
    .await;
    let client = server.stream_client(None);
    let mut handle = client.connect_directory(context()).unwrap();

    let _ = handle.next().await.unwrap().unwrap();

    match handle.next().await.unwrap() {
        Err(OpenCodeBridgeError::InvalidEvent { endpoint, raw, .. }) => {
            assert_eq!(endpoint, "event.directory");
            assert!(raw.contains("\"message.updated\""));
        }
        other => panic!("expected invalid event error, got {other:?}"),
    }

    handle.close();
}

#[tokio::test]
async fn dropped_connection_triggers_reconnect_ready_and_resync_hints() {
    let plans = vec![
        ResponsePlan::sse(sse_record(fixtures::json(
            "event_server_connected.sse.json",
        ))),
        ResponsePlan::sse(sse_record(fixtures::json(
            "event_server_connected.sse.json",
        )))
        .with_linger(Duration::from_millis(250)),
    ];
    let policy = OpenCodeReconnectPolicy {
        initial_delay: Duration::from_millis(10),
        backoff_factor: 2,
        max_delay: Duration::from_millis(20),
        jitter_max: Duration::from_millis(0),
    };
    let server = TestServer::spawn(plans).await;
    let client = server.stream_client(Some(OpenCodeStreamConfig {
        connect_timeout: Duration::from_secs(2),
        channel_capacity: 32,
        reconnect_policy: policy,
    }));

    let mut handle = client.connect_directory(context()).unwrap();

    assert!(matches!(
        handle.next().await.unwrap().unwrap(),
        OpenCodeStreamEvent::Ready { .. }
    ));

    match handle.next().await.unwrap().unwrap() {
        OpenCodeStreamEvent::Disconnected { cause, .. } => assert!(cause.retryable),
        other => panic!("expected disconnected event, got {other:?}"),
    }

    assert_eq!(
        handle.next().await.unwrap().unwrap(),
        OpenCodeStreamEvent::Reconnecting {
            directory: directory().to_string(),
            attempt: 1,
            delay_ms: 10,
        }
    );
    assert_eq!(
        handle.next().await.unwrap().unwrap(),
        OpenCodeStreamEvent::Ready {
            directory: directory().to_string(),
        }
    );
    assert_eq!(
        handle.next().await.unwrap().unwrap(),
        OpenCodeStreamEvent::Resynced {
            directory: directory().to_string(),
            hints: vec![
                OpenCodeRefreshHint::SessionList,
                OpenCodeRefreshHint::SessionStatus,
                OpenCodeRefreshHint::OpenSessionMessages,
            ],
        }
    );

    handle.close();
}

fn context() -> OpenCodeRequestContext {
    OpenCodeRequestContext::new(directory()).unwrap()
}

fn directory() -> &'static str {
    "/Users/franklin/Development/OpenSource/litter"
}

fn message_updated_payload() -> String {
    serde_json::to_string_pretty(
        serde_json::from_str::<Value>(fixtures::json("event_global_message_updated.json"))
            .unwrap()
            .get("payload")
            .unwrap(),
    )
    .unwrap()
}

fn sse_record(data: &str) -> String {
    format!("data: {}\n\n", data.replace('\n', "\ndata: "))
}

fn multiline_sse_record(data: String) -> String {
    let mut record = String::from("event: ignored\nid: one\n");
    for line in data.lines() {
        record.push_str("data: ");
        record.push_str(line);
        record.push('\n');
    }
    record.push('\n');
    record
}

#[derive(Clone, Debug)]
struct RequestRecord {
    _method: String,
    path: String,
    query: BTreeMap<String, String>,
    headers: BTreeMap<String, String>,
    _body: String,
}

#[derive(Clone)]
struct ResponsePlan {
    status: u16,
    headers: Vec<(String, String)>,
    body: String,
    omit_content_length: bool,
    linger_after_write: Option<Duration>,
}

impl ResponsePlan {
    fn sse(body: String) -> Self {
        Self {
            status: 200,
            headers: vec![("content-type".to_string(), "text/event-stream".to_string())],
            body,
            omit_content_length: true,
            linger_after_write: None,
        }
    }

    fn with_linger(mut self, duration: Duration) -> Self {
        self.linger_after_write = Some(duration);
        self
    }
}

struct TestServer {
    base_url: Url,
    requests: Arc<Mutex<Vec<RequestRecord>>>,
    shutdown: Option<oneshot::Sender<()>>,
    task: JoinHandle<()>,
}

impl TestServer {
    async fn spawn(plans: Vec<ResponsePlan>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let base_url = Url::parse(&format!("http://{addr}")).unwrap();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let plans = Arc::new(Mutex::new(VecDeque::from(plans)));
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
        let requests_for_task = Arc::clone(&requests);
        let plans_for_task = Arc::clone(&plans);

        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = &mut shutdown_rx => break,
                    accepted = listener.accept() => {
                        let Ok((stream, _peer)) = accepted else { break };
                        let requests = Arc::clone(&requests_for_task);
                        let plans = Arc::clone(&plans_for_task);
                        tokio::spawn(async move {
                            if let Err(error) = handle_connection(stream, requests, plans).await {
                                panic!("test server connection failed: {error}");
                            }
                        });
                    }
                }
            }
        });

        Self {
            base_url,
            requests,
            shutdown: Some(shutdown_tx),
            task,
        }
    }

    fn stream_client(
        &self,
        stream_config: Option<OpenCodeStreamConfig>,
    ) -> OpenCodeEventStreamClient {
        let config = OpenCodeServerConfig::new(
            "server-1",
            "OpenCode",
            self.base_url.as_str(),
            "127.0.0.1",
            self.base_url.port().unwrap(),
            false,
        )
        .unwrap();

        match stream_config {
            Some(stream_config) => {
                OpenCodeEventStreamClient::with_stream_config(config, stream_config).unwrap()
            }
            None => OpenCodeEventStreamClient::new(config).unwrap(),
        }
    }

    fn requests(&self) -> Vec<RequestRecord> {
        self.requests.lock().unwrap().clone()
    }

    fn only_request(&self) -> RequestRecord {
        let requests = self.requests();
        assert_eq!(requests.len(), 1, "expected exactly one request");
        requests.into_iter().next().unwrap()
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        self.task.abort();
    }
}

async fn handle_connection(
    mut stream: TcpStream,
    requests: Arc<Mutex<Vec<RequestRecord>>>,
    plans: Arc<Mutex<VecDeque<ResponsePlan>>>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let request = read_request(&mut stream).await?;
    requests.lock().unwrap().push(request);

    let response = plans
        .lock()
        .unwrap()
        .pop_front()
        .expect("missing response plan for request");

    let reason = reason_phrase(response.status);
    let mut header_block = String::new();
    let mut has_content_length = false;

    for (name, value) in &response.headers {
        if name.eq_ignore_ascii_case("content-length") {
            has_content_length = true;
        }
        header_block.push_str(name);
        header_block.push_str(": ");
        header_block.push_str(value);
        header_block.push_str("\r\n");
    }

    if !has_content_length && !response.omit_content_length {
        header_block.push_str(&format!("Content-Length: {}\r\n", response.body.len()));
    }
    header_block.push_str("Connection: close\r\n");

    let head = format!(
        "HTTP/1.1 {} {}\r\n{}\r\n",
        response.status, reason, header_block
    );
    stream.write_all(head.as_bytes()).await?;
    if !response.body.is_empty() {
        stream.write_all(response.body.as_bytes()).await?;
    }
    stream.flush().await?;

    if let Some(duration) = response.linger_after_write {
        tokio::time::sleep(duration).await;
    }

    stream.shutdown().await?;
    Ok(())
}

async fn read_request(
    stream: &mut TcpStream,
) -> Result<RequestRecord, Box<dyn std::error::Error + Send + Sync>> {
    let mut buffer = Vec::new();
    let mut headers_end = None;
    let mut content_length = 0usize;

    loop {
        let mut chunk = [0_u8; 4096];
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);

        if headers_end.is_none() {
            headers_end = find_headers_end(&buffer);
            if let Some(end) = headers_end {
                content_length = parse_content_length(&buffer[..end])?;
            }
        }

        if let Some(end) = headers_end {
            if buffer.len() >= end + content_length {
                break;
            }
        }
    }

    let headers_end = headers_end.ok_or("missing request headers")?;
    let headers_text = std::str::from_utf8(&buffer[..headers_end])?;
    let mut lines = headers_text.split("\r\n").filter(|line| !line.is_empty());
    let request_line = lines.next().ok_or("missing request line")?;
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next().ok_or("missing method")?.to_string();
    let target = request_parts.next().ok_or("missing target")?;
    let url = Url::parse(&format!("http://127.0.0.1{target}"))?;

    let mut headers = BTreeMap::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_string());
        }
    }

    let query = url.query_pairs().into_owned().collect();
    let body =
        String::from_utf8_lossy(&buffer[headers_end..headers_end + content_length]).to_string();

    Ok(RequestRecord {
        _method: method,
        path: url.path().to_string(),
        query,
        headers,
        _body: body,
    })
}

fn find_headers_end(buffer: &[u8]) -> Option<usize> {
    buffer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|index| index + 4)
}

fn parse_content_length(headers: &[u8]) -> Result<usize, Box<dyn std::error::Error + Send + Sync>> {
    let text = std::str::from_utf8(headers)?;
    for line in text.lines() {
        if let Some((name, value)) = line.split_once(':') {
            if name.trim().eq_ignore_ascii_case("content-length") {
                return Ok(value.trim().parse()?);
            }
        }
    }
    Ok(0)
}

fn reason_phrase(status: u16) -> &'static str {
    match status {
        200 => "OK",
        204 => "No Content",
        401 => "Unauthorized",
        404 => "Not Found",
        500 => "Internal Server Error",
        _ => "OK",
    }
}
