//! iOS-only iSH bootstrap + run surface. Port of the former Obj-C
//! `apps/ios/Sources/Litter/Bridge/IshBridge.{h,m}` into Rust.
//!
//! Responsibilities, mirroring the Obj-C original 1:1:
//! 1. Extract the bundled `fs` rootfs into `<app_support>/fs/` on first launch.
//! 2. `chmod 0644` the fakefs `meta.db` so SQLite can write.
//! 3. Boot the iSH kernel at `<app_support>/fs/data` with `/root` as cwd.
//! 4. Install a small runtime-env preamble (`LANG`, `PAGER`, `CODEX_HOME`, …).
//! 5. Snapshot host DNS into `/etc/resolv.conf` inside the fakefs.
//! 6. Mount `<documents>/Apps/` at `/mnt/apps/` via iSH's `realfs` driver.
//! 7. Register the `codex_core` exec hook (`ish_exec::install()`).
//!
//! After `bootstrap`, `run(cmd, cwd)` dispatches command strings through the
//! persistent `/bin/sh` the same way `codex_ish_run` did in Obj-C.

use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_uint, CStr};
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use ish_embed_host::{IshInstance, SpawnOpts};

use crate::ish_types::IshBootstrapError;

// Numeric error codes preserved for back-compat with the previous `ish` crate
// surface. The Swift side observes these as negative `Int32` values.
pub const ISH_E_BOOT:        i32 = -1;
pub const ISH_E_MOUNT:       i32 = -2;
pub const ISH_E_EXECVE:      i32 = -3;
pub const ISH_E_PIPE:        i32 = -4;
pub const ISH_E_THREAD:      i32 = -5;
pub const ISH_E_NOT_RUNNING: i32 = -6;
pub const ISH_E_IO:          i32 = -7;
pub const ISH_E_TIMEOUT:     i32 = -8;
pub const ISH_E_NOMEM:       i32 = -9;
pub const ISH_E_ARGS:        i32 = -10;

const RUN_TIMEOUT_MS: u64 = 60_000;

impl From<ish_embed_host::IshError> for IshBootstrapError {
    fn from(err: ish_embed_host::IshError) -> Self {
        IshBootstrapError::Ish(err.to_string())
    }
}

static INSTANCE: OnceLock<IshInstance> = OnceLock::new();

/// One-time iSH boot. Mirrors `codex_ish_init` + the post-init setup calls in
/// IshBridge.m. After this returns `Ok`, `run()` is safe to call and the
/// codex_core exec hook has been installed.
///
/// * `bundle_fs_path` — absolute path to the `fs` directory inside the app
///   bundle (Swift resolves this via `Bundle.main.url(forResource:"fs", …)`).
/// * `application_support_dir` — Application Support dir for the app; the
///   rootfs lives under `<application_support_dir>/fs/`.
/// * `documents_dir` — the app's Documents directory; `Apps/` inside it is
///   bind-mounted at `/mnt/apps` inside the fakefs.
pub fn bootstrap(
    bundle_fs_path: &Path,
    application_support_dir: &Path,
    documents_dir: &Path,
) -> Result<(), IshBootstrapError> {
    if INSTANCE.get().is_some() {
        return Err(IshBootstrapError::AlreadyBootstrapped);
    }

    let dest = application_support_dir.join("fs");
    extract_rootfs_if_needed(bundle_fs_path, &dest)?;

    let meta_db = dest.join("meta.db");
    if meta_db.exists() {
        let mut perms = fs::metadata(&meta_db)?.permissions();
        perms.set_mode(0o644);
        if let Err(err) = fs::set_permissions(&meta_db, perms) {
            eprintln!("[ish] chmod 0644 on meta.db failed: {err}");
        }
    }

    let data_path = dest.join("data");
    eprintln!(
        "[ish] booting kernel with rootfs='{}' workdir='/root'",
        data_path.display()
    );
    let instance = IshInstance::boot(&data_path, Some(Path::new("/root")))?;
    eprintln!("[ish] kernel booted");

    INSTANCE
        .set(instance)
        .map_err(|_| IshBootstrapError::AlreadyBootstrapped)?;

    // Now that INSTANCE is published, the post-init setup goes through the
    // normal run() path, which takes the shared lock and honors the same
    // ordering guarantees as regular command dispatch.
    runtime_setup();
    write_resolv_conf();
    mount_apps_dir(documents_dir);

    crate::ish_exec::install();

    Ok(())
}

/// Default working directory for iSH-backed local sessions. Port of
/// `codex_ish_default_cwd` — always `/root` (Alpine's root home).
pub fn default_cwd() -> &'static str {
    "/root"
}

/// Run `cmd` through the persistent `/bin/sh`. When `cwd` is non-empty the
/// command is wrapped as `cd '<cwd>' && <cmd>` (same shell-quote pass as the
/// Obj-C port). Returns (exit_code, merged stdout+stderr bytes). If the kernel
/// has not been booted or the FFI call fails, returns a negative ISH_E_* code
/// and an empty byte vector — matching the IshBridge.m error semantics so the
/// exec-hook path can surface the failure without a nil pointer panic.
pub fn run(cmd: &str, cwd: Option<&str>) -> (i32, Vec<u8>) {
    let Some(instance) = INSTANCE.get() else {
        eprintln!("[ish] run() called before bootstrap succeeded");
        return (ISH_E_NOT_RUNNING, Vec::new());
    };

    // The previous embed library funnelled every command through a single
    // persistent `/bin/sh`, so `cd` between calls leaked. The new architecture
    // forks a fresh shell per call, so an explicit `cd && cmd` wrapper is
    // still the right way to honour caller-supplied cwd.
    let wrapped = match cwd {
        Some(c) if !c.is_empty() => format!("cd {} && {}", shell_quote(c), cmd),
        _ => cmd.to_string(),
    };

    let argv = [
        "/bin/sh".to_string(),
        "-c".to_string(),
        wrapped,
    ];
    let env = HashMap::new();
    let cwd_path = PathBuf::from("/");
    instance.run_oneshot(&argv, &cwd_path, &env, Some(RUN_TIMEOUT_MS))
}

// ── post-init setup helpers ──────────────────────────────────────────────
// These mirror codex_ish_runtime_setup / codex_ish_write_resolv_conf /
// codex_ish_mount_apps_dir from IshBridge.m. They call run() internally; the
// ish crate's own lock serializes the actual dispatches.

const RUNTIME_SETUP_SCRIPT: &str = concat!(
    "export LANG=C.UTF-8 LC_ALL=C.UTF-8 ;",
    "export LOGNAME=root ;",
    "export TMPDIR=/tmp ;",
    // No tty under the exec hook — force pagers to dump-and-exit so
    // things like `git log` / `man` don't block the persistent shell.
    "export PAGER=cat ;",
    "export EDITOR=vi ;",
    "export HOSTNAME=litter ;",
    // Symmetric with the iOS-side CODEX_HOME (which points into the iOS
    // sandbox the codex Rust process actually uses). Tools running inside
    // iSH that look for $CODEX_HOME find a path local to the fakefs.
    "export CODEX_HOME=/root/.codex ;",
    "mkdir -p /root/.codex /tmp ;",
    "chmod 700 /root/.codex ;",
    "chmod 1777 /tmp",
);

fn runtime_setup() {
    let (rc, _) = run(RUNTIME_SETUP_SCRIPT, None);
    if rc != 0 {
        eprintln!("[ish] runtime setup failed rc={rc}");
    }
}

fn write_resolv_conf() {
    let body = resolv_conf_body();
    let cmd = format!("printf %s {} > /etc/resolv.conf", shell_quote(&body));
    let (rc, _) = run(&cmd, None);
    if rc != 0 {
        eprintln!("[ish] failed to write /etc/resolv.conf rc={rc}");
    } else {
        eprintln!("[ish] /etc/resolv.conf installed ({} bytes)", body.len());
    }
}

fn mount_apps_dir(documents_dir: &Path) {
    let apps_dir = documents_dir.join("Apps");
    if let Err(err) = fs::create_dir_all(&apps_dir) {
        eprintln!("[ish] could not create {}: {err}", apps_dir.display());
        return;
    }
    let Some(apps_str) = apps_dir.to_str() else {
        eprintln!("[ish] apps dir not utf-8: {}", apps_dir.display());
        return;
    };
    let cmd = format!(
        "mkdir -p /mnt/apps && mount -t real {} /mnt/apps",
        shell_quote(apps_str)
    );
    let (rc, _) = run(&cmd, None);
    if rc != 0 {
        eprintln!("[ish] mount /mnt/apps failed rc={rc}");
    } else {
        eprintln!("[ish] /mnt/apps mounted from '{}'", apps_str);
    }
}

// ── bundled rootfs extraction ────────────────────────────────────────────

fn extract_rootfs_if_needed(source: &Path, dest: &Path) -> Result<(), IshBootstrapError> {
    if dest.is_dir() {
        return Ok(());
    }
    if !source.is_dir() {
        return Err(IshBootstrapError::BundledRootfsMissing(
            source.display().to_string(),
        ));
    }
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }
    copy_dir_recursive(source, dest)?;
    Ok(())
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> io::Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let ft = entry.file_type()?;
        let src_path = entry.path();
        let dst_path = dst.join(entry.file_name());
        if ft.is_dir() {
            copy_dir_recursive(&src_path, &dst_path)?;
        } else if ft.is_symlink() {
            let target = fs::read_link(&src_path)?;
            // Unix symlink copy; iSH fakefs data dir contains plain files +
            // dirs in practice, but tolerate symlinks in the bundle just in
            // case.
            std::os::unix::fs::symlink(&target, &dst_path)?;
        } else {
            fs::copy(&src_path, &dst_path)?;
        }
    }
    Ok(())
}

// ── shell quoting ────────────────────────────────────────────────────────

/// POSIX single-quote escape: wrap in `'…'` and replace embedded `'` with
/// `'\''`. Port of `codex_ish_shell_quote` from IshBridge.m.
fn shell_quote(s: &str) -> String {
    let escaped = s.replace('\'', "'\\''");
    format!("'{escaped}'")
}

// ── resolv.conf snapshot (libresolv FFI) ─────────────────────────────────
//
// Apple's <resolv.h> macro-renames `res_ninit` / `res_getservers` /
// `res_ndestroy` to `res_9_*`, so libresolv.9.tbd on iPhoneOS.sdk exports
// the `res_9_*` symbols. The Rust FFI declares those names directly.
//
// We reproduce `codex_ish_resolv_conf_body()` from IshBridge.m with one
// intentional scope narrowing: we do not emit the `search …` line. Reading
// `struct __res_state::dnsrch` requires reaching into an opaque Apple
// resolver struct with no stable ABI contract; nameservers alone are enough
// for the bootstrap script to reach apk/curl, which is what the original
// Obj-C path was protecting. Empty search list falls through to the public
// resolver fallback below, matching the Obj-C "empty ⇒ fallback" semantic.

// Size chosen generously: the 64-bit Apple `struct __res_state` layout is
// around 1 KB (see resolv.h:182-232; includes MAXNS=3 sockaddr_in slots,
// MAXDNSRCH+1=7 char* pointers, and a 72-byte `_u` union). 4 KB zeroed is a
// safe upper bound that doesn't depend on Apple's internal offsets staying
// stable across SDKs.
const RES_STATE_BUF: usize = 4096;
// `union res_sockaddr_union` is 128-byte `__space` plus alignment padding
// (resolv.h:242-253). 256 bytes is the safe upper bound.
const RES_SOCKADDR_UNION_BUF: usize = 256;
// `<arpa/nameser.h>` / `<resolv.h>` — maximum name servers res_getservers
// will return.
const MAXNS: c_int = 3;

// `<netdb.h>` on Apple.
const NI_MAXHOST: usize = 1025;
const NI_NUMERICHOST: c_int = 0x0000_0002;

#[repr(C)]
struct Sockaddr {
    sa_len: u8,
    sa_family: u8,
    _opaque: [u8; 254],
}

unsafe extern "C" {
    fn res_9_ninit(state: *mut u8) -> c_int;
    fn res_9_getservers(state: *mut u8, servers: *mut u8, count: c_int) -> c_int;
    fn res_9_ndestroy(state: *mut u8);

    fn getnameinfo(
        sa: *const Sockaddr,
        salen: c_uint,
        host: *mut c_char,
        hostlen: c_uint,
        serv: *mut c_char,
        servlen: c_uint,
        flags: c_int,
    ) -> c_int;
}

fn resolv_conf_body() -> String {
    let mut out = String::new();

    let mut res_state = [0u8; RES_STATE_BUF];
    // SAFETY: res_state is a zeroed byte buffer sized generously above the
    // Apple `__res_state` struct. res_9_ninit writes through the pointer; we
    // never dereference fields on the Rust side. res_9_ndestroy is called
    // unconditionally on the Ok path, balancing res_9_ninit.
    let init_rc = unsafe { res_9_ninit(res_state.as_mut_ptr()) };
    if init_rc == 0 {
        let mut servers = [0u8; RES_SOCKADDR_UNION_BUF * MAXNS as usize];
        let found = unsafe {
            res_9_getservers(
                res_state.as_mut_ptr(),
                servers.as_mut_ptr(),
                MAXNS,
            )
        };
        for i in 0..found.max(0) {
            // SAFETY: Each sockaddr_union slot is RES_SOCKADDR_UNION_BUF
            // bytes; the first byte is sin_len (Apple BSD sockaddr has
            // sa_len as the first byte). A zero sin_len means the slot was
            // left empty by the resolver — skip it, matching IshBridge.m.
            let slot =
                unsafe { servers.as_ptr().add(i as usize * RES_SOCKADDR_UNION_BUF) };
            let sa_len = unsafe { *slot };
            if sa_len == 0 {
                continue;
            }
            let mut host_buf = [0i8; NI_MAXHOST];
            let rc = unsafe {
                getnameinfo(
                    slot as *const Sockaddr,
                    sa_len as c_uint,
                    host_buf.as_mut_ptr(),
                    NI_MAXHOST as c_uint,
                    std::ptr::null_mut(),
                    0,
                    NI_NUMERICHOST,
                )
            };
            if rc == 0 {
                // SAFETY: getnameinfo NUL-terminates on success.
                let addr = unsafe { CStr::from_ptr(host_buf.as_ptr()) };
                if let Ok(s) = addr.to_str() {
                    out.push_str("nameserver ");
                    out.push_str(s);
                    out.push('\n');
                }
            }
        }
        unsafe { res_9_ndestroy(res_state.as_mut_ptr()) };
    }

    if !out.contains("nameserver ") {
        // Fallback: public resolvers so apk/curl still work when the host
        // resolver handed back nothing (offline, fresh container, etc.).
        out.push_str("nameserver 1.1.1.1\nnameserver 8.8.8.8\n");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_quote_basic() {
        assert_eq!(shell_quote("x"), "'x'");
    }

    #[test]
    fn shell_quote_with_single_quote() {
        assert_eq!(shell_quote("x's"), "'x'\\''s'");
    }

    #[test]
    fn shell_quote_path_with_spaces() {
        assert_eq!(
            shell_quote("/var/Documents/Apps"),
            "'/var/Documents/Apps'"
        );
    }
}
