//! SSH bootstrap client for remote server setup.
//!
//! Pure Rust SSH2 client (via `russh`) that replaces platform-specific
//! SSH libraries (Citadel on iOS, JSch on Android).

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use futures::future::BoxFuture;
use russh::ChannelMsg;
use russh::ChannelStream;
use russh::client::{self, Handle, Msg};
use russh_keys::decode_secret_key;
use russh_keys::{HashAlg, PublicKey};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tokio_tungstenite::connect_async;
use tracing::{debug, error, info, warn};

#[cfg(target_os = "android")]
fn append_android_debug_log(line: &str) {
    use std::io::Write;

    let Some(codex_home) = std::env::var_os("CODEX_HOME") else {
        return;
    };
    let path = std::path::PathBuf::from(codex_home).join("mobile-debug.log");
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(file, "{line}");
    }
}

#[cfg(not(target_os = "android"))]
fn append_android_debug_log(_line: &str) {}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Credentials for establishing an SSH connection.
#[derive(Clone)]
pub struct SshCredentials {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth: SshAuth,
}

/// Authentication method.
#[derive(Clone)]
pub enum SshAuth {
    Password(String),
    PrivateKey {
        key_pem: String,
        passphrase: Option<String>,
    },
}

/// Result of a successful `bootstrap_codex_server` call.
#[derive(Debug, Clone)]
pub struct SshBootstrapResult {
    pub server_port: u16,
    pub tunnel_local_port: u16,
    pub server_version: Option<String>,
    pub pid: Option<u32>,
}

/// Outcome of running a remote command.
#[derive(Debug, Clone)]
pub struct ExecResult {
    pub exit_code: u32,
    pub stdout: String,
    pub stderr: String,
}

/// SSH-specific errors.
#[derive(Debug, thiserror::Error)]
pub enum SshError {
    #[error("connection failed: {0}")]
    ConnectionFailed(String),
    #[error("auth failed: {0}")]
    AuthFailed(String),
    #[error("host key verification failed: fingerprint {fingerprint}")]
    HostKeyVerification { fingerprint: String },
    #[error("command failed (exit {exit_code}): {stderr}")]
    ExecFailed { exit_code: u32, stderr: String },
    #[error("port forward failed: {0}")]
    PortForwardFailed(String),
    #[error("timeout")]
    Timeout,
    #[error("disconnected")]
    Disconnected,
}

// ---------------------------------------------------------------------------
// russh Handler (internal)
// ---------------------------------------------------------------------------

type HostKeyCallback = Arc<dyn Fn(&str) -> BoxFuture<'static, bool> + Send + Sync>;

struct ClientHandler {
    host_key_cb: HostKeyCallback,
    /// If the callback rejects the key we store the fingerprint so we can
    /// surface it in [`SshError::HostKeyVerification`].
    rejected_fingerprint: Arc<Mutex<Option<String>>>,
}

#[async_trait]
impl client::Handler for ClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKey,
    ) -> Result<bool, Self::Error> {
        let fp = format!("{}", server_public_key.fingerprint(HashAlg::Sha256));
        let accepted = (self.host_key_cb)(&fp).await;
        if !accepted {
            *self.rejected_fingerprint.lock().await = Some(fp);
        }
        Ok(accepted)
    }
}

// ---------------------------------------------------------------------------
// SshClient
// ---------------------------------------------------------------------------

/// A connected SSH session that can execute commands, upload files,
/// forward ports, and bootstrap a remote Codex server.
pub struct SshClient {
    /// The underlying russh handle, behind Arc<Mutex> so port-forwarding
    /// background tasks can open channels.
    handle: Arc<Mutex<Handle<ClientHandler>>>,
    /// Tracks forwarding background tasks so we can abort on disconnect.
    forward_tasks: Mutex<Vec<tokio::task::JoinHandle<()>>>,
}

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const EXEC_TIMEOUT: Duration = Duration::from_secs(30);
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(15);

/// Default base port for remote Codex server (matches Android).
const DEFAULT_REMOTE_PORT: u16 = 8390;
/// Number of candidate ports to try.
const PORT_CANDIDATES: u16 = 21;

impl SshClient {
    /// Open an SSH connection to `credentials.host:credentials.port`.
    ///
    /// `host_key_callback` is invoked with the SHA-256 fingerprint of the
    /// server's public key. Return `true` to accept, `false` to reject.
    pub async fn connect(
        credentials: SshCredentials,
        host_key_callback: Box<dyn Fn(&str) -> BoxFuture<'static, bool> + Send + Sync>,
    ) -> Result<Self, SshError> {
        let rejected_fp = Arc::new(Mutex::new(None));

        let handler = ClientHandler {
            host_key_cb: Arc::from(host_key_callback),
            rejected_fingerprint: Arc::clone(&rejected_fp),
        };

        let config = client::Config {
            keepalive_interval: Some(KEEPALIVE_INTERVAL),
            keepalive_max: 3,
            inactivity_timeout: None,
            ..Default::default()
        };

        let addr = format!("{}:{}", normalize_host(&credentials.host), credentials.port);

        let mut handle = tokio::time::timeout(
            CONNECT_TIMEOUT,
            client::connect(Arc::new(config), &*addr, handler),
        )
        .await
        .map_err(|_| SshError::Timeout)?
        .map_err(|e| SshError::ConnectionFailed(format!("{e}")))?;

        // If the handler rejected the key, surface a specific error.
        if let Some(fp) = rejected_fp.lock().await.take() {
            return Err(SshError::HostKeyVerification { fingerprint: fp });
        }

        // --- Authenticate -----------------------------------------------
        let auth_ok = match &credentials.auth {
            SshAuth::Password(pw) => handle
                .authenticate_password(&credentials.username, pw)
                .await
                .map_err(|e| SshError::AuthFailed(format!("{e}")))?,
            SshAuth::PrivateKey {
                key_pem,
                passphrase,
            } => {
                let key = decode_secret_key(key_pem, passphrase.as_deref())
                    .map_err(|e| SshError::AuthFailed(format!("bad private key: {e}")))?;
                handle
                    .authenticate_publickey(&credentials.username, Arc::new(key))
                    .await
                    .map_err(|e| SshError::AuthFailed(format!("{e}")))?
            }
        };

        if !auth_ok {
            return Err(SshError::AuthFailed("server rejected credentials".into()));
        }

        info!("SSH connected and authenticated to {addr}");

        Ok(Self {
            handle: Arc::new(Mutex::new(handle)),
            forward_tasks: Mutex::new(Vec::new()),
        })
    }

    // --------------------------------------------------------------------
    // exec
    // --------------------------------------------------------------------

    /// Run a command on the remote host and collect its stdout/stderr.
    pub async fn exec(&self, command: &str) -> Result<ExecResult, SshError> {
        tokio::time::timeout(EXEC_TIMEOUT, self.exec_inner(command))
            .await
            .map_err(|_| SshError::Timeout)?
    }

    async fn exec_inner(&self, command: &str) -> Result<ExecResult, SshError> {
        let handle = self.handle.lock().await;
        if handle.is_closed() {
            return Err(SshError::Disconnected);
        }
        let mut channel = handle
            .channel_open_session()
            .await
            .map_err(|e| SshError::ConnectionFailed(format!("open session: {e}")))?;
        drop(handle);

        channel
            .exec(true, command)
            .await
            .map_err(|e| SshError::ConnectionFailed(format!("exec: {e}")))?;

        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let mut exit_code: u32 = 0;

        loop {
            match channel.wait().await {
                Some(ChannelMsg::Data { data }) => {
                    stdout.extend_from_slice(&data);
                }
                Some(ChannelMsg::ExtendedData { data, ext: 1 }) => {
                    stderr.extend_from_slice(&data);
                }
                Some(ChannelMsg::ExitStatus { exit_status }) => {
                    exit_code = exit_status;
                }
                Some(ChannelMsg::Eof | ChannelMsg::Close) => {
                    // Keep draining until the channel is fully closed.
                }
                None => break,
                _ => {}
            }
        }

        Ok(ExecResult {
            exit_code,
            stdout: String::from_utf8_lossy(&stdout).into_owned(),
            stderr: String::from_utf8_lossy(&stderr).into_owned(),
        })
    }

    // --------------------------------------------------------------------
    // upload
    // --------------------------------------------------------------------

    /// Write `content` to a remote file at `remote_path` via `cat`.
    ///
    /// This avoids an SFTP dependency — it pipes stdin into a shell command.
    pub async fn upload(&self, content: &[u8], remote_path: &str) -> Result<(), SshError> {
        let handle = self.handle.lock().await;
        if handle.is_closed() {
            return Err(SshError::Disconnected);
        }
        let mut channel = handle
            .channel_open_session()
            .await
            .map_err(|e| SshError::ConnectionFailed(format!("open session: {e}")))?;
        drop(handle);

        let cmd = format!("cat > {}", shell_quote(remote_path));
        channel
            .exec(true, cmd.as_bytes())
            .await
            .map_err(|e| SshError::ConnectionFailed(format!("exec upload: {e}")))?;

        channel
            .data(&content[..])
            .await
            .map_err(|e| SshError::ConnectionFailed(format!("upload data: {e}")))?;

        channel
            .eof()
            .await
            .map_err(|e| SshError::ConnectionFailed(format!("upload eof: {e}")))?;

        let mut exit_code: u32 = 0;
        loop {
            match channel.wait().await {
                Some(ChannelMsg::ExitStatus { exit_status }) => {
                    exit_code = exit_status;
                }
                Some(ChannelMsg::Eof | ChannelMsg::Close) => {}
                None => break,
                _ => {}
            }
        }

        if exit_code != 0 {
            return Err(SshError::ExecFailed {
                exit_code,
                stderr: format!("upload to {remote_path} failed"),
            });
        }

        Ok(())
    }

    // --------------------------------------------------------------------
    // port forwarding
    // --------------------------------------------------------------------

    /// Set up local-to-remote TCP port forwarding.
    ///
    /// Binds a local TCP listener on `local_port` (use 0 for a random port)
    /// and forwards each accepted connection through the SSH tunnel to
    /// `127.0.0.1:remote_port` on the remote host.
    ///
    /// Returns the actual local port that was bound.
    ///
    /// Forwarding runs in background tokio tasks until [`disconnect`] is
    /// called.
    pub async fn forward_port(&self, local_port: u16, remote_port: u16) -> Result<u16, SshError> {
        self.forward_port_to(local_port, "127.0.0.1", remote_port)
            .await
    }

    /// Set up local-to-remote TCP port forwarding to an explicit remote host.
    pub async fn forward_port_to(
        &self,
        local_port: u16,
        remote_host: &str,
        remote_port: u16,
    ) -> Result<u16, SshError> {
        let (actual_port, task) = self
            .spawn_forward_port(local_port, remote_host, remote_port)
            .await?;
        self.forward_tasks.lock().await.push(task);
        Ok(actual_port)
    }

    async fn spawn_forward_port(
        &self,
        local_port: u16,
        remote_host: &str,
        remote_port: u16,
    ) -> Result<(u16, tokio::task::JoinHandle<()>), SshError> {
        let listener = TcpListener::bind(format!("127.0.0.1:{local_port}"))
            .await
            .map_err(|e| SshError::PortForwardFailed(format!("bind: {e}")))?;

        let actual_port = listener
            .local_addr()
            .map_err(|e| SshError::PortForwardFailed(format!("local_addr: {e}")))?
            .port();

        info!("port forward: 127.0.0.1:{actual_port} -> remote {remote_host}:{remote_port}");

        let handle = Arc::clone(&self.handle);
        let remote_host = remote_host.to_string();

        let task = tokio::spawn(async move {
            loop {
                let (local_stream, peer_addr) = match listener.accept().await {
                    Ok(v) => v,
                    Err(e) => {
                        warn!("port forward accept error: {e}");
                        append_android_debug_log(&format!(
                            "ssh_forward_accept_error listen=127.0.0.1:{} remote={}:{} error={}",
                            actual_port, remote_host, remote_port, e
                        ));
                        break;
                    }
                };

                debug!("port forward: accepted connection from {peer_addr}");
                append_android_debug_log(&format!(
                    "ssh_forward_accept listen=127.0.0.1:{} remote={}:{} peer={}",
                    actual_port, remote_host, remote_port, peer_addr
                ));

                let handle = Arc::clone(&handle);
                let remote_host = remote_host.clone();

                tokio::spawn(async move {
                    let ssh_channel = {
                        let h = handle.lock().await;
                        match h
                            .channel_open_direct_tcpip(
                                &remote_host,
                                remote_port as u32,
                                "127.0.0.1",
                                actual_port as u32,
                            )
                            .await
                        {
                            Ok(ch) => ch,
                            Err(e) => {
                                error!("port forward: open direct-tcpip failed: {e}");
                                append_android_debug_log(&format!(
                                    "ssh_forward_direct_tcpip_failed listen=127.0.0.1:{} remote={}:{} peer={} error={}",
                                    actual_port, remote_host, remote_port, peer_addr, e
                                ));
                                return;
                            }
                        }
                    };

                    append_android_debug_log(&format!(
                        "ssh_forward_direct_tcpip_opened listen=127.0.0.1:{} remote={}:{} peer={}",
                        actual_port, remote_host, remote_port, peer_addr
                    ));

                    if let Err(e) = proxy_connection(local_stream, ssh_channel, actual_port, &remote_host, remote_port, peer_addr).await {
                        debug!("port forward proxy ended: {e}");
                        append_android_debug_log(&format!(
                            "ssh_forward_proxy_error listen=127.0.0.1:{} remote={}:{} peer={} error={}",
                            actual_port, remote_host, remote_port, peer_addr, e
                        ));
                    }
                });
            }
        });

        Ok((actual_port, task))
    }

    /// Open a direct streamlocal channel to a remote Unix socket path.
    pub async fn open_streamlocal(
        &self,
        socket_path: &str,
    ) -> Result<ChannelStream<Msg>, SshError> {
        let handle = self.handle.lock().await;
        if handle.is_closed() {
            return Err(SshError::Disconnected);
        }
        let channel = handle
            .channel_open_direct_streamlocal(socket_path)
            .await
            .map_err(|e| {
                SshError::ConnectionFailed(format!("open direct-streamlocal {socket_path}: {e}"))
            })?;
        Ok(channel.into_stream())
    }

    /// Resolve the default remote Codex IPC socket path for the current SSH user.
    pub async fn resolve_remote_ipc_socket_path(&self) -> Result<String, SshError> {
        const SCRIPT: &str = r#"uid="$(id -u 2>/dev/null || printf '0')"
tmp="${TMPDIR:-${TMP:-/tmp}}"
tmp="${tmp%/}"
printf '%s/codex-ipc/ipc-%s.sock' "$tmp" "$uid""#;
        let result = self.exec(SCRIPT).await?;
        let path = result.stdout.trim().to_string();
        if path.is_empty() {
            return Err(SshError::ExecFailed {
                exit_code: result.exit_code,
                stderr: "failed to resolve remote IPC socket path".to_string(),
            });
        }
        Ok(path)
    }

    /// Return the requested IPC socket path if it exists on the remote host.
    pub async fn remote_ipc_socket_if_present(
        &self,
        override_path: Option<&str>,
    ) -> Result<Option<String>, SshError> {
        let socket_path = match override_path {
            Some(path) => path.to_string(),
            None => self.resolve_remote_ipc_socket_path().await?,
        };
        let check = format!(
            "if [ -S {path} ]; then printf '%s' {path}; fi",
            path = shell_quote(&socket_path),
        );
        let result = self.exec(&check).await?;
        if result.exit_code != 0 {
            return Err(SshError::ExecFailed {
                exit_code: result.exit_code,
                stderr: result.stderr,
            });
        }
        let resolved = result.stdout.trim();
        if resolved.is_empty() {
            Ok(None)
        } else {
            Ok(Some(resolved.to_string()))
        }
    }

    // --------------------------------------------------------------------
    // bootstrap
    // --------------------------------------------------------------------

    /// Bootstrap a remote Codex server and set up a local tunnel.
    ///
    /// 1. Locate the `codex` binary on the remote host.
    /// 2. Start a server on a free port.
    /// 3. Wait for it to begin listening.
    /// 4. Set up local port forwarding.
    /// 5. Return the [`SshBootstrapResult`].
    pub async fn bootstrap_codex_server(
        &self,
        working_dir: Option<&str>,
        prefer_ipv6: bool,
    ) -> Result<SshBootstrapResult, SshError> {
        // --- 1. Locate codex binary -------------------------------------
        let codex_binary = self.resolve_codex_binary().await?;
        info!("remote codex binary: {}", codex_binary.path());

        // --- 2. Try candidate ports until one works ---------------------
        let cd_prefix = match working_dir {
            Some(dir) => format!("cd {} && ", shell_quote(dir)),
            None => String::new(),
        };

        for offset in 0..PORT_CANDIDATES {
            let port = DEFAULT_REMOTE_PORT + offset;

            // Do not blindly reuse an already-listening port here. During SSH
            // bootstrap we have no proof that the listener is actually a healthy
            // Codex app-server, and reusing an unrelated or stale process can
            // produce a tunnel that accepts TCP but immediately resets the
            // WebSocket handshake. Skip occupied ports and launch a fresh
            // server on the next free candidate instead.
            if self.is_port_listening(port).await {
                info!("port {port} already listening, skipping occupied candidate");
                continue;
            }

            let listen_addr = if prefer_ipv6 {
                format!("[::]:{port}")
            } else {
                format!("0.0.0.0:{port}")
            };
            let log_path = format!("/tmp/codex-mobile-server-{port}.log");

            let launch_cmd = format!(
                "{profile_init} {cd_prefix}nohup {launch} \
                 </dev/null >{log} 2>&1 & echo $!",
                profile_init = PROFILE_INIT,
                cd_prefix = cd_prefix,
                launch = server_launch_command(&codex_binary, &format!("ws://{listen_addr}")),
                log = shell_quote(&log_path),
            );

            let launch_result = self.exec(&launch_cmd).await?;
            let pid: Option<u32> = launch_result.stdout.trim().parse().ok();

            // --- 3. Wait for the server to start listening ---------------
            let mut started = false;
            for _attempt in 0..60 {
                if self.is_port_listening(port).await {
                    started = true;
                    break;
                }

                // If the process died, check logs for "address already in use".
                if let Some(p) = pid {
                    if !self.is_process_alive(p).await {
                        let tail = self.fetch_log_tail(&log_path).await;
                        if tail.to_ascii_lowercase().contains("address already in use") {
                            break; // try next port
                        }
                        return Err(SshError::ExecFailed {
                            exit_code: 1,
                            stderr: if tail.is_empty() {
                                "server process exited immediately".into()
                            } else {
                                tail
                            },
                        });
                    }
                }

                tokio::time::sleep(Duration::from_millis(500)).await;
            }

            if !started {
                let tail = self.fetch_log_tail(&log_path).await;
                if tail.to_ascii_lowercase().contains("address already in use") {
                    continue; // try next port
                }
                if offset == PORT_CANDIDATES - 1 {
                    return Err(SshError::ExecFailed {
                        exit_code: 1,
                        stderr: if tail.is_empty() {
                            "timed out waiting for remote server to start".into()
                        } else {
                            tail
                        },
                    });
                }
                continue;
            }

            // --- 4. Prove the websocket endpoint is actually ready -------
            let remote_loopback = if prefer_ipv6 { "::1" } else { "127.0.0.1" };
            let (probe_port, probe_task) =
                self.spawn_forward_port(0, remote_loopback, port).await?;
            let websocket_ready = self
                .wait_for_forwarded_websocket_ready(probe_port, pid, &log_path)
                .await;
            probe_task.abort();

            if let Err(error) = websocket_ready {
                warn!("remote websocket readiness probe failed on port {port}: {error}");
                if let Some(p) = pid {
                    let _ = self.exec(&format!("kill {p} 2>/dev/null")).await;
                }
                if offset == PORT_CANDIDATES - 1 {
                    return Err(SshError::ExecFailed {
                        exit_code: 1,
                        stderr: error,
                    });
                }
                continue;
            }

            // --- 5. Set up local port forwarding -------------------------
            let local_port = self.forward_port_to(0, remote_loopback, port).await?;

            // --- 6. Optionally read server version -----------------------
            let version = self.read_server_version(codex_binary.path()).await;

            return Ok(SshBootstrapResult {
                server_port: port,
                tunnel_local_port: local_port,
                server_version: version,
                pid,
            });
        }

        Err(SshError::ExecFailed {
            exit_code: 1,
            stderr: "exhausted all candidate ports".into(),
        })
    }

    /// Whether the SSH session appears to still be connected.
    pub fn is_connected(&self) -> bool {
        match self.handle.try_lock() {
            Ok(h) => !h.is_closed(),
            Err(_) => true, // locked = in use = presumably connected
        }
    }

    /// Disconnect the SSH session, aborting any port forwards.
    pub async fn disconnect(&self) {
        // Abort all forwarding tasks.
        let mut tasks = self.forward_tasks.lock().await;
        for task in tasks.drain(..) {
            task.abort();
        }
        drop(tasks);

        let handle = self.handle.lock().await;
        let _ = handle
            .disconnect(russh::Disconnect::ByApplication, "bye", "en")
            .await;
    }

    // --------------------------------------------------------------------
    // Private helpers
    // --------------------------------------------------------------------

    /// Locate the `codex` (or `codex-app-server`) binary on the remote host.
    async fn resolve_codex_binary(&self) -> Result<RemoteCodexBinary, SshError> {
        let script = format!(
            r#"{profile_init}
codex_path="$(command -v codex 2>/dev/null || true)"
if [ -n "$codex_path" ] && [ -f "$codex_path" ] && [ -x "$codex_path" ]; then
  printf 'codex:%s' "$codex_path"
elif [ -x "$HOME/.volta/bin/codex" ]; then
  printf 'codex:%s' "$HOME/.volta/bin/codex"
elif [ -x "$HOME/.cargo/bin/codex" ]; then
  printf 'codex:%s' "$HOME/.cargo/bin/codex"
elif [ -x "$HOME/.local/bin/codex" ]; then
  printf 'codex:%s' "$HOME/.local/bin/codex"
elif [ -x "/opt/homebrew/bin/codex" ]; then
  printf 'codex:%s' "/opt/homebrew/bin/codex"
elif [ -x "/usr/local/bin/codex" ]; then
  printf 'codex:%s' "/usr/local/bin/codex"
else
  app_server_path="$(command -v codex-app-server 2>/dev/null || true)"
  if [ -n "$app_server_path" ] && [ -f "$app_server_path" ] && [ -x "$app_server_path" ]; then
    printf 'app-server:%s' "$app_server_path"
  elif [ -x "/opt/homebrew/bin/codex-app-server" ]; then
    printf 'app-server:%s' "/opt/homebrew/bin/codex-app-server"
  elif [ -x "$HOME/.cargo/bin/codex-app-server" ]; then
    printf 'app-server:%s' "$HOME/.cargo/bin/codex-app-server"
  fi
fi"#,
            profile_init = PROFILE_INIT
        );

        let result = self.exec(&script).await?;
        let raw = result.stdout.trim();
        if raw.is_empty() {
            let diagnostics = self.fetch_codex_resolver_diagnostics().await;
            return Err(SshError::ExecFailed {
                exit_code: 1,
                stderr: if diagnostics.is_empty() {
                    "codex/codex-app-server not found on remote host".into()
                } else {
                    format!(
                        "codex/codex-app-server not found on remote host\nresolver diagnostics:\n{}",
                        diagnostics
                    )
                },
            });
        }
        if let Some(path) = raw.strip_prefix("codex:") {
            return Ok(RemoteCodexBinary::Codex(path.to_string()));
        }
        if let Some(path) = raw.strip_prefix("app-server:") {
            return Ok(RemoteCodexBinary::AppServer(path.to_string()));
        }
        Err(SshError::ExecFailed {
            exit_code: 1,
            stderr: format!("unexpected remote codex binary selector: {raw}"),
        })
    }

    async fn fetch_codex_resolver_diagnostics(&self) -> String {
        let script = format!(
            r#"{profile_init}
printf 'shell=%s\n' "${{SHELL:-}}"
printf 'path=%s\n' "${{PATH:-}}"
printf 'whoami='; whoami 2>/dev/null || true
printf 'pwd='; pwd 2>/dev/null || true
printf 'command -v codex='
command -v codex 2>/dev/null || printf '<missing>'
printf '\n'
printf 'command -v codex-app-server='
command -v codex-app-server 2>/dev/null || printf '<missing>'
printf '\n'
for candidate in \
  "$HOME/.volta/bin/codex" \
  "$HOME/.cargo/bin/codex" \
  "$HOME/.local/bin/codex" \
  "/opt/homebrew/bin/codex" \
  "/usr/local/bin/codex" \
  "$HOME/.cargo/bin/codex-app-server" \
  "/opt/homebrew/bin/codex-app-server" \
  "/usr/local/bin/codex-app-server"
do
  if [ -e "$candidate" ]; then
    if [ -x "$candidate" ]; then
      printf 'candidate=%s [exists executable]\n' "$candidate"
    else
      printf 'candidate=%s [exists not-executable]\n' "$candidate"
    fi
  fi
done"#,
            profile_init = PROFILE_INIT
        );

        match self.exec(&script).await {
            Ok(result) => result.stdout.trim().to_string(),
            Err(error) => format!("failed to collect resolver diagnostics: {error}"),
        }
    }

    /// Check if a TCP port is currently listening on the remote host.
    async fn is_port_listening(&self, port: u16) -> bool {
        let cmd = format!(
            r#"if command -v lsof >/dev/null 2>&1; then
  lsof -nP -iTCP:{port} -sTCP:LISTEN -t 2>/dev/null | head -n 1
elif command -v ss >/dev/null 2>&1; then
  ss -ltn "sport = :{port}" 2>/dev/null | tail -n +2 | head -n 1
elif command -v netstat >/dev/null 2>&1; then
  netstat -ltn 2>/dev/null | awk '{{print $4}}' | grep -E '[:\.]{port}$' | head -n 1
fi"#
        );

        match self.exec(&cmd).await {
            Ok(r) => !r.stdout.trim().is_empty(),
            Err(_) => false,
        }
    }

    /// Check if a process is alive on the remote host.
    async fn is_process_alive(&self, pid: u32) -> bool {
        let cmd = format!("kill -0 {pid} >/dev/null 2>&1 && echo alive || echo dead");
        match self.exec(&cmd).await {
            Ok(r) => r.stdout.trim() == "alive",
            Err(_) => false,
        }
    }

    /// Read the last 25 lines of a remote log file.
    async fn fetch_log_tail(&self, log_path: &str) -> String {
        match self
            .exec(&format!("tail -n 25 {} 2>/dev/null", shell_quote(log_path)))
            .await
        {
            Ok(r) => r.stdout.trim().to_string(),
            Err(_) => String::new(),
        }
    }

    async fn wait_for_forwarded_websocket_ready(
        &self,
        local_port: u16,
        pid: Option<u32>,
        log_path: &str,
    ) -> Result<(), String> {
        let websocket_url = format!("ws://127.0.0.1:{local_port}");
        let mut last_error = String::new();

        for _ in 0..20 {
            match connect_async(&websocket_url).await {
                Ok((mut websocket, _)) => {
                    let _ = websocket.close(None).await;
                    return Ok(());
                }
                Err(error) => {
                    last_error = error.to_string();
                }
            }

            if let Some(p) = pid {
                if !self.is_process_alive(p).await {
                    let tail = self.fetch_log_tail(log_path).await;
                    return Err(if tail.is_empty() { last_error } else { tail });
                }
            }

            tokio::time::sleep(Duration::from_millis(250)).await;
        }

        let tail = self.fetch_log_tail(log_path).await;
        Err(if tail.is_empty() {
            format!("websocket readiness probe failed: {last_error}")
        } else if last_error.is_empty() {
            tail
        } else {
            format!("{tail}\nwebsocket readiness probe failed: {last_error}")
        })
    }

    /// Attempt to read the server version from `codex --version`.
    async fn read_server_version(&self, codex_path: &str) -> Option<String> {
        let cmd = format!(
            "{} {} --version 2>/dev/null",
            PROFILE_INIT,
            shell_quote(codex_path)
        );
        match self.exec(&cmd).await {
            Ok(r) if r.exit_code == 0 => {
                let v = r.stdout.trim().to_string();
                if v.is_empty() { None } else { Some(v) }
            }
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------------
// Port-forward proxy
// ---------------------------------------------------------------------------

/// Bidirectionally proxy data between a local TCP stream and an SSH channel.
///
/// Uses `make_writer()` to obtain an independent write handle (which clones
/// internal channel senders), then spawns local-to-remote copying in a separate
/// task while the current task handles remote-to-local via `channel.wait()`.
async fn proxy_connection(
    local: tokio::net::TcpStream,
    mut ssh_channel: russh::Channel<Msg>,
    local_port: u16,
    remote_host: &str,
    remote_port: u16,
    peer_addr: std::net::SocketAddr,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let remote_host = remote_host.to_string();

    // `make_writer` clones internal senders so it can be used independently
    // from `channel.wait()` which takes `&mut self`.
    let mut ssh_writer = ssh_channel.make_writer();

    // `into_split` gives us owned halves that are `Send + 'static`.
    let (mut local_read, mut local_write) = local.into_split();

    // Spawn local -> remote copying.
    let local_to_remote_remote_host = remote_host.clone();
    let local_to_remote = tokio::spawn(async move {
        let mut buf = vec![0u8; 32768];
        loop {
            match local_read.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    if ssh_writer.write_all(&buf[..n]).await.is_err() {
                        append_android_debug_log(&format!(
                            "ssh_forward_local_to_remote_write_failed listen=127.0.0.1:{} remote={}:{} peer={}",
                            local_port, local_to_remote_remote_host, remote_port, peer_addr
                        ));
                        break;
                    }
                }
                Err(error) => {
                    append_android_debug_log(&format!(
                        "ssh_forward_local_read_error listen=127.0.0.1:{} remote={}:{} peer={} error={}",
                        local_port, local_to_remote_remote_host, remote_port, peer_addr, error
                    ));
                    break;
                }
            }
        }
        // Dropping ssh_writer signals we are done writing to the channel.
    });

    // Remote -> local: drain channel messages on the current task.
    loop {
        match ssh_channel.wait().await {
            Some(ChannelMsg::Data { data }) => {
                if local_write.write_all(&data).await.is_err() {
                    append_android_debug_log(&format!(
                        "ssh_forward_local_write_failed listen=127.0.0.1:{} remote={}:{} peer={}",
                        local_port, remote_host, remote_port, peer_addr
                    ));
                    break;
                }
            }
            Some(ChannelMsg::Eof) => {
                append_android_debug_log(&format!(
                    "ssh_forward_channel_eof listen=127.0.0.1:{} remote={}:{} peer={}",
                    local_port, remote_host, remote_port, peer_addr
                ));
                break;
            }
            Some(ChannelMsg::Close) => {
                append_android_debug_log(&format!(
                    "ssh_forward_channel_close listen=127.0.0.1:{} remote={}:{} peer={}",
                    local_port, remote_host, remote_port, peer_addr
                ));
                break;
            }
            None => {
                append_android_debug_log(&format!(
                    "ssh_forward_channel_ended listen=127.0.0.1:{} remote={}:{} peer={}",
                    local_port, remote_host, remote_port, peer_addr
                ));
                break;
            }
            _ => {}
        }
    }

    local_to_remote.abort();
    let _ = ssh_channel.close().await;

    Ok(())
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Shell snippet that sources common profile files to pick up PATH additions.
const PROFILE_INIT: &str = r#"for f in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.zprofile" "$HOME/.zshrc"; do [ -f "$f" ] && . "$f" 2>/dev/null; done;"#;

#[derive(Debug, Clone)]
enum RemoteCodexBinary {
    Codex(String),
    AppServer(String),
}

impl RemoteCodexBinary {
    fn path(&self) -> &str {
        match self {
            Self::Codex(path) | Self::AppServer(path) => path,
        }
    }
}

fn server_launch_command(binary: &RemoteCodexBinary, listen_url: &str) -> String {
    match binary {
        RemoteCodexBinary::Codex(path) => format!(
            "{} app-server --listen {}",
            shell_quote(path),
            shell_quote(listen_url)
        ),
        RemoteCodexBinary::AppServer(path) => {
            format!("{} --listen {}", shell_quote(path), shell_quote(listen_url))
        }
    }
}

fn normalize_host(host: &str) -> String {
    let mut h = host.trim().trim_matches('[').trim_matches(']').to_string();
    h = h.replace("%25", "%");
    if !h.contains(':') {
        if let Some(idx) = h.find('%') {
            h.truncate(idx);
        }
    }
    h
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\"'\"'"))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_host_simple() {
        assert_eq!(normalize_host("example.com"), "example.com");
    }

    #[test]
    fn test_normalize_host_trimming() {
        assert_eq!(normalize_host("  example.com  "), "example.com");
    }

    #[test]
    fn test_normalize_host_ipv6_brackets() {
        assert_eq!(normalize_host("[::1]"), "::1");
    }

    #[test]
    fn test_normalize_host_percent_encoding() {
        assert_eq!(normalize_host("fe80::1%25eth0"), "fe80::1%eth0");
    }

    #[test]
    fn test_normalize_host_zone_id_removal() {
        // Non-IPv6 host with a zone id should have it stripped.
        assert_eq!(normalize_host("192.168.1.1%eth0"), "192.168.1.1");
    }

    #[test]
    fn test_shell_quote_simple() {
        assert_eq!(shell_quote("hello"), "'hello'");
    }

    #[test]
    fn test_server_launch_command_for_codex() {
        let command = server_launch_command(
            &RemoteCodexBinary::Codex("/usr/local/bin/codex".into()),
            "ws://0.0.0.0:8390",
        );
        assert_eq!(
            command,
            "'/usr/local/bin/codex' app-server --listen 'ws://0.0.0.0:8390'"
        );
    }

    #[test]
    fn test_server_launch_command_for_codex_app_server() {
        let command = server_launch_command(
            &RemoteCodexBinary::AppServer("/usr/local/bin/codex-app-server".into()),
            "ws://[::]:8390",
        );
        assert_eq!(
            command,
            "'/usr/local/bin/codex-app-server' --listen 'ws://[::]:8390'"
        );
    }

    #[test]
    fn test_shell_quote_with_single_quote() {
        assert_eq!(shell_quote("it's"), "'it'\"'\"'s'");
    }

    #[test]
    fn test_shell_quote_path() {
        assert_eq!(
            shell_quote("/home/user/my file.txt"),
            "'/home/user/my file.txt'"
        );
    }

    #[test]
    fn test_exec_result_default() {
        let r = ExecResult {
            exit_code: 0,
            stdout: "hello\n".into(),
            stderr: String::new(),
        };
        assert_eq!(r.exit_code, 0);
        assert_eq!(r.stdout.trim(), "hello");
    }

    #[test]
    fn test_ssh_error_display() {
        let e = SshError::ConnectionFailed("refused".into());
        assert_eq!(e.to_string(), "connection failed: refused");

        let e = SshError::HostKeyVerification {
            fingerprint: "SHA256:abc".into(),
        };
        assert!(e.to_string().contains("SHA256:abc"));

        let e = SshError::ExecFailed {
            exit_code: 127,
            stderr: "not found".into(),
        };
        assert!(e.to_string().contains("127"));
        assert!(e.to_string().contains("not found"));

        assert_eq!(SshError::Timeout.to_string(), "timeout");
        assert_eq!(SshError::Disconnected.to_string(), "disconnected");
    }

    #[test]
    fn test_ssh_credentials_construction() {
        let creds = SshCredentials {
            host: "example.com".into(),
            port: 22,
            username: "user".into(),
            auth: SshAuth::Password("pass".into()),
        };
        assert_eq!(creds.port, 22);
        assert_eq!(creds.username, "user");

        let creds_key = SshCredentials {
            host: "example.com".into(),
            port: 2222,
            username: "deploy".into(),
            auth: SshAuth::PrivateKey {
                key_pem:
                    "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----"
                        .into(),
                passphrase: None,
            },
        };
        assert_eq!(creds_key.port, 2222);
    }

    #[test]
    fn test_bootstrap_result_clone() {
        let r = SshBootstrapResult {
            server_port: 8390,
            tunnel_local_port: 12345,
            server_version: Some("1.0.0".into()),
            pid: Some(42),
        };
        let r2 = r.clone();
        assert_eq!(r2.server_port, 8390);
        assert_eq!(r2.tunnel_local_port, 12345);
        assert_eq!(r2.server_version.as_deref(), Some("1.0.0"));
        assert_eq!(r2.pid, Some(42));
    }

    #[test]
    fn test_profile_init_sources_common_files() {
        // Verify the profile init string references the expected shell config files.
        assert!(PROFILE_INIT.contains(".profile"));
        assert!(PROFILE_INIT.contains(".bash_profile"));
        assert!(PROFILE_INIT.contains(".bashrc"));
        assert!(PROFILE_INIT.contains(".zprofile"));
        assert!(PROFILE_INIT.contains(".zshrc"));
    }

    #[test]
    fn test_default_remote_port() {
        assert_eq!(DEFAULT_REMOTE_PORT, 8390);
    }

    #[test]
    fn test_port_candidates_range() {
        let ports: Vec<u16> = (0..PORT_CANDIDATES)
            .map(|i| DEFAULT_REMOTE_PORT + i)
            .collect();
        assert_eq!(ports.len(), 21);
        assert_eq!(*ports.first().unwrap(), 8390);
        assert_eq!(*ports.last().unwrap(), 8410);
    }
}
