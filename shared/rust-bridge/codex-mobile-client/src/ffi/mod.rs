//! FFI layer for iOS and Android consumption.
//!
//! Uses UniFFI proc-macro approach for automatic Swift/Kotlin binding generation.
//! The scaffolding macro is invoked in lib.rs; this module holds additional
//! FFI helper types and exported functions.

mod app_store;
mod client;
mod discovery;
mod errors;
mod parser;
pub(crate) mod shared;
mod ssh;

pub use app_store::{AppStore, AppStoreSubscription};
pub use client::AppClient;
pub use discovery::{DiscoveryBridge, DiscoveryScanSubscription, ServerBridge};
pub use errors::ClientError;
pub use parser::MessageParser;
pub use ssh::{AppSshConnectionResult, SshBridge};
