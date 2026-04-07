//! PiMonoSession — wraps transport + mapper into a session lifecycle.

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{broadcast, watch};

use crate::mapper::{MappedEvent, PiMonoEventMapper};
use crate::protocol::{
    PiCommand, PiImage, PiModel, PiSessionState, StreamingBehavior,
};
use crate::transport::{PiMonoTransport, TransportError};

const DEFAULT_RESPONSE_TIMEOUT: Duration = Duration::from_secs(30);

/// Connection health for a pi-mono session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PiConnectionHealth {
    Connected,
    Disconnected,
}

/// Configuration for creating a pi-mono session.
#[derive(Debug, Clone)]
pub struct PiSessionConfig {
    pub server_id: String,
    pub thread_id: String,
}

pub struct PiMonoSession {
    config: PiSessionConfig,
    transport: PiMonoTransport,
    mapper: Arc<PiMonoEventMapper>,
    health_tx: Arc<watch::Sender<PiConnectionHealth>>,
    health_rx: watch::Receiver<PiConnectionHealth>,
    mapped_event_tx: broadcast::Sender<MappedEvent>,
    _worker_handle: tokio::task::JoinHandle<()>,
}

impl PiMonoSession {
    /// Create a session from an already-launched transport.
    pub fn new(
        config: PiSessionConfig,
        transport: PiMonoTransport,
    ) -> Self {
        let mapper = Arc::new(PiMonoEventMapper::new(config.thread_id.clone()));
        let (health_tx, health_rx) = watch::channel(PiConnectionHealth::Connected);
        let health_tx = Arc::new(health_tx);
        let (mapped_event_tx, _) = broadcast::channel::<MappedEvent>(256);

        let worker_mapper = Arc::clone(&mapper);
        let worker_health_tx = Arc::clone(&health_tx);
        let worker_event_tx = mapped_event_tx.clone();
        let mut transport_rx = transport.subscribe();

        let worker_handle = tokio::spawn(async move {
            loop {
                match transport_rx.recv().await {
                    Ok(event) => {
                        let mapped = worker_mapper.map_event(&event);
                        for m in mapped {
                            let _ = worker_event_tx.send(m);
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        tracing::warn!(count = n, "pi-mono event reader lagged");
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        tracing::info!("pi-mono transport closed");
                        let _ = worker_health_tx.send(PiConnectionHealth::Disconnected);
                        break;
                    }
                }
            }
        });

        Self {
            config,
            transport,
            mapper,
            health_tx,
            health_rx,
            mapped_event_tx,
            _worker_handle: worker_handle,
        }
    }

    /// Subscribe to mapped events (ready for conversion to UiEvent).
    pub fn subscribe(&self) -> broadcast::Receiver<MappedEvent> {
        self.mapped_event_tx.subscribe()
    }

    /// Get a health watch receiver.
    pub fn health(&self) -> watch::Receiver<PiConnectionHealth> {
        self.health_rx.clone()
    }

    /// Get the session config.
    pub fn config(&self) -> &PiSessionConfig {
        &self.config
    }

    /// Get a reference to the mapper for message hydration.
    pub fn mapper(&self) -> &PiMonoEventMapper {
        &self.mapper
    }

    /// Shut down the session.
    pub async fn disconnect(&self) {
        self.transport.shutdown().await;
        let _ = self.health_tx.send(PiConnectionHealth::Disconnected);
    }

    // ── Pi-mono command methods ────────────────────────────────────────

    pub async fn send_prompt(
        &self,
        message: String,
        images: Vec<PiImage>,
        streaming_behavior: Option<StreamingBehavior>,
    ) -> Result<(), TransportError> {
        self.transport
            .send_command(&PiCommand::Prompt {
                message,
                images,
                streaming_behavior,
            })
            .await
    }

    pub async fn send_abort(&self) -> Result<(), TransportError> {
        self.transport.send_command(&PiCommand::Abort).await
    }

    pub async fn send_steer(&self, message: String) -> Result<(), TransportError> {
        self.transport
            .send_command(&PiCommand::Steer { message })
            .await
    }

    pub async fn send_follow_up(&self, message: String) -> Result<(), TransportError> {
        self.transport
            .send_command(&PiCommand::FollowUp { message })
            .await
    }

    pub async fn get_state(&self) -> Result<PiSessionState, TransportError> {
        let data = self
            .transport
            .send_command_with_response(&PiCommand::GetState, DEFAULT_RESPONSE_TIMEOUT)
            .await?;
        serde_json::from_value(data).map_err(|e| TransportError::Serialize(e))
    }

    pub async fn get_messages(&self) -> Result<Vec<serde_json::Value>, TransportError> {
        let data = self
            .transport
            .send_command_with_response(&PiCommand::GetMessages, DEFAULT_RESPONSE_TIMEOUT)
            .await?;
        match data {
            serde_json::Value::Array(arr) => Ok(arr),
            other => Ok(vec![other]),
        }
    }

    pub async fn get_available_models(&self) -> Result<Vec<PiModel>, TransportError> {
        let data = self
            .transport
            .send_command_with_response(
                &PiCommand::GetAvailableModels,
                DEFAULT_RESPONSE_TIMEOUT,
            )
            .await?;
        serde_json::from_value(data).map_err(|e| TransportError::Serialize(e))
    }

    pub async fn set_model(
        &self,
        provider: String,
        model_id: String,
    ) -> Result<(), TransportError> {
        self.transport
            .send_command(&PiCommand::SetModel { provider, model_id })
            .await
    }

    pub async fn set_thinking_level(&self, level: String) -> Result<(), TransportError> {
        self.transport
            .send_command(&PiCommand::SetThinkingLevel { level })
            .await
    }

    pub async fn respond_extension_ui(
        &self,
        id: String,
        value: Option<String>,
        confirmed: Option<bool>,
        cancelled: Option<bool>,
    ) -> Result<(), TransportError> {
        self.transport
            .send_command(&PiCommand::ExtensionUiResponse {
                id,
                value,
                confirmed,
                cancelled,
            })
            .await
    }

    pub async fn fork(&self, entry_id: String) -> Result<serde_json::Value, TransportError> {
        self.transport
            .send_command_with_response(
                &PiCommand::Fork { entry_id },
                DEFAULT_RESPONSE_TIMEOUT,
            )
            .await
    }

    pub async fn switch_session(
        &self,
        session_path: String,
    ) -> Result<serde_json::Value, TransportError> {
        self.transport
            .send_command_with_response(
                &PiCommand::SwitchSession { session_path },
                DEFAULT_RESPONSE_TIMEOUT,
            )
            .await
    }

    pub async fn new_session(&self) -> Result<serde_json::Value, TransportError> {
        self.transport
            .send_command_with_response(&PiCommand::NewSession, DEFAULT_RESPONSE_TIMEOUT)
            .await
    }

    pub async fn compact(&self) -> Result<(), TransportError> {
        self.transport.send_command(&PiCommand::Compact).await
    }

    pub async fn set_session_name(&self, name: String) -> Result<(), TransportError> {
        self.transport
            .send_command(&PiCommand::SetSessionName { name })
            .await
    }

    pub async fn set_auto_compaction(&self, enabled: bool) -> Result<(), TransportError> {
        self.transport
            .send_command(&PiCommand::SetAutoCompaction { enabled })
            .await
    }
}
