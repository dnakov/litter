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
}

impl From<crate::rpc::RpcClientError> for ClientError {
    fn from(value: crate::rpc::RpcClientError) -> Self {
        match value {
            crate::rpc::RpcClientError::Rpc(message) => ClientError::Rpc(message),
            crate::rpc::RpcClientError::Serialization(message) => {
                ClientError::Serialization(message)
            }
        }
    }
}
