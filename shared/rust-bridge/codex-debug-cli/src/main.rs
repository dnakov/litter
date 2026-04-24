use std::collections::HashSet;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use codex_app_server_protocol as upstream;
use codex_ipc::handler::RequestHandler;
use codex_ipc::transport::{frame, socket};
use codex_ipc::{
    Envelope, InitializeParams, IpcClient, IpcClientConfig, Method, MethodKind, Request,
    ThreadFollowerCommandApprovalDecisionParams, ThreadFollowerEditLastUserTurnParams,
    ThreadFollowerFileApprovalDecisionParams, ThreadFollowerInterruptTurnParams,
    ThreadFollowerSetCollaborationModeParams, ThreadFollowerSetModelAndReasoningParams,
    ThreadFollowerSetQueuedFollowUpsStateParams, ThreadFollowerStartTurnParams,
    ThreadFollowerSteerTurnParams, ThreadFollowerSubmitMcpServerElicitationResponseParams,
    ThreadFollowerSubmitUserInputParams, TypedBroadcast, TypedRequest,
};
use codex_mobile_client::MobileClient;
use codex_mobile_client::ffi::{AppClient, AppStore, ServerBridge, SshBridge};
use codex_mobile_client::session::connection::ServerConfig;
use codex_mobile_client::ssh::{SshAuth, SshCredentials};
use codex_mobile_client::store::snapshot::{AppSnapshot, ServerHealthSnapshot, ThreadSnapshot};
use codex_mobile_client::store::updates::AppStoreUpdateRecord;
use codex_mobile_client::types::{
    AppArchiveThreadRequest, AppInterruptTurnRequest, AppListThreadsRequest, AppReadThreadRequest,
    AppRenameThreadRequest, AppResumeThreadRequest, AppStartThreadRequest, AppStartTurnRequest,
    ApprovalDecisionValue, PendingUserInputAnswer, ThreadKey,
};
use tokio::io::AsyncBufReadExt;
use tokio::sync::RwLock;

#[derive(clap::Parser)]
#[command(
    name = "codex-debug-cli",
    about = "Debug CLI for MobileClient RPC and IPC flows"
)]
struct Args {
    #[command(subcommand)]
    command: Option<CliCommand>,

    /// Server host
    #[arg(long)]
    host: Option<String>,

    /// SSH port
    #[arg(long, default_value = "22")]
    ssh_port: u16,

    /// SSH username (if set, connects over SSH)
    #[arg(long, short)]
    user: Option<String>,

    /// SSH password
    #[arg(long, short)]
    password: Option<String>,

    /// Direct WebSocket URL (skip SSH)
    #[arg(long)]
    ws_url: Option<String>,

    /// WebSocket port for direct connection
    #[arg(long, default_value = "4321")]
    port: u16,

    /// Use TLS
    #[arg(long)]
    tls: bool,

    /// Override the remote IPC socket path when connecting over SSH.
    #[arg(long)]
    ipc_socket_path_override: Option<String>,
}

#[derive(clap::Subcommand)]
enum CliCommand {
    /// Connect to a server through the same MobileClient/AppStore paths the apps use.
    App(AppArgs),
    /// Connect to the Codex IPC bus using the shared mobile IPC client surface.
    Ipc(IpcArgs),
}

#[derive(clap::Args)]
struct AppArgs {
    /// Server host
    #[arg(long)]
    host: String,

    /// SSH port
    #[arg(long, default_value = "22")]
    ssh_port: u16,

    /// SSH username (if set, connects over SSH)
    #[arg(long, short)]
    user: Option<String>,

    /// SSH password
    #[arg(long, short)]
    password: Option<String>,

    /// Direct WebSocket URL (skip SSH)
    #[arg(long)]
    ws_url: Option<String>,

    /// WebSocket port for direct connection
    #[arg(long, default_value = "4321")]
    port: u16,

    /// Use TLS
    #[arg(long)]
    tls: bool,

    /// Override the remote IPC socket path when connecting over SSH.
    #[arg(long)]
    ipc_socket_path_override: Option<String>,

    #[command(subcommand)]
    command: AppCommand,
}

#[derive(clap::Subcommand)]
enum AppCommand {
    /// Keep one MobileClient connection open and drive app-like actions with JSONL stdin/stdout.
    Session,
}

#[derive(clap::Args)]
struct IpcArgs {
    #[arg(long)]
    socket_path: Option<PathBuf>,

    #[arg(long, default_value = "debug-cli")]
    client_type: String,

    #[arg(long, default_value = "10")]
    timeout_secs: u64,

    #[command(subcommand)]
    command: IpcCommand,
}

#[derive(clap::Subcommand)]
enum IpcCommand {
    /// Perform initialize and print the assigned client ID.
    Connect,
    /// List every known IPC method, grouped by kind/version.
    Methods,
    /// Listen for IPC broadcasts until interrupted.
    Listen {
        #[arg(long)]
        raw: bool,
    },
    /// Keep one IPC connection open and drive it with JSONL commands on stdin/stdout.
    Session,
    /// Send one IPC request using the same typed helper methods as the mobile apps.
    Call { method: String, params: String },
    /// Send one IPC broadcast with arbitrary JSON params.
    Broadcast { method: String, params: String },
    /// Register a simple request handler for inbound IPC routing tests.
    Serve {
        #[arg(long, value_delimiter = ',', default_value = "all")]
        methods: Vec<String>,

        #[arg(long, conflicts_with = "error")]
        result: Option<String>,

        #[arg(long)]
        error: Option<String>,
    },
}

struct ServerArgs {
    host: String,
    ssh_port: u16,
    user: Option<String>,
    password: Option<String>,
    ws_url: Option<String>,
    port: u16,
    tls: bool,
    ipc_socket_path_override: Option<String>,
}

#[derive(Clone)]
enum HandlerOutcome {
    Result(serde_json::Value),
    Error(String),
}

#[derive(Clone)]
struct HandlerConfig {
    methods: HashSet<Method>,
    outcome: HandlerOutcome,
}

struct ConfigurableIpcHandler {
    state: Arc<RwLock<Option<HandlerConfig>>>,
}

#[derive(Clone)]
struct OutputWriter {
    lock: Arc<Mutex<()>>,
}

impl OutputWriter {
    fn new() -> Self {
        Self {
            lock: Arc::new(Mutex::new(())),
        }
    }

    fn emit_json(&self, value: &serde_json::Value) -> Result<(), String> {
        let _guard = self
            .lock
            .lock()
            .map_err(|_| "stdout lock poisoned".to_string())?;
        let mut stdout = io::stdout().lock();
        serde_json::to_writer(&mut stdout, value)
            .map_err(|e| format!("failed to write JSON response: {e}"))?;
        writeln!(stdout).map_err(|e| format!("failed to write newline: {e}"))?;
        stdout
            .flush()
            .map_err(|e| format!("failed to flush stdout: {e}"))
    }
}

#[derive(serde::Deserialize)]
struct SessionInput {
    #[serde(default)]
    id: Option<String>,
    #[serde(flatten)]
    command: SessionCommand,
}

#[derive(serde::Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
enum SessionCommand {
    Status,
    Methods,
    Call {
        method: String,
        params: serde_json::Value,
    },
    Broadcast {
        method: String,
        params: serde_json::Value,
    },
    SetHandler {
        methods: Vec<String>,
        #[serde(default)]
        result: Option<serde_json::Value>,
        #[serde(default)]
        error: Option<String>,
    },
    ClearHandler,
    Quit,
}

#[derive(serde::Deserialize)]
struct AppSessionInput {
    #[serde(default)]
    id: Option<String>,
    #[serde(flatten)]
    command: AppSessionCommand,
}

#[derive(serde::Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
enum AppSessionCommand {
    Status,
    Snapshot,
    ListThreads {
        #[serde(default)]
        params: Option<AppListThreadsRequest>,
    },
    ReadThread {
        params: AppReadThreadRequest,
    },
    ThreadSnapshot {
        thread_id: String,
    },
    StartThread {
        params: AppStartThreadRequest,
    },
    ResumeThread {
        params: AppResumeThreadRequest,
    },
    StartTurn {
        params: AppStartTurnRequest,
    },
    ExternalResumeThread {
        thread_id: String,
        #[serde(default)]
        host_id: Option<String>,
    },
    InterruptTurn {
        params: AppInterruptTurnRequest,
    },
    EditMessage {
        thread_id: String,
        selected_turn_index: u32,
    },
    RespondToApproval {
        request_id: String,
        decision: ApprovalDecisionValue,
    },
    RespondToUserInput {
        request_id: String,
        answers: Vec<PendingUserInputAnswer>,
    },
    RenameThread {
        params: AppRenameThreadRequest,
    },
    ArchiveThread {
        params: AppArchiveThreadRequest,
    },
    Quit,
}

#[async_trait::async_trait]
impl RequestHandler for ConfigurableIpcHandler {
    async fn can_handle(&self, method: &Method, version: u32) -> bool {
        let guard = self.state.read().await;
        guard.as_ref().is_some_and(|state| {
            state.methods.contains(method) && version == method.current_version()
        })
    }

    async fn handle_request(
        &self,
        method: Method,
        request: TypedRequest,
    ) -> Result<serde_json::Value, String> {
        eprintln!("request {} {:?}", method.wire_name(), request);
        let guard = self.state.read().await;
        let Some(state) = guard.as_ref() else {
            return Err("handler-not-configured".to_string());
        };
        match &state.outcome {
            HandlerOutcome::Result(value) => Ok(value.clone()),
            HandlerOutcome::Error(error) => Err(error.clone()),
        }
    }
}

static REQUEST_COUNTER: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(1);

fn next_id() -> upstream::RequestId {
    upstream::RequestId::Integer(REQUEST_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed))
}

fn ok(msg: &str) {
    println!("\x1b[32m{msg}\x1b[0m");
}

fn err(msg: &str) {
    eprintln!("\x1b[31merror:\x1b[0m {msg}");
}

fn server_help() {
    println!(
        r#"
  list [limit]               List threads (syncs to store)
  read <thread_id>           Read thread (syncs to store)
  start [cwd]                Start new thread
  open <thread_id>           Load thread and mark it active in the store
  open-ios <thread_id>       Follow the same metadata-read + deferred hydrate path the iOS app uses
  resume <thread_id>         Resume thread
  wait <thread_id>           Wait until thread is idle
  send <thread_id> <msg>     Send a message (turn/start)
  archive <thread_id>        Archive thread
  rename <thread_id> <name>  Rename thread
  models                     List models
  features                   List experimental features
  skills                     List skills
  auth-status                Auth status
  snapshot                   Dump app store snapshot
  help                       This help
  quit                       Exit
"#
    );
}

async fn wait_for_thread_idle(
    app_store: &AppStore,
    key: ThreadKey,
    timeout: Duration,
) -> Result<(), String> {
    let started = std::time::Instant::now();
    loop {
        match app_store.thread_snapshot(key.clone()).await {
            Ok(Some(thread)) => {
                if thread.active_turn_id.is_none()
                    && !matches!(
                        thread.info.status,
                        codex_mobile_client::types::ThreadSummaryStatus::Active
                    )
                {
                    return Ok(());
                }
            }
            Ok(None) => {}
            Err(error) => return Err(error.to_string()),
        }

        if started.elapsed() >= timeout {
            return Err(format!("timed out waiting for thread {}", key.thread_id));
        }

        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

fn format_broadcast(tb: &TypedBroadcast) -> String {
    match tb {
        TypedBroadcast::ClientStatusChanged(p) => {
            format!(
                "client-status-changed client={} type={} status={:?}",
                p.client_id, p.client_type, p.status
            )
        }
        TypedBroadcast::ThreadStreamStateChanged(p) => match &p.change {
            codex_ipc::StreamChange::Snapshot { .. } => {
                format!(
                    "thread-stream-state-changed conv={} change=snapshot version={}",
                    p.conversation_id, p.version
                )
            }
            codex_ipc::StreamChange::Patches { patches } => {
                format!(
                    "thread-stream-state-changed conv={} patches={} version={}",
                    p.conversation_id,
                    patches.len(),
                    p.version
                )
            }
        },
        TypedBroadcast::ThreadArchived(p) => {
            format!(
                "thread-archived conv={} host={} cwd={}",
                p.conversation_id, p.host_id, p.cwd
            )
        }
        TypedBroadcast::ThreadUnarchived(p) => {
            format!(
                "thread-unarchived conv={} host={}",
                p.conversation_id, p.host_id
            )
        }
        TypedBroadcast::ThreadQueuedFollowupsChanged(p) => {
            format!(
                "thread-queued-followups-changed conv={} messages={}",
                p.conversation_id,
                p.messages.len()
            )
        }
        TypedBroadcast::QueryCacheInvalidate(p) => {
            format!("query-cache-invalidate key={:?}", p.query_key)
        }
        TypedBroadcast::Unknown { method, params } => {
            format!("unknown method={method} params={params}")
        }
    }
}

/// Same as AppClient's rpc() — send ClientRequest, deserialize response.
async fn rpc<T: serde::de::DeserializeOwned>(
    client: &MobileClient,
    server_id: &str,
    request: upstream::ClientRequest,
) -> Result<T, String> {
    client.request_typed_for_server(server_id, request).await
}

macro_rules! req {
    ($variant:ident, $params:expr) => {
        upstream::ClientRequest::$variant {
            request_id: next_id(),
            params: $params,
        }
    };
}

fn print_update(update: &AppStoreUpdateRecord) {
    use AppStoreUpdateRecord::*;
    match update {
        ThreadStreamingDelta {
            key,
            item_id,
            kind,
            text,
        } => {
            eprint!(
                "\x1b[33m[delta {}/{}:{:?}]\x1b[0m {}",
                key.thread_id, item_id, kind, text
            );
        }
        ThreadItemChanged { key, item, .. } => {
            eprintln!(
                "\x1b[36m[item {}/{}]\x1b[0m {:?}",
                key.server_id, key.thread_id, item
            );
        }
        ThreadMetadataChanged { state, .. } => {
            eprintln!(
                "\x1b[35m[state {}]\x1b[0m {:?}",
                state.key.thread_id, state.info.status
            );
        }
        ThreadUpserted { thread, .. } => {
            eprintln!(
                "\x1b[34m[thread {}]\x1b[0m {:?}",
                thread.key.thread_id, thread.info.status
            );
        }
        PendingApprovalsChanged { approvals } => {
            eprintln!("\x1b[31m[approvals]\x1b[0m {} pending", approvals.len());
            for approval in approvals {
                eprintln!("  {:?}", approval);
            }
        }
        PendingUserInputsChanged { requests } => {
            eprintln!("\x1b[31m[user-inputs]\x1b[0m {} pending", requests.len());
        }
        ServerChanged { server_id } => {
            eprintln!("\x1b[90m[server changed]\x1b[0m {server_id}");
        }
        _ => {
            eprintln!("\x1b[90m[update]\x1b[0m {update:?}");
        }
    }
}

fn server_health_json(health: &ServerHealthSnapshot) -> serde_json::Value {
    serde_json::Value::String(
        match health {
            ServerHealthSnapshot::Disconnected => "disconnected",
            ServerHealthSnapshot::Connecting => "connecting",
            ServerHealthSnapshot::Connected => "connected",
            ServerHealthSnapshot::Unresponsive => "unresponsive",
            ServerHealthSnapshot::Unknown(_) => "unknown",
        }
        .to_string(),
    )
}

fn server_snapshot_json(
    snapshot: &codex_mobile_client::store::snapshot::ServerSnapshot,
) -> serde_json::Value {
    serde_json::json!({
        "serverId": snapshot.server_id,
        "displayName": snapshot.display_name,
        "host": snapshot.host,
        "port": snapshot.port,
        "isLocal": snapshot.is_local,
        "hasIpc": snapshot.has_ipc,
        "health": server_health_json(&snapshot.health),
        "requiresOpenaiAuth": snapshot.requires_openai_auth,
        "account": snapshot.account,
        "rateLimits": snapshot.rate_limits,
        "availableModels": snapshot.available_models,
        "connectionProgress": format!("{:?}", snapshot.connection_progress),
    })
}

fn thread_snapshot_json(thread: &ThreadSnapshot) -> serde_json::Value {
    serde_json::json!({
        "key": thread.key,
        "info": thread.info,
        "model": thread.model,
        "reasoningEffort": thread.reasoning_effort,
        "effectiveApprovalPolicy": thread.effective_approval_policy,
        "effectiveSandboxPolicy": thread.effective_sandbox_policy,
        "items": thread.items,
        "localOverlayItems": thread.local_overlay_items,
        "queuedFollowUps": thread.queued_follow_ups.iter().map(|preview| serde_json::json!({
            "id": preview.id,
            "text": preview.text,
        })).collect::<Vec<_>>(),
        "activeTurnId": thread.active_turn_id,
        "contextTokensUsed": thread.context_tokens_used,
        "modelContextWindow": thread.model_context_window,
        "rateLimits": thread.rate_limits,
        "realtimeSessionId": thread.realtime_session_id,
    })
}

fn app_snapshot_json(snapshot: &AppSnapshot, server_id: &str) -> serde_json::Value {
    let mut server_ids = snapshot.servers.keys().cloned().collect::<Vec<_>>();
    server_ids.sort();
    let mut thread_entries = snapshot
        .threads
        .values()
        .filter(|thread| thread.key.server_id == server_id)
        .collect::<Vec<_>>();
    thread_entries.sort_by(|lhs, rhs| lhs.key.thread_id.cmp(&rhs.key.thread_id));

    serde_json::json!({
        "server": snapshot.servers.get(server_id).map(server_snapshot_json),
        "servers": server_ids,
        "threads": thread_entries.into_iter().map(thread_snapshot_json).collect::<Vec<_>>(),
        "activeThread": snapshot.active_thread,
        "pendingApprovals": snapshot.pending_approvals,
        "pendingUserInputs": snapshot.pending_user_inputs,
        "voiceSession": format!("{:?}", snapshot.voice_session),
    })
}

fn app_update_event(update: &AppStoreUpdateRecord) -> serde_json::Value {
    match update {
        AppStoreUpdateRecord::FullResync => serde_json::json!({
            "event": "app-update",
            "kind": "full-resync",
        }),
        AppStoreUpdateRecord::ServerChanged { server_id } => serde_json::json!({
            "event": "app-update",
            "kind": "server-changed",
            "serverId": server_id,
        }),
        AppStoreUpdateRecord::ServerRemoved { server_id } => serde_json::json!({
            "event": "app-update",
            "kind": "server-removed",
            "serverId": server_id,
        }),
        AppStoreUpdateRecord::ThreadUpserted { thread, .. } => serde_json::json!({
            "event": "app-update",
            "kind": "thread-upserted",
            "threadId": thread.key.thread_id,
            "serverId": thread.key.server_id,
            "status": thread.info.status,
            "activeTurnId": thread.active_turn_id,
        }),
        AppStoreUpdateRecord::ThreadMetadataChanged { state, .. } => serde_json::json!({
            "event": "app-update",
            "kind": "thread-metadata-changed",
            "threadId": state.key.thread_id,
            "serverId": state.key.server_id,
            "status": state.info.status,
            "activeTurnId": state.active_turn_id,
            "queuedFollowUps": state.queued_follow_ups.iter().map(|preview| serde_json::json!({
                "id": preview.id,
                "text": preview.text,
            })).collect::<Vec<_>>(),
        }),
        AppStoreUpdateRecord::ThreadItemChanged { key, item, .. } => serde_json::json!({
            "event": "app-update",
            "kind": "thread-item-changed",
            "threadId": key.thread_id,
            "serverId": key.server_id,
            "item": item,
        }),
        AppStoreUpdateRecord::ThreadStreamingDelta {
            key,
            item_id,
            kind,
            text,
        } => serde_json::json!({
            "event": "app-update",
            "kind": "thread-streaming-delta",
            "threadId": key.thread_id,
            "serverId": key.server_id,
            "itemId": item_id,
            "deltaKind": format!("{kind:?}"),
            "text": text,
        }),
        AppStoreUpdateRecord::ThreadRemoved { key, .. } => serde_json::json!({
            "event": "app-update",
            "kind": "thread-removed",
            "threadId": key.thread_id,
            "serverId": key.server_id,
        }),
        AppStoreUpdateRecord::ActiveThreadChanged { key } => serde_json::json!({
            "event": "app-update",
            "kind": "active-thread-changed",
            "key": key,
        }),
        AppStoreUpdateRecord::PendingApprovalsChanged { approvals } => serde_json::json!({
            "event": "app-update",
            "kind": "pending-approvals-changed",
            "approvals": approvals,
        }),
        AppStoreUpdateRecord::PendingUserInputsChanged { requests } => serde_json::json!({
            "event": "app-update",
            "kind": "pending-user-inputs-changed",
            "requests": requests,
        }),
        other => serde_json::json!({
            "event": "app-update",
            "kind": "other",
            "debug": format!("{other:?}"),
        }),
    }
}

async fn connect_mobile_client(args: &AppArgs) -> Result<(Arc<MobileClient>, String), String> {
    let client = Arc::new(MobileClient::new());
    let server_id = "debug-cli-app".to_string();
    let config = ServerConfig {
        server_id: server_id.clone(),
        display_name: args.host.clone(),
        host: args.host.clone(),
        port: args.port,
        websocket_url: args.ws_url.clone(),
        is_local: false,
        tls: args.tls,
    };

    if let Some(user) = &args.user {
        let password = args.password.clone().unwrap_or_default();
        let creds = SshCredentials {
            host: args.host.clone(),
            port: args.ssh_port,
            username: user.clone(),
            auth: SshAuth::Password(password),
            unlock_macos_keychain: false,
        };
        client
            .connect_remote_over_ssh(
                config,
                creds,
                true,
                None,
                args.ipc_socket_path_override.clone(),
            )
            .await
            .map_err(|e| e.to_string())?;
    } else {
        client
            .connect_remote(config)
            .await
            .map_err(|e| e.to_string())?;
    }

    Ok((client, server_id))
}

async fn app_list_threads(
    client: &MobileClient,
    server_id: &str,
    params: AppListThreadsRequest,
) -> Result<serde_json::Value, String> {
    let response: upstream::ThreadListResponse =
        rpc(client, server_id, req!(ThreadList, params.into())).await?;
    client
        .sync_thread_list(server_id, &response.data)
        .map_err(|e| format!("sync: {e}"))?;
    Ok(serde_json::json!({
        "threads": response.data,
    }))
}

async fn app_read_thread(
    client: &MobileClient,
    server_id: &str,
    params: AppReadThreadRequest,
) -> Result<serde_json::Value, String> {
    let response: upstream::ThreadReadResponse =
        rpc(client, server_id, req!(ThreadRead, params.into())).await?;
    let key = client
        .apply_thread_read_response(server_id, &response)
        .map_err(|e| format!("sync: {e}"))?;
    Ok(serde_json::json!({
        "key": key,
        "thread": response.thread,
    }))
}

async fn app_start_thread(
    client: &MobileClient,
    server_id: &str,
    params: AppStartThreadRequest,
) -> Result<serde_json::Value, String> {
    let params = upstream::ThreadStartParams::try_from(params).map_err(|e| e.to_string())?;
    let response: upstream::ThreadStartResponse =
        rpc(client, server_id, req!(ThreadStart, params)).await?;
    let key = client
        .apply_thread_start_response(server_id, &response)
        .map_err(|e| format!("sync: {e}"))?;
    Ok(serde_json::json!({
        "key": key,
        "thread": response.thread,
    }))
}

async fn app_resume_thread(
    client: &MobileClient,
    server_id: &str,
    params: AppResumeThreadRequest,
) -> Result<serde_json::Value, String> {
    let params = upstream::ThreadResumeParams::try_from(params).map_err(|e| e.to_string())?;
    let response: upstream::ThreadResumeResponse =
        rpc(client, server_id, req!(ThreadResume, params)).await?;
    let key = client
        .apply_thread_resume_response(server_id, &response)
        .map_err(|e| format!("sync: {e}"))?;
    Ok(serde_json::json!({
        "key": key,
        "thread": response.thread,
    }))
}

async fn app_open_thread_like_ios(
    app_client: &AppClient,
    app_store: &AppStore,
    server_id: &str,
    thread_id: &str,
) -> Result<ThreadKey, String> {
    let key = ThreadKey {
        server_id: server_id.to_string(),
        thread_id: thread_id.to_string(),
    };

    app_client
        .read_thread(
            server_id.to_string(),
            AppReadThreadRequest {
                thread_id: thread_id.to_string(),
                include_turns: false,
            },
        )
        .await
        .map_err(|error| error.to_string())?;

    app_store.set_active_thread(Some(key.clone()));

    tokio::time::sleep(Duration::from_millis(300)).await;
    let needs_deferred_hydration = match app_store.thread_snapshot(key.clone()).await {
        Ok(Some(thread)) => {
            let preview = thread.info.preview.as_deref().unwrap_or_default().trim();
            let title = thread.info.title.as_deref().unwrap_or_default().trim();
            thread.hydrated_conversation_items.is_empty()
                && (!preview.is_empty() || !title.is_empty() || thread.active_turn_id.is_some())
        }
        Ok(None) => true,
        Err(error) => return Err(error.to_string()),
    };

    if needs_deferred_hydration {
        app_client
            .read_thread(
                server_id.to_string(),
                AppReadThreadRequest {
                    thread_id: thread_id.to_string(),
                    include_turns: true,
                },
            )
            .await
            .map_err(|error| error.to_string())?;
    }

    Ok(key)
}

fn parse_json_value(input: &str) -> Result<serde_json::Value, String> {
    if let Some(path) = input.strip_prefix('@') {
        let raw = std::fs::read_to_string(path)
            .map_err(|e| format!("failed to read JSON from {path}: {e}"))?;
        serde_json::from_str(&raw).map_err(|e| format!("invalid JSON in {path}: {e}"))
    } else {
        serde_json::from_str(input).map_err(|e| format!("invalid JSON: {e}"))
    }
}

fn parse_method(name: &str) -> Result<Method, String> {
    Method::from_wire(name).ok_or_else(|| format!("unknown IPC method: {name}"))
}

fn parse_request_methods(names: &[String]) -> Result<HashSet<Method>, String> {
    if names.len() == 1 && names[0] == "all" {
        return Ok(Method::all()
            .iter()
            .copied()
            .filter(|method| method.kind() == MethodKind::Request)
            .collect());
    }

    let mut methods = HashSet::new();
    for name in names {
        let method = parse_method(name)?;
        if method.kind() != MethodKind::Request {
            return Err(format!(
                "{} is not a request method the mobile apps call",
                method.wire_name()
            ));
        }
        methods.insert(method);
    }
    Ok(methods)
}

fn handler_config_from_inputs(
    methods: &[String],
    result: Option<serde_json::Value>,
    error: Option<String>,
) -> Result<HandlerConfig, String> {
    let methods = parse_request_methods(methods)?;
    let outcome = if let Some(error) = error {
        HandlerOutcome::Error(error)
    } else if let Some(result) = result {
        HandlerOutcome::Result(result)
    } else {
        HandlerOutcome::Result(serde_json::json!({ "ok": true }))
    };
    Ok(HandlerConfig { methods, outcome })
}

fn ipc_config(args: &IpcArgs) -> IpcClientConfig {
    IpcClientConfig {
        socket_path: args
            .socket_path
            .clone()
            .unwrap_or_else(socket::resolve_socket_path),
        client_type: args.client_type.clone(),
        request_timeout: Duration::from_secs(args.timeout_secs),
    }
}

fn print_ipc_methods() {
    for method in Method::all() {
        let kind = match method.kind() {
            MethodKind::Handshake => "handshake",
            MethodKind::Request => "request",
            MethodKind::Broadcast => "broadcast",
        };
        println!(
            "{:<52} kind={:<10} version={}",
            method.wire_name(),
            kind,
            method.current_version()
        );
    }
}

fn ipc_methods_json() -> serde_json::Value {
    serde_json::Value::Array(
        Method::all()
            .iter()
            .map(|method| {
                serde_json::json!({
                    "method": method.wire_name(),
                    "kind": match method.kind() {
                        MethodKind::Handshake => "handshake",
                        MethodKind::Request => "request",
                        MethodKind::Broadcast => "broadcast",
                    },
                    "version": method.current_version(),
                })
            })
            .collect(),
    )
}

fn typed_broadcast_event(message: &TypedBroadcast) -> serde_json::Value {
    match message {
        TypedBroadcast::ClientStatusChanged(params) => serde_json::json!({
            "event": "broadcast",
            "method": Method::ClientStatusChanged.wire_name(),
            "params": params,
        }),
        TypedBroadcast::ThreadStreamStateChanged(params) => serde_json::json!({
            "event": "broadcast",
            "method": Method::ThreadStreamStateChanged.wire_name(),
            "params": params,
        }),
        TypedBroadcast::ThreadArchived(params) => serde_json::json!({
            "event": "broadcast",
            "method": Method::ThreadArchived.wire_name(),
            "params": params,
        }),
        TypedBroadcast::ThreadUnarchived(params) => serde_json::json!({
            "event": "broadcast",
            "method": Method::ThreadUnarchived.wire_name(),
            "params": params,
        }),
        TypedBroadcast::ThreadQueuedFollowupsChanged(params) => serde_json::json!({
            "event": "broadcast",
            "method": Method::ThreadQueuedFollowupsChanged.wire_name(),
            "params": params,
        }),
        TypedBroadcast::QueryCacheInvalidate(params) => serde_json::json!({
            "event": "broadcast",
            "method": Method::QueryCacheInvalidate.wire_name(),
            "params": params,
        }),
        TypedBroadcast::Unknown { method, params } => serde_json::json!({
            "event": "broadcast",
            "method": method,
            "params": params,
        }),
    }
}

fn print_json(value: &serde_json::Value) -> Result<(), String> {
    let pretty =
        serde_json::to_string_pretty(value).map_err(|e| format!("failed to format JSON: {e}"))?;
    println!("{pretty}");
    Ok(())
}

async fn connect_ipc(config: &IpcClientConfig) -> Result<IpcClient, String> {
    IpcClient::connect_with_config(config)
        .await
        .map_err(|e| format!("{e}"))
}

async fn send_mobile_request(
    client: &IpcClient,
    method: Method,
    params: serde_json::Value,
) -> Result<serde_json::Value, String> {
    match method {
        Method::ThreadFollowerStartTurn => client
            .start_turn(
                serde_json::from_value::<ThreadFollowerStartTurnParams>(params)
                    .map_err(|e| format!("invalid params for {}: {e}", method.wire_name()))?,
            )
            .await
            .map_err(|e| format!("{e}")),
        Method::ThreadFollowerSteerTurn => client
            .steer_turn(
                serde_json::from_value::<ThreadFollowerSteerTurnParams>(params)
                    .map_err(|e| format!("invalid params for {}: {e}", method.wire_name()))?,
            )
            .await
            .map_err(|e| format!("{e}")),
        Method::ThreadFollowerInterruptTurn => client
            .interrupt_turn(
                serde_json::from_value::<ThreadFollowerInterruptTurnParams>(params)
                    .map_err(|e| format!("invalid params for {}: {e}", method.wire_name()))?,
            )
            .await
            .map_err(|e| format!("{e}")),
        Method::ThreadFollowerSetModelAndReasoning => client
            .set_model_and_reasoning(
                serde_json::from_value::<ThreadFollowerSetModelAndReasoningParams>(params)
                    .map_err(|e| format!("invalid params for {}: {e}", method.wire_name()))?,
            )
            .await
            .map_err(|e| format!("{e}")),
        Method::ThreadFollowerSetCollaborationMode => client
            .set_collaboration_mode(
                serde_json::from_value::<ThreadFollowerSetCollaborationModeParams>(params)
                    .map_err(|e| format!("invalid params for {}: {e}", method.wire_name()))?,
            )
            .await
            .map_err(|e| format!("{e}")),
        Method::ThreadFollowerEditLastUserTurn => client
            .edit_last_user_turn(
                serde_json::from_value::<ThreadFollowerEditLastUserTurnParams>(params)
                    .map_err(|e| format!("invalid params for {}: {e}", method.wire_name()))?,
            )
            .await
            .map_err(|e| format!("{e}")),
        Method::ThreadFollowerCommandApprovalDecision => client
            .command_approval_decision(
                serde_json::from_value::<ThreadFollowerCommandApprovalDecisionParams>(params)
                    .map_err(|e| format!("invalid params for {}: {e}", method.wire_name()))?,
            )
            .await
            .map_err(|e| format!("{e}")),
        Method::ThreadFollowerFileApprovalDecision => client
            .file_approval_decision(
                serde_json::from_value::<ThreadFollowerFileApprovalDecisionParams>(params)
                    .map_err(|e| format!("invalid params for {}: {e}", method.wire_name()))?,
            )
            .await
            .map_err(|e| format!("{e}")),
        Method::ThreadFollowerSubmitUserInput => client
            .submit_user_input(
                serde_json::from_value::<ThreadFollowerSubmitUserInputParams>(params)
                    .map_err(|e| format!("invalid params for {}: {e}", method.wire_name()))?,
            )
            .await
            .map_err(|e| format!("{e}")),
        Method::ThreadFollowerSubmitMcpServerElicitationResponse => client
            .submit_mcp_server_elicitation_response(
                serde_json::from_value::<ThreadFollowerSubmitMcpServerElicitationResponseParams>(
                    params,
                )
                .map_err(|e| format!("invalid params for {}: {e}", method.wire_name()))?,
            )
            .await
            .map_err(|e| format!("{e}")),
        Method::ThreadFollowerSetQueuedFollowUpsState => client
            .set_queued_follow_ups_state(
                serde_json::from_value::<ThreadFollowerSetQueuedFollowUpsStateParams>(params)
                    .map_err(|e| format!("invalid params for {}: {e}", method.wire_name()))?,
            )
            .await
            .map_err(|e| format!("{e}")),
        Method::Initialize => Err("initialize is handled by IPC connect".to_string()),
        Method::ClientStatusChanged
        | Method::ThreadStreamStateChanged
        | Method::ThreadArchived
        | Method::ThreadUnarchived
        | Method::ThreadQueuedFollowupsChanged
        | Method::QueryCacheInvalidate => Err(format!(
            "{} is a broadcast, not a request",
            method.wire_name()
        )),
    }
}

async fn run_ipc_command(args: IpcArgs) -> Result<(), String> {
    let config = ipc_config(&args);

    match args.command {
        IpcCommand::Connect => {
            let client = connect_ipc(&config).await?;
            println!(
                "connected socket={} client_type={} client_id={}",
                config.socket_path.display(),
                config.client_type,
                client.client_id()
            );
            Ok(())
        }
        IpcCommand::Methods => {
            print_ipc_methods();
            Ok(())
        }
        IpcCommand::Listen { raw } => {
            if raw {
                run_ipc_raw_listener(&config).await
            } else {
                run_ipc_typed_listener(&config).await
            }
        }
        IpcCommand::Session => run_ipc_session(&config).await,
        IpcCommand::Call { method, params } => {
            let method = parse_method(&method)?;
            if method.kind() != MethodKind::Request {
                return Err(format!(
                    "{} is not a request method the mobile apps call",
                    method.wire_name()
                ));
            }
            let params = parse_json_value(&params)?;
            let client = connect_ipc(&config).await?;
            let result = send_mobile_request(&client, method, params).await?;
            print_json(&result)
        }
        IpcCommand::Broadcast { method, params } => {
            let method = parse_method(&method)?;
            if method.kind() != MethodKind::Broadcast {
                return Err(format!("{} is not a broadcast method", method.wire_name()));
            }
            let params = parse_json_value(&params)?;
            let client = connect_ipc(&config).await?;
            client
                .send_broadcast(method, &params)
                .await
                .map_err(|e| format!("{e}"))?;
            ok("broadcast sent");
            Ok(())
        }
        IpcCommand::Serve {
            methods,
            result,
            error,
        } => {
            let handler_state = Arc::new(RwLock::new(Some(handler_config_from_inputs(
                &methods,
                match result {
                    Some(value) => Some(parse_json_value(&value)?),
                    None => None,
                },
                error,
            )?)));
            let client = connect_ipc(&config).await?;
            let handler = ConfigurableIpcHandler {
                state: handler_state.clone(),
            };
            client.set_request_handler(Arc::new(handler)).await;
            let allowed_methods = {
                let guard = handler_state.read().await;
                guard
                    .as_ref()
                    .map(|state| state.methods.clone())
                    .unwrap_or_default()
            };

            println!(
                "serving socket={} client_id={}",
                config.socket_path.display(),
                client.client_id()
            );
            for method in Method::all() {
                if allowed_methods.contains(method) {
                    println!("  {}", method.wire_name());
                }
            }
            println!("waiting for IPC requests...");
            std::future::pending::<()>().await;
            Ok(())
        }
    }
}

async fn run_ipc_typed_listener(config: &IpcClientConfig) -> Result<(), String> {
    let client = connect_ipc(config).await?;
    println!(
        "listening socket={} client_id={}",
        config.socket_path.display(),
        client.client_id()
    );

    let mut rx = client.subscribe_broadcasts();
    loop {
        match rx.recv().await {
            Ok(message) => println!("{}", format_broadcast(&message)),
            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                eprintln!("lagged, missed {n} broadcasts");
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                return Ok(());
            }
        }
    }
}

async fn run_ipc_raw_listener(config: &IpcClientConfig) -> Result<(), String> {
    let stream = socket::connect_unix(&config.socket_path)
        .await
        .map_err(|e| format!("{e}"))?;
    let (mut reader, mut writer) = stream.into_split();

    let init_envelope = Envelope::Request(Request {
        request_id: format!(
            "raw-listener-{}",
            REQUEST_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ),
        source_client_id: "initializing-client".to_string(),
        version: Method::Initialize.current_version(),
        method: Method::Initialize.wire_name().to_string(),
        params: serde_json::to_value(InitializeParams {
            client_type: config.client_type.clone(),
        })
        .map_err(|e| format!("failed to serialize initialize params: {e}"))?,
        target_client_id: None,
    });

    let json = serde_json::to_string(&init_envelope)
        .map_err(|e| format!("failed to serialize initialize envelope: {e}"))?;
    frame::write_frame(&mut writer, &json)
        .await
        .map_err(|e| format!("failed to send initialize: {e}"))?;

    println!("raw listening socket={}", config.socket_path.display());
    loop {
        let raw = frame::read_frame(&mut reader)
            .await
            .map_err(|e| format!("read error: {e}"))?;
        match serde_json::from_str::<serde_json::Value>(&raw) {
            Ok(value) => print_json(&value)?,
            Err(_) => println!("{raw}"),
        }
    }
}

async fn run_ipc_session(config: &IpcClientConfig) -> Result<(), String> {
    let client = connect_ipc(config).await?;
    let output = OutputWriter::new();
    let handler_state = Arc::new(RwLock::new(None));
    let handler = ConfigurableIpcHandler {
        state: handler_state.clone(),
    };
    client.set_request_handler(Arc::new(handler)).await;

    output.emit_json(&serde_json::json!({
        "event": "connected",
        "clientId": client.client_id(),
        "clientType": config.client_type,
        "socketPath": config.socket_path,
    }))?;

    let mut broadcasts = client.subscribe_broadcasts();
    let broadcast_output = output.clone();
    tokio::spawn(async move {
        loop {
            match broadcasts.recv().await {
                Ok(message) => {
                    if let Err(error) = broadcast_output.emit_json(&typed_broadcast_event(&message))
                    {
                        eprintln!("failed to emit broadcast: {error}");
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    let _ = broadcast_output.emit_json(&serde_json::json!({
                        "event": "warning",
                        "warning": format!("lagged, missed {n} broadcasts"),
                    }));
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });

    let stdin = tokio::io::BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();

    while let Some(line) = lines.next_line().await.map_err(|e| format!("{e}"))? {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        let input: SessionInput = match serde_json::from_str(line) {
            Ok(input) => input,
            Err(error) => {
                output.emit_json(&serde_json::json!({
                    "ok": false,
                    "error": format!("invalid session command JSON: {error}"),
                }))?;
                continue;
            }
        };

        let response = match input.command {
            SessionCommand::Status => {
                let handler_methods = {
                    let guard = handler_state.read().await;
                    guard
                        .as_ref()
                        .map(|state| {
                            state
                                .methods
                                .iter()
                                .map(|method| method.wire_name().to_string())
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default()
                };
                serde_json::json!({
                    "id": input.id,
                    "ok": true,
                    "result": {
                        "clientId": client.client_id(),
                        "clientType": config.client_type,
                        "socketPath": config.socket_path,
                        "handlerMethods": handler_methods,
                    }
                })
            }
            SessionCommand::Methods => serde_json::json!({
                "id": input.id,
                "ok": true,
                "result": ipc_methods_json(),
            }),
            SessionCommand::Call { method, params } => match parse_method(&method) {
                Ok(method) if method.kind() == MethodKind::Request => {
                    match send_mobile_request(&client, method, params).await {
                        Ok(result) => serde_json::json!({
                            "id": input.id,
                            "ok": true,
                            "result": result,
                        }),
                        Err(error) => serde_json::json!({
                            "id": input.id,
                            "ok": false,
                            "error": error,
                        }),
                    }
                }
                Ok(method) => serde_json::json!({
                    "id": input.id,
                    "ok": false,
                    "error": format!("{} is not a request method the mobile apps call", method.wire_name()),
                }),
                Err(error) => serde_json::json!({
                    "id": input.id,
                    "ok": false,
                    "error": error,
                }),
            },
            SessionCommand::Broadcast { method, params } => match parse_method(&method) {
                Ok(method) if method.kind() == MethodKind::Broadcast => {
                    match client.send_broadcast(method, &params).await {
                        Ok(_) => serde_json::json!({
                            "id": input.id,
                            "ok": true,
                            "result": { "sent": true },
                        }),
                        Err(error) => serde_json::json!({
                            "id": input.id,
                            "ok": false,
                            "error": format!("{error}"),
                        }),
                    }
                }
                Ok(method) => serde_json::json!({
                    "id": input.id,
                    "ok": false,
                    "error": format!("{} is not a broadcast method", method.wire_name()),
                }),
                Err(error) => serde_json::json!({
                    "id": input.id,
                    "ok": false,
                    "error": error,
                }),
            },
            SessionCommand::SetHandler {
                methods,
                result,
                error,
            } => match handler_config_from_inputs(&methods, result, error) {
                Ok(config_update) => {
                    let method_names = config_update
                        .methods
                        .iter()
                        .map(|method| method.wire_name().to_string())
                        .collect::<Vec<_>>();
                    let mut guard = handler_state.write().await;
                    *guard = Some(config_update);
                    serde_json::json!({
                        "id": input.id,
                        "ok": true,
                        "result": {
                            "handlerMethods": method_names,
                        }
                    })
                }
                Err(error) => serde_json::json!({
                    "id": input.id,
                    "ok": false,
                    "error": error,
                }),
            },
            SessionCommand::ClearHandler => {
                let mut guard = handler_state.write().await;
                *guard = None;
                serde_json::json!({
                    "id": input.id,
                    "ok": true,
                    "result": { "handlerCleared": true },
                })
            }
            SessionCommand::Quit => {
                output.emit_json(&serde_json::json!({
                    "id": input.id,
                    "ok": true,
                    "result": { "quitting": true },
                }))?;
                return Ok(());
            }
        };

        output.emit_json(&response)?;
    }

    Ok(())
}

async fn run_app_command(args: AppArgs) -> Result<(), String> {
    match args.command {
        AppCommand::Session => run_app_session(&args).await,
    }
}

async fn run_app_session(args: &AppArgs) -> Result<(), String> {
    let (client, server_id) = connect_mobile_client(args).await?;
    let output = OutputWriter::new();

    output.emit_json(&serde_json::json!({
        "event": "connected",
        "mode": "app",
        "serverId": server_id,
        "host": args.host,
        "transport": if args.user.is_some() { "ssh" } else { "direct" },
    }))?;

    let mut updates = client.subscribe_app_updates();
    let updates_output = output.clone();
    tokio::spawn(async move {
        loop {
            match updates.recv().await {
                Ok(update) => {
                    if let Err(error) = updates_output.emit_json(&app_update_event(&update)) {
                        eprintln!("failed to emit app update: {error}");
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    let _ = updates_output.emit_json(&serde_json::json!({
                        "event": "warning",
                        "warning": format!("lagged, missed {n} app updates"),
                    }));
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });

    let stdin = tokio::io::BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();

    while let Some(line) = lines.next_line().await.map_err(|e| format!("{e}"))? {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        let input: AppSessionInput = match serde_json::from_str(line) {
            Ok(input) => input,
            Err(error) => {
                output.emit_json(&serde_json::json!({
                    "ok": false,
                    "error": format!("invalid app session command JSON: {error}"),
                }))?;
                continue;
            }
        };

        let response = match input.command {
            AppSessionCommand::Status => {
                let snapshot = client.app_snapshot();
                serde_json::json!({
                    "id": input.id,
                    "ok": true,
                    "result": {
                        "server": snapshot.servers.get(&server_id).map(server_snapshot_json),
                        "activeThread": snapshot.active_thread,
                        "pendingApprovalCount": snapshot.pending_approvals.len(),
                        "pendingUserInputCount": snapshot.pending_user_inputs.len(),
                    }
                })
            }
            AppSessionCommand::Snapshot => {
                let snapshot = client.app_snapshot();
                serde_json::json!({
                    "id": input.id,
                    "ok": true,
                    "result": app_snapshot_json(&snapshot, &server_id),
                })
            }
            AppSessionCommand::ListThreads { params } => match app_list_threads(
                client.as_ref(),
                &server_id,
                params.unwrap_or(AppListThreadsRequest {
                    cursor: None,
                    limit: None,
                    archived: None,
                    cwd: None,
                    search_term: None,
                }),
            )
            .await
            {
                Ok(result) => serde_json::json!({
                    "id": input.id,
                    "ok": true,
                    "result": result,
                }),
                Err(error) => serde_json::json!({
                    "id": input.id,
                    "ok": false,
                    "error": error,
                }),
            },
            AppSessionCommand::ReadThread { params } => {
                match app_read_thread(client.as_ref(), &server_id, params).await {
                    Ok(result) => serde_json::json!({
                        "id": input.id,
                        "ok": true,
                        "result": result,
                    }),
                    Err(error) => serde_json::json!({
                        "id": input.id,
                        "ok": false,
                        "error": error,
                    }),
                }
            }
            AppSessionCommand::ThreadSnapshot { thread_id } => {
                let snapshot = client.app_snapshot();
                let key = ThreadKey {
                    server_id: server_id.clone(),
                    thread_id,
                };
                match snapshot.threads.get(&key) {
                    Some(thread) => serde_json::json!({
                        "id": input.id,
                        "ok": true,
                        "result": thread_snapshot_json(thread),
                    }),
                    None => serde_json::json!({
                        "id": input.id,
                        "ok": false,
                        "error": format!("thread not loaded: {}", key.thread_id),
                    }),
                }
            }
            AppSessionCommand::StartThread { params } => {
                match app_start_thread(client.as_ref(), &server_id, params).await {
                    Ok(result) => serde_json::json!({
                        "id": input.id,
                        "ok": true,
                        "result": result,
                    }),
                    Err(error) => serde_json::json!({
                        "id": input.id,
                        "ok": false,
                        "error": error,
                    }),
                }
            }
            AppSessionCommand::ResumeThread { params } => {
                match app_resume_thread(client.as_ref(), &server_id, params).await {
                    Ok(result) => serde_json::json!({
                        "id": input.id,
                        "ok": true,
                        "result": result,
                    }),
                    Err(error) => serde_json::json!({
                        "id": input.id,
                        "ok": false,
                        "error": error,
                    }),
                }
            }
            AppSessionCommand::StartTurn { params } => {
                let thread_id = params.thread_id.clone();
                match upstream::TurnStartParams::try_from(params.clone()) {
                    Ok(turn_params) => match client.start_turn(&server_id, turn_params).await {
                        Ok(()) => serde_json::json!({
                            "id": input.id,
                            "ok": true,
                            "result": {
                                "threadId": thread_id,
                                "appPath": "store.start_turn",
                            },
                        }),
                        Err(error) => serde_json::json!({
                            "id": input.id,
                            "ok": false,
                            "error": error.to_string(),
                        }),
                    },
                    Err(error) => serde_json::json!({
                        "id": input.id,
                        "ok": false,
                        "error": error.to_string(),
                    }),
                }
            }
            AppSessionCommand::ExternalResumeThread { thread_id, host_id } => {
                match client
                    .external_resume_thread(&server_id, &thread_id, host_id)
                    .await
                {
                    Ok(()) => serde_json::json!({
                        "id": input.id,
                        "ok": true,
                        "result": {
                            "threadId": thread_id,
                            "appPath": "store.external_resume_thread",
                        },
                    }),
                    Err(error) => serde_json::json!({
                        "id": input.id,
                        "ok": false,
                        "error": error.to_string(),
                    }),
                }
            }
            AppSessionCommand::InterruptTurn { params } => {
                let thread_id = params.thread_id.clone();
                let turn_id = params.turn_id.clone();
                let result: Result<upstream::TurnInterruptResponse, _> = rpc(
                    client.as_ref(),
                    &server_id,
                    req!(TurnInterrupt, params.into()),
                )
                .await;
                match result {
                    Ok(_) => serde_json::json!({
                        "id": input.id,
                        "ok": true,
                        "result": {
                            "threadId": thread_id,
                            "turnId": turn_id,
                            "appPath": "client.interrupt_turn",
                        },
                    }),
                    Err(error) => serde_json::json!({
                        "id": input.id,
                        "ok": false,
                        "error": error,
                    }),
                }
            }
            AppSessionCommand::EditMessage {
                thread_id,
                selected_turn_index,
            } => {
                let key = ThreadKey {
                    server_id: server_id.clone(),
                    thread_id,
                };
                match client.edit_message(&key, selected_turn_index).await {
                    Ok(prefill_text) => serde_json::json!({
                        "id": input.id,
                        "ok": true,
                        "result": {
                            "prefillText": prefill_text,
                            "appPath": "store.edit_message",
                        },
                    }),
                    Err(error) => serde_json::json!({
                        "id": input.id,
                        "ok": false,
                        "error": error.to_string(),
                    }),
                }
            }
            AppSessionCommand::RespondToApproval {
                request_id,
                decision,
            } => match client.respond_to_approval(&request_id, decision).await {
                Ok(()) => serde_json::json!({
                    "id": input.id,
                    "ok": true,
                    "result": {
                        "requestId": request_id,
                        "appPath": "store.respond_to_approval",
                    },
                }),
                Err(error) => serde_json::json!({
                    "id": input.id,
                    "ok": false,
                    "error": error.to_string(),
                }),
            },
            AppSessionCommand::RespondToUserInput {
                request_id,
                answers,
            } => match client.respond_to_user_input(&request_id, answers).await {
                Ok(()) => serde_json::json!({
                    "id": input.id,
                    "ok": true,
                    "result": {
                        "requestId": request_id,
                        "appPath": "store.respond_to_user_input",
                    },
                }),
                Err(error) => serde_json::json!({
                    "id": input.id,
                    "ok": false,
                    "error": error.to_string(),
                }),
            },
            AppSessionCommand::RenameThread { params } => {
                let thread_id = params.thread_id.clone();
                let result: Result<upstream::ThreadSetNameResponse, _> = rpc(
                    client.as_ref(),
                    &server_id,
                    req!(ThreadSetName, params.into()),
                )
                .await;
                match result {
                    Ok(_) => serde_json::json!({
                        "id": input.id,
                        "ok": true,
                        "result": {
                            "threadId": thread_id,
                            "appPath": "client.rename_thread",
                        },
                    }),
                    Err(error) => serde_json::json!({
                        "id": input.id,
                        "ok": false,
                        "error": error,
                    }),
                }
            }
            AppSessionCommand::ArchiveThread { params } => {
                let thread_id = params.thread_id.clone();
                let result: Result<upstream::ThreadArchiveResponse, _> = rpc(
                    client.as_ref(),
                    &server_id,
                    req!(ThreadArchive, params.into()),
                )
                .await;
                match result {
                    Ok(_) => serde_json::json!({
                        "id": input.id,
                        "ok": true,
                        "result": {
                            "threadId": thread_id,
                            "appPath": "client.archive_thread",
                        },
                    }),
                    Err(error) => serde_json::json!({
                        "id": input.id,
                        "ok": false,
                        "error": error,
                    }),
                }
            }
            AppSessionCommand::Quit => {
                output.emit_json(&serde_json::json!({
                    "id": input.id,
                    "ok": true,
                    "result": { "quitting": true },
                }))?;
                return Ok(());
            }
        };

        output.emit_json(&response)?;
    }

    Ok(())
}

async fn run_server_cli(args: ServerArgs) -> Result<(), Box<dyn std::error::Error>> {
    let server_id = "debug-cli".to_string();
    let app_client = AppClient::new();
    let app_store = AppStore::new();
    let server_bridge = ServerBridge::new();
    let ssh_bridge = SshBridge::new();

    println!("Connecting to {}...", args.host);

    if let Some(user) = &args.user {
        ssh_bridge
            .ssh_connect_remote_server(
                server_id.clone(),
                args.host.clone(),
                args.host.clone(),
                args.ssh_port,
                user.clone(),
                args.password.clone(),
                None,
                None,
                false,
                true,
                None,
                args.ipc_socket_path_override.clone(),
            )
            .await?;
    } else if let Some(ws_url) = &args.ws_url {
        server_bridge
            .connect_remote_url_server(server_id.clone(), args.host.clone(), ws_url.clone())
            .await?;
    } else {
        let scheme = if args.tls { "wss" } else { "ws" };
        let ws_url = format!("{scheme}://{}:{}", args.host, args.port);
        server_bridge
            .connect_remote_url_server(server_id.clone(), args.host.clone(), ws_url)
            .await?;
    }

    ok("Connected!");
    println!("Type 'help' for commands.\n");

    let update_subscription = app_store.subscribe_updates();
    tokio::spawn(async move {
        loop {
            match update_subscription.next_update().await {
                Ok(update) => print_update(&update),
                Err(error) => {
                    eprintln!("\x1b[31m[updates closed]\x1b[0m {error}");
                    break;
                }
            }
        }
    });

    let stdin = io::stdin();
    let mut stdout = io::stdout();

    loop {
        print!("\x1b[32m>\x1b[0m ");
        stdout.flush()?;

        let mut line = String::new();
        if stdin.lock().read_line(&mut line)? == 0 {
            break;
        }
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        let parts: Vec<&str> = line.splitn(3, ' ').collect();
        let cmd = parts[0];
        let sid = server_id.as_str();

        match cmd {
            "quit" | "exit" | "q" => break,
            "help" | "?" => server_help(),
            "list" => {
                let limit = parts.get(1).and_then(|s| s.parse::<u32>().ok());
                let result = app_client
                    .list_threads(
                        sid.to_string(),
                        AppListThreadsRequest {
                            cursor: None,
                            limit,
                            archived: None,
                            cwd: None,
                            search_term: None,
                        },
                    )
                    .await;
                match result {
                    Ok(()) => match app_store.snapshot().await {
                        Ok(snapshot) => {
                            let threads = snapshot
                                .threads
                                .into_iter()
                                .filter(|thread| thread.key.server_id == sid)
                                .collect::<Vec<_>>();
                            for thread in &threads {
                                let label = thread
                                    .info
                                    .title
                                    .as_deref()
                                    .or(thread.info.preview.as_deref())
                                    .unwrap_or("<untitled>");
                                println!(
                                    "  {} | {:?} | {}",
                                    thread.info.id, thread.info.status, label
                                );
                            }
                            ok(&format!("{} threads", threads.len()));
                        }
                        Err(error) => err(&error.to_string()),
                    },
                    Err(error) => err(&error.to_string()),
                }
            }
            "read" => {
                let Some(thread_id) = parts.get(1) else {
                    err("usage: read <thread_id>");
                    continue;
                };
                let result = app_client
                    .read_thread(
                        sid.to_string(),
                        AppReadThreadRequest {
                            thread_id: thread_id.to_string(),
                            include_turns: true,
                        },
                    )
                    .await;
                match result {
                    Ok(key) => {
                        ok(&format!("synced {}/{}", key.server_id, key.thread_id));
                        match app_store.thread_snapshot(key).await {
                            Ok(Some(thread)) => {
                                println!("  id: {}", thread.info.id);
                                println!("  status: {:?}", thread.info.status);
                                println!(
                                    "  preview: {}",
                                    thread.info.preview.as_deref().unwrap_or_default()
                                );
                                println!("  title: {:?}", thread.info.title);
                                println!("  items: {}", thread.hydrated_conversation_items.len());
                                for item in &thread.hydrated_conversation_items {
                                    println!("      {item:?}");
                                }
                            }
                            Ok(None) => err("thread snapshot unavailable after read"),
                            Err(error) => err(&error.to_string()),
                        }
                    }
                    Err(error) => err(&error.to_string()),
                }
            }
            "start" => {
                let cwd = parts.get(1).map(|value| value.to_string());
                let result = app_client
                    .start_thread(
                        sid.to_string(),
                        AppStartThreadRequest {
                            model: None,
                            cwd,
                            approval_policy: None,
                            sandbox: None,
                            developer_instructions: None,
                            persist_extended_history: false,
                            dynamic_tools: None,
                            ephemeral: None,
                        },
                    )
                    .await;
                match result {
                    Ok(key) => ok(&format!("started: {}/{}", key.server_id, key.thread_id)),
                    Err(error) => err(&error.to_string()),
                }
            }
            "open" => {
                let Some(thread_id) = parts.get(1) else {
                    err("usage: open <thread_id>");
                    continue;
                };
                let key = ThreadKey {
                    server_id: sid.to_string(),
                    thread_id: thread_id.to_string(),
                };
                let loaded = match app_store.thread_snapshot(key.clone()).await {
                    Ok(Some(_)) => true,
                    Ok(None) => false,
                    Err(error) => {
                        err(&error.to_string());
                        continue;
                    }
                };
                if !loaded {
                    let result = app_client
                        .read_thread(
                            sid.to_string(),
                            AppReadThreadRequest {
                                thread_id: thread_id.to_string(),
                                include_turns: true,
                            },
                        )
                        .await;
                    if let Err(error) = result {
                        err(&error.to_string());
                        continue;
                    }
                }
                app_store.set_active_thread(Some(key.clone()));
                ok(&format!("opened: {}/{}", key.server_id, key.thread_id));
            }
            "open-ios" => {
                let Some(thread_id) = parts.get(1) else {
                    err("usage: open-ios <thread_id>");
                    continue;
                };
                match app_open_thread_like_ios(&app_client, &app_store, sid, thread_id).await {
                    Ok(key) => {
                        app_store.set_active_thread(Some(key.clone()));
                        ok(&format!("opened-ios: {}/{}", key.server_id, key.thread_id));
                    }
                    Err(error) => err(&error),
                }
            }
            "resume" => {
                let Some(thread_id) = parts.get(1) else {
                    err("usage: resume <thread_id>");
                    continue;
                };
                let result = app_client
                    .resume_thread(
                        sid.to_string(),
                        AppResumeThreadRequest {
                            thread_id: thread_id.to_string(),
                            model: None,
                            cwd: None,
                            approval_policy: None,
                            sandbox: None,
                            developer_instructions: None,
                            persist_extended_history: false,
                        },
                    )
                    .await;
                match result {
                    Ok(key) => ok(&format!("resumed: {}/{}", key.server_id, key.thread_id)),
                    Err(error) => err(&error.to_string()),
                }
            }
            "wait" => {
                let Some(thread_id) = parts.get(1) else {
                    err("usage: wait <thread_id>");
                    continue;
                };
                let key = ThreadKey {
                    server_id: sid.to_string(),
                    thread_id: thread_id.to_string(),
                };
                match wait_for_thread_idle(&app_store, key.clone(), Duration::from_secs(60)).await {
                    Ok(()) => {
                        ok(&format!("idle: {}/{}", key.server_id, key.thread_id));
                        match app_store.thread_snapshot(key).await {
                            Ok(Some(thread)) => {
                                println!("  status: {:?}", thread.info.status);
                                println!("  active_turn_id: {:?}", thread.active_turn_id);
                            }
                            Ok(None) => {}
                            Err(error) => err(&error.to_string()),
                        }
                    }
                    Err(error) => err(&error),
                }
            }
            "send" => {
                let thread_id = parts.get(1);
                let msg = parts.get(2);
                let (Some(thread_id), Some(msg)) = (thread_id, msg) else {
                    err("usage: send <thread_id> <message>");
                    continue;
                };
                let result = app_store
                    .start_turn(
                        ThreadKey {
                            server_id: sid.to_string(),
                            thread_id: thread_id.to_string(),
                        },
                        AppStartTurnRequest {
                            thread_id: thread_id.to_string(),
                            input: vec![codex_mobile_client::types::AppUserInput::Text {
                                text: msg.to_string(),
                                text_elements: vec![],
                            }],
                            approval_policy: None,
                            sandbox_policy: None,
                            model: None,
                            service_tier: None,
                            effort: None,
                            output_schema: None,
                        },
                    )
                    .await;
                match result {
                    Ok(()) => ok("turn started"),
                    Err(error) => err(&error.to_string()),
                }
            }
            "archive" => {
                let Some(thread_id) = parts.get(1) else {
                    err("usage: archive <thread_id>");
                    continue;
                };
                let result = app_client
                    .archive_thread(
                        sid.to_string(),
                        AppArchiveThreadRequest {
                            thread_id: thread_id.to_string(),
                        },
                    )
                    .await;
                match result {
                    Ok(()) => ok("archived"),
                    Err(error) => err(&error.to_string()),
                }
            }
            "rename" => {
                let (Some(thread_id), Some(name)) = (parts.get(1), parts.get(2)) else {
                    err("usage: rename <thread_id> <name>");
                    continue;
                };
                let result = app_client
                    .rename_thread(
                        sid.to_string(),
                        AppRenameThreadRequest {
                            thread_id: thread_id.to_string(),
                            name: name.to_string(),
                        },
                    )
                    .await;
                match result {
                    Ok(()) => ok("renamed"),
                    Err(error) => err(&error.to_string()),
                }
            }
            "models" => match app_store.snapshot().await {
                Ok(snapshot) => {
                    let Some(server) = snapshot
                        .servers
                        .into_iter()
                        .find(|server| server.server_id == sid)
                    else {
                        err("server not found in app snapshot");
                        continue;
                    };
                    let Some(models) = server.available_models else {
                        err("models not available in app snapshot yet");
                        continue;
                    };
                    for model in &models {
                        println!("  {} — {}", model.id, model.display_name);
                    }
                    ok(&format!("{} models", models.len()));
                }
                Err(error) => err(&error.to_string()),
            },
            "features" => {
                err("features is not exposed on the mobile FFI surface yet");
            }
            "skills" => {
                err("skills is not exposed on the mobile FFI surface yet");
            }
            "auth-status" => match app_store.snapshot().await {
                Ok(snapshot) => {
                    let Some(server) = snapshot
                        .servers
                        .into_iter()
                        .find(|server| server.server_id == sid)
                    else {
                        err("server not found in app snapshot");
                        continue;
                    };
                    println!("  requires_openai_auth: {}", server.requires_openai_auth);
                    println!("  account: {:?}", server.account);
                }
                Err(error) => err(&error.to_string()),
            },
            "snapshot" => match app_store.snapshot().await {
                Ok(snapshot) => println!("{snapshot:#?}"),
                Err(error) => err(&error.to_string()),
            },
            other => err(&format!("unknown command: {other}. Type 'help'.")),
        }
    }

    println!("Bye!");
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    use clap::Parser;

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let args = Args::parse();

    if let Some(command) = args.command {
        return match command {
            CliCommand::App(app_args) => run_app_command(app_args)
                .await
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e).into()),
            CliCommand::Ipc(ipc_args) => run_ipc_command(ipc_args)
                .await
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e).into()),
        };
    }

    let Some(host) = args.host else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "missing required --host (or use the `app` or `ipc` subcommand)",
        )
        .into());
    };

    run_server_cli(ServerArgs {
        host,
        ssh_port: args.ssh_port,
        user: args.user,
        password: args.password,
        ws_url: args.ws_url,
        port: args.port,
        tls: args.tls,
        ipc_socket_path_override: args.ipc_socket_path_override,
    })
    .await
}
