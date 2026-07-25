// lvim-rest-core::ws — WebSocket sessions.
//
// A WebSocket is the first thing this daemon does that is not request/response: the connection
// outlives the call that opened it and pushes frames at us. That is what the NOTIFICATION half of
// the protocol is for — `ws.open` answers once the handshake succeeds, and every frame afterwards
// arrives in the editor as a `ws.message` notification carrying the session id.
//
// Each session owns a writer half behind an mpsc channel, so `ws.send` from any request task never
// touches the socket directly and frames cannot interleave mid-message.
//
// This is the reason WebSocket is daemon-only: curl cannot hold a duplex connection open and report
// frames as they arrive, so there is no fallback to degrade to — the Lua side says so up front
// rather than failing at send time.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::json;
use tokio::sync::mpsc::{unbounded_channel, UnboundedSender};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::Message;

use crate::rpc::Writer;

/// What a live session accepts from the rest of the daemon. Crate-visible because `Sessions` — the
/// map the dispatcher hands to every ws handler — names it.
pub(crate) enum Outbound {
    Text(String),
    Binary(Vec<u8>),
    Close(Option<CloseFrame<'static>>),
}

/// id → the channel feeding that session's writer half.
pub type Sessions = Arc<Mutex<HashMap<i64, UnboundedSender<Outbound>>>>;

pub fn sessions() -> Sessions {
    Arc::new(Mutex::new(HashMap::new()))
}

#[derive(Deserialize)]
pub struct OpenParams {
    pub url: String,
    #[serde(default)]
    pub headers: Vec<(String, String)>,
    #[serde(default)]
    pub subprotocols: Vec<String>,
}

#[derive(Deserialize)]
pub struct SendParams {
    pub id: i64,
    #[serde(default)]
    pub data: String,
    /// "text" (default) or "binary" — binary data arrives base64-encoded.
    #[serde(default)]
    pub kind: Option<String>,
}

#[derive(Deserialize)]
pub struct CloseParams {
    pub id: i64,
    #[serde(default)]
    pub code: Option<u16>,
    #[serde(default)]
    pub reason: Option<String>,
}

/// Open a session. Answers `id` once the handshake is through, then streams notifications until the
/// peer or the editor closes it.
pub async fn open(id: i64, p: OpenParams, writer: Writer, sessions: Sessions) {
    let mut request = match p.url.as_str().into_client_request() {
        Ok(r) => r,
        Err(e) => {
            writer.err(id, format!("bad websocket url: {e}"));
            return;
        }
    };
    {
        let headers = request.headers_mut();
        for (name, value) in &p.headers {
            if let (Ok(n), Ok(v)) = (
                name.parse::<tokio_tungstenite::tungstenite::http::HeaderName>(),
                value.parse::<tokio_tungstenite::tungstenite::http::HeaderValue>(),
            ) {
                headers.insert(n, v);
            }
        }
        if !p.subprotocols.is_empty() {
            if let Ok(v) = p.subprotocols.join(", ").parse() {
                headers.insert("Sec-WebSocket-Protocol", v);
            }
        }
    }

    let (stream, response) = match tokio_tungstenite::connect_async(request).await {
        Ok(pair) => pair,
        Err(e) => {
            writer.err(id, format!("{e}"));
            return;
        }
    };

    let negotiated = response
        .headers()
        .get("sec-websocket-protocol")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    writer.ok(
        id,
        json!({ "open": true, "status": response.status().as_u16(), "subprotocol": negotiated }),
    );

    let (mut sink, mut source) = stream.split();
    let (tx, mut rx) = unbounded_channel::<Outbound>();
    sessions.lock().unwrap().insert(id, tx);

    // Writer half: everything the editor sends goes through this one task, in order.
    let write_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            let out = match msg {
                Outbound::Text(t) => sink.send(Message::Text(t)).await,
                Outbound::Binary(b) => sink.send(Message::Binary(b)).await,
                Outbound::Close(frame) => {
                    let _ = sink.send(Message::Close(frame)).await;
                    break;
                }
            };
            if out.is_err() {
                break;
            }
        }
        let _ = sink.close().await;
    });

    // Reader half: every inbound frame becomes a notification.
    while let Some(frame) = source.next().await {
        match frame {
            Ok(Message::Text(t)) => writer.notify(
                "ws.message",
                json!({ "id": id, "dir": "in", "kind": "text", "data": t }),
            ),
            Ok(Message::Binary(b)) => writer.notify(
                "ws.message",
                json!({ "id": id, "dir": "in", "kind": "binary", "data": base64_encode(&b) }),
            ),
            // Ping/pong are answered by tungstenite itself; they are reported because a silent
            // connection that is merely idle looks identical to a dead one otherwise.
            Ok(Message::Ping(_)) => writer.notify(
                "ws.message",
                json!({ "id": id, "dir": "in", "kind": "ping", "data": "" }),
            ),
            Ok(Message::Pong(_)) => writer.notify(
                "ws.message",
                json!({ "id": id, "dir": "in", "kind": "pong", "data": "" }),
            ),
            Ok(Message::Close(frame)) => {
                let (code, reason) = frame
                    .map(|f| (u16::from(f.code), f.reason.to_string()))
                    .unwrap_or((1005, String::new()));
                writer.notify(
                    "ws.closed",
                    json!({ "id": id, "code": code, "reason": reason }),
                );
                break;
            }
            Ok(Message::Frame(_)) => {}
            Err(e) => {
                writer.notify(
                    "ws.closed",
                    json!({ "id": id, "code": 1006, "error": format!("{e}") }),
                );
                break;
            }
        }
    }

    sessions.lock().unwrap().remove(&id);
    write_task.abort();
    writer.notify(
        "ws.closed",
        json!({ "id": id, "code": 1000, "final": true }),
    );
}

/// Send one frame on an open session.
pub fn send(rpc_id: Option<i64>, p: SendParams, writer: Writer, sessions: &Sessions) {
    let tx = sessions.lock().unwrap().get(&p.id).cloned();
    let Some(tx) = tx else {
        if let Some(id) = rpc_id {
            writer.err(id, format!("no open websocket session {}", p.id));
        }
        return;
    };
    let kind = p.kind.as_deref().unwrap_or("text");
    let out = if kind == "binary" {
        match base64_decode(&p.data) {
            Ok(bytes) => Outbound::Binary(bytes),
            Err(e) => {
                if let Some(id) = rpc_id {
                    writer.err(id, format!("bad base64 payload: {e}"));
                }
                return;
            }
        }
    } else {
        Outbound::Text(p.data.clone())
    };
    let ok = tx.send(out).is_ok();
    // Echo what we sent as a notification too: the message log in the editor is then one stream in
    // send order, not two lists the user has to interleave by eye.
    if ok {
        writer.notify(
            "ws.message",
            json!({ "id": p.id, "dir": "out", "kind": kind, "data": p.data }),
        );
    }
    if let Some(id) = rpc_id {
        if ok {
            writer.ok(id, json!({ "sent": true }));
        } else {
            writer.err(id, "the websocket session is closing");
        }
    }
}

/// Close a session from the editor's side.
pub fn close(rpc_id: Option<i64>, p: CloseParams, writer: Writer, sessions: &Sessions) {
    let tx = sessions.lock().unwrap().get(&p.id).cloned();
    if let Some(tx) = tx {
        let frame = Some(CloseFrame {
            code: CloseCode::from(p.code.unwrap_or(1000)),
            reason: p.reason.unwrap_or_default().into(),
        });
        let _ = tx.send(Outbound::Close(frame));
    }
    if let Some(id) = rpc_id {
        writer.ok(id, json!({ "closing": true }));
    }
}

fn base64_encode(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn base64_decode(text: &str) -> anyhow::Result<Vec<u8>> {
    use base64::Engine;
    Ok(base64::engine::general_purpose::STANDARD.decode(text)?)
}
