use crate::MobileClient;
use std::sync::Arc;
use std::sync::OnceLock;
static SHARED_RUNTIME: OnceLock<Arc<tokio::runtime::Runtime>> = OnceLock::new();
static SHARED_MOBILE_CLIENT: OnceLock<Arc<MobileClient>> = OnceLock::new();
static PLATFORM_INIT: OnceLock<()> = OnceLock::new();

fn ensure_platform_init() {
    PLATFORM_INIT.get_or_init(|| {
        #[cfg(all(target_os = "ios", not(target_abi = "macabi")))]
        crate::ish_exec::install();
    });
}

pub(crate) fn shared_runtime() -> Arc<tokio::runtime::Runtime> {
    ensure_platform_init();
    SHARED_RUNTIME
        .get_or_init(|| {
            crate::logging::install_tracing_subscriber();
            Arc::new(
                tokio::runtime::Builder::new_multi_thread()
                    // iOS can hand us very small default thread stacks; large
                    // recorded/replayed payloads can overflow them during serde.
                    .thread_stack_size(crate::MOBILE_ASYNC_THREAD_STACK_SIZE_BYTES)
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

/// Non-initializing peek at the singleton. Returns `None` when
/// `MobileClient` hasn't been constructed yet — used by side-channel
/// emitters (e.g. `saved_apps::notify_saved_apps_changed`) that need
/// to broadcast on the reducer but must NOT force a full client
/// bootstrap when called from a `#[cfg(test)]` context that never
/// went through `AppClient::new`.
pub(crate) fn shared_mobile_client_if_initialized() -> Option<Arc<MobileClient>> {
    SHARED_MOBILE_CLIENT.get().cloned()
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
