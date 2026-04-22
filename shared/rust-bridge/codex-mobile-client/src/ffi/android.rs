//! UniFFI surface for Android-only platform setup.
//!
//! Kotlin calls `register_android_tools` from `UniffiInit.ensure()` with a
//! map of canonical tool name → absolute path inside the app's
//! `nativeLibraryDir`. The first call wins; later calls are ignored.

use std::collections::HashMap;

#[cfg(target_os = "android")]
#[uniffi::export]
pub fn register_android_tools(tools: HashMap<String, String>) {
    crate::android_exec::install(tools);
}

/// No-op stub on non-Android targets so the binding surface stays uniform.
/// Generated Kotlin/Swift bindings won't use this on other platforms, but
/// keeping the symbol resolvable simplifies the cdylib build matrix.
#[cfg(not(target_os = "android"))]
#[uniffi::export]
pub fn register_android_tools(_tools: HashMap<String, String>) {}
