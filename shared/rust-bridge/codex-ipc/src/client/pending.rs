//! Pending request tracking with oneshot resolution.

use std::collections::HashMap;
use std::sync::Mutex;
use tokio::sync::oneshot;

use crate::error::IpcError;
use crate::protocol::envelope::Response;

/// Tracks in-flight requests awaiting responses from the IPC bus.
pub struct PendingRequests {
    inner: Mutex<HashMap<String, oneshot::Sender<Result<Response, IpcError>>>>,
}

impl PendingRequests {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
        }
    }

    /// Register a new pending request. Returns a receiver that will be resolved
    /// when the response arrives.
    pub fn insert(
        &self,
        request_id: String,
    ) -> oneshot::Receiver<Result<Response, IpcError>> {
        let (tx, rx) = oneshot::channel();
        self.inner.lock().unwrap().insert(request_id, tx);
        rx
    }

    /// Resolve a pending request with the given response. Returns `true` if the
    /// request was found and resolved.
    pub fn resolve(&self, request_id: &str, response: Result<Response, IpcError>) -> bool {
        if let Some(tx) = self.inner.lock().unwrap().remove(request_id) {
            // Ignore send error — receiver may have been dropped.
            let _ = tx.send(response);
            true
        } else {
            false
        }
    }

    /// Remove a pending request without resolving it (for cleanup).
    pub fn remove(&self, request_id: &str) {
        self.inner.lock().unwrap().remove(request_id);
    }

    /// Resolve all pending requests with a `NotConnected` error and clear the map.
    pub fn clear(&self) {
        let mut map = self.inner.lock().unwrap();
        for (_, tx) in map.drain() {
            let _ = tx.send(Err(IpcError::NotConnected));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::envelope::Response;

    #[tokio::test]
    async fn insert_and_resolve() {
        let pending = PendingRequests::new();
        let rx = pending.insert("req-1".into());

        let resp = Response::Success {
            request_id: "req-1".into(),
            method: "test".into(),
            handled_by_client_id: "c1".into(),
            result: serde_json::json!({"ok": true}),
        };

        assert!(pending.resolve("req-1", Ok(resp)));
        let result = rx.await.unwrap();
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn resolve_unknown_returns_false() {
        let pending = PendingRequests::new();
        let resp = Response::Error {
            request_id: "nope".into(),
            error: "test".into(),
        };
        assert!(!pending.resolve("nope", Ok(resp)));
    }

    #[tokio::test]
    async fn remove_prevents_resolution() {
        let pending = PendingRequests::new();
        let _rx = pending.insert("req-1".into());
        pending.remove("req-1");

        let resp = Response::Success {
            request_id: "req-1".into(),
            method: "test".into(),
            handled_by_client_id: "c1".into(),
            result: serde_json::json!(null),
        };
        assert!(!pending.resolve("req-1", Ok(resp)));
    }

    #[tokio::test]
    async fn clear_resolves_all_with_not_connected() {
        let pending = PendingRequests::new();
        let rx1 = pending.insert("a".into());
        let rx2 = pending.insert("b".into());

        pending.clear();

        let r1 = rx1.await.unwrap();
        let r2 = rx2.await.unwrap();
        assert!(matches!(r1, Err(IpcError::NotConnected)));
        assert!(matches!(r2, Err(IpcError::NotConnected)));
    }
}
