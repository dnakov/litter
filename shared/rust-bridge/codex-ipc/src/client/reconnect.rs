//! Reconnecting IPC client wrapper with exponential backoff.

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{RwLock, broadcast};
use tracing::{error, info, warn};

use crate::client::handle::{IpcClient, IpcClientConfig};
use crate::error::IpcError;
use crate::handler::RequestHandler;
use crate::protocol::params::TypedBroadcast;

/// Policy for reconnection attempts.
pub struct ReconnectPolicy {
    pub initial_delay: Duration,
    pub max_delay: Duration,
    pub max_attempts: Option<u32>,
}

impl Default for ReconnectPolicy {
    fn default() -> Self {
        Self {
            initial_delay: Duration::from_secs(1),
            max_delay: Duration::from_secs(30),
            max_attempts: None,
        }
    }
}

/// IPC client wrapper that automatically reconnects on disconnection.
pub struct ReconnectingIpcClient {
    client: Arc<RwLock<Option<IpcClient>>>,
    handler: Arc<RwLock<Option<Arc<dyn RequestHandler>>>>,
    broadcast_tx: broadcast::Sender<TypedBroadcast>,
    _reconnect_task: tokio::task::JoinHandle<()>,
}

impl ReconnectingIpcClient {
    /// Connect to the IPC bus with automatic reconnection.
    pub async fn connect(
        config: IpcClientConfig,
        policy: ReconnectPolicy,
    ) -> Result<Self, IpcError> {
        let ipc_client = IpcClient::connect_with_config(&config).await?;
        let client: Arc<RwLock<Option<IpcClient>>> =
            Arc::new(RwLock::new(Some(ipc_client.clone())));
        let handler: Arc<RwLock<Option<Arc<dyn RequestHandler>>>> = Arc::new(RwLock::new(None));
        let (broadcast_tx, _) = broadcast::channel::<TypedBroadcast>(256);

        // Forward broadcasts from the initial client.
        let fwd_task_broadcast_tx = broadcast_tx.clone();
        let mut sub = ipc_client.subscribe_broadcasts();
        tokio::spawn(async move {
            while let Ok(msg) = sub.recv().await {
                let _ = fwd_task_broadcast_tx.send(msg);
            }
        });

        let reconnect_task = {
            let client = Arc::clone(&client);
            let handler = Arc::clone(&handler);
            let broadcast_tx = broadcast_tx.clone();
            tokio::spawn(Self::reconnect_loop(
                config,
                policy,
                client,
                handler,
                broadcast_tx,
            ))
        };

        Ok(Self {
            client,
            handler,
            broadcast_tx,
            _reconnect_task: reconnect_task,
        })
    }

    /// Returns the current connected client, if any.
    pub async fn client(&self) -> Option<IpcClient> {
        self.client.read().await.clone()
    }

    /// Subscribe to typed broadcasts. Subscriptions survive reconnections.
    pub fn subscribe_broadcasts(&self) -> broadcast::Receiver<TypedBroadcast> {
        self.broadcast_tx.subscribe()
    }

    /// Set the request handler. It will be re-registered on reconnect.
    pub async fn set_request_handler(&self, h: Arc<dyn RequestHandler>) {
        {
            let mut guard = self.handler.write().await;
            *guard = Some(Arc::clone(&h));
        }
        let guard = self.client.read().await;
        if let Some(c) = guard.as_ref() {
            c.set_request_handler(h).await;
        }
    }

    async fn reconnect_loop(
        config: IpcClientConfig,
        policy: ReconnectPolicy,
        client: Arc<RwLock<Option<IpcClient>>>,
        handler: Arc<RwLock<Option<Arc<dyn RequestHandler>>>>,
        broadcast_tx: broadcast::Sender<TypedBroadcast>,
    ) {
        loop {
            // Wait for the current client's broadcast subscription to end,
            // which signals the connection has dropped.
            {
                let guard = client.read().await;
                if let Some(c) = guard.as_ref() {
                    let mut sub = c.subscribe_broadcasts();
                    drop(guard);
                    // Block until the channel is closed (recv returns Err).
                    loop {
                        match sub.recv().await {
                            Ok(msg) => {
                                let _ = broadcast_tx.send(msg);
                            }
                            Err(broadcast::error::RecvError::Closed) => break,
                            Err(broadcast::error::RecvError::Lagged(_)) => continue,
                        }
                    }
                } else {
                    drop(guard);
                }
            }

            // Clear the client while we reconnect.
            {
                let mut guard = client.write().await;
                *guard = None;
            }

            info!("ipc connection lost, starting reconnect");

            let mut delay = policy.initial_delay;
            let mut attempt = 0u32;

            let new_client = loop {
                attempt += 1;
                if let Some(max) = policy.max_attempts {
                    if attempt > max {
                        error!("ipc reconnect: max attempts ({max}) reached, giving up");
                        return;
                    }
                }

                info!("ipc reconnecting, attempt {attempt}");
                tokio::time::sleep(delay).await;

                match IpcClient::connect_with_config(&config).await {
                    Ok(c) => {
                        info!("ipc reconnected");
                        break c;
                    }
                    Err(e) => {
                        warn!("ipc reconnect failed: {e}");
                        delay = (delay * 2).min(policy.max_delay);
                    }
                }
            };

            // Re-register handler if set.
            {
                let h_guard = handler.read().await;
                if let Some(h) = h_guard.as_ref() {
                    new_client.set_request_handler(Arc::clone(h)).await;
                }
            }

            // Store the new client.
            {
                let mut guard = client.write().await;
                *guard = Some(new_client);
            }
        }
    }
}
