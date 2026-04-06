use crate::MobileClient;
use codex_utils_rustls_provider::ensure_rustls_crypto_provider;
use std::sync::Arc;
use std::sync::OnceLock;
static SHARED_RUNTIME: OnceLock<Arc<tokio::runtime::Runtime>> = OnceLock::new();
static SHARED_MOBILE_CLIENT: OnceLock<Arc<MobileClient>> = OnceLock::new();
static PLATFORM_INIT: OnceLock<()> = OnceLock::new();

fn ensure_platform_init() {
    PLATFORM_INIT.get_or_init(|| {
        ensure_rustls_crypto_provider();
        #[cfg(target_os = "ios")]
        crate::ios_exec::install();
    });
}

pub(crate) fn shared_runtime() -> Arc<tokio::runtime::Runtime> {
    ensure_platform_init();
    SHARED_RUNTIME
        .get_or_init(|| {
            crate::logging::install_tracing_subscriber();
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
    ensure_platform_init();
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
