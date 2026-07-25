// lvim-rest-core::rpc — the JSON-RPC wire types + the single-writer output channel.
//
// Neovim speaks newline-delimited JSON on our stdin/stdout (the lvim-db transport shape). A
// REQUEST is `{ id, method, params }`; a RESPONSE carries the same `id` with `ok` + `result` or
// `error`; a NOTIFICATION has no `id` (`{ method, params }`) and is how streamed events reach the
// editor (`http.chunk`, `http.done`). One writer task serialises all output so responses and
// notifications never interleave.

use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::mpsc::UnboundedSender;

/// An inbound request line.
#[derive(Deserialize)]
pub struct Request {
    pub id: Option<i64>,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

/// The output sink: every task sends a JSON line here; `main` writes them to stdout in order.
#[derive(Clone)]
pub struct Writer {
    tx: UnboundedSender<String>,
}

impl Writer {
    pub fn new(tx: UnboundedSender<String>) -> Self {
        Writer { tx }
    }

    /// Emit a successful response for `id`.
    pub fn ok(&self, id: i64, result: Value) {
        let _ = self
            .tx
            .send(json!({ "id": id, "ok": true, "result": result }).to_string());
    }

    /// Emit an error response for `id`.
    pub fn err(&self, id: i64, message: impl Into<String>) {
        let _ = self
            .tx
            .send(json!({ "id": id, "ok": false, "error": message.into() }).to_string());
    }

    /// Emit an unsolicited notification (a streamed event; correlated by an `id` inside `params`).
    /// Used by the incremental-streaming path added in a later phase.
    #[allow(dead_code)]
    pub fn notify(&self, method: &str, params: Value) {
        let _ = self
            .tx
            .send(json!({ "method": method, "params": params }).to_string());
    }
}
