//! Rust implementation of the Codex Local IPC protocol.
//!
//! This crate provides a fully typed client for connecting to the Codex IPC
//! socket bus, which is used to synchronize conversation state between Codex
//! instances via an owner/follower model.
//!
//! # Transport
//!
//! Communication happens over Unix domain sockets using length-prefixed JSON
//! frames (4-byte little-endian u32 length prefix + UTF-8 JSON payload).
//!
//! # Protocol
//!
//! The protocol uses four envelope types:
//! - **Request** — client-to-client RPC, routed by the IPC router
//! - **Response** — success or error reply to a request
//! - **Broadcast** — one-to-many notifications (e.g., state changes)
//! - **ClientDiscovery** — router probes to find a handler for a request

pub mod client;
pub mod conversation_state;
pub mod error;
pub mod handler;
pub mod protocol;
pub mod transport;

pub use client::handle::{IpcClient, IpcClientConfig};
pub use client::reconnect::{ReconnectPolicy, ReconnectingIpcClient};
pub use conversation_state::*;
pub use error::{IpcError, RequestError, TransportError};
pub use handler::RequestHandler;
pub use protocol::envelope::*;
pub use protocol::method::Method;
pub use protocol::params::*;
