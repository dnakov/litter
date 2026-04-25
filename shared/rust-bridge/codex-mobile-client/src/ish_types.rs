//! Always-compiled UniFFI-visible types for the iSH surface. The
//! implementation (kernel boot, libresolv FFI, command dispatch) lives in
//! `ish_runtime` and is gated to iOS-non-macabi, but the *types* that cross
//! the UniFFI boundary must exist on every build so the host cdylib used by
//! `generate-bindings.sh` emits them into the generated Swift/Kotlin.
//!
//! Non-iOS platforms only ever receive the `Unsupported` variant / stub
//! `IshRunResult` values — see the `#[uniffi::export]` wrappers in `lib.rs`.

/// Captured result of an `ish_run` invocation. UniFFI record so Swift gets
/// `exit_code: Int32` + `output: Data`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct IshRunResult {
    pub exit_code: i32,
    pub output: Vec<u8>,
}

/// Errors surfaced from `ish_bootstrap`. Variant payloads are flattened to
/// plain strings so the generated Swift/Kotlin enum is straightforward to
/// consume.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum IshBootstrapError {
    #[error("already bootstrapped")]
    AlreadyBootstrapped,
    #[error("bundled rootfs missing at {0}")]
    BundledRootfsMissing(String),
    #[error("filesystem: {0}")]
    Io(String),
    #[error("ish: {0}")]
    Ish(String),
    /// Returned from UniFFI stubs on non-iOS targets (Mac Catalyst, Android,
    /// host bindgen build) where the iSH kernel is not linked in.
    #[error("unsupported on this platform: {message}")]
    Unsupported { message: String },
}

impl From<std::io::Error> for IshBootstrapError {
    fn from(err: std::io::Error) -> Self {
        IshBootstrapError::Io(err.to_string())
    }
}
