//! CLI tool to connect to a Codex IPC socket and print all broadcasts.
//!
//! Usage:
//!   codex-ipc-listen [--raw] [socket-path]
//!
//! --raw    Print full JSON payloads (default: summary one-liners)

use std::path::PathBuf;
use std::time::Duration;

use codex_ipc::{IpcClient, IpcClientConfig, TypedBroadcast};

fn format_broadcast(tb: &TypedBroadcast) -> String {
    match tb {
        TypedBroadcast::ClientStatusChanged(p) => {
            format!(
                "client-status-changed  client={} type={} status={:?}",
                p.client_id, p.client_type, p.status
            )
        }
        TypedBroadcast::ThreadStreamStateChanged(p) => {
            let change_type = match &p.change {
                codex_ipc::StreamChange::Snapshot { .. } => "snapshot",
                codex_ipc::StreamChange::Patches { patches } => {
                    return format!(
                        "thread-stream-state-changed  conv={} patches={}",
                        p.conversation_id,
                        patches.len()
                    );
                }
            };
            format!(
                "thread-stream-state-changed  conv={} change={}",
                p.conversation_id, change_type
            )
        }
        TypedBroadcast::ThreadArchived(p) => {
            format!(
                "thread-archived  conv={} host={} cwd={}",
                p.conversation_id, p.host_id, p.cwd
            )
        }
        TypedBroadcast::ThreadUnarchived(p) => {
            format!(
                "thread-unarchived  conv={} host={}",
                p.conversation_id, p.host_id
            )
        }
        TypedBroadcast::ThreadQueuedFollowupsChanged(p) => {
            format!(
                "thread-queued-followups-changed  conv={} messages={}",
                p.conversation_id,
                p.messages.len()
            )
        }
        TypedBroadcast::QueryCacheInvalidate(p) => {
            format!("query-cache-invalidate  key={:?}", p.query_key)
        }
        TypedBroadcast::Unknown { method, params } => {
            format!("unknown  method={method} params={params}")
        }
    }
}

/// Connect at the raw frame level and print every envelope as JSON.
async fn run_raw(socket_path: PathBuf) {
    use codex_ipc::transport::{frame, socket};
    use codex_ipc::{Envelope, InitializeParams, Request};
    use codex_ipc::protocol::method::Method;

    eprintln!("connecting to {} (raw mode)", socket_path.display());

    let stream = match socket::connect_unix(&socket_path).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("failed to connect: {e}");
            std::process::exit(1);
        }
    };

    let (mut reader, mut writer) = stream.into_split();

    // Send initialize handshake.
    let init_envelope = Envelope::Request(Request {
        request_id: uuid::Uuid::new_v4().to_string(),
        source_client_id: "initializing-client".to_string(),
        version: 0,
        method: Method::Initialize.wire_name().to_string(),
        params: serde_json::to_value(InitializeParams {
            client_type: "cli-listener".to_string(),
        })
        .unwrap(),
        target_client_id: None,
    });

    let json = serde_json::to_string(&init_envelope).unwrap();
    if let Err(e) = frame::write_frame(&mut writer, &json).await {
        eprintln!("failed to send initialize: {e}");
        std::process::exit(1);
    }

    eprintln!("listening for all messages... (ctrl-c to quit)\n");

    loop {
        match frame::read_frame(&mut reader).await {
            Ok(raw) => {
                let ts = chrono::Local::now().format("%H:%M:%S%.3f");
                // Pretty-print if it's valid JSON, otherwise print raw.
                match serde_json::from_str::<serde_json::Value>(&raw) {
                    Ok(val) => {
                        let pretty = serde_json::to_string_pretty(&val).unwrap();
                        println!("[{ts}] {pretty}");
                    }
                    Err(_) => {
                        println!("[{ts}] {raw}");
                    }
                }
            }
            Err(e) => {
                eprintln!("read error: {e}");
                break;
            }
        }
    }
}

/// Connect via IpcClient and print typed broadcast summaries.
async fn run_typed(socket_path: PathBuf) {
    let config = IpcClientConfig {
        socket_path: socket_path.clone(),
        client_type: "cli-listener".to_string(),
        request_timeout: Duration::from_secs(10),
    };

    eprintln!("connecting to {}", config.socket_path.display());

    let client = match IpcClient::connect(config).await {
        Ok(c) => c,
        Err(e) => {
            eprintln!("failed to connect: {e}");
            std::process::exit(1);
        }
    };

    eprintln!("connected as {}", client.client_id());
    eprintln!("listening for broadcasts... (ctrl-c to quit)\n");

    let mut rx = client.subscribe_broadcasts();

    loop {
        match rx.recv().await {
            Ok(broadcast) => {
                let ts = chrono::Local::now().format("%H:%M:%S%.3f");
                println!("[{ts}] {}", format_broadcast(&broadcast));
            }
            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                eprintln!("(lagged, missed {n} broadcasts)");
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                eprintln!("connection closed");
                break;
            }
        }
    }
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let raw = args.iter().any(|a| a == "--raw");
    let socket_path = args
        .iter()
        .find(|a| !a.starts_with("--"))
        .map(PathBuf::from)
        .unwrap_or_else(codex_ipc::transport::socket::resolve_socket_path);

    if raw {
        run_raw(socket_path).await;
    } else {
        run_typed(socket_path).await;
    }
}
