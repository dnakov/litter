//! Socket path resolution and Unix domain socket connection helpers.

use std::path::{Path, PathBuf};

use crate::error::TransportError;

#[cfg(unix)]
fn get_uid() -> u32 {
    unsafe { libc::getuid() }
}

/// Compute the default IPC socket path: `{tmpdir}/codex-ipc/ipc-{uid}.sock`.
#[cfg(unix)]
pub fn resolve_socket_path() -> PathBuf {
    let mut path = std::env::temp_dir();
    path.push("codex-ipc");
    path.push(format!("ipc-{}.sock", get_uid()));
    path
}

/// Connect to a Unix domain socket at the given path.
#[cfg(unix)]
pub async fn connect_unix(path: &Path) -> Result<tokio::net::UnixStream, TransportError> {
    tokio::net::UnixStream::connect(path)
        .await
        .map_err(TransportError::Io)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_socket_path_has_expected_suffix() {
        let path = resolve_socket_path();
        let uid = get_uid();
        let expected_suffix = format!("codex-ipc/ipc-{uid}.sock");
        assert!(
            path.ends_with(&expected_suffix),
            "expected path ending with {expected_suffix}, got {path:?}"
        );
    }

    #[test]
    fn resolve_socket_path_starts_with_temp_dir() {
        let path = resolve_socket_path();
        let tmp = std::env::temp_dir();
        assert!(
            path.starts_with(&tmp),
            "expected path starting with {tmp:?}, got {path:?}"
        );
    }
}
