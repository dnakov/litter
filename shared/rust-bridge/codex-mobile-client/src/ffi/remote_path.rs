//! UniFFI wrapper for [`crate::remote_path::RemotePath`].

use std::sync::Arc;

use crate::types::DirectoryPathSegment;

/// Opaque remote-path object exposed to Swift / Kotlin via UniFFI.
#[derive(uniffi::Object)]
pub struct RemotePath {
    inner: crate::remote_path::RemotePath,
}

#[uniffi::export]
impl RemotePath {
    /// Parse a path string, auto-detecting Windows vs POSIX from its format.
    #[uniffi::constructor]
    pub fn parse(path: String) -> Arc<Self> {
        Arc::new(Self {
            inner: crate::remote_path::RemotePath::parse(&path),
        })
    }

    /// The raw path string.
    pub fn as_string(&self) -> String {
        self.inner.as_str().to_string()
    }

    /// Whether this is a Windows-style path (drive letter).
    pub fn is_windows(&self) -> bool {
        self.inner.is_windows()
    }

    /// Whether this path is a root (`/` or `C:\`).
    pub fn is_root(&self) -> bool {
        self.inner.is_root()
    }

    /// Append a child name using the correct separator.
    pub fn join(&self, name: String) -> Arc<Self> {
        Arc::new(Self {
            inner: self.inner.join(&name),
        })
    }

    /// Navigate up one directory level. Root paths return themselves.
    pub fn parent(&self) -> Arc<Self> {
        Arc::new(Self {
            inner: self.inner.parent(),
        })
    }

    /// Split the path into breadcrumb segments for display.
    pub fn segments(&self) -> Vec<DirectoryPathSegment> {
        self.inner
            .segments()
            .into_iter()
            .map(|(label, full_path)| DirectoryPathSegment { label, full_path })
            .collect()
    }
}
