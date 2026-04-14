//! Narrow OpenCode contract models used by the mobile bridge.
//!
//! Phase 1 intentionally stops at type modeling, fixtures, and validation.
//! Transport, store integration, and UniFFI wiring land in later phases.

pub mod capabilities;
pub mod client;
pub mod error;
pub mod events;
pub mod mapping;
mod sse;
pub mod stream;
pub mod types;

pub use capabilities::OpenCodeCapabilities;
pub use client::OpenCodeClient;
pub use error::OpenCodeBridgeError;
pub use events::{OpenCodeEvent, OpenCodeGlobalEvent};
pub use mapping::*;
pub use stream::{
    OpenCodeDisconnectCause, OpenCodeEventStreamClient, OpenCodeReconnectPolicy,
    OpenCodeRefreshHint, OpenCodeStreamConfig, OpenCodeStreamEvent, OpenCodeStreamHandle,
};
pub use types::*;
