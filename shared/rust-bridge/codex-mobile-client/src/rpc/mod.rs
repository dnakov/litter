use std::sync::atomic::{AtomicI64, Ordering};

static REQUEST_COUNTER: AtomicI64 = AtomicI64::new(1);

pub(crate) fn next_request_id() -> i64 {
    REQUEST_COUNTER.fetch_add(1, Ordering::Relaxed)
}

#[derive(Debug, thiserror::Error)]
pub enum RpcClientError {
    #[error("RPC: {0}")]
    Rpc(String),
    #[error("Serialization: {0}")]
    Serialization(String),
}

pub(crate) use generated_client::convert_generated_field;

#[path = "generated_client.rs"]
pub(crate) mod generated_client;
