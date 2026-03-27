use std::sync::Arc;

use crate::logging::{LogInput, LogLevelName, LogPipeline, PersistedLogConfig};

#[derive(uniffi::Enum, Clone, Copy)]
pub enum LogLevel {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

#[derive(uniffi::Enum, Clone, Copy)]
pub enum LogSource {
    Rust,
    Ios,
    Android,
}

#[derive(uniffi::Record, Clone)]
pub struct LogEvent {
    pub timestamp_ms: Option<i64>,
    pub level: LogLevel,
    pub source: LogSource,
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

#[derive(uniffi::Record, Clone)]
pub struct LogConfig {
    pub enabled: bool,
    pub collector_url: Option<String>,
    pub min_level: LogLevel,
    pub device_id: Option<String>,
    pub device_name: Option<String>,
    pub app_version: Option<String>,
    pub build: Option<String>,
}

#[derive(uniffi::Object)]
pub struct Logs {
    inner: Arc<LogPipeline>,
}

#[uniffi::export(async_runtime = "tokio")]
impl Logs {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: LogPipeline::shared(),
        }
    }

    pub fn log(&self, event: LogEvent) {
        self.inner.log(event.into());
    }

    pub fn configure(&self, config: LogConfig) {
        let current = self.inner.config_snapshot();
        self.inner.configure(PersistedLogConfig {
            enabled: config.enabled,
            collector_url: config.collector_url,
            min_level: config.min_level.into(),
            device_id: config.device_id.unwrap_or(current.device_id),
            device_name: config.device_name,
            app_version: config.app_version,
            build: config.build,
        });
    }

    pub async fn flush(&self) {
        self.inner.flush().await;
    }
}

impl From<LogLevel> for LogLevelName {
    fn from(value: LogLevel) -> Self {
        match value {
            LogLevel::Trace => Self::Trace,
            LogLevel::Debug => Self::Debug,
            LogLevel::Info => Self::Info,
            LogLevel::Warn => Self::Warn,
            LogLevel::Error => Self::Error,
        }
    }
}

impl From<LogEvent> for LogInput {
    fn from(value: LogEvent) -> Self {
        Self {
            timestamp_ms: value.timestamp_ms,
            level: value.level.into(),
            source: match value.source {
                LogSource::Rust => "rust".to_string(),
                LogSource::Ios => "ios".to_string(),
                LogSource::Android => "android".to_string(),
            },
            subsystem: value.subsystem,
            category: value.category,
            message: value.message,
            session_id: value.session_id,
            server_id: value.server_id,
            thread_id: value.thread_id,
            request_id: value.request_id,
            payload_json: value.payload_json,
            fields_json: value.fields_json,
        }
    }
}
