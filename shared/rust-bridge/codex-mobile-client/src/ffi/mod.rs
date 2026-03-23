//! FFI layer for iOS and Android consumption.
//!
//! Uses UniFFI proc-macro approach for automatic Swift/Kotlin binding generation.
//! The scaffolding macro is invoked in lib.rs; this module holds additional
//! FFI helper types and exported functions.

mod app_store;
mod discovery;
mod errors;
mod parser;
mod rpc;
mod shared;
mod ssh;

pub use app_store::{AppStore, AppStoreSubscription};
pub use discovery::{DiscoveryBridge, ServerBridge};
pub use errors::ClientError;
pub use parser::MessageParser;
pub use rpc::AppServerRpc;
pub use ssh::{FfiSshConnectionResult, FfiSshExecResult, SshBridge};
