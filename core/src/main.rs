// lvim-rest-daemon: the out-of-process execution engine for lvim-rest.
//
// Neovim spawns this binary and speaks newline-delimited JSON (see rpc.rs) over its stdin/stdout.
// A tokio multi-thread runtime drives every request on its own task, so a slow request never blocks
// the handshake or another call. A single writer task serialises all output (responses +
// streamed notifications) so they never interleave. Each in-flight request's task handle is kept in
// a map so `http.cancel` can abort it (dropping the reqwest future cancels the request). When stdin
// reaches EOF (Neovim exited) the daemon shuts down.
//
// The daemon is CRASH-ISOLATED from the editor: a panic takes down this process, not Neovim — the
// Lua side notices the pipe close, notifies, and can respawn. HTTP/1.1 + HTTP/2 today; gRPC
// (tonic), WebSocket (tokio-tungstenite), HTTP/3 and OAuth2 loopback land in a later phase.

mod http;
mod rpc;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use crate::rpc::{Request, Writer};

// The protocol version this daemon speaks (the Lua client checks `proto >= PROTO_MIN`).
const PROTO: i64 = 1;

/// The set of in-flight request task handles, by request id — for cancellation.
type Inflight = Arc<Mutex<HashMap<i64, tokio::task::AbortHandle>>>;

#[tokio::main(flavor = "multi_thread")]
async fn main() {
    // The single output writer: every task sends its JSON line here; this task writes them in order.
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    let writer_task = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(line) = rx.recv().await {
            if stdout.write_all(line.as_bytes()).await.is_err() || stdout.write_all(b"\n").await.is_err() {
                break;
            }
            let _ = stdout.flush().await;
        }
    });

    let writer = Writer::new(tx);
    let inflight: Inflight = Arc::new(Mutex::new(HashMap::new()));

    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let req: Request = match serde_json::from_str(line) {
            Ok(r) => r,
            Err(_) => continue, // a malformed line has no id to correlate; ignore it
        };
        dispatch(req, writer.clone(), inflight.clone());
    }

    // stdin closed → Neovim is gone. Let the writer drain.
    drop(writer);
    let _ = writer_task.await;
}

/// Route one request to its handler.
fn dispatch(req: Request, writer: Writer, inflight: Inflight) {
    let id = req.id;
    match req.method.as_str() {
        "rpc.hello" => {
            if let Some(id) = id {
                writer.ok(
                    id,
                    json!({
                        "proto": PROTO,
                        "engine": "lvim-rest-core",
                        "version": env!("CARGO_PKG_VERSION"),
                        "protocols": ["http", "graphql"],
                    }),
                );
            }
        }
        "http.send" => {
            let Some(id) = id else { return };
            let params = match serde_json::from_value::<http::HttpParams>(req.params) {
                Ok(p) => p,
                Err(e) => {
                    writer.err(id, format!("bad params: {e}"));
                    return;
                }
            };
            let inflight2 = inflight.clone();
            let handle = tokio::spawn(async move {
                http::send(id, params, writer).await;
                inflight2.lock().unwrap().remove(&id);
            });
            inflight.lock().unwrap().insert(id, handle.abort_handle());
        }
        "http.cancel" => {
            // params: { id }
            if let Some(target) = req.params.get("id").and_then(|v| v.as_i64()) {
                if let Some(h) = inflight.lock().unwrap().remove(&target) {
                    h.abort();
                }
            }
            if let Some(id) = id {
                writer.ok(id, json!({ "cancelled": true }));
            }
        }
        _ => {
            if let Some(id) = id {
                writer.err(id, format!("unknown method: {}", req.method));
            }
        }
    }
}
