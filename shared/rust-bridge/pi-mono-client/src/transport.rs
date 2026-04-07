use std::sync::Arc;
use std::time::Duration;

use russh::ChannelMsg;
use russh::client::Msg;
use tokio::sync::{Mutex, broadcast, mpsc};

use crate::protocol::{PiCommand, PiEvent};

#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("channel closed")]
    ChannelClosed,
    #[error("serialization error: {0}")]
    Serialize(#[from] serde_json::Error),
    #[error("ssh error: {0}")]
    Ssh(String),
    #[error("response timeout")]
    Timeout,
    #[error("response error: {0}")]
    ResponseError(String),
}

pub struct PiMonoTransport {
    channel: Arc<Mutex<russh::Channel<Msg>>>,
    event_tx: broadcast::Sender<PiEvent>,
    reader_handle: tokio::task::JoinHandle<()>,
    response_rx: Mutex<mpsc::Receiver<PiEvent>>,
}

impl PiMonoTransport {
    /// Create a transport from an already-opened SSH exec channel running `pi --mode rpc`.
    pub fn launch(channel: russh::Channel<Msg>) -> Self {
        let (event_tx, _) = broadcast::channel::<PiEvent>(256);
        let (response_tx, response_rx) = mpsc::channel::<PiEvent>(64);

        let channel = Arc::new(Mutex::new(channel));
        let reader_channel = Arc::clone(&channel);
        let reader_event_tx = event_tx.clone();

        let reader_handle = tokio::spawn(async move {
            Self::reader_loop(reader_channel, reader_event_tx, response_tx).await;
        });

        Self {
            channel,
            event_tx,
            reader_handle,
            response_rx: Mutex::new(response_rx),
        }
    }

    async fn reader_loop(
        channel: Arc<Mutex<russh::Channel<Msg>>>,
        event_tx: broadcast::Sender<PiEvent>,
        response_tx: mpsc::Sender<PiEvent>,
    ) {
        let mut buf = Vec::<u8>::new();

        loop {
            let msg = {
                let mut ch = channel.lock().await;
                ch.wait().await
            };

            match msg {
                Some(ChannelMsg::Data { data }) => {
                    buf.extend_from_slice(&data);

                    // Process complete lines
                    while let Some(newline_pos) = buf.iter().position(|&b| b == b'\n') {
                        let line = &buf[..newline_pos];
                        if !line.is_empty() {
                            if let Ok(line_str) = std::str::from_utf8(line) {
                                match serde_json::from_str::<PiEvent>(line_str) {
                                    Ok(event) => {
                                        tracing::debug!(rpc_in = line_str, "pi-mono ←");
                                        // Send to response channel if it's a Response
                                        if matches!(&event, PiEvent::Response { .. }) {
                                            let _ = response_tx.send(event.clone()).await;
                                        }
                                        let _ = event_tx.send(event);
                                    }
                                    Err(e) => {
                                        tracing::warn!(
                                            line = line_str,
                                            error = %e,
                                            "failed to parse pi-mono event"
                                        );
                                    }
                                }
                            }
                        }
                        buf.drain(..=newline_pos);
                    }
                }
                Some(ChannelMsg::ExtendedData { data, ext: 1 }) => {
                    if let Ok(stderr) = std::str::from_utf8(&data) {
                        tracing::warn!(stderr = stderr, "pi-mono stderr");
                    }
                }
                Some(ChannelMsg::ExitStatus { exit_status }) => {
                    tracing::info!(exit_status, "pi-mono process exited");
                    break;
                }
                Some(ChannelMsg::Eof | ChannelMsg::Close) => {
                    tracing::info!("pi-mono channel closed");
                    break;
                }
                None => {
                    tracing::info!("pi-mono channel returned None");
                    break;
                }
                _ => {}
            }
        }
    }

    /// Send a command to pi-mono (fire-and-forget).
    pub async fn send_command(&self, cmd: &PiCommand) -> Result<(), TransportError> {
        let mut json = serde_json::to_string(cmd)?;
        tracing::debug!(rpc_out = %json, "pi-mono →");
        json.push('\n');
        let ch = self.channel.lock().await;
        ch.data(json.as_bytes())
            .await
            .map_err(|e| TransportError::Ssh(e.to_string()))?;
        Ok(())
    }

    /// Send a command and wait for the matching `Response` event.
    pub async fn send_command_with_response(
        &self,
        cmd: &PiCommand,
        timeout: Duration,
    ) -> Result<serde_json::Value, TransportError> {
        let expected_command = command_type_name(cmd);
        self.send_command(cmd).await?;

        let mut rx = self.response_rx.lock().await;
        let result = tokio::time::timeout(timeout, async {
            loop {
                match rx.recv().await {
                    Some(PiEvent::Response {
                        command,
                        success,
                        data,
                        error,
                    }) if command == expected_command => {
                        if success {
                            return Ok(data.unwrap_or(serde_json::Value::Null));
                        } else {
                            return Err(TransportError::ResponseError(
                                error.unwrap_or_else(|| "unknown error".into()),
                            ));
                        }
                    }
                    Some(_) => continue, // not our response, keep waiting
                    None => return Err(TransportError::ChannelClosed),
                }
            }
        })
        .await;

        match result {
            Ok(inner) => inner,
            Err(_) => Err(TransportError::Timeout),
        }
    }

    /// Subscribe to all events from pi-mono.
    pub fn subscribe(&self) -> broadcast::Receiver<PiEvent> {
        self.event_tx.subscribe()
    }

    /// Shut down the transport: signal EOF to stdin, abort the reader.
    pub async fn shutdown(&self) {
        {
            let ch = self.channel.lock().await;
            let _ = ch.eof().await;
        }
        self.reader_handle.abort();
    }
}

impl Drop for PiMonoTransport {
    fn drop(&mut self) {
        self.reader_handle.abort();
    }
}

/// Extract the snake_case command type name from a PiCommand for response matching.
fn command_type_name(cmd: &PiCommand) -> String {
    // Serialize to get the "type" field value from serde
    if let Ok(v) = serde_json::to_value(cmd) {
        if let Some(t) = v.get("type").and_then(|t| t.as_str()) {
            return t.to_owned();
        }
    }
    // Fallback — shouldn't happen since PiCommand always serializes with a type field
    "unknown".to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::PiCommand;

    #[test]
    fn command_type_name_extracts_correctly() {
        assert_eq!(command_type_name(&PiCommand::GetState), "get_state");
        assert_eq!(command_type_name(&PiCommand::GetMessages), "get_messages");
        assert_eq!(command_type_name(&PiCommand::Abort), "abort");
        assert_eq!(
            command_type_name(&PiCommand::GetAvailableModels),
            "get_available_models"
        );
        assert_eq!(
            command_type_name(&PiCommand::SetModel {
                provider: "x".into(),
                model_id: "y".into(),
            }),
            "set_model"
        );
    }
}
