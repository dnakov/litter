use crate::ffi::ClientError;
use crate::ffi::shared::{shared_mobile_client, shared_runtime};
use crate::session::connection::ServerConfig;
use crate::ssh::{
    ExecResult, RemoteShell, SshAuth, SshBootstrapResult, SshClient, SshCredentials, SshError,
};
use crate::store::{
    ServerConnectionProgressSnapshot, ServerConnectionStepKind, ServerConnectionStepState,
    ServerHealthSnapshot,
};
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use tokio::sync::oneshot;
use tracing::{debug, info, trace, warn};

#[derive(Clone)]
pub(crate) struct ManagedSshSession {
    pub(crate) client: Arc<SshClient>,
    pub(crate) pid: Option<u32>,
    pub(crate) shell: RemoteShell,
}

pub(crate) struct ManagedSshBootstrapFlow {
    pub(crate) install_decision: Option<oneshot::Sender<bool>>,
}

#[derive(uniffi::Object)]
pub struct SshBridge {
    pub(crate) rt: Arc<tokio::runtime::Runtime>,
    pub(crate) ssh_sessions: Mutex<std::collections::HashMap<String, ManagedSshSession>>,
    pub(crate) next_ssh_session_id: AtomicU64,
    pub(crate) bootstrap_flows:
        Arc<tokio::sync::Mutex<std::collections::HashMap<String, ManagedSshBootstrapFlow>>>,
}

#[derive(uniffi::Record)]
pub struct FfiSshConnectionResult {
    pub session_id: String,
    pub normalized_host: String,
    pub server_port: u16,
    pub tunnel_local_port: Option<u16>,
    pub server_version: Option<String>,
    pub pid: Option<u32>,
    pub wake_mac: Option<String>,
}

#[derive(uniffi::Record)]
pub struct FfiSshExecResult {
    pub exit_code: u32,
    pub stdout: String,
    pub stderr: String,
}

impl From<ExecResult> for FfiSshExecResult {
    fn from(value: ExecResult) -> Self {
        Self {
            exit_code: value.exit_code,
            stdout: value.stdout,
            stderr: value.stderr,
        }
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl SshBridge {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            rt: shared_runtime(),
            ssh_sessions: Mutex::new(std::collections::HashMap::new()),
            next_ssh_session_id: AtomicU64::new(1),
            bootstrap_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        }
    }

    pub async fn ssh_connect_and_bootstrap(
        &self,
        host: String,
        port: u16,
        username: String,
        password: Option<String>,
        private_key_pem: Option<String>,
        passphrase: Option<String>,
        accept_unknown_host: bool,
        working_dir: Option<String>,
    ) -> Result<FfiSshConnectionResult, ClientError> {
        let normalized_host = normalize_ssh_host(&host);
        let auth = ssh_auth(password, private_key_pem, passphrase)?;
        info!(
            "SshBridge: ssh_connect_and_bootstrap start host={} normalized_host={} ssh_port={} username={} auth={} working_dir={}",
            host.as_str(),
            normalized_host.as_str(),
            port,
            username.as_str(),
            ssh_auth_kind(&auth),
            working_dir.as_deref().unwrap_or("<none>")
        );
        let credentials = SshCredentials {
            host: normalized_host.clone(),
            port,
            username,
            auth,
        };

        let rt = Arc::clone(&self.rt);
        let session = tokio::task::spawn_blocking(move || {
            rt.block_on(async move {
                SshClient::connect(
                    credentials,
                    Box::new(move |_fingerprint| Box::pin(async move { accept_unknown_host })),
                )
                .await
                .map_err(map_ssh_error)
            })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))??;
        info!(
            "SshBridge: ssh_connect_and_bootstrap connected normalized_host={} ssh_port={}",
            normalized_host.as_str(),
            port
        );

        let session = Arc::new(session);
        let bootstrap = {
            let session = Arc::clone(&session);
            let rt = Arc::clone(&self.rt);
            let working_dir = working_dir.clone();
            let use_ipv6 = normalized_host.contains(':');
            tokio::task::spawn_blocking(move || {
                rt.block_on(async move {
                    session
                        .bootstrap_codex_server(working_dir.as_deref(), use_ipv6)
                        .await
                        .map_err(map_ssh_error)
                })
            })
            .await
            .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))?
        };

        let bootstrap = match bootstrap {
            Ok(result) => result,
            Err(error) => {
                warn!(
                    "SshBridge: ssh_connect_and_bootstrap bootstrap failed normalized_host={} ssh_port={} error={}",
                    normalized_host.as_str(),
                    port,
                    error
                );
                let session = Arc::clone(&session);
                let rt = Arc::clone(&self.rt);
                let _ = tokio::task::spawn_blocking(move || {
                    rt.block_on(async move {
                        session.disconnect().await;
                    })
                })
                .await;
                return Err(error);
            }
        };

        let wake_mac = self.ssh_read_wake_mac(Arc::clone(&session)).await;
        let session_id = format!(
            "ssh-{}",
            self.next_ssh_session_id.fetch_add(1, Ordering::Relaxed)
        );
        let shell = {
            let session = Arc::clone(&session);
            let rt = Arc::clone(&self.rt);
            tokio::task::spawn_blocking(move || {
                rt.block_on(async move { session.detect_remote_shell().await })
            })
            .await
            .unwrap_or(RemoteShell::Posix)
        };
        self.ssh_sessions_lock().insert(
            session_id.clone(),
            ManagedSshSession {
                client: Arc::clone(&session),
                pid: bootstrap.pid,
                shell,
            },
        );
        info!(
            "SshBridge: ssh_connect_and_bootstrap succeeded normalized_host={} ssh_port={} session_id={} remote_port={} local_tunnel_port={} pid={:?}",
            normalized_host.as_str(),
            port,
            session_id,
            bootstrap.server_port,
            bootstrap.tunnel_local_port,
            bootstrap.pid
        );

        Ok(FfiSshConnectionResult {
            session_id,
            normalized_host,
            server_port: bootstrap.server_port,
            tunnel_local_port: Some(bootstrap.tunnel_local_port),
            server_version: bootstrap.server_version,
            pid: bootstrap.pid,
            wake_mac,
        })
    }

    pub async fn ssh_close(&self, session_id: String) -> Result<(), ClientError> {
        debug!("SshBridge: ssh_close session_id={}", session_id);
        let session = self
            .ssh_sessions_lock()
            .remove(&session_id)
            .ok_or_else(|| {
                ClientError::InvalidParams(format!("unknown SSH session id: {session_id}"))
            })?;
        let rt = Arc::clone(&self.rt);
        tokio::task::spawn_blocking(move || {
            rt.block_on(async move {
                if let Some(pid) = session.pid {
                    let kill_cmd = match session.shell {
                        RemoteShell::Posix => format!("kill {pid} 2>/dev/null"),
                        RemoteShell::PowerShell => {
                            format!("Stop-Process -Id {pid} -Force -ErrorAction SilentlyContinue")
                        }
                    };
                    let _ = session.client.exec_shell(&kill_cmd, session.shell).await;
                }
                session.client.disconnect().await;
            })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))?;
        debug!("SshBridge: ssh_close completed session_id={}", session_id);
        Ok(())
    }

    pub async fn ssh_connect_remote_server(
        &self,
        server_id: String,
        display_name: String,
        host: String,
        port: u16,
        username: String,
        password: Option<String>,
        private_key_pem: Option<String>,
        passphrase: Option<String>,
        accept_unknown_host: bool,
        working_dir: Option<String>,
        ipc_socket_path_override: Option<String>,
    ) -> Result<String, ClientError> {
        let normalized_host = normalize_ssh_host(&host);
        let auth = ssh_auth(password, private_key_pem, passphrase)?;
        info!(
            "SshBridge: ssh_connect_remote_server start server_id={} host={} normalized_host={} ssh_port={} username={} auth={} working_dir={} ipc_socket_path_override={}",
            server_id,
            host.as_str(),
            normalized_host.as_str(),
            port,
            username.as_str(),
            ssh_auth_kind(&auth),
            working_dir.as_deref().unwrap_or("<none>"),
            ipc_socket_path_override.as_deref().unwrap_or("<none>")
        );
        let credentials = SshCredentials {
            host: normalized_host.clone(),
            port,
            username,
            auth,
        };
        let config = ServerConfig {
            server_id,
            display_name,
            host: normalized_host,
            port: 0,
            websocket_url: None,
            is_local: false,
            tls: false,
        };
        let mobile_client = shared_mobile_client();
        let (tx, rx) = oneshot::channel();
        let task_server_id = config.server_id.clone();

        // Run the full SSH bootstrap on Tokio and only surface the final
        // completion back through UniFFI. Polling the full bootstrap future
        // directly from Swift's cooperative executor can overflow its small
        // stack on iOS when the websocket handshake wakes aggressively.
        tokio::spawn(async move {
            let result = mobile_client
                .connect_remote_over_ssh(
                    config,
                    credentials,
                    accept_unknown_host,
                    working_dir,
                    ipc_socket_path_override,
                )
                .await
                .map_err(|e| ClientError::Transport(e.to_string()));
            match &result {
                Ok(server_id) => info!(
                    "SshBridge: ssh_connect_remote_server completed server_id={}",
                    server_id
                ),
                Err(error) => warn!(
                    "SshBridge: ssh_connect_remote_server failed server_id={} error={}",
                    task_server_id, error
                ),
            }
            let _ = tx.send(result);
        });

        rx.await
            .map_err(|_| ClientError::Rpc("ssh connect task cancelled".to_string()))?
    }

    pub async fn ssh_start_remote_server_connect(
        &self,
        server_id: String,
        display_name: String,
        host: String,
        port: u16,
        username: String,
        password: Option<String>,
        private_key_pem: Option<String>,
        passphrase: Option<String>,
        accept_unknown_host: bool,
        working_dir: Option<String>,
        ipc_socket_path_override: Option<String>,
    ) -> Result<String, ClientError> {
        let normalized_host = normalize_ssh_host(&host);
        let auth = ssh_auth(password, private_key_pem, passphrase)?;
        info!(
            "SshBridge: ssh_start_remote_server_connect start server_id={} host={} normalized_host={} ssh_port={} username={} auth={} working_dir={} ipc_socket_path_override={}",
            server_id,
            host.as_str(),
            normalized_host.as_str(),
            port,
            username.as_str(),
            ssh_auth_kind(&auth),
            working_dir.as_deref().unwrap_or("<none>"),
            ipc_socket_path_override.as_deref().unwrap_or("<none>")
        );
        let credentials = SshCredentials {
            host: normalized_host.clone(),
            port,
            username,
            auth,
        };
        let config = ServerConfig {
            server_id: server_id.clone(),
            display_name,
            host: normalized_host,
            port: 0,
            websocket_url: None,
            is_local: false,
            tls: false,
        };

        {
            let mut flows = self.bootstrap_flows.lock().await;
            if flows.contains_key(&server_id) {
                debug!(
                    "SshBridge: ssh_start_remote_server_connect reusing existing bootstrap flow server_id={}",
                    server_id
                );
                return Ok(server_id);
            }
            flows.insert(
                server_id.clone(),
                ManagedSshBootstrapFlow {
                    install_decision: None,
                },
            );
        }

        let mobile_client = shared_mobile_client();
        mobile_client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connecting);
        let initial_progress = ServerConnectionProgressSnapshot::ssh_bootstrap();
        mobile_client
            .app_store
            .update_server_connection_progress(&server_id, Some(initial_progress.clone()));

        let flows = Arc::clone(&self.bootstrap_flows);
        let task_server_id = server_id.clone();
        let task_host = credentials.host.clone();
        tokio::spawn(async move {
            let mut progress = initial_progress;
            trace!(
                "SshBridge: guided ssh connect task spawned server_id={} host={}",
                task_server_id, task_host
            );
            let task_result = run_guided_ssh_connect(
                Arc::clone(&mobile_client),
                Arc::clone(&flows),
                config,
                credentials,
                accept_unknown_host,
                working_dir,
                ipc_socket_path_override,
                &mut progress,
            )
            .await;

            if let Err(ref error) = task_result {
                warn!(
                    "guided ssh connect failed server_id={} host={} error={}",
                    task_server_id, task_host, error
                );
                mark_progress_failure(&mut progress, error.to_string());
                mobile_client
                    .app_store
                    .update_server_health(&task_server_id, ServerHealthSnapshot::Disconnected);
                mobile_client
                    .app_store
                    .update_server_connection_progress(&task_server_id, Some(progress));
            }

            if task_result.is_ok() {
                info!(
                    "SshBridge: guided ssh connect completed server_id={} host={}",
                    task_server_id, task_host
                );
            }

            flows.lock().await.remove(&task_server_id);
        });

        Ok(server_id)
    }

    pub async fn ssh_respond_to_install_prompt(
        &self,
        server_id: String,
        install: bool,
    ) -> Result<(), ClientError> {
        info!(
            "SshBridge: ssh_respond_to_install_prompt server_id={} install={}",
            server_id, install
        );
        let sender = {
            let mut flows = self.bootstrap_flows.lock().await;
            flows
                .get_mut(&server_id)
                .and_then(|flow| flow.install_decision.take())
        }
        .ok_or_else(|| {
            ClientError::InvalidParams(format!("no pending install prompt for {server_id}"))
        })?;

        sender
            .send(install)
            .map_err(|_| ClientError::EventClosed("install prompt already closed".to_string()))
    }
}

fn ssh_auth_kind(auth: &SshAuth) -> &'static str {
    match auth {
        SshAuth::Password(_) => "password",
        SshAuth::PrivateKey { .. } => "private_key",
    }
}

impl SshBridge {
    fn ssh_sessions_lock(
        &self,
    ) -> std::sync::MutexGuard<'_, std::collections::HashMap<String, ManagedSshSession>> {
        match self.ssh_sessions.lock() {
            Ok(guard) => guard,
            Err(error) => {
                tracing::warn!("SshBridge: recovering poisoned ssh_sessions lock");
                error.into_inner()
            }
        }
    }

    pub(crate) async fn ssh_read_wake_mac(&self, session: Arc<SshClient>) -> Option<String> {
        const WAKE_MAC_SCRIPT: &str = r#"iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
if [ -z "$iface" ]; then iface="en0"; fi
mac="$(ifconfig "$iface" 2>/dev/null | awk '/ether /{print $2; exit}')"
if [ -z "$mac" ]; then
  mac="$(ifconfig en0 2>/dev/null | awk '/ether /{print $2; exit}')"
fi
if [ -z "$mac" ]; then
  mac="$(ifconfig 2>/dev/null | awk '/ether /{print $2; exit}')"
fi
printf '%s' "$mac""#;
        let rt = Arc::clone(&self.rt);
        let result = tokio::task::spawn_blocking(move || {
            rt.block_on(async move { session.exec(WAKE_MAC_SCRIPT).await.map_err(map_ssh_error) })
        })
        .await
        .ok()?
        .ok()?;
        if result.exit_code != 0 {
            return None;
        }
        normalize_wake_mac(&result.stdout)
    }
}

async fn run_guided_ssh_connect(
    mobile_client: Arc<crate::MobileClient>,
    bootstrap_flows: Arc<
        tokio::sync::Mutex<std::collections::HashMap<String, ManagedSshBootstrapFlow>>,
    >,
    config: ServerConfig,
    credentials: SshCredentials,
    accept_unknown_host: bool,
    working_dir: Option<String>,
    ipc_socket_path_override: Option<String>,
    progress: &mut ServerConnectionProgressSnapshot,
) -> Result<(), ClientError> {
    let server_id = config.server_id.clone();
    info!(
        "guided ssh connect start server_id={} host={} ssh_port={} working_dir={} ipc_socket_path_override={}",
        server_id,
        credentials.host.as_str(),
        credentials.port,
        working_dir.as_deref().unwrap_or("<none>"),
        ipc_socket_path_override.as_deref().unwrap_or("<none>")
    );
    let ssh_client = Arc::new(
        SshClient::connect(
            credentials.clone(),
            Box::new(move |_fingerprint| Box::pin(async move { accept_unknown_host })),
        )
        .await
        .map_err(map_ssh_error)?,
    );
    info!(
        "guided ssh connect connected to ssh server_id={} host={} ssh_port={}",
        server_id,
        credentials.host.as_str(),
        credentials.port
    );
    progress.update_step(
        ServerConnectionStepKind::ConnectingToSsh,
        ServerConnectionStepState::Completed,
        Some(format!("Connected to {}", credentials.host.as_str())),
    );
    progress.update_step(
        ServerConnectionStepKind::FindingCodex,
        ServerConnectionStepState::InProgress,
        None,
    );
    mobile_client
        .app_store
        .update_server_connection_progress(&server_id, Some(progress.clone()));

    let remote_shell = ssh_client.detect_remote_shell().await;
    info!(
        "guided ssh connect detected shell server_id={} shell={:?}",
        server_id, remote_shell
    );
    let codex_binary = match ssh_client
        .resolve_codex_binary_optional_with_shell(Some(remote_shell))
        .await
        .map_err(map_ssh_error)?
    {
        Some(binary) => {
            info!(
                "guided ssh connect found codex server_id={} path={}",
                server_id,
                binary.path()
            );
            progress.update_step(
                ServerConnectionStepKind::FindingCodex,
                ServerConnectionStepState::Completed,
                Some(binary.path().to_string()),
            );
            progress.update_step(
                ServerConnectionStepKind::InstallingCodex,
                ServerConnectionStepState::Cancelled,
                Some("Already installed".to_string()),
            );
            mobile_client
                .app_store
                .update_server_connection_progress(&server_id, Some(progress.clone()));
            binary
        }
        None => {
            info!(
                "guided ssh connect missing codex server_id={} host={}; awaiting install decision",
                server_id,
                credentials.host.as_str()
            );
            progress.pending_install = true;
            progress.update_step(
                ServerConnectionStepKind::FindingCodex,
                ServerConnectionStepState::AwaitingUserInput,
                Some("Codex not found on remote host".to_string()),
            );
            mobile_client
                .app_store
                .update_server_connection_progress(&server_id, Some(progress.clone()));

            let (tx, rx) = oneshot::channel();
            {
                let mut flows = bootstrap_flows.lock().await;
                if let Some(flow) = flows.get_mut(&server_id) {
                    flow.install_decision = Some(tx);
                }
            }

            let should_install = rx.await.unwrap_or(false);
            info!(
                "guided ssh connect install decision server_id={} install={}",
                server_id, should_install
            );
            progress.pending_install = false;
            if !should_install {
                progress.update_step(
                    ServerConnectionStepKind::FindingCodex,
                    ServerConnectionStepState::Failed,
                    Some("Install declined".to_string()),
                );
                progress.update_step(
                    ServerConnectionStepKind::InstallingCodex,
                    ServerConnectionStepState::Cancelled,
                    Some("Install declined".to_string()),
                );
                progress.terminal_message = Some("Install declined".to_string());
                mobile_client
                    .app_store
                    .update_server_health(&server_id, ServerHealthSnapshot::Disconnected);
                mobile_client
                    .app_store
                    .update_server_connection_progress(&server_id, Some(progress.clone()));
                ssh_client.disconnect().await;
                return Ok(());
            }

            progress.update_step(
                ServerConnectionStepKind::FindingCodex,
                ServerConnectionStepState::Completed,
                Some("Installing latest stable release".to_string()),
            );
            progress.update_step(
                ServerConnectionStepKind::InstallingCodex,
                ServerConnectionStepState::InProgress,
                None,
            );
            mobile_client
                .app_store
                .update_server_connection_progress(&server_id, Some(progress.clone()));

            let platform = ssh_client
                .detect_remote_platform_with_shell(Some(remote_shell))
                .await
                .map_err(map_ssh_error)?;
            info!(
                "guided ssh connect install platform server_id={} platform={:?}",
                server_id, platform
            );
            let installed_binary = ssh_client
                .install_latest_stable_codex(platform)
                .await
                .map_err(map_ssh_error)?;
            info!(
                "guided ssh connect install completed server_id={} path={}",
                server_id,
                installed_binary.path()
            );
            progress.update_step(
                ServerConnectionStepKind::InstallingCodex,
                ServerConnectionStepState::Completed,
                Some(installed_binary.path().to_string()),
            );
            mobile_client
                .app_store
                .update_server_connection_progress(&server_id, Some(progress.clone()));
            installed_binary
        }
    };

    progress.update_step(
        ServerConnectionStepKind::StartingAppServer,
        ServerConnectionStepState::InProgress,
        None,
    );
    mobile_client
        .app_store
        .update_server_connection_progress(&server_id, Some(progress.clone()));

    info!(
        "guided ssh connect bootstrapping app server server_id={} host={}",
        server_id,
        credentials.host.as_str()
    );
    let bootstrap = ssh_client
        .bootstrap_codex_server_with_binary(
            &codex_binary,
            working_dir.as_deref(),
            config.host.contains(':'),
        )
        .await
        .map_err(map_ssh_error)?;
    info!(
        "guided ssh connect bootstrap completed server_id={} remote_port={} local_tunnel_port={} pid={:?}",
        server_id, bootstrap.server_port, bootstrap.tunnel_local_port, bootstrap.pid
    );

    progress.update_step(
        ServerConnectionStepKind::StartingAppServer,
        ServerConnectionStepState::Completed,
        Some(format!("Remote port {}", bootstrap.server_port)),
    );
    progress.update_step(
        ServerConnectionStepKind::OpeningTunnel,
        ServerConnectionStepState::Completed,
        Some(format!("127.0.0.1:{}", bootstrap.tunnel_local_port)),
    );
    progress.update_step(
        ServerConnectionStepKind::Connected,
        ServerConnectionStepState::InProgress,
        None,
    );
    mobile_client
        .app_store
        .update_server_connection_progress(&server_id, Some(progress.clone()));

    let host = credentials.host.clone();
    mobile_client
        .finish_connect_remote_over_ssh(
            config,
            credentials,
            ssh_client,
            SshBootstrapResult {
                server_port: bootstrap.server_port,
                tunnel_local_port: bootstrap.tunnel_local_port,
                server_version: bootstrap.server_version,
                pid: bootstrap.pid,
            },
            ipc_socket_path_override,
        )
        .await
        .map_err(|error| ClientError::Transport(error.to_string()))?;
    info!(
        "guided ssh connect attached remote session server_id={} host={}",
        server_id,
        host.as_str()
    );

    progress.update_step(
        ServerConnectionStepKind::Connected,
        ServerConnectionStepState::Completed,
        Some("Connected".to_string()),
    );
    progress.terminal_message = None;
    mobile_client
        .app_store
        .update_server_connection_progress(&server_id, Some(progress.clone()));
    Ok(())
}

fn mark_progress_failure(progress: &mut ServerConnectionProgressSnapshot, message: String) {
    if let Some(step) = progress.steps.iter_mut().find(|step| {
        matches!(
            step.state,
            ServerConnectionStepState::InProgress | ServerConnectionStepState::AwaitingUserInput
        )
    }) {
        step.state = ServerConnectionStepState::Failed;
        step.detail = Some(message.clone());
    } else if let Some(step) = progress.steps.last_mut() {
        step.state = ServerConnectionStepState::Failed;
        step.detail = Some(message.clone());
    }
    progress.pending_install = false;
    progress.terminal_message = Some(message);
}

pub(crate) fn map_ssh_error(error: SshError) -> ClientError {
    match error {
        SshError::ConnectionFailed(message)
        | SshError::AuthFailed(message)
        | SshError::PortForwardFailed(message)
        | SshError::ExecFailed {
            stderr: message, ..
        } => ClientError::Transport(message),
        SshError::HostKeyVerification { fingerprint } => {
            ClientError::Transport(format!("host key verification failed: {fingerprint}"))
        }
        SshError::Timeout => ClientError::Transport("SSH operation timed out".into()),
        SshError::Disconnected => ClientError::Transport("SSH session disconnected".into()),
    }
}

fn ssh_auth(
    password: Option<String>,
    private_key_pem: Option<String>,
    passphrase: Option<String>,
) -> Result<SshAuth, ClientError> {
    match (password, private_key_pem) {
        (Some(password), None) => Ok(SshAuth::Password(password)),
        (None, Some(key_pem)) => Ok(SshAuth::PrivateKey {
            key_pem,
            passphrase,
        }),
        (None, None) => Err(ClientError::InvalidParams(
            "missing SSH credential: provide either password or private key".into(),
        )),
        (Some(_), Some(_)) => Err(ClientError::InvalidParams(
            "ambiguous SSH credentials: provide either password or private key, not both".into(),
        )),
    }
}

fn normalize_ssh_host(host: &str) -> String {
    let mut normalized = host.trim().trim_matches(['[', ']']).replace("%25", "%");
    if !normalized.contains(':') {
        if let Some((base, _scope)) = normalized.split_once('%') {
            normalized = base.to_string();
        }
    }
    normalized
}

fn normalize_wake_mac(raw: &str) -> Option<String> {
    let compact = raw
        .trim()
        .replace(':', "")
        .replace('-', "")
        .to_ascii_lowercase();
    if compact.len() != 12 || !compact.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return None;
    }

    let mut chunks = Vec::with_capacity(6);
    for index in (0..12).step_by(2) {
        chunks.push(compact[index..index + 2].to_string());
    }
    Some(chunks.join(":"))
}
