//! IPC connection managing read/write loop tasks over an async byte stream.

use std::sync::Arc;

use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{RwLock, broadcast, mpsc};
use tracing::{debug, error, warn};

use crate::client::pending::PendingRequests;
use crate::error::TransportError;
use crate::handler::RequestHandler;
use crate::protocol::envelope::{ClientDiscoveryResponse, DiscoveryAnswer, Envelope, Response};
use crate::protocol::method::Method;
use crate::protocol::params::{TypedBroadcast, TypedRequest};
use crate::transport::frame;

/// Active IPC connection with spawned read/write loop tasks.
pub struct IpcConnection {
    write_tx: mpsc::Sender<Envelope>,
    broadcast_tx: broadcast::Sender<TypedBroadcast>,
    pending: Arc<PendingRequests>,
    handler: Arc<RwLock<Option<Arc<dyn RequestHandler>>>>,
    read_task: tokio::task::JoinHandle<()>,
    write_task: tokio::task::JoinHandle<()>,
}

impl IpcConnection {
    /// Spawn read and write loop tasks over split async I/O halves.
    pub fn spawn<R, W>(
        reader: R,
        writer: W,
        pending: Arc<PendingRequests>,
        handler: Arc<RwLock<Option<Arc<dyn RequestHandler>>>>,
    ) -> Self
    where
        R: AsyncRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let (write_tx, write_rx) = mpsc::channel::<Envelope>(256);
        let (broadcast_tx, _) = broadcast::channel::<TypedBroadcast>(256);

        let read_task = {
            let pending = Arc::clone(&pending);
            let handler = Arc::clone(&handler);
            let write_tx = write_tx.clone();
            let broadcast_tx = broadcast_tx.clone();
            tokio::spawn(Self::read_loop(
                reader,
                pending,
                handler,
                write_tx,
                broadcast_tx,
            ))
        };

        let write_task = tokio::spawn(Self::write_loop(writer, write_rx));

        Self {
            write_tx,
            broadcast_tx,
            pending,
            handler,
            read_task,
            write_task,
        }
    }

    /// The sender for writing outbound envelopes.
    pub fn write_tx(&self) -> &mpsc::Sender<Envelope> {
        &self.write_tx
    }

    /// Subscribe to typed broadcast events.
    pub fn subscribe_broadcasts(&self) -> broadcast::Receiver<TypedBroadcast> {
        self.broadcast_tx.subscribe()
    }

    /// Access the pending requests tracker.
    pub fn pending(&self) -> &Arc<PendingRequests> {
        &self.pending
    }

    /// Access the request handler slot.
    pub fn handler(&self) -> &Arc<RwLock<Option<Arc<dyn RequestHandler>>>> {
        &self.handler
    }

    /// Gracefully shut down the connection: abort tasks and clear pending.
    pub async fn shutdown(self) {
        self.read_task.abort();
        self.write_task.abort();
        self.pending.clear();
    }

    async fn read_loop<R>(
        mut reader: R,
        pending: Arc<PendingRequests>,
        handler: Arc<RwLock<Option<Arc<dyn RequestHandler>>>>,
        write_tx: mpsc::Sender<Envelope>,
        broadcast_tx: broadcast::Sender<TypedBroadcast>,
    ) where
        R: AsyncRead + Unpin + Send + 'static,
    {
        loop {
            let raw = match frame::read_frame(&mut reader).await {
                Ok(data) => data,
                Err(TransportError::ConnectionClosed) => {
                    debug!("ipc connection closed");
                    pending.clear();
                    break;
                }
                Err(e) => {
                    error!("ipc read error: {e}");
                    pending.clear();
                    break;
                }
            };

            let envelope: Envelope = match serde_json::from_str(&raw) {
                Ok(e) => e,
                Err(e) => {
                    warn!("ipc: failed to parse envelope: {e}");
                    continue;
                }
            };

            match envelope {
                Envelope::Response(resp) => {
                    let req_id = resp.request_id().to_string();
                    if !pending.resolve(&req_id, Ok(resp)) {
                        warn!("ipc: response for unknown request {req_id}");
                    }
                }
                Envelope::Broadcast(b) => {
                    let typed = TypedBroadcast::from_broadcast(&b);
                    // Ignore lag errors — slow receivers just miss broadcasts.
                    let _ = broadcast_tx.send(typed);
                }
                Envelope::ClientDiscoveryRequest(disc) => {
                    let method = Method::from_wire(&disc.request.method);
                    let can_handle = if let Some(method) = method {
                        let guard = handler.read().await;
                        if let Some(h) = guard.as_ref() {
                            h.can_handle(&method, disc.request.version).await
                        } else {
                            false
                        }
                    } else {
                        false
                    };

                    let response_envelope =
                        Envelope::ClientDiscoveryResponse(ClientDiscoveryResponse {
                            request_id: disc.request_id,
                            response: DiscoveryAnswer { can_handle },
                        });
                    if write_tx.send(response_envelope).await.is_err() {
                        break;
                    }
                }
                Envelope::Request(req) => {
                    let method = Method::from_wire(&req.method);
                    let guard = handler.read().await;
                    if let (Some(method), Some(h)) = (method, guard.as_ref()) {
                        let h = Arc::clone(h);
                        let write_tx = write_tx.clone();
                        let request_id = req.request_id.clone();
                        let source_client_id = req.source_client_id.clone();
                        let method_str = req.method.clone();
                        let typed = TypedRequest::from_request(&req);
                        drop(guard);
                        // Spawn handler so we don't block the read loop.
                        tokio::spawn(async move {
                            let response_envelope = match h.handle_request(method, typed).await {
                                Ok(result) => Envelope::Response(Response::Success {
                                    request_id,
                                    method: method_str,
                                    handled_by_client_id: source_client_id,
                                    result,
                                }),
                                Err(error) => {
                                    Envelope::Response(Response::Error { request_id, error })
                                }
                            };
                            let _ = write_tx.send(response_envelope).await;
                        });
                    } else {
                        drop(guard);
                        warn!(
                            "ipc: no handler for request {} (method: {})",
                            req.request_id, req.method
                        );
                    }
                }
                Envelope::ClientDiscoveryResponse(_) => {
                    // Clients don't normally receive discovery responses;
                    // the router sends these. Log and skip.
                    debug!("ipc: ignoring unexpected ClientDiscoveryResponse");
                }
            }
        }
    }

    async fn write_loop<W>(mut writer: W, mut write_rx: mpsc::Receiver<Envelope>)
    where
        W: AsyncWrite + Unpin + Send + 'static,
    {
        while let Some(envelope) = write_rx.recv().await {
            let json_str = match serde_json::to_string(&envelope) {
                Ok(s) => s,
                Err(e) => {
                    error!("ipc: failed to serialize envelope: {e}");
                    continue;
                }
            };
            if let Err(e) = frame::write_frame(&mut writer, &json_str).await {
                error!("ipc: write error: {e}");
                break;
            }
        }
    }
}
