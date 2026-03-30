//! CLI tool to connect to a Codex server, interactively pick sessions,
//! and export them as a JSON fixture for screenshot testing.
//!
//! Usage:
//!   export-fixture --connect HOST:PORT [--output fixture.json]

use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::Arc;

use codex_app_server_protocol as upstream;
use codex_mobile_client::MobileClient;
use codex_mobile_client::session::connection::ServerConfig;

fn parse_args() -> (String, PathBuf) {
    let mut connect = None;
    let mut output = PathBuf::from("fixture.json");
    let mut iter = std::env::args().skip(1);
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--connect" | "-c" => {
                connect = iter.next();
            }
            "--output" | "-o" => {
                if let Some(p) = iter.next() {
                    output = PathBuf::from(p);
                }
            }
            "--help" | "-h" => {
                eprintln!("export-fixture — export Codex sessions as a JSON fixture");
                eprintln!();
                eprintln!("USAGE:");
                eprintln!("  export-fixture -c HOST:PORT [-o fixture.json]");
                eprintln!();
                eprintln!("OPTIONS:");
                eprintln!("  -c, --connect HOST:PORT   Server to connect to (required)");
                eprintln!("  -o, --output PATH         Output file (default: fixture.json)");
                std::process::exit(0);
            }
            _ => {
                eprintln!("Unknown argument: {arg}. Run with --help.");
                std::process::exit(1);
            }
        }
    }
    let connect = connect.unwrap_or_else(|| {
        eprintln!("Error: --connect HOST:PORT is required");
        std::process::exit(1);
    });
    (connect, output)
}

fn parse_host_port(addr: &str) -> (String, u16) {
    if let Some((host, port_str)) = addr.rsplit_once(':') {
        if let Ok(port) = port_str.parse::<u16>() {
            return (host.to_string(), port);
        }
    }
    (addr.to_string(), 8390)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let (addr, output_path) = parse_args();
    let (host, port) = parse_host_port(&addr);

    eprintln!("Connecting to {host}:{port}...");

    let client = Arc::new(MobileClient::new());
    let config = ServerConfig {
        server_id: format!("{host}:{port}"),
        display_name: host.clone(),
        host: host.clone(),
        port,
        websocket_url: None,
        is_local: false,
        tls: false,
    };

    let server_id = client.connect_remote(config.clone()).await?;
    eprintln!("Connected as {server_id}");

    // Wait a moment for the thread list to sync
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;

    // List threads via raw JSON-RPC
    let list_request = upstream::ClientRequest::ThreadList {
        request_id: upstream::RequestId::Integer(1),
        params: upstream::ThreadListParams {
            limit: None,
            cursor: None,
            sort_key: None,
            model_providers: None,
            source_kinds: None,
            archived: None,
            cwd: None,
            search_term: None,
        },
    };

    let list_response = client
        .request_raw_for_server(&server_id, list_request)
        .await
        .map_err(|e| anyhow::anyhow!("thread/list failed: {e}"))?;

    let threads = list_response
        .get("data")
        .and_then(|d| d.as_array())
        .cloned()
        .unwrap_or_default();

    if threads.is_empty() {
        eprintln!("No sessions found on this server.");
        std::process::exit(0);
    }

    // Display threads for selection
    eprintln!("\nAvailable sessions:");
    eprintln!("{}", "─".repeat(60));
    for (i, thread) in threads.iter().enumerate() {
        let name = thread
            .get("name")
            .and_then(|n| n.as_str())
            .or_else(|| thread.get("preview").and_then(|p| p.as_str()))
            .unwrap_or("(untitled)");
        let cwd = thread.get("cwd").and_then(|c| c.as_str()).unwrap_or("~");
        let model = thread
            .get("source")
            .and_then(|s| s.get("model"))
            .and_then(|m| m.as_str())
            .unwrap_or("");
        let status = thread.get("status").and_then(|s| s.as_str()).unwrap_or("");
        let turn_count = thread
            .get("turns")
            .and_then(|t| t.as_array())
            .map(|a| a.len())
            .unwrap_or(0);

        eprintln!(
            "  [{:>2}] {} ({} turns)",
            i + 1,
            truncate(name, 45),
            turn_count
        );
        eprintln!("       {} · {} · {}", cwd, model, status);
    }
    eprintln!("{}", "─".repeat(60));
    eprintln!("Enter session numbers to export (comma-separated, or 'all'):");
    eprint!("> ");
    io::stderr().flush()?;

    let mut input = String::new();
    io::stdin().lock().read_line(&mut input)?;
    let input = input.trim();

    let selected_indices: Vec<usize> = if input.eq_ignore_ascii_case("all") {
        (0..threads.len()).collect()
    } else {
        input
            .split([',', ' '])
            .filter_map(|s| s.trim().parse::<usize>().ok())
            .map(|n| n.saturating_sub(1))
            .filter(|&i| i < threads.len())
            .collect()
    };

    if selected_indices.is_empty() {
        eprintln!("No valid sessions selected.");
        std::process::exit(0);
    }

    // Fetch full thread data (with turns/conversation) for selected sessions
    eprintln!("\nExporting {} session(s)...", selected_indices.len());

    let mut exported_threads = Vec::new();
    for &idx in &selected_indices {
        let thread_id = threads[idx]
            .get("id")
            .and_then(|i| i.as_str())
            .unwrap_or_default();
        let name = threads[idx]
            .get("name")
            .and_then(|n| n.as_str())
            .or_else(|| threads[idx].get("preview").and_then(|p| p.as_str()))
            .unwrap_or("(untitled)");

        eprint!("  Fetching '{}'... ", truncate(name, 40));

        let read_request = upstream::ClientRequest::ThreadRead {
            request_id: upstream::RequestId::Integer(idx as i64 + 100),
            params: upstream::ThreadReadParams {
                thread_id: thread_id.to_string(),
                include_turns: true,
            },
        };

        match client
            .request_raw_for_server(&server_id, read_request)
            .await
        {
            Ok(response) => {
                if let Some(thread) = response.get("thread") {
                    let turns = thread
                        .get("turns")
                        .and_then(|t| t.as_array())
                        .map(|a| a.len())
                        .unwrap_or(0);
                    exported_threads.push(thread.clone());
                    eprintln!("OK ({} turns)", turns);
                } else {
                    exported_threads.push(response);
                    eprintln!("OK (raw)");
                }
            }
            Err(e) => {
                eprintln!("FAILED: {e}");
            }
        }
    }

    // Build fixture JSON
    let fixture = serde_json::json!({
        "server": {
            "server_id": server_id,
            "display_name": config.display_name,
            "host": config.host,
            "port": config.port,
        },
        "threads": exported_threads,
    });

    let json = serde_json::to_string_pretty(&fixture)?;
    std::fs::write(&output_path, &json)?;

    eprintln!(
        "\nExported {} session(s) to {}",
        exported_threads.len(),
        output_path.display()
    );
    eprintln!("File size: {} KB", json.len() / 1024);

    Ok(())
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        format!("{}…", &s[..max - 1])
    }
}
