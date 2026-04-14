mod fixtures;

use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};

use opencode_bridge::{
    OpenCodeBridgeError, OpenCodeClient, OpenCodePermissionId, OpenCodePermissionReplyRequest,
    OpenCodePermissionResponse, OpenCodePromptAsyncRequest, OpenCodePromptPartInput,
    OpenCodePromptTextPartInput, OpenCodeRequestContext, OpenCodeServerConfig,
    OpenCodeSessionCreateRequest, OpenCodeSessionForkRequest, OpenCodeSessionListQuery,
    OpenCodeSessionUpdateRequest,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
    task::JoinHandle,
};
use url::Url;

#[tokio::test]
async fn health_project_and_path_decode() {
    let server = TestServer::spawn(|request| match request.path.as_str() {
        "/global/health" => ResponseSpec::json(200, fixtures::json("health.json")),
        "/project/current" => ResponseSpec::json(200, fixtures::json("project_current.json")),
        "/path" => ResponseSpec::json(200, fixtures::json("path_info.json")),
        other => panic!("unexpected path: {other}"),
    })
    .await;
    let client = server.client();
    let context = context();

    let health = client.get_health().await.unwrap();
    let project = client.get_current_project(&context).await.unwrap();
    let path = client.get_path_info(&context).await.unwrap();

    assert!(health.healthy);
    assert_eq!(health.version, "0.4.2");
    assert_eq!(project.id, "proj_litter");
    assert_eq!(project.icon.unwrap().override_name.as_deref(), Some("book"));
    assert_eq!(path.directory, context.directory.unwrap());

    let requests = server.requests();
    assert_eq!(requests[0].path, "/global/health");
    assert_eq!(
        requests[1].query.get("directory").map(String::as_str),
        Some("/Users/franklin/Development/OpenSource/litter")
    );
    assert_eq!(
        requests[2].query.get("directory").map(String::as_str),
        Some("/Users/franklin/Development/OpenSource/litter")
    );
}

#[tokio::test]
async fn session_list_sends_directory_query_and_returns_typed_sessions() {
    let server = TestServer::spawn(|request| {
        assert_eq!(request.method, "GET");
        assert_eq!(request.path, "/session");
        ResponseSpec::json(200, fixtures::json("session_list.json"))
    })
    .await;
    let client = server.client();
    let query = OpenCodeSessionListQuery {
        context: context(),
        roots: Some(true),
        start: None,
        search: Some("litter".to_string()),
        limit: Some(25),
    };

    let sessions = client.list_sessions(&query).await.unwrap();

    assert_eq!(sessions.len(), 2);
    assert_eq!(sessions[0].id, "sess_root");

    let request = server.only_request();
    assert_eq!(
        request.query.get("directory").map(String::as_str),
        Some("/Users/franklin/Development/OpenSource/litter")
    );
    assert_eq!(request.query.get("roots").map(String::as_str), Some("true"));
    assert_eq!(
        request.query.get("search").map(String::as_str),
        Some("litter")
    );
    assert_eq!(request.query.get("limit").map(String::as_str), Some("25"));
}

#[tokio::test]
async fn session_create_requires_directory_and_posts_body_correctly() {
    let server = TestServer::spawn(|request| {
        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/session");
        ResponseSpec::json(200, fixtures::json("session_created.json"))
    })
    .await;
    let client = server.client();

    let missing_context = OpenCodeSessionCreateRequest {
        context: OpenCodeRequestContext::default(),
        parent_id: None,
        title: Some("Missing".to_string()),
        workspace_id: None,
    };
    assert!(matches!(
        client.create_session(&missing_context).await,
        Err(OpenCodeBridgeError::MissingDirectory {
            operation: "session create"
        })
    ));
    assert!(server.requests().is_empty());

    let request = OpenCodeSessionCreateRequest {
        context: context(),
        parent_id: Some("sess_root".to_string()),
        title: Some("Follow-up".to_string()),
        workspace_id: Some("workspace-1".to_string()),
    };
    let session = client.create_session(&request).await.unwrap();

    assert_eq!(session.id, "sess_created");

    let captured = server.only_request();
    assert_eq!(
        captured.query.get("directory").map(String::as_str),
        Some("/Users/franklin/Development/OpenSource/litter")
    );
    assert_eq!(
        captured
            .headers
            .get("x-opencode-directory")
            .map(String::as_str),
        Some("/Users/franklin/Development/OpenSource/litter")
    );
    assert!(captured.body.contains("\"parentID\":\"sess_root\""));
    assert!(captured.body.contains("\"title\":\"Follow-up\""));
    assert!(captured.body.contains("\"workspaceID\":\"workspace-1\""));
    assert!(!captured.body.contains("\"directory\""));
}

#[tokio::test]
async fn message_list_decodes_typed_history_and_cursor() {
    let server = TestServer::spawn(|request| {
        assert_eq!(request.method, "GET");
        assert_eq!(request.path, "/session/sess_created/message");
        ResponseSpec::json(200, fixtures::json("messages_text_reasoning_tool.json"))
            .with_header("x-next-cursor", "cursor-2")
    })
    .await;
    let client = server.client();

    let messages = client
        .list_messages("sess_created", &context(), Some(10), Some("cursor-1"))
        .await
        .unwrap();

    assert_eq!(messages.items.len(), 2);
    assert_eq!(messages.next_cursor.as_deref(), Some("cursor-2"));

    let request = server.only_request();
    assert_eq!(request.query.get("limit").map(String::as_str), Some("10"));
    assert_eq!(
        request.query.get("before").map(String::as_str),
        Some("cursor-1")
    );
    assert_eq!(
        request.query.get("directory").map(String::as_str),
        Some("/Users/franklin/Development/OpenSource/litter")
    );
}

#[tokio::test]
async fn prompt_async_posts_model_payload_correctly() {
    let server = TestServer::spawn(|request| {
        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/session/sess_created/prompt_async");
        ResponseSpec::empty(204)
    })
    .await;
    let client = server.client();
    let body = OpenCodePromptAsyncRequest {
        message_id: Some("msg_user".to_string()),
        model: Some(opencode_bridge::OpenCodeModelRef {
            provider_id: "openai".to_string(),
            model_id: "gpt-5.4".to_string(),
        }),
        agent: Some("default".to_string()),
        no_reply: Some(false),
        tools: None,
        format: None,
        system: Some("Be concise".to_string()),
        variant: Some("fast".to_string()),
        parts: vec![OpenCodePromptPartInput::Text(OpenCodePromptTextPartInput {
            id: Some("part_1".to_string()),
            text: "Ship the fix".to_string(),
            synthetic: None,
            ignored: None,
            metadata: serde_json::json!({}),
        })],
    };

    client
        .prompt_async("sess_created", &context(), &body)
        .await
        .unwrap();

    let request = server.only_request();
    assert_eq!(
        request.query.get("directory").map(String::as_str),
        Some("/Users/franklin/Development/OpenSource/litter")
    );
    assert_eq!(
        request
            .headers
            .get("x-opencode-directory")
            .map(String::as_str),
        Some("/Users/franklin/Development/OpenSource/litter")
    );
    assert!(request.body.contains("\"messageID\":\"msg_user\""));
    assert!(request.body.contains("\"providerID\":\"openai\""));
    assert!(request.body.contains("\"modelID\":\"gpt-5.4\""));
    assert!(request.body.contains("\"type\":\"text\""));
    assert!(request.body.contains("\"text\":\"Ship the fix\""));
}

#[tokio::test]
async fn session_mutations_and_provider_calls_use_directory_context() {
    let server =
        TestServer::spawn(
            |request| match (request.method.as_str(), request.path.as_str()) {
                ("POST", "/session/sess_created/abort") => ResponseSpec::json(200, "true"),
                ("POST", "/session/sess_created/fork") => {
                    ResponseSpec::json(200, fixtures::json("session_created.json"))
                }
                ("PATCH", "/session/sess_created") => {
                    ResponseSpec::json(200, fixtures::json("session_created.json"))
                }
                ("GET", "/provider") => {
                    ResponseSpec::json(200, fixtures::json("provider_list.json"))
                }
                ("GET", "/provider/auth") => {
                    ResponseSpec::json(200, r#"{"openai":[{"type":"api","label":"API key"}]}"#)
                }
                other => panic!("unexpected request: {other:?}"),
            },
        )
        .await;
    let client = server.client();
    let context = context();

    assert!(
        client
            .abort_session("sess_created", &context)
            .await
            .unwrap()
    );
    let forked = client
        .fork_session(
            "sess_created",
            &context,
            &OpenCodeSessionForkRequest {
                message_id: Some("msg_2".to_string()),
            },
        )
        .await
        .unwrap();
    let renamed = client
        .rename_session(
            "sess_created",
            &context,
            &OpenCodeSessionUpdateRequest {
                title: Some("Renamed".to_string()),
            },
        )
        .await
        .unwrap();
    let providers = client.list_providers(&context).await.unwrap();
    let auth_methods = client.list_provider_auth_methods(&context).await.unwrap();

    assert_eq!(forked.id, "sess_created");
    assert_eq!(renamed.id, "sess_created");
    assert_eq!(providers.connected, vec!["openai"]);
    assert_eq!(auth_methods["openai"][0].method_type, "api");

    for request in server.requests() {
        if request.path == "/global/health" {
            continue;
        }
        assert_eq!(
            request.query.get("directory").map(String::as_str),
            Some("/Users/franklin/Development/OpenSource/litter")
        );
    }
}

#[tokio::test]
async fn permission_reply_sends_right_body_enum() {
    let server = TestServer::spawn(|request| {
        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/session/sess_created/permissions/perm_1");
        ResponseSpec::json(200, "true")
    })
    .await;
    let client = server.client();

    let approved = client
        .reply_permission(
            "sess_created",
            &OpenCodePermissionId("perm_1".to_string()),
            &context(),
            &OpenCodePermissionReplyRequest {
                response: OpenCodePermissionResponse::Always,
            },
        )
        .await
        .unwrap();

    assert!(approved);

    let request = server.only_request();
    assert!(request.body.contains("\"response\":\"always\""));
    assert_eq!(
        request
            .headers
            .get("x-opencode-directory")
            .map(String::as_str),
        Some("/Users/franklin/Development/OpenSource/litter")
    );
}

#[tokio::test]
async fn http_errors_become_normalized_bridge_errors() {
    let server = TestServer::spawn(|request| match request.path.as_str() {
        "/provider" => ResponseSpec::json(401, r#"{"message":"invalid credentials"}"#),
        "/session/missing" => ResponseSpec::json(404, r#"{"error":{"message":"session missing"}}"#),
        "/session/oops/abort" => ResponseSpec::text(500, "server exploded"),
        other => panic!("unexpected path: {other}"),
    })
    .await;
    let client = server.client();
    let context = context();

    let unauthorized = client.list_providers(&context).await.unwrap_err();
    let missing = client.get_session("missing", &context).await.unwrap_err();
    let failed_abort = client.abort_session("oops", &context).await.unwrap_err();

    match unauthorized {
        OpenCodeBridgeError::HttpStatus {
            endpoint,
            status,
            retryable,
            message,
            ..
        } => {
            assert_eq!(endpoint, "provider.list");
            assert_eq!(status.as_u16(), 401);
            assert!(!retryable);
            assert_eq!(message, "invalid credentials");
        }
        other => panic!("expected status error, got {other:?}"),
    }

    match missing {
        OpenCodeBridgeError::HttpStatus {
            endpoint,
            status,
            retryable,
            message,
            ..
        } => {
            assert_eq!(endpoint, "session.get");
            assert_eq!(status.as_u16(), 404);
            assert!(!retryable);
            assert_eq!(message, "session missing");
        }
        other => panic!("expected status error, got {other:?}"),
    }

    match failed_abort {
        OpenCodeBridgeError::HttpStatus {
            endpoint,
            status,
            retryable,
            message,
            ..
        } => {
            assert_eq!(endpoint, "session.abort");
            assert_eq!(status.as_u16(), 500);
            assert!(retryable);
            assert_eq!(
                message,
                "request failed with status 500 Internal Server Error"
            );
        }
        other => panic!("expected status error, got {other:?}"),
    }
}

#[tokio::test]
async fn invalid_json_becomes_invalid_response_error() {
    let server = TestServer::spawn(|request| {
        assert_eq!(request.path, "/global/health");
        ResponseSpec::json(200, r#"{"healthy":true,"version":1}"#)
    })
    .await;
    let client = server.client();

    match client.get_health().await.unwrap_err() {
        OpenCodeBridgeError::InvalidResponse { endpoint, body, .. } => {
            assert_eq!(endpoint, "global.health");
            assert_eq!(body.as_deref(), Some(r#"{"healthy":true,"version":1}"#));
        }
        other => panic!("expected invalid response, got {other:?}"),
    }
}

#[tokio::test]
async fn basic_auth_is_applied_when_password_is_configured() {
    let server = TestServer::spawn(|request| {
        assert_eq!(request.path, "/global/health");
        ResponseSpec::json(200, fixtures::json("health.json"))
    })
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
    let client = OpenCodeClient::new(config).unwrap();

    client.get_health().await.unwrap();

    let request = server.only_request();
    assert_eq!(
        request.headers.get("authorization").map(String::as_str),
        Some("Basic YWxpY2U6c2VjcmV0")
    );
}

fn context() -> OpenCodeRequestContext {
    OpenCodeRequestContext::new("/Users/franklin/Development/OpenSource/litter").unwrap()
}

#[derive(Clone, Debug)]
struct RequestRecord {
    method: String,
    path: String,
    query: BTreeMap<String, String>,
    headers: BTreeMap<String, String>,
    body: String,
}

#[derive(Clone)]
struct ResponseSpec {
    status: u16,
    headers: Vec<(String, String)>,
    body: String,
}

impl ResponseSpec {
    fn json(status: u16, body: &str) -> Self {
        Self {
            status,
            headers: vec![("content-type".to_string(), "application/json".to_string())],
            body: body.to_string(),
        }
    }

    fn text(status: u16, body: &str) -> Self {
        Self {
            status,
            headers: vec![(
                "content-type".to_string(),
                "text/plain; charset=utf-8".to_string(),
            )],
            body: body.to_string(),
        }
    }

    fn empty(status: u16) -> Self {
        Self {
            status,
            headers: Vec::new(),
            body: String::new(),
        }
    }

    fn with_header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.to_string(), value.to_string()));
        self
    }
}

type RequestHandler = dyn Fn(&RequestRecord) -> ResponseSpec + Send + Sync + 'static;

struct TestServer {
    base_url: Url,
    requests: Arc<Mutex<Vec<RequestRecord>>>,
    shutdown: Option<oneshot::Sender<()>>,
    task: JoinHandle<()>,
}

impl TestServer {
    async fn spawn(
        handler: impl Fn(&RequestRecord) -> ResponseSpec + Send + Sync + 'static,
    ) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let base_url = Url::parse(&format!("http://{addr}")).unwrap();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let handler: Arc<RequestHandler> = Arc::new(handler);
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
        let requests_for_task = Arc::clone(&requests);

        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = &mut shutdown_rx => break,
                    accepted = listener.accept() => {
                        let Ok((stream, _peer)) = accepted else { break };
                        let handler = Arc::clone(&handler);
                        let requests = Arc::clone(&requests_for_task);
                        tokio::spawn(async move {
                            if let Err(error) = handle_connection(stream, handler, requests).await {
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

    fn client(&self) -> OpenCodeClient {
        let config = OpenCodeServerConfig::new(
            "server-1",
            "OpenCode",
            self.base_url.as_str(),
            "127.0.0.1",
            self.base_url.port().unwrap(),
            false,
        )
        .unwrap();
        OpenCodeClient::new(config).unwrap()
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
    handler: Arc<RequestHandler>,
    requests: Arc<Mutex<Vec<RequestRecord>>>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let request = read_request(&mut stream).await?;
    let response = handler(&request);
    requests.lock().unwrap().push(request);

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

    if !has_content_length {
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
        method,
        path: url.path().to_string(),
        query,
        headers,
        body,
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
