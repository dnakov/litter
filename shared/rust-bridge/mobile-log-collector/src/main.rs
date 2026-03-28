use std::fs::File;
use std::io::{BufRead, BufReader};
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use axum::body::{Body, Bytes};
use axum::extract::{ConnectInfo, Query, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::get;
use axum::{Json, Router};
use chrono::{TimeZone, Utc};
use clap::{Args, Parser, Subcommand};
use flate2::read::GzDecoder;
use mobile_log_shared::StoredLogEvent;
use rusqlite::{Connection, OptionalExtension, params, params_from_iter, types::Value};
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;
use tokio::sync::broadcast;
use tokio_stream::StreamExt;
use tokio_stream::wrappers::BroadcastStream;
use uuid::Uuid;

#[derive(Parser)]
#[command(name = "mobile-log-collector")]
#[command(about = "LAN collector for centralized mobile logs")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Serve(ServeArgs),
    Query(ClientArgs),
    Tail(ClientArgs),
}

#[derive(Args, Clone)]
struct ServeArgs {
    #[arg(long, default_value = "0.0.0.0:8585")]
    bind: String,
    #[arg(long)]
    data_dir: Option<PathBuf>,
    #[arg(long, default_value_t = true)]
    private_only: bool,
}

#[derive(Args, Clone)]
struct ClientArgs {
    #[arg(long, default_value = "http://127.0.0.1:8585")]
    base_url: String,
    #[arg(long)]
    device_id: Option<String>,
    #[arg(long)]
    platform: Option<String>,
    #[arg(long)]
    level: Option<String>,
    #[arg(long)]
    subsystem: Option<String>,
    #[arg(long)]
    session_id: Option<String>,
    #[arg(long)]
    thread_id: Option<String>,
    #[arg(long)]
    request_id: Option<String>,
    #[arg(long)]
    start_ms: Option<i64>,
    #[arg(long)]
    end_ms: Option<i64>,
    #[arg(long, default_value_t = 1000)]
    limit: usize,
    #[arg(long, default_value_t = false)]
    pretty: bool,
}

#[derive(Clone)]
struct AppState {
    inner: Arc<AppStateInner>,
}

struct AppStateInner {
    private_only: bool,
    data_dir: PathBuf,
    db: Mutex<Connection>,
    live_tx: broadcast::Sender<StoredLogEvent>,
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    ok: bool,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
struct QueryParams {
    device_id: Option<String>,
    platform: Option<String>,
    level: Option<String>,
    subsystem: Option<String>,
    session_id: Option<String>,
    thread_id: Option<String>,
    request_id: Option<String>,
    start_ms: Option<i64>,
    end_ms: Option<i64>,
    limit: Option<usize>,
}

#[derive(Debug)]
struct BatchIngestResult {
    duplicate: bool,
    events: Vec<StoredLogEvent>,
}

#[derive(Debug)]
struct BatchIndexRow {
    batch_id: String,
    device_id: String,
    platform: Option<String>,
    app_version: Option<String>,
    first_ts: i64,
    last_ts: i64,
    event_count: usize,
    path: String,
}

#[derive(Debug)]
struct ApiError(StatusCode, String);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, self.1).into_response()
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();
    match cli.command {
        Command::Serve(args) => serve(args).await?,
        Command::Query(args) => run_query(args).await?,
        Command::Tail(args) => run_tail(args).await?,
    }
    Ok(())
}

async fn serve(args: ServeArgs) -> Result<(), Box<dyn std::error::Error>> {
    let data_dir = args.data_dir.unwrap_or_else(default_data_dir);
    std::fs::create_dir_all(&data_dir)?;
    let db_path = data_dir.join("collector.sqlite3");
    let connection = Connection::open(db_path)?;
    init_db(&connection)?;
    let (live_tx, _) = broadcast::channel(10_000);

    let state = AppState {
        inner: Arc::new(AppStateInner {
            private_only: args.private_only,
            data_dir,
            db: Mutex::new(connection),
            live_tx: live_tx.clone(),
        }),
    };

    // Print incoming events to stdout (like a built-in tail)
    let mut console_rx = live_tx.subscribe();
    tokio::spawn(async move {
        loop {
            match console_rx.recv().await {
                Ok(event) => {
                    let ts = chrono::Utc
                        .timestamp_millis_opt(event.timestamp_ms)
                        .single()
                        .map(|t| t.format("%H:%M:%S%.3f").to_string())
                        .unwrap_or_else(|| event.timestamp_ms.to_string());
                    let level_color = match event.level.as_str() {
                        "ERROR" => "\x1b[31m",
                        "WARN" => "\x1b[33m",
                        "INFO" => "\x1b[32m",
                        "DEBUG" => "\x1b[36m",
                        "TRACE" => "\x1b[90m",
                        _ => "\x1b[0m",
                    };
                    let reset = "\x1b[0m";
                    let dim = "\x1b[90m";
                    let device = if event.device_name.is_empty() {
                        &event.device_id
                    } else {
                        &event.device_name
                    };
                    let sub = event
                        .subsystem
                        .rsplit("::")
                        .next()
                        .unwrap_or(&event.subsystem);
                    eprint!(
                        "{dim}{ts}{reset} {dim}[{device}]{reset} {level_color}{:<5}{reset} {dim}{}{reset} {}",
                        event.level, sub, event.message
                    );
                    if let Some(ref fields) = event.fields_json {
                        if fields != "null" && !fields.is_empty() {
                            eprint!(" {dim}{fields}{reset}");
                        }
                    }
                    eprintln!();
                }
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    eprintln!("\x1b[33m[collector] skipped {n} events\x1b[0m");
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    });

    let app = Router::new()
        .route("/", get(root_redirect))
        .route("/tail", get(tail_ui))
        .route("/static/renderjson.js", get(renderjson_asset))
        .route("/healthz", get(healthz))
        .route("/v1/logs", axum::routing::post(post_logs))
        .route("/v1/query", get(query_logs))
        .route("/v1/tail", get(tail_logs))
        .with_state(state);

    let addr: SocketAddr = args.bind.parse()?;
    let listener = TcpListener::bind(&addr).await?;
    let local_addr = listener.local_addr()?;
    eprintln!("\x1b[32m[collector]\x1b[0m listening on {addr}");
    eprintln!(
        "\x1b[32m[collector]\x1b[0m web ui: {}",
        local_tail_ui_url(local_addr)
    );
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;
    Ok(())
}

async fn healthz() -> Json<HealthResponse> {
    Json(HealthResponse { ok: true })
}

async fn root_redirect() -> Redirect {
    Redirect::temporary("/tail")
}

async fn tail_ui() -> Html<&'static str> {
    Html(include_str!("tail_ui.html"))
}

async fn renderjson_asset() -> impl IntoResponse {
    (
        [(
            axum::http::header::CONTENT_TYPE,
            HeaderValue::from_static("text/javascript; charset=utf-8"),
        )],
        include_str!("renderjson.js"),
    )
}

async fn post_logs(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<impl IntoResponse, ApiError> {
    authorize(&state, &addr)?;
    let batch_id = required_header(&headers, "X-Batch-Id")?;
    let device_id = required_header(&headers, "X-Device-Id")?;
    let state_clone = state.clone();
    let body_vec = body.to_vec();

    let result = tokio::task::spawn_blocking(move || {
        ingest_batch(&state_clone, &batch_id, &device_id, &body_vec)
    })
    .await
    .map_err(|err| {
        ApiError(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("ingest join error: {err}"),
        )
    })?
    .map_err(|err| ApiError(StatusCode::BAD_REQUEST, err))?;

    if !result.duplicate {
        for event in result.events {
            let _ = state.inner.live_tx.send(event);
        }
    }

    Ok(StatusCode::NO_CONTENT)
}

async fn query_logs(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Query(params): Query<QueryParams>,
    _headers: HeaderMap,
) -> Result<Response, ApiError> {
    authorize(&state, &addr)?;
    let state_clone = state.clone();
    let rows = tokio::task::spawn_blocking(move || query_events(&state_clone, &params))
        .await
        .map_err(|err| {
            ApiError(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("query join error: {err}"),
            )
        })?
        .map_err(|err| ApiError(StatusCode::INTERNAL_SERVER_ERROR, err))?;

    let mut body = String::new();
    for row in rows {
        body.push_str(&serde_json::to_string(&row).map_err(internal_error)?);
        body.push('\n');
    }

    Ok((
        [(
            axum::http::header::CONTENT_TYPE,
            HeaderValue::from_static("application/x-ndjson"),
        )],
        body,
    )
        .into_response())
}

async fn tail_logs(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Query(params): Query<QueryParams>,
    _headers: HeaderMap,
) -> Result<Response, ApiError> {
    authorize(&state, &addr)?;
    let rx = state.inner.live_tx.subscribe();
    let stream = BroadcastStream::new(rx).filter_map(move |item| {
        let params = params.clone();
        let event = item.ok()?;
        if matches_event(&event, &params) {
            let line = serde_json::to_vec(&event).ok()?;
            Some(Ok::<Bytes, std::convert::Infallible>(Bytes::from(
                [line, b"\n".to_vec()].concat(),
            )))
        } else {
            None
        }
    });

    Ok((
        [(
            axum::http::header::CONTENT_TYPE,
            HeaderValue::from_static("application/x-ndjson"),
        )],
        Body::from_stream(stream),
    )
        .into_response())
}

fn ingest_batch(
    state: &AppState,
    batch_id: &str,
    device_id: &str,
    body: &[u8],
) -> Result<BatchIngestResult, String> {
    let duplicate = {
        let db = state
            .inner
            .db
            .lock()
            .map_err(|_| "collector database lock poisoned".to_string())?;
        db.query_row(
            "SELECT 1 FROM batches WHERE batch_id = ?1",
            params![batch_id],
            |_| Ok(()),
        )
        .optional()
        .map_err(|err| format!("failed to query batch index: {err}"))?
        .is_some()
    };
    if duplicate {
        return Ok(BatchIngestResult {
            duplicate: true,
            events: Vec::new(),
        });
    }

    let events = decode_batch(body)?;
    if events.is_empty() {
        return Err("batch contained no log events".to_string());
    }

    let first = events.first().expect("non-empty batch");
    let last = events.last().expect("non-empty batch");
    let batch_dir = batch_dir_for(&state.inner.data_dir, first.timestamp_ms, device_id);
    std::fs::create_dir_all(&batch_dir)
        .map_err(|err| format!("failed to create batch dir: {err}"))?;
    let path = batch_dir.join(format!("{batch_id}.ndjson.gz"));
    std::fs::write(&path, body).map_err(|err| format!("failed to write batch file: {err}"))?;

    let row = BatchIndexRow {
        batch_id: batch_id.to_string(),
        device_id: device_id.to_string(),
        platform: Some(first.platform.clone()),
        app_version: first.app_version.clone(),
        first_ts: first.timestamp_ms,
        last_ts: last.timestamp_ms,
        event_count: events.len(),
        path: path.to_string_lossy().to_string(),
    };

    let db = state
        .inner
        .db
        .lock()
        .map_err(|_| "collector database lock poisoned".to_string())?;
    db.execute(
        "INSERT INTO batches (batch_id, device_id, platform, app_version, first_ts, last_ts, event_count, path, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            row.batch_id,
            row.device_id,
            row.platform,
            row.app_version,
            row.first_ts,
            row.last_ts,
            row.event_count as i64,
            row.path,
            Utc::now().timestamp_millis(),
        ],
    )
    .map_err(|err| format!("failed to insert batch metadata: {err}"))?;

    Ok(BatchIngestResult {
        duplicate: false,
        events,
    })
}

fn query_events(state: &AppState, params: &QueryParams) -> Result<Vec<StoredLogEvent>, String> {
    let rows = {
        let db = state
            .inner
            .db
            .lock()
            .map_err(|_| "collector database lock poisoned".to_string())?;
        let mut sql = String::from(
            "SELECT batch_id, device_id, platform, app_version, first_ts, last_ts, event_count, path FROM batches WHERE 1=1",
        );
        let mut bind_values = Vec::<Value>::new();
        if params.device_id.is_some() {
            sql.push_str(" AND device_id = ?");
            bind_values.push(Value::from(
                params.device_id.clone().expect("device_id checked above"),
            ));
        }
        if params.platform.is_some() {
            sql.push_str(" AND platform = ?");
            bind_values.push(Value::from(
                params.platform.clone().expect("platform checked above"),
            ));
        }
        if params.start_ms.is_some() {
            sql.push_str(" AND last_ts >= ?");
            bind_values.push(Value::from(
                params.start_ms.expect("start_ms checked above"),
            ));
        }
        if params.end_ms.is_some() {
            sql.push_str(" AND first_ts <= ?");
            bind_values.push(Value::from(params.end_ms.expect("end_ms checked above")));
        }
        sql.push_str(" ORDER BY first_ts ASC");

        let mut stmt = db
            .prepare(&sql)
            .map_err(|err| format!("failed to prepare query: {err}"))?;
        let mapped = stmt
            .query_map(params_from_iter(bind_values.iter()), |row| {
                Ok(BatchIndexRow {
                    batch_id: row.get(0)?,
                    device_id: row.get(1)?,
                    platform: row.get(2)?,
                    app_version: row.get(3)?,
                    first_ts: row.get(4)?,
                    last_ts: row.get(5)?,
                    event_count: row.get::<_, i64>(6)? as usize,
                    path: row.get(7)?,
                })
            })
            .map_err(|err| format!("failed to execute query: {err}"))?;

        let mut rows = Vec::new();
        for row in mapped {
            rows.push(row.map_err(|err| format!("failed to decode row: {err}"))?);
        }
        rows
    };

    let limit = params.limit.unwrap_or(1000);
    let mut events = Vec::new();
    for row in rows {
        if events.len() >= limit {
            break;
        }
        for event in read_batch_file(Path::new(&row.path))? {
            if matches_event(&event, params) {
                events.push(event);
                if events.len() >= limit {
                    break;
                }
            }
        }
    }
    Ok(events)
}

fn matches_event(event: &StoredLogEvent, params: &QueryParams) -> bool {
    if let Some(device_id) = params.device_id.as_deref()
        && event.device_id != device_id
    {
        return false;
    }
    if let Some(platform) = params.platform.as_deref()
        && event.platform != platform
    {
        return false;
    }
    if let Some(level) = params.level.as_deref()
        && event.level != level.to_ascii_uppercase()
    {
        return false;
    }
    if let Some(subsystem) = params.subsystem.as_deref()
        && event.subsystem != subsystem
    {
        return false;
    }
    if let Some(session_id) = params.session_id.as_deref()
        && event.session_id.as_deref() != Some(session_id)
    {
        return false;
    }
    if let Some(thread_id) = params.thread_id.as_deref()
        && event.thread_id.as_deref() != Some(thread_id)
    {
        return false;
    }
    if let Some(request_id) = params.request_id.as_deref()
        && event.request_id.as_deref() != Some(request_id)
    {
        return false;
    }
    if let Some(start_ms) = params.start_ms
        && event.timestamp_ms < start_ms
    {
        return false;
    }
    if let Some(end_ms) = params.end_ms
        && event.timestamp_ms > end_ms
    {
        return false;
    }
    true
}

fn decode_batch(body: &[u8]) -> Result<Vec<StoredLogEvent>, String> {
    let decoder = GzDecoder::new(body);
    let reader = BufReader::new(decoder);
    let mut events = Vec::new();
    for line in reader.lines() {
        let line = line.map_err(|err| format!("failed to read batch line: {err}"))?;
        if line.trim().is_empty() {
            continue;
        }
        let event: StoredLogEvent =
            serde_json::from_str(&line).map_err(|err| format!("invalid event json: {err}"))?;
        events.push(event);
    }
    Ok(events)
}

fn read_batch_file(path: &Path) -> Result<Vec<StoredLogEvent>, String> {
    let file =
        File::open(path).map_err(|err| format!("failed to open {}: {err}", path.display()))?;
    let decoder = GzDecoder::new(file);
    let reader = BufReader::new(decoder);
    let mut events = Vec::new();
    for line in reader.lines() {
        let line = line.map_err(|err| format!("failed to read {}: {err}", path.display()))?;
        if line.trim().is_empty() {
            continue;
        }
        events
            .push(serde_json::from_str(&line).map_err(|err| format!("invalid event json: {err}"))?);
    }
    Ok(events)
}

fn init_db(connection: &Connection) -> rusqlite::Result<()> {
    connection.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS batches (
            batch_id TEXT PRIMARY KEY,
            device_id TEXT NOT NULL,
            platform TEXT,
            app_version TEXT,
            first_ts INTEGER NOT NULL,
            last_ts INTEGER NOT NULL,
            event_count INTEGER NOT NULL,
            path TEXT NOT NULL,
            created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_batches_device_id ON batches(device_id);
        CREATE INDEX IF NOT EXISTS idx_batches_platform ON batches(platform);
        CREATE INDEX IF NOT EXISTS idx_batches_first_ts ON batches(first_ts);
        CREATE INDEX IF NOT EXISTS idx_batches_last_ts ON batches(last_ts);
        "#,
    )
}

fn authorize(state: &AppState, addr: &SocketAddr) -> Result<(), ApiError> {
    if state.inner.private_only && !is_private(addr.ip()) {
        return Err(ApiError(
            StatusCode::FORBIDDEN,
            "collector only accepts private-network clients".into(),
        ));
    }
    Ok(())
}

fn required_header(headers: &HeaderMap, name: &'static str) -> Result<String, ApiError> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::to_string)
        .ok_or_else(|| {
            ApiError(
                StatusCode::BAD_REQUEST,
                format!("missing required header: {name}"),
            )
        })
}

fn is_private(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.is_private() || ip.is_loopback(),
        IpAddr::V6(ip) => ip.is_loopback() || ip.is_unique_local(),
    }
}

fn batch_dir_for(data_dir: &Path, timestamp_ms: i64, device_id: &str) -> PathBuf {
    let date = Utc
        .timestamp_millis_opt(timestamp_ms)
        .single()
        .unwrap_or_else(Utc::now)
        .format("%Y-%m-%d")
        .to_string();
    data_dir.join("batches").join(date).join(device_id)
}

fn default_data_dir() -> PathBuf {
    if let Ok(home) = std::env::var("HOME")
        && !home.is_empty()
    {
        return PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("mobile-log-collector");
    }
    std::env::temp_dir().join(format!("mobile-log-collector-{}", Uuid::new_v4()))
}

fn local_tail_ui_url(addr: SocketAddr) -> String {
    let host = match addr.ip() {
        IpAddr::V4(ip) if ip.is_unspecified() => "127.0.0.1".to_string(),
        IpAddr::V6(ip) if ip.is_unspecified() => "[::1]".to_string(),
        IpAddr::V4(ip) => ip.to_string(),
        IpAddr::V6(ip) => format!("[{ip}]"),
    };
    format!("http://{host}:{}/tail", addr.port())
}

async fn run_query(args: ClientArgs) -> Result<(), Box<dyn std::error::Error>> {
    let client = reqwest::Client::new();
    let response = client
        .get(format!("{}/v1/query", args.base_url.trim_end_matches('/')))
        .query(&QueryParams {
            device_id: args.device_id,
            platform: args.platform,
            level: args.level,
            subsystem: args.subsystem,
            session_id: args.session_id,
            thread_id: args.thread_id,
            request_id: args.request_id,
            start_ms: args.start_ms,
            end_ms: args.end_ms,
            limit: Some(args.limit),
        })
        .send()
        .await?;
    let body = response.text().await?;
    if !args.pretty {
        print!("{body}");
        return Ok(());
    }

    for line in body.lines() {
        if line.trim().is_empty() {
            continue;
        }
        let event: StoredLogEvent = serde_json::from_str(line)?;
        println!(
            "[{}] {} {} {}",
            event.timestamp_ms, event.level, event.subsystem, event.message
        );
    }
    Ok(())
}

async fn run_tail(args: ClientArgs) -> Result<(), Box<dyn std::error::Error>> {
    let pretty = args.pretty;
    let client = reqwest::Client::new();
    let response = client
        .get(format!("{}/v1/tail", args.base_url.trim_end_matches('/')))
        .query(&QueryParams {
            device_id: args.device_id,
            platform: args.platform,
            level: args.level,
            subsystem: args.subsystem,
            session_id: args.session_id,
            thread_id: args.thread_id,
            request_id: args.request_id,
            start_ms: args.start_ms,
            end_ms: args.end_ms,
            limit: Some(args.limit),
        })
        .send()
        .await?;
    let mut response = response;
    let mut buf = String::new();
    while let Some(chunk) = response.chunk().await? {
        buf.push_str(&String::from_utf8_lossy(&chunk));
        while let Some(newline_pos) = buf.find('\n') {
            let line = buf[..newline_pos].to_string();
            buf.drain(..=newline_pos);
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            if !pretty {
                println!("{trimmed}");
                continue;
            }
            if let Ok(event) = serde_json::from_str::<StoredLogEvent>(trimmed) {
                let ts = chrono::Utc
                    .timestamp_millis_opt(event.timestamp_ms)
                    .single()
                    .map(|t| t.format("%H:%M:%S%.3f").to_string())
                    .unwrap_or_else(|| event.timestamp_ms.to_string());
                let level_color = match event.level.as_str() {
                    "ERROR" => "\x1b[31m",
                    "WARN" => "\x1b[33m",
                    "INFO" => "\x1b[32m",
                    "DEBUG" => "\x1b[36m",
                    "TRACE" => "\x1b[90m",
                    _ => "\x1b[0m",
                };
                let reset = "\x1b[0m";
                let dim = "\x1b[90m";
                let sub = event
                    .subsystem
                    .rsplit("::")
                    .next()
                    .unwrap_or(&event.subsystem);
                print!(
                    "{dim}{ts}{reset} {level_color}{:<5}{reset} {dim}{}{reset} {}",
                    event.level, sub, event.message
                );
                if let Some(ref fields) = event.fields_json {
                    if fields != "null" && !fields.is_empty() {
                        print!(" {dim}{fields}{reset}");
                    }
                }
                println!();
            } else {
                println!("{trimmed}");
            }
        }
    }
    Ok(())
}

fn internal_error(err: serde_json::Error) -> ApiError {
    ApiError(
        StatusCode::INTERNAL_SERVER_ERROR,
        format!("serialization error: {err}"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::Compression;
    use flate2::write::GzEncoder;
    use std::io::Write;
    use std::net::Ipv4Addr;
    use std::sync::{Arc, Mutex};

    fn encode_events(events: &[StoredLogEvent]) -> Vec<u8> {
        let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
        for event in events {
            serde_json::to_writer(&mut encoder, event).expect("encode event");
            encoder.write_all(b"\n").expect("newline");
        }
        encoder.finish().expect("finish")
    }

    #[test]
    fn decode_batch_round_trips() {
        let event = StoredLogEvent {
            timestamp_ms: 123,
            level: "INFO".into(),
            source: "ios".into(),
            platform: "ios".into(),
            subsystem: "test".into(),
            category: "roundtrip".into(),
            message: "hello".into(),
            session_id: None,
            server_id: None,
            thread_id: None,
            request_id: None,
            payload_json: None,
            fields_json: None,
            device_id: "device-1".into(),
            device_name: "phone".into(),
            app_version: Some("1.0".into()),
            build: Some("1".into()),
            process_id: 7,
        };

        let decoded = decode_batch(&encode_events(&[event.clone()])).expect("decode");
        assert_eq!(decoded, vec![event]);
    }

    #[test]
    fn private_ip_detection_accepts_lan_and_loopback() {
        assert!(is_private(IpAddr::V4(Ipv4Addr::LOCALHOST)));
        assert!(is_private(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 8))));
        assert!(!is_private(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8))));
    }

    #[test]
    fn local_tail_ui_url_prefers_loopback_for_unspecified_bindings() {
        let ipv4 = local_tail_ui_url(SocketAddr::from(([0, 0, 0, 0], 8585)));
        let ipv6 = local_tail_ui_url(SocketAddr::from(([0, 0, 0, 0, 0, 0, 0, 0], 8585)));

        assert_eq!(ipv4, "http://127.0.0.1:8585/tail");
        assert_eq!(ipv6, "http://[::1]:8585/tail");
    }

    #[test]
    fn query_events_accepts_missing_optional_filters() {
        let temp_dir =
            std::env::temp_dir().join(format!("mobile-log-collector-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&temp_dir).expect("create temp dir");
        let db_path = temp_dir.join("collector.sqlite3");
        let connection = Connection::open(&db_path).expect("open db");
        init_db(&connection).expect("init db");

        let batch_path = temp_dir.join("batch.ndjson.gz");
        let event = StoredLogEvent {
            timestamp_ms: 456,
            level: "INFO".into(),
            source: "android".into(),
            platform: "android".into(),
            subsystem: "test".into(),
            category: "query".into(),
            message: "collector query regression".into(),
            session_id: None,
            server_id: None,
            thread_id: None,
            request_id: None,
            payload_json: None,
            fields_json: None,
            device_id: "device-2".into(),
            device_name: "emulator".into(),
            app_version: Some("0.1.0".into()),
            build: Some("5".into()),
            process_id: 42,
        };
        std::fs::write(&batch_path, encode_events(std::slice::from_ref(&event)))
            .expect("write batch");
        connection
            .execute(
                "INSERT INTO batches (batch_id, device_id, platform, app_version, first_ts, last_ts, event_count, path, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    "batch-1",
                    event.device_id,
                    event.platform,
                    event.app_version,
                    event.timestamp_ms,
                    event.timestamp_ms,
                    1,
                    batch_path.to_string_lossy().to_string(),
                    event.timestamp_ms,
                ],
            )
            .expect("insert batch");

        let (live_tx, _) = broadcast::channel(8);
        let state = AppState {
            inner: Arc::new(AppStateInner {
                private_only: false,
                data_dir: temp_dir.clone(),
                db: Mutex::new(connection),
                live_tx,
            }),
        };

        let rows = query_events(
            &state,
            &QueryParams {
                device_id: None,
                platform: None,
                level: None,
                subsystem: None,
                session_id: None,
                thread_id: None,
                request_id: None,
                start_ms: None,
                end_ms: None,
                limit: Some(10),
            },
        )
        .expect("query without filters");

        assert_eq!(rows, vec![event]);

        std::fs::remove_dir_all(temp_dir).expect("cleanup temp dir");
    }
}
