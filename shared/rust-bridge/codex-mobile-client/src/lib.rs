//! Shared mobile client library for iOS / Android.
//!
//! This crate owns the single public UniFFI surface for mobile. Keep shared
//! business logic here so Swift/Kotlin only compile one binding set.

#[cfg(target_os = "ios")]
mod aec;

pub mod conversation;
pub mod conversation_uniffi;
pub mod discovery;
pub mod discovery_uniffi;
pub mod ffi;
pub mod hydration;
pub mod immer_patch;
pub mod logging;
pub mod parser;
pub mod rpc;
pub mod session;
pub mod ssh;
pub mod store;
pub mod transport;
pub mod types;
mod mobile_client_impl;

pub use mobile_client_impl::*;

uniffi::setup_scaffolding!();
