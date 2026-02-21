use codex_app_server::AppServerTransport;
use codex_app_server::run_main_with_transport;
use codex_core::config_loader::LoaderOverrides;
use codex_utils_cli::CliConfigOverrides;
use std::fs;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::OnceLock;
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
                None,
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
