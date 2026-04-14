use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeCapabilities {
    pub supports_streaming: bool,
    pub supports_abort: bool,
    pub supports_fork: bool,
    pub supports_rename: bool,
    pub supports_delete: bool,
    pub supports_archive: bool,
    pub supports_permissions: bool,
    pub supports_directory_scoped_sessions: bool,
    pub supports_global_event_stream: bool,
    pub supports_file_search: bool,
    pub supports_provider_login: bool,
}

impl OpenCodeCapabilities {
    pub fn phase1_defaults() -> Self {
        Self {
            supports_streaming: true,
            supports_abort: true,
            supports_fork: true,
            supports_rename: true,
            supports_delete: true,
            supports_archive: false,
            supports_permissions: true,
            supports_directory_scoped_sessions: true,
            supports_global_event_stream: true,
            supports_file_search: true,
            supports_provider_login: false,
        }
    }
}

impl Default for OpenCodeCapabilities {
    fn default() -> Self {
        Self::phase1_defaults()
    }
}
