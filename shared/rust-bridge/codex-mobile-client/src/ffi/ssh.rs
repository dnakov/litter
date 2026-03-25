use crate::ffi::ClientError;
use crate::ffi::shared::{shared_mobile_client, shared_runtime};
use crate::session::connection::ServerConfig;
use crate::ssh::{ExecResult, SshAuth, SshClient, SshCredentials, SshError};
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;

#[derive(Clone)]
pub(crate) struct ManagedSshSession {
    pub(crate) client: Arc<SshClient>,
    pub(crate) pid: Option<u32>,
}

#[derive(uniffi::Object)]
pub struct SshBridge {
    pub(crate) rt: Arc<tokio::runtime::Runtime>,
    pub(crate) ssh_sessions: Mutex<std::collections::HashMap<String, ManagedSshSession>>,
    pub(crate) next_ssh_session_id: AtomicU64,
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
        self.ssh_sessions_lock().insert(
            session_id.clone(),
            ManagedSshSession {
                client: Arc::clone(&session),
                pid: bootstrap.pid,
            },
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
                    let _ = session
                        .client
                        .exec(&format!("kill {pid} 2>/dev/null"))
                        .await;
                }
                session.client.disconnect().await;
            })
        })
        .await
        .map_err(|e| ClientError::Rpc(format!("task join error: {e}")))?;
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
        shared_mobile_client()
            .connect_remote_over_ssh(
                config,
                credentials,
                accept_unknown_host,
                working_dir,
                ipc_socket_path_override,
            )
            .await
            .map_err(|e| ClientError::Transport(e.to_string()))
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
