use std::error::Error as StdError;

#[derive(Debug, thiserror::Error)]
pub enum OpenCodeBridgeError {
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),

    #[error("url: {0}")]
    Url(#[from] url::ParseError),

    #[error("http transport failed for {endpoint}: {source}")]
    HttpTransport {
        endpoint: &'static str,
        retryable: bool,
        #[source]
        source: reqwest::Error,
    },

    #[error("http {status} for {endpoint}: {message}")]
    HttpStatus {
        endpoint: &'static str,
        status: reqwest::StatusCode,
        retryable: bool,
        message: String,
        body: Option<String>,
    },

    #[error("invalid response from {endpoint}: {source}")]
    InvalidResponse {
        endpoint: &'static str,
        body: Option<String>,
        #[source]
        source: serde_json::Error,
    },

    #[error("sse connect failed for {endpoint}: {source}")]
    SseConnect {
        endpoint: &'static str,
        retryable: bool,
        #[source]
        source: Box<dyn StdError + Send + Sync>,
    },

    #[error("sse read failed for {endpoint}: {source}")]
    SseRead {
        endpoint: &'static str,
        retryable: bool,
        #[source]
        source: Box<dyn StdError + Send + Sync>,
    },

    #[error("invalid sse protocol from {endpoint}: {message}")]
    SseProtocol {
        endpoint: &'static str,
        message: String,
        raw: Option<String>,
    },

    #[error("invalid event payload from {endpoint}: {source}")]
    InvalidEvent {
        endpoint: &'static str,
        raw: String,
        #[source]
        source: serde_json::Error,
    },

    #[error("directory is required for {operation}")]
    MissingDirectory { operation: &'static str },

    #[error("directory context is required for {operation}")]
    MissingDirectoryContext { operation: &'static str },

    #[error("directory cannot be empty for {operation}")]
    EmptyDirectory { operation: &'static str },

    #[error("session context is required for {operation}")]
    MissingSessionContext { operation: &'static str },

    #[error("unsupported event in {operation}: {event_type}")]
    UnsupportedEvent {
        operation: &'static str,
        event_type: String,
        raw: Option<String>,
    },

    #[error("unsupported message part in {operation}: {part_type}")]
    UnsupportedPart {
        operation: &'static str,
        part_type: String,
        raw: Option<String>,
    },

    #[error("invalid mapped payload for {operation}: {message}")]
    InvalidMappedPayload {
        operation: &'static str,
        message: String,
        raw: Option<String>,
    },

    #[error("unsupported capability: {0}")]
    UnsupportedCapability(&'static str),
}

impl OpenCodeBridgeError {
    pub fn retryable(&self) -> bool {
        match self {
            Self::HttpTransport { retryable, .. }
            | Self::HttpStatus { retryable, .. }
            | Self::SseConnect { retryable, .. }
            | Self::SseRead { retryable, .. } => *retryable,
            _ => false,
        }
    }

    pub(crate) fn transport(endpoint: &'static str, source: reqwest::Error) -> Self {
        Self::HttpTransport {
            endpoint,
            retryable: source.is_timeout() || source.is_connect() || source.is_body(),
            source,
        }
    }

    pub(crate) fn status(
        endpoint: &'static str,
        status: reqwest::StatusCode,
        message: String,
        body: Option<String>,
    ) -> Self {
        Self::HttpStatus {
            endpoint,
            status,
            retryable: matches!(
                status,
                reqwest::StatusCode::REQUEST_TIMEOUT
                    | reqwest::StatusCode::TOO_EARLY
                    | reqwest::StatusCode::TOO_MANY_REQUESTS
                    | reqwest::StatusCode::INTERNAL_SERVER_ERROR
                    | reqwest::StatusCode::BAD_GATEWAY
                    | reqwest::StatusCode::SERVICE_UNAVAILABLE
                    | reqwest::StatusCode::GATEWAY_TIMEOUT
            ),
            message,
            body,
        }
    }

    pub(crate) fn invalid_response(
        endpoint: &'static str,
        body: Option<String>,
        source: serde_json::Error,
    ) -> Self {
        Self::InvalidResponse {
            endpoint,
            body,
            source,
        }
    }

    pub(crate) fn sse_connect<E>(endpoint: &'static str, retryable: bool, source: E) -> Self
    where
        E: StdError + Send + Sync + 'static,
    {
        Self::SseConnect {
            endpoint,
            retryable,
            source: Box::new(source),
        }
    }

    pub(crate) fn sse_connect_transport(endpoint: &'static str, source: reqwest::Error) -> Self {
        Self::sse_connect(endpoint, source.is_timeout() || source.is_connect(), source)
    }

    pub(crate) fn sse_read<E>(endpoint: &'static str, retryable: bool, source: E) -> Self
    where
        E: StdError + Send + Sync + 'static,
    {
        Self::SseRead {
            endpoint,
            retryable,
            source: Box::new(source),
        }
    }

    pub(crate) fn sse_read_transport(endpoint: &'static str, source: reqwest::Error) -> Self {
        Self::sse_read(endpoint, true, source)
    }

    pub(crate) fn sse_protocol(
        endpoint: &'static str,
        message: impl Into<String>,
        raw: Option<String>,
    ) -> Self {
        Self::SseProtocol {
            endpoint,
            message: message.into(),
            raw,
        }
    }

    pub(crate) fn invalid_event(
        endpoint: &'static str,
        raw: impl Into<String>,
        source: serde_json::Error,
    ) -> Self {
        Self::InvalidEvent {
            endpoint,
            raw: raw.into(),
            source,
        }
    }
}
