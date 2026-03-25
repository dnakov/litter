//! Error types for the Codex IPC protocol.

/// Top-level error type for IPC operations.
#[derive(Debug, thiserror::Error)]
pub enum IpcError {
    #[error("transport: {0}")]
    Transport(#[from] TransportError),

    #[error("protocol: {0}")]
    Protocol(String),

    #[error("request failed: {0}")]
    Request(#[from] RequestError),

    #[error("not connected")]
    NotConnected,

    #[error("initialization failed: {0}")]
    InitializationFailed(String),
}

/// Transport-level errors (framing, I/O, serialization).
#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),

    #[error("frame too large: {size} bytes (max {max})")]
    FrameTooLarge { size: u32, max: u32 },

    #[error("invalid utf-8 in frame")]
    InvalidUtf8,

    #[error("json: {0}")]
    Json(#[from] serde_json::Error),

    #[error("connection closed")]
    ConnectionClosed,
}

/// Request-level errors returned by the router or remote client.
#[derive(Debug, thiserror::Error)]
pub enum RequestError {
    #[error("request timed out")]
    Timeout,

    #[error("no handler for request")]
    NoHandler,

    #[error("no client found")]
    NoClientFound,

    #[error("client disconnected")]
    ClientDisconnected,

    #[error("version mismatch")]
    VersionMismatch,

    #[error("server error: {0}")]
    ServerError(String),
}

impl RequestError {
    /// Parse a wire-format error string into a typed error.
    pub fn from_wire(s: &str) -> Self {
        match s {
            "request-timeout" => Self::Timeout,
            "no-handler-for-request" => Self::NoHandler,
            "no-client-found" => Self::NoClientFound,
            "client-disconnected" => Self::ClientDisconnected,
            "request-version-mismatch" => Self::VersionMismatch,
            other => Self::ServerError(other.to_string()),
        }
    }

    /// Convert to the wire-format error string.
    pub fn to_wire(&self) -> &str {
        match self {
            Self::Timeout => "request-timeout",
            Self::NoHandler => "no-handler-for-request",
            Self::NoClientFound => "no-client-found",
            Self::ClientDisconnected => "client-disconnected",
            Self::VersionMismatch => "request-version-mismatch",
            Self::ServerError(s) => s.as_str(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_error_roundtrip() {
        let cases = [
            ("request-timeout", RequestError::Timeout),
            ("no-handler-for-request", RequestError::NoHandler),
            ("no-client-found", RequestError::NoClientFound),
            ("client-disconnected", RequestError::ClientDisconnected),
            ("request-version-mismatch", RequestError::VersionMismatch),
        ];

        for (wire, expected) in &cases {
            let parsed = RequestError::from_wire(wire);
            assert_eq!(parsed.to_wire(), *wire);
            assert_eq!(
                std::mem::discriminant(&parsed),
                std::mem::discriminant(expected)
            );
        }
    }

    #[test]
    fn unknown_wire_error_becomes_server_error() {
        let err = RequestError::from_wire("something-unexpected");
        assert!(matches!(err, RequestError::ServerError(s) if s == "something-unexpected"));
    }
}
