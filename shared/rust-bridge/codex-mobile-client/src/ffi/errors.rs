#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ClientError {
    #[error("Transport: {0}")]
    Transport(String),
    #[error("RPC: {0}")]
    Rpc(String),
    #[error("Invalid params: {0}")]
    InvalidParams(String),
    #[error("Serialization: {0}")]
    Serialization(String),
    #[error("Event stream closed: {0}")]
    EventClosed(String),
    #[error("Minigame generation failed: {0}")]
    MinigameGenerationFailed(String),
}

impl From<crate::RpcClientError> for ClientError {
    fn from(value: crate::RpcClientError) -> Self {
        match value {
            crate::RpcClientError::Rpc(message) => ClientError::Rpc(message),
            crate::RpcClientError::Serialization(message) => ClientError::Serialization(message),
        }
    }
}
