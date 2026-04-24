//! Shared mobile client library for iOS / Android.
//!
//! This crate owns the single public UniFFI surface for mobile. Keep shared
//! business logic here so Swift/Kotlin only compile one binding set.

#[cfg(all(target_os = "ios", not(target_abi = "macabi")))]
mod ios_exec;
#[cfg(any(all(target_os = "ios", not(target_abi = "macabi")), test))]
mod mobile_exec_command;

#[cfg(target_os = "android")]
pub mod android_exec;

#[cfg(any(
    all(target_os = "ios", not(target_abi = "macabi")),
    target_os = "android",
    test
))]
pub mod shell_preflight;

pub mod ambient_suggestions;
pub mod cloud_sync;
pub mod conversation;
pub mod conversation_uniffi;
pub mod discovery;
pub mod discovery_uniffi;
pub mod ffi;
pub mod hydration;
pub mod immer_patch;
pub mod local_server;
pub mod logging;
pub mod markdown_blocks;
mod mobile_client;
pub mod pair;
pub mod parser;
pub mod permissions;
pub mod plugin_refs;
pub mod preferences;
pub mod project;
pub mod reconnect;
pub mod recorder;
pub mod remote_path;
pub mod saved_apps;
pub mod session;
pub mod ssh;
pub mod store;
pub mod transport;
pub mod types;
pub mod widget_guidelines;

pub use mobile_client::*;

// ── Shared infra ─────────────────────────────────────────────────────────

use std::sync::atomic::{AtomicI64, Ordering};

static REQUEST_COUNTER: AtomicI64 = AtomicI64::new(1);
pub(crate) const MOBILE_ASYNC_THREAD_STACK_SIZE_BYTES: usize = 4 * 1024 * 1024;

pub(crate) fn next_request_id() -> i64 {
    REQUEST_COUNTER.fetch_add(1, Ordering::Relaxed)
}

#[derive(Debug, thiserror::Error)]
pub enum RpcClientError {
    #[error("RPC: {0}")]
    Rpc(String),
    #[error("Serialization: {0}")]
    Serialization(String),
}

uniffi::setup_scaffolding!();
