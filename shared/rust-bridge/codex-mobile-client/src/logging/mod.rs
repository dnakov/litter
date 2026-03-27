use std::collections::BTreeMap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use arc_swap::ArcSwap;
use flate2::Compression;
use flate2::write::GzEncoder;
use mobile_log_shared::StoredLogEvent;
use reqwest::header::{CONTENT_ENCODING, CONTENT_TYPE, HeaderMap, HeaderValue};
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, Notify, mpsc, oneshot};
use tracing::Subscriber;
use tracing_subscriber::Layer;
use tracing_subscriber::layer::Context;
use tracing_subscriber::prelude::*;
use tracing_subscriber::registry::LookupSpan;
use uuid::Uuid;

use crate::ffi::shared::shared_runtime;

const DEFAULT_QUEUE_CAPACITY: usize = 4_096;
const DEFAULT_MAX_BATCH_BYTES: usize = 256 * 1024;
const DEFAULT_MAX_PENDING_BYTES: u64 = 256 * 1024 * 1024;
const DEFAULT_ROLL_INTERVAL: Duration = Duration::from_secs(1);
const DEFAULT_MAX_BACKOFF: Duration = Duration::from_secs(60);

static SHARED_LOG_PIPELINE: OnceLock<Arc<LogPipeline>> = OnceLock::new();
static TRACING_SUBSCRIBER_INSTALLED: OnceLock<()> = OnceLock::new();

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum LogLevelName {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

impl LogLevelName {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Trace => "TRACE",
            Self::Debug => "DEBUG",
            Self::Info => "INFO",
            Self::Warn => "WARN",
            Self::Error => "ERROR",
        }
    }

    fn from_str(value: &str) -> Self {
        match value.trim().to_ascii_uppercase().as_str() {
            "TRACE" => Self::Trace,
            "DEBUG" => Self::Debug,
            "WARN" | "WARNING" => Self::Warn,
            "ERROR" => Self::Error,
            _ => Self::Info,
        }
    }
}

#[derive(Debug, Clone)]
pub struct LogInput {
    pub timestamp_ms: Option<i64>,
    pub level: LogLevelName,
    pub source: String,
    pub subsystem: String,
    pub category: String,
    pub message: String,
    pub session_id: Option<String>,
    pub server_id: Option<String>,
    pub thread_id: Option<String>,
    pub request_id: Option<String>,
    pub payload_json: Option<String>,
    pub fields_json: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PersistedLogConfig {
    pub enabled: bool,
    pub collector_url: Option<String>,
    pub min_level: LogLevelName,
    pub device_id: String,
    pub device_name: Option<String>,
    pub app_version: Option<String>,
    pub build: Option<String>,
}

impl Default for PersistedLogConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            collector_url: None,
            min_level: LogLevelName::Info,
            device_id: Uuid::new_v4().to_string(),
            device_name: None,
            app_version: None,
            build: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct LogPipelineOptions {
    pub queue_capacity: usize,
    pub max_batch_bytes: usize,
    pub max_pending_bytes: u64,
    pub roll_interval: Duration,
    pub spawn_background_tasks: bool,
    pub install_tracing_subscriber: bool,
}

impl Default for LogPipelineOptions {
    fn default() -> Self {
        Self {
            queue_capacity: DEFAULT_QUEUE_CAPACITY,
            max_batch_bytes: DEFAULT_MAX_BATCH_BYTES,
            max_pending_bytes: DEFAULT_MAX_PENDING_BYTES,
            roll_interval: DEFAULT_ROLL_INTERVAL,
            spawn_background_tasks: true,
            install_tracing_subscriber: true,
        }
    }
}

enum QueueItem {
    Event(StoredLogEvent),
    Flush(oneshot::Sender<()>),
}

#[derive(Default)]
struct BatchBuffer {
    items: Vec<StoredLogEvent>,
    raw_bytes: usize,
}

impl BatchBuffer {
    fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    fn push(&mut self, event: StoredLogEvent) -> Result<(), serde_json::Error> {
        let encoded = serde_json::to_vec(&event)?;
        self.raw_bytes += encoded.len() + 1;
        self.items.push(event);
        Ok(())
    }

    fn should_roll(&self, max_batch_bytes: usize) -> bool {
        self.raw_bytes >= max_batch_bytes
    }

    fn take(&mut self) -> Self {
        let mut next = Self::default();
        std::mem::swap(self, &mut next);
        next
    }
}

struct TracingLogLayer {
    pipeline: Arc<LogPipeline>,
}

impl<S> Layer<S> for TracingLogLayer
where
    S: Subscriber + for<'span> LookupSpan<'span>,
{
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        let metadata = event.metadata();
        let target = metadata.target();
        if !target.starts_with("codex")
            && !target.starts_with("app_server")
            && !target.starts_with("rpc")
            && !target.starts_with("store")
        {
            return;
        }

        let mut visitor = FieldVisitor::default();
        event.record(&mut visitor);
        let request_id = visitor
            .remove("request_id")
            .or_else(|| visitor.remove("rpc.request_id"))
            .or_else(|| visitor.remove("rpc_request_id"));
        let message = visitor
            .remove("message")
            .unwrap_or_else(|| metadata.name().to_string());
        let fields_json = if visitor.fields.is_empty() {
            None
        } else {
            serde_json::to_string(&visitor.fields).ok()
        };

        self.pipeline.log(LogInput {
            timestamp_ms: None,
            level: LogLevelName::from_str(metadata.level().as_str()),
            source: "rust".to_string(),
            subsystem: target.to_string(),
            category: metadata.name().to_string(),
            message,
            session_id: None,
            server_id: None,
            thread_id: None,
            request_id,
            payload_json: None,
            fields_json,
        });
    }
}

#[derive(Default)]
struct FieldVisitor {
    fields: BTreeMap<String, String>,
}

impl FieldVisitor {
    fn remove(&mut self, key: &str) -> Option<String> {
        self.fields.remove(key)
    }
}

impl tracing::field::Visit for FieldVisitor {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        self.fields
            .insert(field.name().to_string(), format!("{value:?}"));
    }

    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        self.fields
            .insert(field.name().to_string(), value.to_string());
    }

    fn record_i64(&mut self, field: &tracing::field::Field, value: i64) {
        self.fields
            .insert(field.name().to_string(), value.to_string());
    }

    fn record_u64(&mut self, field: &tracing::field::Field, value: u64) {
        self.fields
            .insert(field.name().to_string(), value.to_string());
    }

    fn record_bool(&mut self, field: &tracing::field::Field, value: bool) {
        self.fields
            .insert(field.name().to_string(), value.to_string());
    }
}

pub struct LogPipeline {
    options: LogPipelineOptions,
    queue: mpsc::Sender<QueueItem>,
    config: ArcSwap<PersistedLogConfig>,
    config_path: PathBuf,
    pending_dir: PathBuf,
    upload_notify: Notify,
    upload_lock: Mutex<()>,
    dropped_events: AtomicU64,
    http: reqwest::Client,
}

impl LogPipeline {
    fn bootstrap(base_dir: PathBuf, options: LogPipelineOptions) -> Arc<Self> {
        let rt = shared_runtime();
        let spool_dir = base_dir.join("log-spool");
        let pending_dir = spool_dir.join("pending");
        let config_path = spool_dir.join("config.json");
        let _ = std::fs::create_dir_all(&pending_dir);
        let config = load_config(&config_path);

        // Debug: write spool init state to a file so we can verify bootstrap ran
        let debug_path = spool_dir.join("_debug_init.txt");
        let _ = std::fs::write(
            &debug_path,
            format!(
                "bootstrap at {}\nbase_dir={}\nconfig_path={}\nenabled={}\ncollector_url={:?}\ndevice_id={}\n",
                now_ms(),
                base_dir.display(),
                config_path.display(),
                config.enabled,
                config.collector_url,
                config.device_id,
            ),
        );

        let (tx, rx) = mpsc::channel(options.queue_capacity);

        let pipeline = Arc::new(Self {
            options: options.clone(),
            queue: tx,
            config: ArcSwap::from_pointee(config),
            config_path,
            pending_dir,
            upload_notify: Notify::new(),
            upload_lock: Mutex::new(()),
            dropped_events: AtomicU64::new(0),
            http: reqwest::Client::new(),
        });

        if options.spawn_background_tasks {
            let writer = Arc::clone(&pipeline);
            rt.spawn(async move {
                writer.run_writer(rx).await;
            });

            let uploader = Arc::clone(&pipeline);
            rt.spawn(async move {
                uploader.run_uploader().await;
            });

            // Periodically re-read config from disk so external edits are picked up
            let config_reloader = Arc::clone(&pipeline);
            let debug_spool_dir = spool_dir.clone();
            rt.spawn(async move {
                let mut tick = 0u64;
                loop {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    tick += 1;
                    let fresh = load_config(&config_reloader.config_path);
                    let current = config_reloader.config.load_full();

                    // Debug: write reload state every tick
                    let _ = std::fs::write(
                        debug_spool_dir.join("_debug_reload.txt"),
                        format!(
                            "tick={}\nconfig_path={}\nfresh.enabled={}\ncurrent.enabled={}\nfresh.collector_url={:?}\nfresh.device_id={}\n",
                            tick,
                            config_reloader.config_path.display(),
                            fresh.enabled,
                            current.enabled,
                            fresh.collector_url,
                            fresh.device_id,
                        ),
                    );

                    if fresh.enabled != current.enabled
                        || fresh.collector_url != current.collector_url
                        || fresh.min_level != current.min_level
                        || fresh.device_id != current.device_id
                    {
                        config_reloader.config.store(Arc::new(fresh));
                        config_reloader.upload_notify.notify_waiters();
                    }
                }
            });
        }

        if options.install_tracing_subscriber {
            install_tracing_subscriber(Arc::clone(&pipeline));
        }

        pipeline
    }

    pub fn shared() -> Arc<Self> {
        SHARED_LOG_PIPELINE
            .get_or_init(|| Self::bootstrap(resolve_codex_home(), LogPipelineOptions::default()))
            .clone()
    }

    #[cfg(test)]
    fn new_for_tests(base_dir: PathBuf, options: LogPipelineOptions) -> Arc<Self> {
        Self::bootstrap(base_dir, options)
    }

    pub fn config_snapshot(&self) -> PersistedLogConfig {
        (*self.config.load_full()).clone()
    }

    pub fn configure(&self, mut next: PersistedLogConfig) {
        let current = self.config_snapshot();
        if next.device_id.trim().is_empty() {
            next.device_id = current.device_id;
        }
        if next.device_name.as_deref().is_none_or(str::is_empty) {
            next.device_name = current.device_name;
        }
        if next.app_version.as_deref().is_none_or(str::is_empty) {
            next.app_version = current.app_version;
        }
        if next.build.as_deref().is_none_or(str::is_empty) {
            next.build = current.build;
        }

        next.collector_url = clean_opt(next.collector_url);
        next.device_name = clean_opt(next.device_name);
        next.app_version = clean_opt(next.app_version);
        next.build = clean_opt(next.build);

        // Env vars override
        if let Ok(url) = std::env::var("LOG_COLLECTOR_URL") {
            if !url.is_empty() {
                next.collector_url = Some(url);
            }
        }
        if next.collector_url.is_some() {
            next.enabled = true;
        }

        if let Ok(json) = serde_json::to_vec_pretty(&next) {
            let _ = std::fs::write(&self.config_path, json);
        }
        self.config.store(Arc::new(next));
        self.upload_notify.notify_waiters();
    }

    pub fn log(&self, input: LogInput) {
        let config = self.config.load_full();

        // Debug: write to file so we can verify log() is actually being called
        let debug_path = self
            .pending_dir
            .parent()
            .map(|p| p.join("_debug_log_calls.txt"));
        if let Some(ref path) = debug_path {
            use std::io::Write;
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
            {
                let _ = writeln!(
                    f,
                    "log() called: enabled={} level={:?} min={:?} msg={}",
                    config.enabled,
                    input.level,
                    config.min_level,
                    &input.message[..input.message.len().min(80)]
                );
            }
        }

        if !config.enabled || input.level < config.min_level {
            return;
        }

        let event = normalize_event(&input, &config);
        if self.queue.try_send(QueueItem::Event(event)).is_err() {
            self.dropped_events.fetch_add(1, Ordering::Relaxed);
            return;
        }

        let dropped = self.dropped_events.swap(0, Ordering::Relaxed);
        if dropped > 0 {
            let summary = synthetic_event(
                LogLevelName::Warn,
                "logging",
                "backpressure",
                format!("dropped {dropped} log event(s) while queue was full"),
                Some(serde_json::json!({ "dropped": dropped }).to_string()),
                &config,
            );
            if self.queue.try_send(QueueItem::Event(summary)).is_err() {
                self.dropped_events.fetch_add(dropped, Ordering::Relaxed);
            }
        }
    }

    pub async fn flush(&self) {
        let (tx, rx) = oneshot::channel();
        let _ = self.queue.send(QueueItem::Flush(tx)).await;
        let _ = rx.await;
        let _guard = self.upload_lock.lock().await;
        let _ = self.process_pending_uploads().await;
    }

    async fn run_writer(self: Arc<Self>, mut rx: mpsc::Receiver<QueueItem>) {
        // Debug: confirm writer task started
        if let Some(spool) = self.pending_dir.parent() {
            let _ = std::fs::write(
                spool.join("_debug_writer_started.txt"),
                format!("writer started at {}\n", now_ms()),
            );
        }
        let mut batch = BatchBuffer::default();
        let mut recv_count: u64 = 0;
        loop {
            let maybe_item = if batch.is_empty() {
                rx.recv().await
            } else {
                match tokio::time::timeout(self.options.roll_interval, rx.recv()).await {
                    Ok(item) => item,
                    Err(_) => {
                        let batch_len = batch.items.len();
                        if let Some(spool) = self.pending_dir.parent() {
                            let _ = std::fs::write(
                                spool.join("_debug_writer_roll.txt"),
                                format!(
                                    "roll timeout fired at {} recv_count={} batch_items={}\n",
                                    now_ms(),
                                    recv_count,
                                    batch_len
                                ),
                            );
                        }
                        let result = self.persist_batch(batch.take()).await;
                        if let Some(spool) = self.pending_dir.parent() {
                            let _ = std::fs::write(
                                spool.join("_debug_persist_result.txt"),
                                format!(
                                    "persist_batch result: {:?} items={}\npending_dir={}\n",
                                    result,
                                    batch_len,
                                    self.pending_dir.display()
                                ),
                            );
                        }
                        continue;
                    }
                }
            };

            let Some(item) = maybe_item else {
                if !batch.is_empty() {
                    let _ = self.persist_batch(batch.take()).await;
                }
                break;
            };

            match item {
                QueueItem::Event(event) => {
                    recv_count += 1;
                    if recv_count <= 3 {
                        if let Some(spool) = self.pending_dir.parent() {
                            use std::io::Write;
                            if let Ok(mut f) = std::fs::OpenOptions::new()
                                .create(true)
                                .append(true)
                                .open(spool.join("_debug_writer_recv.txt"))
                            {
                                let _ = writeln!(
                                    f,
                                    "recv #{} msg={}",
                                    recv_count,
                                    &event.message[..event.message.len().min(60)]
                                );
                            }
                        }
                    }
                    if batch.push(event).is_err() {
                        continue;
                    }
                    if batch.should_roll(self.options.max_batch_bytes) {
                        let _ = self.persist_batch(batch.take()).await;
                    }
                }
                QueueItem::Flush(done) => {
                    if !batch.is_empty() {
                        let _ = self.persist_batch(batch.take()).await;
                    }
                    let _ = done.send(());
                }
            }
        }
    }

    async fn persist_batch(&self, batch: BatchBuffer) -> std::io::Result<()> {
        if batch.items.is_empty() {
            return Ok(());
        }

        let pending_dir = self.pending_dir.clone();
        let batch_id = format!("{}-{}", now_ms(), Uuid::new_v4());
        let path = pending_dir.join(format!("{batch_id}.ndjson.gz"));
        let temp_path = pending_dir.join(format!("{batch_id}.tmp"));

        tokio::task::spawn_blocking(move || -> std::io::Result<()> {
            let file = File::create(&temp_path)?;
            let writer = BufWriter::new(file);
            let mut encoder = GzEncoder::new(writer, Compression::default());
            for item in &batch.items {
                serde_json::to_writer(&mut encoder, item).map_err(std::io::Error::other)?;
                encoder.write_all(b"\n")?;
            }
            let writer = encoder.finish()?;
            writer.into_inner()?.sync_all()?;
            std::fs::rename(temp_path, path)?;
            Ok(())
        })
        .await
        .map_err(|err| std::io::Error::other(format!("batch writer join error: {err}")))??;

        let deleted = prune_pending_dir(self.pending_dir.clone(), self.options.max_pending_bytes)
            .await
            .unwrap_or(0);
        if deleted > 0 {
            self.log(LogInput {
                timestamp_ms: None,
                level: LogLevelName::Warn,
                source: "rust".to_string(),
                subsystem: "logging".to_string(),
                category: "spool".to_string(),
                message: format!(
                    "deleted {deleted} bytes from pending spool after exceeding disk cap"
                ),
                session_id: None,
                server_id: None,
                thread_id: None,
                request_id: None,
                payload_json: None,
                fields_json: Some(serde_json::json!({ "deleted_bytes": deleted }).to_string()),
            });
        }

        self.upload_notify.notify_waiters();
        Ok(())
    }

    async fn run_uploader(self: Arc<Self>) {
        let mut attempts = 0u32;

        loop {
            let _guard = self.upload_lock.lock().await;
            let result = self.process_pending_uploads().await;
            drop(_guard);

            match result {
                Ok(processed) if processed > 0 => {
                    self.write_upload_status("success", format!("processed={processed}"));
                    attempts = 0;
                    continue;
                }
                Ok(_) => {
                    let config = self.config.load_full();
                    let detail = if !config.enabled {
                        ("disabled", "logging disabled".to_string())
                    } else if config.collector_url.is_none() {
                        ("disabled", "collector_url missing".to_string())
                    } else {
                        ("idle", "no pending uploads".to_string())
                    };
                    self.write_upload_status(detail.0, detail.1);
                    attempts = 0;
                    self.upload_notify.notified().await;
                }
                Err(err) => {
                    self.write_upload_status("error", err);
                    attempts = attempts.saturating_add(1);
                    let backoff = backoff_delay(attempts);
                    tokio::select! {
                        _ = self.upload_notify.notified() => {}
                        _ = tokio::time::sleep(backoff) => {}
                    }
                }
            }
        }
    }

    async fn process_pending_uploads(&self) -> Result<usize, String> {
        let config = self.config.load_full();
        if !config.enabled {
            return Ok(0);
        }
        let Some(base_url) = config.collector_url.as_ref() else {
            return Ok(0);
        };

        let files = pending_batch_paths(&self.pending_dir)
            .await
            .map_err(|e| e.to_string())?;
        if files.is_empty() {
            return Ok(0);
        }

        let mut processed = 0usize;
        for path in files {
            upload_file(&self.http, &path, base_url, &config.device_id).await?;
            processed += 1;
        }

        Ok(processed)
    }

    fn write_upload_status(&self, state: &str, detail: String) {
        let Some(spool_dir) = self.pending_dir.parent() else {
            return;
        };
        let config = self.config.load_full();
        let pending_count = std::fs::read_dir(&self.pending_dir)
            .ok()
            .map(|entries| entries.filter_map(Result::ok).count())
            .unwrap_or_default();
        let _ = std::fs::write(
            spool_dir.join("_debug_upload_status.txt"),
            format!(
                "timestamp_ms={}\nstate={}\ndetail={}\ncollector_url={}\ndevice_id={}\npending_count={}\n",
                now_ms(),
                state,
                detail,
                config.collector_url.as_deref().unwrap_or("<none>"),
                config.device_id,
                pending_count,
            ),
        );
    }
}

pub(crate) fn log_rust(
    level: LogLevelName,
    subsystem: impl Into<String>,
    category: impl Into<String>,
    message: impl Into<String>,
    fields_json: Option<String>,
) {
    LogPipeline::shared().log(LogInput {
        timestamp_ms: None,
        level,
        source: "rust".to_string(),
        subsystem: subsystem.into(),
        category: category.into(),
        message: message.into(),
        session_id: None,
        server_id: None,
        thread_id: None,
        request_id: None,
        payload_json: None,
        fields_json,
    });
}

fn install_tracing_subscriber(pipeline: Arc<LogPipeline>) {
    TRACING_SUBSCRIBER_INSTALLED.get_or_init(|| {
        let subscriber = tracing_subscriber::registry().with(TracingLogLayer { pipeline });
        let _ = tracing::subscriber::set_global_default(subscriber);
    });
}

fn normalize_event(input: &LogInput, config: &PersistedLogConfig) -> StoredLogEvent {
    StoredLogEvent {
        timestamp_ms: input.timestamp_ms.unwrap_or_else(now_ms),
        level: input.level.as_str().to_string(),
        source: clean_non_empty(&input.source).unwrap_or_else(|| "rust".to_string()),
        platform: platform_name().to_string(),
        subsystem: clean_non_empty(&input.subsystem).unwrap_or_else(|| "app".to_string()),
        category: clean_non_empty(&input.category).unwrap_or_else(|| "default".to_string()),
        message: input.message.trim().to_string(),
        session_id: clean_opt(input.session_id.clone()),
        server_id: clean_opt(input.server_id.clone()),
        thread_id: clean_opt(input.thread_id.clone()),
        request_id: clean_opt(input.request_id.clone()),
        payload_json: clean_opt(input.payload_json.clone()),
        fields_json: clean_opt(input.fields_json.clone()),
        device_id: config.device_id.clone(),
        device_name: config
            .device_name
            .clone()
            .or_else(default_device_name)
            .unwrap_or_else(|| platform_name().to_string()),
        app_version: config.app_version.clone(),
        build: config.build.clone(),
        process_id: std::process::id(),
    }
}

fn synthetic_event(
    level: LogLevelName,
    subsystem: impl Into<String>,
    category: impl Into<String>,
    message: impl Into<String>,
    fields_json: Option<String>,
    config: &PersistedLogConfig,
) -> StoredLogEvent {
    normalize_event(
        &LogInput {
            timestamp_ms: None,
            level,
            source: "rust".to_string(),
            subsystem: subsystem.into(),
            category: category.into(),
            message: message.into(),
            session_id: None,
            server_id: None,
            thread_id: None,
            request_id: None,
            payload_json: None,
            fields_json,
        },
        config,
    )
}

fn load_config(path: &Path) -> PersistedLogConfig {
    let mut config: PersistedLogConfig = std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();

    // Env vars override file-based config
    if let Ok(url) = std::env::var("LOG_COLLECTOR_URL") {
        if !url.is_empty() {
            config.collector_url = Some(url);
        }
    }
    if config.collector_url.is_some() {
        config.enabled = true;
    }

    config
}

async fn pending_batch_paths(pending_dir: &Path) -> std::io::Result<Vec<PathBuf>> {
    let pending_dir = pending_dir.to_path_buf();
    tokio::task::spawn_blocking(move || -> std::io::Result<Vec<PathBuf>> {
        let mut entries: Vec<PathBuf> = std::fs::read_dir(&pending_dir)?
            .filter_map(|entry| entry.ok().map(|entry| entry.path()))
            .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("gz"))
            .collect();
        entries.sort();
        Ok(entries)
    })
    .await
    .map_err(|err| std::io::Error::other(format!("pending dir join error: {err}")))?
}

async fn prune_pending_dir(pending_dir: PathBuf, max_pending_bytes: u64) -> std::io::Result<u64> {
    tokio::task::spawn_blocking(move || -> std::io::Result<u64> {
        let mut entries = Vec::new();
        let mut total_size = 0u64;
        for entry in std::fs::read_dir(&pending_dir)? {
            let path = entry?.path();
            let metadata = std::fs::metadata(&path)?;
            if !metadata.is_file() {
                continue;
            }
            total_size += metadata.len();
            entries.push((
                path,
                metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH),
                metadata.len(),
            ));
        }

        if total_size <= max_pending_bytes {
            return Ok(0);
        }

        entries.sort_by_key(|(_, modified, _)| *modified);
        let mut deleted = 0u64;
        for (path, _, len) in entries {
            if total_size <= max_pending_bytes {
                break;
            }
            if std::fs::remove_file(&path).is_ok() {
                total_size = total_size.saturating_sub(len);
                deleted += len;
            }
        }
        Ok(deleted)
    })
    .await
    .map_err(|err| std::io::Error::other(format!("spool prune join error: {err}")))?
}

async fn upload_file(
    http: &reqwest::Client,
    path: &Path,
    base_url: &str,
    device_id: &str,
) -> Result<(), String> {
    let batch_id = path
        .file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.trim_end_matches(".ndjson.gz").to_string())
        .ok_or_else(|| format!("invalid batch file name: {}", path.display()))?;
    let body = tokio::fs::read(path)
        .await
        .map_err(|err| format!("failed to read {}: {err}", path.display()))?;

    let mut headers = HeaderMap::new();
    headers.insert("X-Batch-Id", header_value(&batch_id)?);
    headers.insert("X-Device-Id", header_value(device_id)?);
    headers.insert(
        CONTENT_TYPE,
        HeaderValue::from_static("application/x-ndjson"),
    );
    headers.insert(CONTENT_ENCODING, HeaderValue::from_static("gzip"));

    let url = format!("{}/v1/logs", base_url.trim_end_matches('/'));
    let response = http
        .post(url)
        .headers(headers)
        .body(body)
        .send()
        .await
        .map_err(|err| format!("upload failed for {batch_id}: {err}"))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response
            .text()
            .await
            .unwrap_or_else(|_| "<failed to read response body>".to_string());
        return Err(format!(
            "collector rejected {batch_id} with status {status}: {body}",
        ));
    }

    tokio::fs::remove_file(path)
        .await
        .map_err(|err| format!("failed to remove uploaded batch {}: {err}", path.display()))?;
    Ok(())
}

fn header_value(value: &str) -> Result<HeaderValue, String> {
    HeaderValue::from_str(value).map_err(|err| format!("invalid header value: {err}"))
}

fn backoff_delay(attempt: u32) -> Duration {
    let capped = attempt.min(6);
    let base = 1u64 << capped;
    let jitter = (attempt as u64 * 137) % 700;
    Duration::from_secs(base)
        .saturating_add(Duration::from_millis(jitter))
        .min(DEFAULT_MAX_BACKOFF)
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or_default()
}

fn clean_opt(value: Option<String>) -> Option<String> {
    value.as_deref().and_then(clean_non_empty)
}

fn clean_non_empty(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn resolve_codex_home() -> PathBuf {
    let mut candidates = Vec::new();

    if let Ok(existing) = std::env::var("CODEX_HOME")
        && !existing.is_empty()
    {
        candidates.push(PathBuf::from(existing));
    }

    if let Ok(home) = std::env::var("HOME")
        && !home.is_empty()
    {
        #[cfg(target_os = "ios")]
        {
            candidates.push(
                PathBuf::from(&home)
                    .join("Library")
                    .join("Application Support")
                    .join("codex"),
            );
        }

        candidates.push(PathBuf::from(home).join(".codex"));
    }

    if let Ok(tmpdir) = std::env::var("TMPDIR")
        && !tmpdir.is_empty()
    {
        candidates.push(PathBuf::from(tmpdir).join("codex-home"));
    }

    for candidate in candidates {
        if std::fs::create_dir_all(&candidate).is_ok() {
            unsafe {
                std::env::set_var("CODEX_HOME", &candidate);
            }
            return candidate;
        }
    }

    let fallback = std::env::temp_dir().join("codex-home");
    let _ = std::fs::create_dir_all(&fallback);
    unsafe {
        std::env::set_var("CODEX_HOME", &fallback);
    }
    fallback
}

fn platform_name() -> &'static str {
    #[cfg(target_os = "ios")]
    {
        return "ios";
    }
    #[cfg(target_os = "android")]
    {
        return "android";
    }
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    {
        "host"
    }
}

fn default_device_name() -> Option<String> {
    clean_opt(std::env::var("HOSTNAME").ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("codex-mobile-log-test-{name}-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&path).expect("temp dir");
        path
    }

    #[tokio::test(flavor = "current_thread")]
    async fn flush_writes_gzipped_ndjson_batch() {
        let base_dir = temp_dir("flush");
        let pipeline = LogPipeline::new_for_tests(
            base_dir.clone(),
            LogPipelineOptions {
                spawn_background_tasks: true,
                install_tracing_subscriber: false,
                ..LogPipelineOptions::default()
            },
        );
        pipeline.configure(PersistedLogConfig {
            enabled: true,
            collector_url: None,
            min_level: LogLevelName::Debug,
            device_id: "device-1".into(),
            device_name: Some("test-device".into()),
            app_version: Some("1.0".into()),
            build: Some("42".into()),
        });

        pipeline.log(LogInput {
            timestamp_ms: Some(123),
            level: LogLevelName::Info,
            source: "ios".into(),
            subsystem: "test".into(),
            category: "flush".into(),
            message: "hello".into(),
            session_id: None,
            server_id: None,
            thread_id: None,
            request_id: None,
            payload_json: Some("{\"ok\":true}".into()),
            fields_json: None,
        });
        pipeline.flush().await;

        let files = pending_batch_paths(&base_dir.join("log-spool").join("pending"))
            .await
            .expect("pending files");
        assert_eq!(files.len(), 1);
    }

    #[test]
    fn normalize_event_attaches_metadata() {
        let config = PersistedLogConfig {
            enabled: true,
            collector_url: None,
            min_level: LogLevelName::Trace,
            device_id: "device-1".into(),
            device_name: Some("phone".into()),
            app_version: Some("1.0".into()),
            build: Some("7".into()),
        };
        let event = normalize_event(
            &LogInput {
                timestamp_ms: Some(55),
                level: LogLevelName::Error,
                source: "android".into(),
                subsystem: "voice".into(),
                category: "".into(),
                message: "boom".into(),
                session_id: None,
                server_id: None,
                thread_id: None,
                request_id: None,
                payload_json: None,
                fields_json: None,
            },
            &config,
        );

        assert_eq!(event.device_id, "device-1");
        assert_eq!(event.device_name, "phone");
        assert_eq!(event.level, "ERROR");
        assert_eq!(event.category, "default");
    }
}
