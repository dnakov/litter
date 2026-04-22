//! Android exec hook: rewrites argv[0] for tools we ship as bundled binaries.
//!
//! On Android the only writable+executable directory inside an app sandbox is
//! the package installer's `nativeLibraryDir`, populated from `jniLibs/<abi>/`
//! at install time. Bundled tools are therefore packaged as `lib<tool>.so`
//! (ELF executables with a `.so` extension so the installer extracts them).
//!
//! At runtime Kotlin computes the absolute paths and registers them via the
//! UniFFI surface; this module installs a resolver into codex-core's exec
//! pipeline that swaps argv[0] from `git` → `<nativeLibraryDir>/libgit.so`
//! before fork/exec. Tools that aren't registered fall through to PATH-based
//! lookup (which still works for everything Android already ships under
//! `/system/bin`, e.g. `ls`, `cat`, `grep`, `sed`, `awk`).
//!
//! The resolver function pointer is `fn(&str) -> Option<String>`, so the map
//! itself lives in a separate `OnceLock` that the resolver reads.

use std::collections::HashMap;
use std::sync::OnceLock;

static TOOL_PATHS: OnceLock<HashMap<String, String>> = OnceLock::new();
static HOOK_INSTALLED: OnceLock<()> = OnceLock::new();

fn resolve(name: &str) -> Option<String> {
    TOOL_PATHS.get()?.get(name).cloned()
}

/// Register the tool→path map and install the codex-core resolver hook.
///
/// Safe to call multiple times; subsequent calls after the first are ignored
/// because both `OnceLock`s only accept a single value. The first registration
/// wins, which matches the lifecycle expectation that Kotlin calls this once
/// during `UniffiInit.ensure`.
pub fn install(tools: HashMap<String, String>) {
    let _ = TOOL_PATHS.set(tools);
    HOOK_INSTALLED.get_or_init(|| {
        codex_core::exec::set_android_tool_resolver(resolve);
    });
}
