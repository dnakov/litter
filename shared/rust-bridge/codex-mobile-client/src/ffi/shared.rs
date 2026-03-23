use crate::MobileClient;
use std::sync::Arc;
use std::sync::OnceLock;
static SHARED_RUNTIME: OnceLock<Arc<tokio::runtime::Runtime>> = OnceLock::new();
static SHARED_MOBILE_CLIENT: OnceLock<Arc<MobileClient>> = OnceLock::new();

pub(crate) fn shared_runtime() -> Arc<tokio::runtime::Runtime> {
    SHARED_RUNTIME
        .get_or_init(|| {
            Arc::new(
                tokio::runtime::Builder::new_multi_thread()
                    .enable_all()
                    .build()
                    .expect("failed to create tokio runtime"),
            )
        })
        .clone()
}

pub(crate) fn shared_mobile_client() -> Arc<MobileClient> {
    SHARED_MOBILE_CLIENT
        .get_or_init(|| Arc::new(MobileClient::new()))
        .clone()
}

macro_rules! blocking_async {
    ($rt:expr, $inner:expr, |$client:ident| $body:expr) => {{
        let rt = Arc::clone(&$rt);
        let inner = Arc::clone(&$inner);
        tokio::task::spawn_blocking(move || {
            let $client = &inner;
            rt.block_on(async { $body })
        })
        .await
        .map_err(|e| crate::ffi::ClientError::Rpc(format!("task join error: {e}")))?
    }};
}

pub(crate) use blocking_async;
