use std::io::{self, BufRead, Write};
use std::sync::Arc;

use codex_app_server_protocol as upstream;
use codex_mobile_client::MobileClient;
use codex_mobile_client::session::connection::ServerConfig;
use codex_mobile_client::ssh::{SshAuth, SshCredentials};
use codex_mobile_client::store::updates::AppStoreUpdateRecord;

#[derive(clap::Parser)]
#[command(name = "codex-debug-cli", about = "Debug CLI exercising the MobileClient codepath")]
struct Args {
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

fn help() {
    println!(
        r#"
  list [limit]               List threads (syncs to store)
  read <thread_id>           Read thread (syncs to store)
  start                      Start new thread
  resume <thread_id>         Resume thread
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
        ThreadStreamingDelta { key, item_id, kind, text } => {
            eprint!("\x1b[33m[delta {}/{}:{:?}]\x1b[0m {}", key.thread_id, item_id, kind, text);
        }
        ThreadItemUpserted { key, item } => {
            eprintln!("\x1b[36m[item {}/{}]\x1b[0m {:?}", key.server_id, key.thread_id, item);
        }
        ThreadStateUpdated { state, .. } => {
            eprintln!("\x1b[35m[state {}]\x1b[0m {:?}", state.key.thread_id, state.info.status);
        }
        ThreadUpserted { thread, .. } => {
            eprintln!("\x1b[34m[thread {}]\x1b[0m {:?}", thread.key.thread_id, thread.info.status);
        }
        PendingApprovalsChanged { approvals } => {
            eprintln!("\x1b[31m[approvals]\x1b[0m {} pending", approvals.len());
            for a in approvals {
                eprintln!("  {:?}", a);
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

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    use clap::Parser;
    let args = Args::parse();

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let client = Arc::new(MobileClient::new());

    let server_id = "debug-cli".to_string();
    let config = ServerConfig {
        server_id: server_id.clone(),
        display_name: args.host.clone(),
        host: args.host.clone(),
        port: args.port,
        websocket_url: args.ws_url.clone(),
        is_local: false,
        tls: args.tls,
    };

    println!("Connecting to {}...", args.host);

    if let Some(user) = &args.user {
        let password = args.password.clone().unwrap_or_default();
        let creds = SshCredentials {
            host: args.host.clone(),
            port: args.ssh_port,
            username: user.clone(),
            auth: SshAuth::Password(password),
        };
        client
            .connect_remote_over_ssh(config, creds, true, None, None)
            .await?;
    } else {
        client.connect_remote(config).await?;
    }

    ok("Connected!");
    println!("Type 'help' for commands.\n");

    // Background listener — prints every store update the mobile app would receive.
    let mut update_rx = client.subscribe_app_updates();
    tokio::spawn(async move {
        loop {
            match update_rx.recv().await {
                Ok(update) => print_update(&update),
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    eprintln!("\x1b[31m[lagged {n} updates]\x1b[0m");
                }
                Err(_) => break,
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
            "help" | "?" => help(),

            // ── list: same as AppClient::list_threads ──────────────────
            "list" => {
                let limit = parts.get(1).and_then(|s| s.parse::<u32>().ok());
                let result: Result<upstream::ThreadListResponse, _> = rpc(
                    &client, sid,
                    req!(ThreadList, upstream::ThreadListParams {
                        cursor: None, limit,
                        sort_key: None, model_providers: None, source_kinds: None,
                        archived: None, cwd: None, search_term: None,
                    }),
                ).await;
                match result {
                    Ok(response) => {
                        // Reconcile into store — same as AppClient::list_threads
                        if let Err(e) = client.sync_thread_list(sid, &response.data) {
                            err(&format!("sync: {e}"));
                        }
                        for thread in &response.data {
                            println!("  {} | {:?} | {}",
                                thread.id, thread.status,
                                thread.name.as_deref().unwrap_or(&thread.preview));
                        }
                        ok(&format!("{} threads", response.data.len()));
                    }
                    Err(e) => err(&e),
                }
            }

            // ── read: same as AppClient::read_thread ───────────────────
            "read" => {
                let Some(thread_id) = parts.get(1) else { err("usage: read <thread_id>"); continue; };
                let result: Result<upstream::ThreadReadResponse, _> = rpc(
                    &client, sid,
                    req!(ThreadRead, upstream::ThreadReadParams {
                        thread_id: thread_id.to_string(), include_turns: true,
                    }),
                ).await;
                match result {
                    Ok(response) => {
                        // Reconcile — same as AppClient::read_thread
                        match client.apply_thread_read_response(sid, &response) {
                            Ok(key) => ok(&format!("synced {}/{}", key.server_id, key.thread_id)),
                            Err(e) => err(&format!("sync: {e}")),
                        }
                        let t = &response.thread;
                        println!("  id: {}", t.id);
                        println!("  status: {:?}", t.status);
                        println!("  preview: {}", t.preview);
                        println!("  name: {:?}", t.name);
                        println!("  turns: {}", t.turns.len());
                        for turn in &t.turns {
                            println!("    turn {} | {:?} | {} items", turn.id, turn.status, turn.items.len());
                            for item in &turn.items {
                                println!("      {item:?}");
                            }
                        }
                    }
                    Err(e) => err(&e),
                }
            }

            // ── start: same as AppClient::start_thread ─────────────────
            "start" => {
                let result: Result<upstream::ThreadStartResponse, _> = rpc(
                    &client, sid,
                    req!(ThreadStart, upstream::ThreadStartParams { ..Default::default() }),
                ).await;
                match result {
                    Ok(response) => {
                        match client.apply_thread_start_response(sid, &response) {
                            Ok(key) => ok(&format!("started: {}/{}", key.server_id, key.thread_id)),
                            Err(e) => err(&format!("sync: {e}")),
                        }
                    }
                    Err(e) => err(&e),
                }
            }

            // ── resume: same as AppClient::resume_thread ───────────────
            "resume" => {
                let Some(thread_id) = parts.get(1) else { err("usage: resume <thread_id>"); continue; };
                let result: Result<upstream::ThreadResumeResponse, _> = rpc(
                    &client, sid,
                    req!(ThreadResume, upstream::ThreadResumeParams {
                        thread_id: thread_id.to_string(), ..Default::default()
                    }),
                ).await;
                match result {
                    Ok(response) => {
                        match client.apply_thread_resume_response(sid, &response) {
                            Ok(key) => ok(&format!("resumed: {}/{}", key.server_id, key.thread_id)),
                            Err(e) => err(&format!("sync: {e}")),
                        }
                    }
                    Err(e) => err(&e),
                }
            }

            // ── send: turn/start ───────────────────────────────────────
            "send" => {
                let thread_id = parts.get(1);
                let msg = parts.get(2);
                let (Some(tid), Some(msg)) = (thread_id, msg) else {
                    err("usage: send <thread_id> <message>"); continue;
                };
                let result: Result<upstream::TurnStartResponse, _> = rpc(
                    &client, sid,
                    req!(TurnStart, upstream::TurnStartParams {
                        thread_id: tid.to_string(),
                        input: vec![upstream::UserInput::Text {
                            text: msg.to_string(), text_elements: vec![],
                        }],
                        ..Default::default()
                    }),
                ).await;
                match result {
                    Ok(response) => ok(&format!("turn started: {}", response.turn.id)),
                    Err(e) => err(&e),
                }
            }

            // ── archive ────────────────────────────────────────────────
            "archive" => {
                let Some(thread_id) = parts.get(1) else { err("usage: archive <thread_id>"); continue; };
                let result: Result<upstream::ThreadArchiveResponse, _> = rpc(
                    &client, sid,
                    req!(ThreadArchive, upstream::ThreadArchiveParams { thread_id: thread_id.to_string() }),
                ).await;
                match result {
                    Ok(_) => ok("archived"),
                    Err(e) => err(&e),
                }
            }

            // ── rename ─────────────────────────────────────────────────
            "rename" => {
                let (Some(tid), Some(name)) = (parts.get(1), parts.get(2)) else {
                    err("usage: rename <thread_id> <name>"); continue;
                };
                let result: Result<upstream::ThreadSetNameResponse, _> = rpc(
                    &client, sid,
                    req!(ThreadSetName, upstream::ThreadSetNameParams {
                        thread_id: tid.to_string(), name: name.to_string(),
                    }),
                ).await;
                match result {
                    Ok(_) => ok("renamed"),
                    Err(e) => err(&e),
                }
            }

            // ── models: same as AppClient::refresh_models ──────────────
            "models" => {
                let result: Result<upstream::ModelListResponse, _> = rpc(
                    &client, sid,
                    req!(ModelList, upstream::ModelListParams { ..Default::default() }),
                ).await;
                match result {
                    Ok(response) => {
                        client.apply_model_list_response(sid, &response);
                        for m in &response.data {
                            println!("  {} — {}", m.id, m.display_name);
                        }
                        ok(&format!("{} models", response.data.len()));
                    }
                    Err(e) => err(&e),
                }
            }

            "features" => {
                let result: Result<upstream::ExperimentalFeatureListResponse, _> = rpc(
                    &client, sid,
                    req!(ExperimentalFeatureList, upstream::ExperimentalFeatureListParams {
                        ..Default::default()
                    }),
                ).await;
                match result {
                    Ok(response) => {
                        for f in &response.data { println!("  {f:?}"); }
                        ok(&format!("{} features", response.data.len()));
                    }
                    Err(e) => err(&e),
                }
            }

            "skills" => {
                let result: Result<upstream::SkillsListResponse, _> = rpc(
                    &client, sid,
                    req!(SkillsList, upstream::SkillsListParams {
                        cwds: vec![], force_reload: false, per_cwd_extra_user_roots: None,
                    }),
                ).await;
                match result {
                    Ok(response) => {
                        for group in &response.data {
                            for s in &group.skills { println!("  {} — {}", s.name, s.description); }
                        }
                    }
                    Err(e) => err(&e),
                }
            }

            "auth-status" => {
                let result: Result<upstream::GetAuthStatusResponse, _> = rpc(
                    &client, sid,
                    req!(GetAuthStatus, upstream::GetAuthStatusParams {
                        include_token: None, refresh_token: None,
                    }),
                ).await;
                match result {
                    Ok(response) => println!("  {response:?}"),
                    Err(e) => err(&e),
                }
            }

            "snapshot" => {
                let snap = client.app_snapshot();
                println!("{snap:#?}");
            }

            other => err(&format!("unknown command: {other}. Type 'help'.")),
        }
    }

    println!("Bye!");
    Ok(())
}
