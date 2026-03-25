//! High-level IPC client handle with handshake and typed API.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use tokio::sync::{broadcast, RwLock};

use crate::client::connection::IpcConnection;
use crate::client::pending::PendingRequests;
use crate::error::{IpcError, RequestError, TransportError};
use crate::handler::RequestHandler;
use crate::protocol::envelope::{Broadcast, Envelope, Request, Response};
use crate::protocol::method::Method;
use crate::protocol::params::{
    InitializeParams, InitializeResult, ThreadFollowerCommandApprovalDecisionParams,
    ThreadFollowerEditLastUserTurnParams, ThreadFollowerFileApprovalDecisionParams,
    ThreadFollowerInterruptTurnParams, ThreadFollowerSetCollaborationModeParams,
    ThreadFollowerSetModelAndReasoningParams, ThreadFollowerSetQueuedFollowUpsStateParams,
    ThreadFollowerStartTurnParams, ThreadFollowerSteerTurnParams,
    ThreadFollowerSubmitMcpServerElicitationResponseParams,
    ThreadFollowerSubmitUserInputParams, TypedBroadcast,
};
use crate::transport::socket;

/// Configuration for an IPC client connection.
pub struct IpcClientConfig {
    pub socket_path: PathBuf,
    pub client_type: String,
    pub request_timeout: Duration,
}

impl Default for IpcClientConfig {
    fn default() -> Self {
        Self {
            socket_path: socket::resolve_socket_path(),
            client_type: "mobile".to_string(),
            request_timeout: Duration::from_secs(10),
        }
    }
}

/// Clone-friendly IPC client handle.
#[derive(Clone)]
pub struct IpcClient {
    inner: Arc<Inner>,
}

struct Inner {
    client_id: String,
    config: IpcClientConfig,
    connection: IpcConnection,
}

impl IpcClient {
    /// Connect to the IPC bus and perform the initialize handshake.
    pub async fn connect(config: IpcClientConfig) -> Result<Self, IpcError> {
        Self::connect_with_config(&config).await
    }

    /// Connect using a borrowed config (allows the caller to retain ownership
    /// for reconnection).
    pub async fn connect_with_config(config: &IpcClientConfig) -> Result<Self, IpcError> {
        let stream = socket::connect_unix(&config.socket_path).await?;
        let (reader, writer) = stream.into_split();

        let pending = Arc::new(PendingRequests::new());
        let handler: Arc<RwLock<Option<Arc<dyn RequestHandler>>>> =
            Arc::new(RwLock::new(None));

        let connection = IpcConnection::spawn(reader, writer, pending, handler);

        // Build and send the initialize request.
        let request_id = uuid::Uuid::new_v4().to_string();
        let init_params = InitializeParams {
            client_type: config.client_type.clone(),
        };
        let envelope = Envelope::Request(Request {
            request_id: request_id.clone(),
            source_client_id: "initializing-client".to_string(),
            version: 0,
            method: Method::Initialize.wire_name().to_string(),
            params: serde_json::to_value(&init_params)
                .map_err(|e| IpcError::Protocol(format!("failed to serialize init params: {e}")))?,
            target_client_id: None,
        });

        let rx = connection.pending().insert(request_id);
        connection
            .write_tx()
            .send(envelope)
            .await
            .map_err(|_| IpcError::Transport(TransportError::ConnectionClosed))?;

        let response = tokio::time::timeout(config.request_timeout, rx)
            .await
            .map_err(|_| IpcError::Request(RequestError::Timeout))?
            .map_err(|_| IpcError::NotConnected)??;

        let client_id = match response {
            Response::Success { result, .. } => {
                let init_result: InitializeResult =
                    serde_json::from_value(result).map_err(|e| {
                        IpcError::InitializationFailed(format!(
                            "failed to parse initialize result: {e}"
                        ))
                    })?;
                init_result.client_id
            }
            Response::Error { error, .. } => {
                return Err(IpcError::InitializationFailed(error));
            }
        };

        Ok(Self {
            inner: Arc::new(Inner {
                client_id,
                config: IpcClientConfig {
                    socket_path: config.socket_path.clone(),
                    client_type: config.client_type.clone(),
                    request_timeout: config.request_timeout,
                },
                connection,
            }),
        })
    }

    /// The client ID assigned by the IPC router during handshake.
    pub fn client_id(&self) -> &str {
        &self.inner.client_id
    }

    /// Send a request to the IPC bus and await the response.
    pub async fn send_request(
        &self,
        method: Method,
        params: impl Serialize,
        target: Option<&str>,
    ) -> Result<serde_json::Value, IpcError> {
        let request_id = uuid::Uuid::new_v4().to_string();
        let envelope = Envelope::Request(Request {
            request_id: request_id.clone(),
            source_client_id: self.inner.client_id.clone(),
            version: method.current_version(),
            method: method.wire_name().to_string(),
            params: serde_json::to_value(&params).map_err(TransportError::Json)?,
            target_client_id: target.map(String::from),
        });

        let rx = self.inner.connection.pending().insert(request_id);
        self.inner
            .connection
            .write_tx()
            .send(envelope)
            .await
            .map_err(|_| IpcError::Transport(TransportError::ConnectionClosed))?;

        let response =
            tokio::time::timeout(self.inner.config.request_timeout, rx)
                .await
                .map_err(|_| IpcError::Request(RequestError::Timeout))?
                .map_err(|_| IpcError::NotConnected)??;

        match response {
            Response::Success { result, .. } => Ok(result),
            Response::Error { error, .. } => Err(IpcError::Request(RequestError::from_wire(&error))),
        }
    }

    /// Send a broadcast to the IPC bus.
    pub async fn send_broadcast(
        &self,
        method: Method,
        params: impl Serialize,
    ) -> Result<(), IpcError> {
        let envelope = Envelope::Broadcast(Broadcast {
            method: method.wire_name().to_string(),
            source_client_id: self.inner.client_id.clone(),
            version: method.current_version(),
            params: serde_json::to_value(&params).map_err(TransportError::Json)?,
        });

        self.inner
            .connection
            .write_tx()
            .send(envelope)
            .await
            .map_err(|_| IpcError::Transport(TransportError::ConnectionClosed))?;

        Ok(())
    }

    /// Subscribe to typed broadcast events from the bus.
    pub fn subscribe_broadcasts(&self) -> broadcast::Receiver<TypedBroadcast> {
        self.inner.connection.subscribe_broadcasts()
    }

    /// Set the request handler for incoming requests routed to this client.
    pub async fn set_request_handler(&self, handler: Arc<dyn RequestHandler>) {
        let mut guard = self.inner.connection.handler().write().await;
        *guard = Some(handler);
    }

    /// Disconnect from the IPC bus, aborting tasks and clearing pending requests.
    pub async fn disconnect(self) {
        // Unwrap the Arc or clone-shutdown the connection.
        // Since IpcClient is Clone, we operate on the connection directly.
        // The connection's shutdown is on the inner, so we access it.
        if let Ok(inner) = Arc::try_unwrap(self.inner) {
            inner.connection.shutdown().await;
        }
        // If there are other clones, we can't take ownership of the connection.
        // The connection will be cleaned up when all clones are dropped.
    }

    // -----------------------------------------------------------------------
    // Typed follower helpers
    // -----------------------------------------------------------------------

    pub async fn start_turn(
        &self,
        params: ThreadFollowerStartTurnParams,
    ) -> Result<serde_json::Value, IpcError> {
        self.send_request(Method::ThreadFollowerStartTurn, &params, None)
            .await
    }

    pub async fn steer_turn(
        &self,
        params: ThreadFollowerSteerTurnParams,
    ) -> Result<serde_json::Value, IpcError> {
        self.send_request(Method::ThreadFollowerSteerTurn, &params, None)
            .await
    }

    pub async fn interrupt_turn(
        &self,
        params: ThreadFollowerInterruptTurnParams,
    ) -> Result<serde_json::Value, IpcError> {
        self.send_request(Method::ThreadFollowerInterruptTurn, &params, None)
            .await
    }

    pub async fn set_model_and_reasoning(
        &self,
        params: ThreadFollowerSetModelAndReasoningParams,
    ) -> Result<serde_json::Value, IpcError> {
        self.send_request(Method::ThreadFollowerSetModelAndReasoning, &params, None)
            .await
    }

    pub async fn set_collaboration_mode(
        &self,
        params: ThreadFollowerSetCollaborationModeParams,
    ) -> Result<serde_json::Value, IpcError> {
        self.send_request(Method::ThreadFollowerSetCollaborationMode, &params, None)
            .await
    }

    pub async fn edit_last_user_turn(
        &self,
        params: ThreadFollowerEditLastUserTurnParams,
    ) -> Result<serde_json::Value, IpcError> {
        self.send_request(Method::ThreadFollowerEditLastUserTurn, &params, None)
            .await
    }

    pub async fn command_approval_decision(
        &self,
        params: ThreadFollowerCommandApprovalDecisionParams,
    ) -> Result<serde_json::Value, IpcError> {
        self.send_request(Method::ThreadFollowerCommandApprovalDecision, &params, None)
            .await
    }

    pub async fn file_approval_decision(
        &self,
        params: ThreadFollowerFileApprovalDecisionParams,
    ) -> Result<serde_json::Value, IpcError> {
        self.send_request(Method::ThreadFollowerFileApprovalDecision, &params, None)
            .await
    }

    pub async fn submit_user_input(
        &self,
        params: ThreadFollowerSubmitUserInputParams,
    ) -> Result<serde_json::Value, IpcError> {
        self.send_request(Method::ThreadFollowerSubmitUserInput, &params, None)
            .await
    }

    pub async fn submit_mcp_server_elicitation_response(
        &self,
        params: ThreadFollowerSubmitMcpServerElicitationResponseParams,
    ) -> Result<serde_json::Value, IpcError> {
        self.send_request(
            Method::ThreadFollowerSubmitMcpServerElicitationResponse,
            &params,
            None,
        )
        .await
    }

    pub async fn set_queued_follow_ups_state(
        &self,
        params: ThreadFollowerSetQueuedFollowUpsStateParams,
    ) -> Result<serde_json::Value, IpcError> {
        self.send_request(
            Method::ThreadFollowerSetQueuedFollowUpsState,
            &params,
            None,
        )
        .await
    }
}
