// lvim-rest-core::http — the reqwest HTTP/1.1 · HTTP/2 execution handler.
//
// One `http.send` request builds a per-call client (redirect policy / TLS verification / timeout /
// forced version vary per request), issues it, and returns status + headers + the body (base64, so
// binary is safe) + a timing split. reqwest transparently handles chunked transfer-encoding and
// content decompression, so a `@accept chunked` body still returns whole here; true INCREMENTAL
// streaming to the dock is a later enhancement (the transport is buffered in this phase).
//
// Cancellation needs no code here: `main` spawns each send as an abortable task and drops it on
// `http.cancel`, which cancels the in-flight reqwest future.

use std::time::{Duration, Instant};

use base64::Engine;
use serde::Deserialize;
use serde_json::json;

use crate::rpc::Writer;

/// The `http.send` params.
#[derive(Deserialize)]
pub struct HttpParams {
    pub method: String,
    pub url: String,
    #[serde(default)]
    pub headers: Vec<(String, String)>,
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub timeout_ms: Option<u64>,
    #[serde(default = "default_true")]
    pub follow_redirects: bool,
    #[serde(default)]
    pub insecure: bool,
    #[serde(default)]
    pub http_version: Option<String>,
}

fn default_true() -> bool {
    true
}

/// Normalise reqwest's `{:?}` version ("HTTP/2.0") to the bare number ("2").
fn version_str(v: reqwest::Version) -> String {
    let s = format!("{:?}", v);
    s.strip_prefix("HTTP/")
        .unwrap_or(&s)
        .trim_end_matches(".0")
        .to_string()
}

/// Handle one `http.send`, emitting the response (or an error) for `id`.
pub async fn send(id: i64, p: HttpParams, writer: Writer) {
    match run(&p).await {
        Ok(value) => writer.ok(id, value),
        Err(e) => writer.err(id, e.to_string()),
    }
}

async fn run(p: &HttpParams) -> anyhow::Result<serde_json::Value> {
    // No cookie store here (reqwest has none by default, and the `cookies` feature is off): the Lua
    // side owns ONE jar for both engines — see `lvim-rest.cookies` — and a second store would send
    // cookies the jar had already dropped.
    let mut cb = reqwest::Client::builder();
    if !p.follow_redirects {
        cb = cb.redirect(reqwest::redirect::Policy::none());
    }
    if p.insecure {
        cb = cb.danger_accept_invalid_certs(true);
    }
    if let Some(ms) = p.timeout_ms {
        cb = cb.timeout(Duration::from_millis(ms));
    }
    if let Some(v) = &p.http_version {
        if v == "1.1" || v == "1" {
            cb = cb.http1_only();
        }
        // "2"/"3"/"auto" negotiate via ALPN on https (the default); HTTP/3 lands in a later phase.
    }
    let client = cb.build()?;

    // A method the HTTP grammar does not accept is an error, not a GET: silently sending a
    // different verb than the document asked for is the one answer that cannot be debugged.
    let method = reqwest::Method::from_bytes(p.method.to_uppercase().as_bytes())
        .map_err(|_| anyhow::anyhow!("{:?} is not a valid HTTP method", p.method))?;
    let mut rb = client.request(method, &p.url);
    for (k, v) in &p.headers {
        rb = rb.header(k.as_str(), v.as_str());
    }
    if let Some(body) = &p.body {
        rb = rb.body(body.clone().into_bytes());
    }

    let start = Instant::now();
    let resp = rb.send().await?;
    let ttfb = start.elapsed().as_millis() as u64;

    let status = resp.status().as_u16();
    let http_version = version_str(resp.version());
    let headers: Vec<[String; 2]> = resp
        .headers()
        .iter()
        .map(|(k, v)| [k.to_string(), v.to_str().unwrap_or("").to_string()])
        .collect();

    let bytes = resp.bytes().await?;
    let total = start.elapsed().as_millis() as u64;
    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);

    Ok(json!({
        "status": status,
        "http_version": http_version,
        "headers": headers,
        "body_b64": body_b64,
        // reqwest does not expose DNS/connect/TLS splits; total + ttfb are real, the splits are
        // the curl backend's forte (documented). Kept in the shape the Lua stats view expects.
        "timing": { "total": total, "ttfb": ttfb, "dns": 0, "connect": 0, "tls": 0 },
        "size": { "down": bytes.len(), "up": p.body.as_ref().map(|b| b.len()).unwrap_or(0) },
    }))
}
