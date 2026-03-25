//! Request handler trait for incoming IPC requests.

use crate::protocol::method::Method;
use crate::protocol::params::TypedRequest;

/// Trait for handling incoming IPC requests routed by the bus.
#[async_trait::async_trait]
pub trait RequestHandler: Send + Sync {
    /// Called when the router probes this client to see if it can handle a request.
    async fn can_handle(&self, method: &Method, version: u32) -> bool;

    /// Called when the router forwards a request this client accepted.
    async fn handle_request(
        &self,
        method: Method,
        request: TypedRequest,
    ) -> Result<serde_json::Value, String>;
}
