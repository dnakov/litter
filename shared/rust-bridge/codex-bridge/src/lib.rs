use codex_app_server::AppServerTransport;
use codex_app_server::in_process::{InProcessClientSender, InProcessServerEvent, InProcessStartArgs};
use codex_app_server::run_main_with_transport;
use codex_app_server_protocol::{
    ClientNotification, ClientRequest, InitializeCapabilities, InitializeParams,
    ClientInfo, RequestId, SessionSource,
};
use codex_cloud_requirements::cloud_requirements_loader;
use codex_core::auth::AuthManager;
use codex_core::config::ConfigBuilder;
use codex_core::config_loader::LoaderOverrides;
use codex_feedback::CodexFeedback;
use codex_utils_cli::CliConfigOverrides;
use std::ffi::c_void;
use std::fs;
use std::net::SocketAddr;
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};
use tokio::runtime::Runtime;

#[cfg(target_os = "ios")]
mod ios_exec;
#[cfg(target_os = "android")]
mod android_jni;

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("failed to create tokio runtime")
    })
}

/// Start the codex app-server on an available loopback port.
/// Writes the actual port to `*out_port`.
/// Returns 0 on success, negative on failure.
#[unsafe(no_mangle)]
pub extern "C" fn codex_start_server(out_port: *mut u16) -> i32 {
    init_codex_home();
    #[cfg(target_os = "ios")]
    init_tls_roots();

    let port = match std::net::TcpListener::bind("127.0.0.1:0")
        .and_then(|l| l.local_addr())
        .map(|a| a.port())
    {
        Ok(p) => p,
        Err(_) => return -1,
    };

    unsafe { *out_port = port; }

    #[cfg(target_os = "ios")]
    {
        ios_exec::init();
        codex_core::exec::set_ios_exec_hook(ios_exec::run_command);
    }

    let bind_address: SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();
    eprintln!("[codex-bridge] starting server on {bind_address}");

    runtime().spawn(async move {
        let handle = runtime().spawn(async move {
            run_main_with_transport(
                Default::default(),
                CliConfigOverrides::default(),
                LoaderOverrides::default(),
                false,
                AppServerTransport::WebSocket { bind_address },
            )
            .await
        });

        match handle.await {
            Ok(Ok(())) => eprintln!("[codex-bridge] server exited normally"),
            Ok(Err(e)) => eprintln!("[codex-bridge] server error: {e}"),
            Err(join_err) if join_err.is_panic() => {
                eprintln!("[codex-bridge] server PANICKED: {join_err}");
            }
            Err(join_err) => eprintln!("[codex-bridge] server task error: {join_err}"),
        }
    });

    // Block until the server is actually accepting connections.
    let ready = runtime().block_on(async {
        for _ in 0..300 {
            if tokio::net::TcpStream::connect(bind_address).await.is_ok() {
                return true;
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        false
    });

    if ready { 0 } else { -2 }
}

/// Stop the codex app-server. Currently a no-op; connections close naturally.
#[unsafe(no_mangle)]
pub extern "C" fn codex_stop_server() {}

// ---------------------------------------------------------------------------
// In-process channel transport (no WebSocket, no TCP)
// ---------------------------------------------------------------------------

/// Callback invoked from a background thread for every server-to-client message.
/// `json` is a UTF-8 JSON-RPC line. The callback must not block.
type MessageCallback = unsafe extern "C" fn(ctx: *mut c_void, json: *const c_char, json_len: usize);

/// Opaque state held behind the FFI handle pointer.
struct ChannelState {
    sender: InProcessClientSender,
    cb_handle: CallbackHandle,
    event_task: tokio::task::JoinHandle<()>,
    request_tasks: std::sync::Mutex<Vec<tokio::task::JoinHandle<()>>>,
}

// SAFETY: callback_ctx is a Swift-side pointer that must remain valid for the
// lifetime of the channel. Swift ensures this by preventing deallocation of the
// callback receiver until codex_channel_close is called.
unsafe impl Send for ChannelState {}
unsafe impl Sync for ChannelState {}

/// Send-safe wrapper for delivering JSON messages to the Swift callback.
/// Bundles the function pointer and context pointer together.
#[derive(Clone, Copy)]
struct CallbackHandle {
    cb: MessageCallback,
    ctx: *mut c_void,
}
unsafe impl Send for CallbackHandle {}
unsafe impl Sync for CallbackHandle {}

impl CallbackHandle {
    unsafe fn deliver(&self, json: &str) {
        unsafe { (self.cb)(self.ctx, json.as_ptr() as *const c_char, json.len()); }
    }
}

fn serialize_server_event(event: &InProcessServerEvent) -> Option<String> {
    match event {
        InProcessServerEvent::ServerRequest(req) => serde_json::to_string(req).ok(),
        InProcessServerEvent::ServerNotification(notif) => serde_json::to_string(notif).ok(),
        InProcessServerEvent::LegacyNotification(notif) => serde_json::to_string(notif).ok(),
        InProcessServerEvent::Lagged { skipped } => {
            eprintln!("[codex-channel] dropped {skipped} events due to backpressure");
            None
        }
    }
}


/// Open an in-process channel to the codex app-server.
/// Performs the initialize handshake internally.
/// On success writes an opaque handle to `*out_handle` and returns 0.
#[unsafe(no_mangle)]
pub extern "C" fn codex_channel_open(
    callback: MessageCallback,
    callback_ctx: *mut c_void,
    out_handle: *mut *mut c_void,
) -> i32 {
    init_codex_home();
    #[cfg(target_os = "ios")]
    init_tls_roots();
    #[cfg(target_os = "ios")]
    {
        ios_exec::init();
        codex_core::exec::set_ios_exec_hook(ios_exec::run_command);
    }

    eprintln!("[codex-channel] opening in-process channel");

    let result: Result<ChannelState, String> = runtime().block_on(async {
        #[cfg(target_os = "ios")]
        let cli_overrides = CliConfigOverrides {
            // The staged iOS core currently exposes unified-exec without working
            // session semantics. Keep one-shot shell execution available, but
            // suppress the model-facing exec_command/write_stdin tools locally.
            raw_overrides: vec!["features.unified_exec=false".to_string()],
        }
        .parse_overrides()
        .map_err(|e| format!("config override parse failed: {e}"))?;
        #[cfg(not(target_os = "ios"))]
        let cli_overrides = Vec::new();

        // Build config with defaults (mirrors run_main_with_transport's setup).
        let config = ConfigBuilder::default()
            .cli_overrides(cli_overrides.clone())
            .build()
            .await
            .map_err(|e| format!("config build failed: {e}"))?;

        let cloud_requirements = {
            let auth_manager = AuthManager::shared(
                config.codex_home.clone(),
                false,
                config.cli_auth_credentials_store_mode,
            );
            cloud_requirements_loader(
                auth_manager,
                config.chatgpt_base_url.clone(),
                config.codex_home.clone(),
            )
        };

        // Rebuild with cloud requirements for full config resolution.
        let config = ConfigBuilder::default()
            .cli_overrides(cli_overrides)
            .cloud_requirements(cloud_requirements.clone())
            .build()
            .await
            .unwrap_or(config);

        let feedback = CodexFeedback::new();

        let args = InProcessStartArgs {
            arg0_paths: Default::default(),
            config: Arc::new(config),
            cli_overrides: Vec::new(),
            loader_overrides: LoaderOverrides::default(),
            cloud_requirements,
            feedback,
            config_warnings: Vec::new(),
            session_source: SessionSource::VsCode.into(),
            enable_codex_api_key_env: false,
            initialize: InitializeParams {
                client_info: ClientInfo {
                    name: "Litter".to_string(),
                    version: "1.0".to_string(),
                    title: None,
                },
                capabilities: Some(InitializeCapabilities {
                    experimental_api: true,
                    opt_out_notification_methods: None,
                }),
            },
            channel_capacity: 256,
        };

        // start() performs the initialize/initialized handshake internally.
        let mut handle = codex_app_server::in_process::start(args)
            .await
            .map_err(|e| format!("in-process start failed: {e}"))?;

        // Split: sender is cloneable and used for sends; handle owns the event_rx.
        let sender = handle.sender();

        // Spawn the event loop that delivers server events to Swift via callback.
        let cb_handle = CallbackHandle { cb: callback, ctx: callback_ctx };
        let event_task = runtime().spawn(async move {
            while let Some(event) = handle.next_event().await {
                if let Some(json) = serialize_server_event(&event) {
                    unsafe { cb_handle.deliver(&json); }
                }
            }
            eprintln!("[codex-channel] event stream ended");
        });

        Ok(ChannelState {
            sender,
            cb_handle: CallbackHandle { cb: callback, ctx: callback_ctx },
            event_task,
            request_tasks: std::sync::Mutex::new(Vec::new()),
        })
    });

    match result {
        Ok(state) => {
            let boxed = Box::new(state);
            unsafe { *out_handle = Box::into_raw(boxed) as *mut c_void; }
            eprintln!("[codex-channel] channel opened successfully");
            0
        }
        Err(e) => {
            eprintln!("[codex-channel] failed to open: {e}");
            -1
        }
    }
}

/// Send a JSON-RPC message from client to server.
/// Returns 0 on success, negative on failure (-4 for parse error, -5 for send error).
#[unsafe(no_mangle)]
pub extern "C" fn codex_channel_send(
    handle: *mut c_void,
    json: *const c_char,
    json_len: usize,
) -> i32 {
    if handle.is_null() || json.is_null() {
        return -1;
    }

    let state = unsafe { &*(handle as *const ChannelState) };
    let json_bytes = unsafe { std::slice::from_raw_parts(json as *const u8, json_len) };
    let json_str = match std::str::from_utf8(json_bytes) {
        Ok(s) => s,
        Err(_) => return -2,
    };

    let value: serde_json::Value = match serde_json::from_str(json_str) {
        Ok(v) => v,
        Err(_) => return -3,
    };

    let has_id = value.get("id").is_some();
    let has_method = value.get("method").is_some();
    let has_result = value.get("result").is_some();
    let has_error = value.get("error").is_some();

    if has_method && has_id {
        // Client request — fire-and-forget, response delivered via callback.
        let request: ClientRequest = match serde_json::from_value(value.clone()) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("[codex-channel] failed to parse request: {e}");
                return -4;
            }
        };

        let request_id = value["id"].clone();
        let sender = state.sender.clone();
        let cb_handle = state.cb_handle;

        let request_task = runtime().spawn(async move {
            match sender.request(request).await {
                Ok(result) => {
                    let response = match result {
                        Ok(value) => serde_json::json!({
                            "jsonrpc": "2.0",
                            "id": request_id,
                            "result": value,
                        }),
                        Err(error) => serde_json::json!({
                            "jsonrpc": "2.0",
                            "id": request_id,
                            "error": {
                                "code": error.code,
                                "message": error.message,
                            },
                        }),
                    };
                    if let Ok(json) = serde_json::to_string(&response) {
                        unsafe { cb_handle.deliver(&json); }
                    }
                }
                Err(e) => {
                    eprintln!("[codex-channel] send request failed: {e}");
                    let error_response = serde_json::json!({
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "error": { "code": -32603, "message": e.to_string() },
                    });
                    if let Ok(json) = serde_json::to_string(&error_response) {
                        unsafe { cb_handle.deliver(&json); }
                    }
                }
            }
        });

        if let Ok(mut tasks) = state.request_tasks.lock() {
            tasks.push(request_task);
        } else {
            request_task.abort();
            return -5;
        }

        0
    } else if has_method && !has_id {
        // Client notification
        let notification: ClientNotification = match serde_json::from_value(value) {
            Ok(n) => n,
            Err(e) => {
                eprintln!("[codex-channel] failed to parse notification: {e}");
                return -4;
            }
        };

        match state.sender.notify(notification) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("[codex-channel] notify failed: {e}");
                -5
            }
        }
    } else if has_id && (has_result || has_error) {
        // Response to a server request
        let id = match &value["id"] {
            serde_json::Value::Number(n) => RequestId::Integer(n.as_i64().unwrap_or(0)),
            serde_json::Value::String(s) => RequestId::String(s.clone()),
            _ => return -6,
        };

        if has_result {
            let result: codex_app_server_protocol::Result = value["result"].clone();
            match state.sender.respond_to_server_request(id, result) {
                Ok(()) => 0,
                Err(e) => {
                    eprintln!("[codex-channel] respond failed: {e}");
                    -5
                }
            }
        } else {
            let error = codex_app_server_protocol::JSONRPCErrorError {
                code: value["error"]["code"].as_i64().unwrap_or(-1),
                message: value["error"]["message"].as_str().unwrap_or("unknown").to_string(),
                data: value["error"]["data"].clone().into(),
            };
            match state.sender.fail_server_request(id, error) {
                Ok(()) => 0,
                Err(e) => {
                    eprintln!("[codex-channel] fail_server_request failed: {e}");
                    -5
                }
            }
        }
    } else {
        eprintln!("[codex-channel] unrecognized JSON-RPC message shape");
        -6
    }
}

/// Close the channel and release resources.
#[unsafe(no_mangle)]
pub extern "C" fn codex_channel_close(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let state = unsafe { Box::from_raw(handle as *mut ChannelState) };
    let ChannelState {
        sender: _sender,
        cb_handle: _cb_handle,
        event_task,
        request_tasks,
    } = *state;

    let mut request_tasks = match request_tasks.into_inner() {
        Ok(tasks) => tasks,
        Err(poisoned) => poisoned.into_inner(),
    };

    event_task.abort();
    for task in &request_tasks {
        task.abort();
    }

    runtime().block_on(async move {
        let _ = event_task.await;
        for task in request_tasks.drain(..) {
            let _ = task.await;
        }
    });
    eprintln!("[codex-channel] channel closed");
}

fn init_codex_home() {
    let mut candidates: Vec<PathBuf> = Vec::new();

    if let Ok(existing) = std::env::var("CODEX_HOME") {
        candidates.push(PathBuf::from(existing));
    }

    if let Ok(home) = std::env::var("HOME") {
        let home = PathBuf::from(home);
        #[cfg(target_os = "ios")]
        {
            candidates.push(home.join("Library").join("Application Support").join("codex"));
            candidates.push(home.join("Documents").join(".codex"));
        }
        candidates.push(home.join(".codex"));
    }

    if let Ok(tmpdir) = std::env::var("TMPDIR") {
        candidates.push(PathBuf::from(tmpdir).join("codex-home"));
    }

    for codex_home in candidates {
        match fs::create_dir_all(&codex_home) {
            Ok(()) => {
                // SAFETY: called before app-server runtime starts handling requests.
                unsafe {
                    std::env::set_var("CODEX_HOME", &codex_home);
                }
                eprintln!("[codex-bridge] CODEX_HOME={}", codex_home.display());
                return;
            }
            Err(err) => {
                eprintln!(
                    "[codex-bridge] failed to create CODEX_HOME candidate {:?}: {err}",
                    codex_home
                );
            }
        }
    }

    eprintln!("[codex-bridge] unable to initialize any writable CODEX_HOME location");
}

#[cfg(target_os = "ios")]
fn init_tls_roots() {
    if std::env::var("SSL_CERT_FILE").is_ok() {
        return;
    }

    let codex_home = match std::env::var("CODEX_HOME") {
        Ok(h) => PathBuf::from(h),
        Err(_) => return,
    };
    let pem_path = codex_home.join("cacert.pem");
    if !pem_path.exists() {
        static CACERT_PEM: &[u8] = include_bytes!("cacert.pem");
        if let Err(e) = fs::write(&pem_path, CACERT_PEM) {
            eprintln!("[codex-bridge] failed to write cacert.pem: {e}");
            return;
        }
    }
    unsafe { std::env::set_var("SSL_CERT_FILE", &pem_path); }
    eprintln!("[codex-bridge] SSL_CERT_FILE={}", pem_path.display());
}
