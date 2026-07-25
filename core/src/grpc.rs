// lvim-rest-core::grpc — dynamic gRPC calls.
//
// "Dynamic" is the whole point: an editor cannot be rebuilt against every user's `.proto`, so the
// message types are discovered at CALL TIME and encoded from JSON. Two sources, in this order:
//
//   1. `.proto` files named by the request — compiled in-process with `protox` (a pure-Rust
//      protobuf compiler, so no `protoc` binary has to exist on the machine).
//   2. SERVER REFLECTION — ask the server for its own descriptors. This is what `grpcurl` does and
//      what most people expect, but plenty of production servers have reflection switched off, so
//      it cannot be the only way in.
//
// Either source yields a `FileDescriptorSet` → a `prost_reflect::DescriptorPool`, and from there a
// `DynamicMessage` is built out of the user's JSON, sent through `tonic`'s generic client with a
// codec that just moves bytes, and the reply is turned back into JSON. So the daemon never needs
// generated code for anything.
//
// Unary only for now: a streaming call has no single "response" for the dock to show, and the
// WebSocket session model is the right shape for that — not this one.

use std::collections::HashMap;

use anyhow::{anyhow, Context, Result};
use prost::Message as _;
use prost_reflect::{DescriptorPool, DynamicMessage, MethodDescriptor, SerializeOptions};
use serde::Deserialize;
use serde_json::{json, Value};
use tonic::codec::{Codec, DecodeBuf, Decoder, EncodeBuf, Encoder};
use tonic::{Request, Status};

use crate::rpc::Writer;

#[derive(Deserialize)]
pub struct GrpcParams {
    /// `host:port`, or a full `http(s)://host:port` — plaintext unless the scheme says otherwise.
    pub url: String,
    /// Fully-qualified `package.Service/Method`, or `package.Service.Method`.
    #[serde(default)]
    pub method: String,
    /// The request message as JSON.
    #[serde(default)]
    pub message: Value,
    /// Metadata (gRPC's headers).
    #[serde(default)]
    pub metadata: Vec<(String, String)>,
    /// `.proto` files to compile instead of asking the server.
    #[serde(default)]
    pub proto: Vec<String>,
    /// Include paths for those files.
    #[serde(default)]
    pub import_paths: Vec<String>,
    #[serde(default)]
    pub timeout_ms: Option<u64>,
    /// TLS server-name override for the certificate check — reach a TLS server through a tunnel
    /// (connect to `localhost` but verify its real domain). Empty = use the URL's host.
    #[serde(default)]
    pub tls_authority: String,
    /// Skip TLS certificate verification entirely (like `curl -k`) — for self-signed / dev servers.
    #[serde(default)]
    pub insecure: bool,
    /// `grpc.list` only: when false, just the service names.
    #[serde(default)]
    pub methods: bool,
}

// ── the codec ────────────────────────────────────────────────────────────────

/// A codec over already-encoded bytes: `tonic` handles framing and compression, and the dynamic
/// message is serialised by us on either side. Nothing here knows a message type.
#[derive(Default, Clone)]
struct BytesCodec;

impl Codec for BytesCodec {
    type Encode = Vec<u8>;
    type Decode = Vec<u8>;
    type Encoder = BytesCodec;
    type Decoder = BytesCodec;

    fn encoder(&mut self) -> Self::Encoder {
        self.clone()
    }
    fn decoder(&mut self) -> Self::Decoder {
        self.clone()
    }
}

impl Encoder for BytesCodec {
    type Item = Vec<u8>;
    type Error = Status;

    fn encode(&mut self, item: Self::Item, buf: &mut EncodeBuf<'_>) -> Result<(), Self::Error> {
        use bytes::BufMut;
        buf.put_slice(&item);
        Ok(())
    }
}

impl Decoder for BytesCodec {
    type Item = Vec<u8>;
    type Error = Status;

    fn decode(&mut self, buf: &mut DecodeBuf<'_>) -> Result<Option<Self::Item>, Self::Error> {
        use bytes::Buf;
        let len = buf.remaining();
        let mut out = vec![0u8; len];
        buf.copy_to_slice(&mut out);
        Ok(Some(out))
    }
}

// ── descriptors ──────────────────────────────────────────────────────────────

/// Compile `.proto` files into a pool, with no external `protoc`.
fn pool_from_files(files: &[String], imports: &[String]) -> Result<DescriptorPool> {
    let default_import = vec![".".to_string()];
    let imports = if imports.is_empty() {
        &default_import[..]
    } else {
        imports
    };
    let fds = protox::compile(files, imports)
        .map_err(|e| anyhow!("could not compile the .proto files: {e}"))?;
    DescriptorPool::from_file_descriptor_set(fds).context("the compiled descriptors are not usable")
}

/// Ask the server for the descriptors of `symbol` (and everything it depends on).
///
/// Reflection exists in TWO versions in the wild — `grpc.reflection.v1` and the older
/// `v1alpha` — and a server implements one, the other, or both. So v1 is tried first and v1alpha is
/// the fallback, which is what grpcurl does and the only way to work against real servers.
async fn pool_from_reflection(endpoint: &str, symbol: &str) -> Result<DescriptorPool> {
    let files = match reflect_v1(endpoint, symbol).await {
        Ok(f) => f,
        Err(first) => reflect_v1alpha(endpoint, symbol)
            .await
            .map_err(|second| anyhow!("server reflection is not available — name a .proto file instead (v1: {first:#}; v1alpha: {second:#})"))?,
    };
    if files.is_empty() {
        return Err(anyhow!("reflection returned no descriptors for {symbol}"));
    }
    let mut set = prost_types::FileDescriptorSet::default();
    for bytes in files {
        set.file
            .push(prost_types::FileDescriptorProto::decode(&bytes[..])?);
    }
    DescriptorPool::from_file_descriptor_set(set)
        .context("the reflected descriptors are not usable")
}

/// The raw file-descriptor bytes for `symbol`, over reflection v1.
async fn reflect_v1(endpoint: &str, symbol: &str) -> Result<Vec<Vec<u8>>> {
    use tonic_reflection::pb::v1::server_reflection_client::ServerReflectionClient;
    use tonic_reflection::pb::v1::server_reflection_request::MessageRequest;
    use tonic_reflection::pb::v1::server_reflection_response::MessageResponse;
    use tonic_reflection::pb::v1::ServerReflectionRequest;

    let channel = tonic::transport::Endpoint::from_shared(endpoint.to_string())?
        .connect()
        .await
        .context("could not connect for reflection")?;
    let mut client = ServerReflectionClient::new(channel);
    let outbound = tokio_stream::once(ServerReflectionRequest {
        host: String::new(),
        message_request: Some(MessageRequest::FileContainingSymbol(symbol.to_string())),
    });
    let mut inbound = client
        .server_reflection_info(Request::new(outbound))
        .await
        .map_err(|e| anyhow!("{}", e.message()))?
        .into_inner();
    // One round-trip is enough: `FileContainingSymbol` returns the file AND its transitive
    // dependencies, which is exactly what the pool needs.
    while let Some(reply) = futures_util::StreamExt::next(&mut inbound).await {
        match reply?.message_response {
            Some(MessageResponse::FileDescriptorResponse(fdr)) => {
                return Ok(fdr.file_descriptor_proto)
            }
            Some(MessageResponse::ErrorResponse(e)) => return Err(anyhow!("{}", e.error_message)),
            _ => break,
        }
    }
    Ok(Vec::new())
}

/// The same, over the older reflection v1alpha.
async fn reflect_v1alpha(endpoint: &str, symbol: &str) -> Result<Vec<Vec<u8>>> {
    use tonic_reflection::pb::v1alpha::server_reflection_client::ServerReflectionClient;
    use tonic_reflection::pb::v1alpha::server_reflection_request::MessageRequest;
    use tonic_reflection::pb::v1alpha::server_reflection_response::MessageResponse;
    use tonic_reflection::pb::v1alpha::ServerReflectionRequest;

    let channel = tonic::transport::Endpoint::from_shared(endpoint.to_string())?
        .connect()
        .await
        .context("could not connect for reflection")?;
    let mut client = ServerReflectionClient::new(channel);
    let outbound = tokio_stream::once(ServerReflectionRequest {
        host: String::new(),
        message_request: Some(MessageRequest::FileContainingSymbol(symbol.to_string())),
    });
    let mut inbound = client
        .server_reflection_info(Request::new(outbound))
        .await
        .map_err(|e| anyhow!("{}", e.message()))?
        .into_inner();
    while let Some(reply) = futures_util::StreamExt::next(&mut inbound).await {
        match reply?.message_response {
            Some(MessageResponse::FileDescriptorResponse(fdr)) => {
                return Ok(fdr.file_descriptor_proto)
            }
            Some(MessageResponse::ErrorResponse(e)) => return Err(anyhow!("{}", e.error_message)),
            _ => break,
        }
    }
    Ok(Vec::new())
}

/// The service names a server advertises, over whichever reflection version it speaks.
async fn reflect_services(endpoint: &str) -> Result<Vec<String>> {
    async fn v1(endpoint: &str) -> Result<Vec<String>> {
        use tonic_reflection::pb::v1::server_reflection_client::ServerReflectionClient;
        use tonic_reflection::pb::v1::server_reflection_request::MessageRequest;
        use tonic_reflection::pb::v1::server_reflection_response::MessageResponse;
        use tonic_reflection::pb::v1::ServerReflectionRequest;

        let channel = tonic::transport::Endpoint::from_shared(endpoint.to_string())?
            .connect()
            .await?;
        let mut client = ServerReflectionClient::new(channel);
        let outbound = tokio_stream::once(ServerReflectionRequest {
            host: String::new(),
            message_request: Some(MessageRequest::ListServices(String::new())),
        });
        let mut inbound = client
            .server_reflection_info(Request::new(outbound))
            .await
            .map_err(|e| anyhow!("{}", e.message()))?
            .into_inner();
        while let Some(reply) = futures_util::StreamExt::next(&mut inbound).await {
            if let Some(MessageResponse::ListServicesResponse(r)) = reply?.message_response {
                return Ok(r.service.into_iter().map(|s| s.name).collect());
            }
        }
        Ok(Vec::new())
    }
    async fn v1alpha(endpoint: &str) -> Result<Vec<String>> {
        use tonic_reflection::pb::v1alpha::server_reflection_client::ServerReflectionClient;
        use tonic_reflection::pb::v1alpha::server_reflection_request::MessageRequest;
        use tonic_reflection::pb::v1alpha::server_reflection_response::MessageResponse;
        use tonic_reflection::pb::v1alpha::ServerReflectionRequest;

        let channel = tonic::transport::Endpoint::from_shared(endpoint.to_string())?
            .connect()
            .await?;
        let mut client = ServerReflectionClient::new(channel);
        let outbound = tokio_stream::once(ServerReflectionRequest {
            host: String::new(),
            message_request: Some(MessageRequest::ListServices(String::new())),
        });
        let mut inbound = client
            .server_reflection_info(Request::new(outbound))
            .await
            .map_err(|e| anyhow!("{}", e.message()))?
            .into_inner();
        while let Some(reply) = futures_util::StreamExt::next(&mut inbound).await {
            if let Some(MessageResponse::ListServicesResponse(r)) = reply?.message_response {
                return Ok(r.service.into_iter().map(|s| s.name).collect());
            }
        }
        Ok(Vec::new())
    }
    match v1(endpoint).await {
        Ok(names) if !names.is_empty() => Ok(names),
        Ok(_) => v1alpha(endpoint).await,
        Err(first) => v1alpha(endpoint).await.map_err(|second| {
            anyhow!("server reflection is not available (v1: {first:#}; v1alpha: {second:#})")
        }),
    }
}

/// `package.Service/Method` and `package.Service.Method` both name the same thing.
fn split_method(name: &str) -> Result<(String, String)> {
    if let Some((service, method)) = name.split_once('/') {
        return Ok((
            service.trim_start_matches('/').to_string(),
            method.to_string(),
        ));
    }
    let (service, method) = name
        .rsplit_once('.')
        .ok_or_else(|| anyhow!("method must be package.Service/Method"))?;
    Ok((service.to_string(), method.to_string()))
}

/// Normalise `host:port` into a URI tonic will accept.
fn endpoint_of(url: &str) -> String {
    if url.starts_with("http://") || url.starts_with("https://") {
        url.to_string()
    } else {
        format!("http://{url}")
    }
}

/// Build a tonic `Endpoint`, enabling TLS for an `https://` URL. `tls_authority` overrides the SNI /
/// certificate name — the way to reach a TLS server through a tunnel: connect to `localhost:port`
/// while verifying the server's REAL domain against the public roots (webpki). `insecure` is not yet
/// supported here (a custom rustls verifier); name the domain with `@grpc-authority` instead.
fn build_endpoint(
    url: &str,
    timeout_ms: Option<u64>,
    tls_authority: &str,
    insecure: bool,
) -> Result<tonic::transport::Endpoint> {
    use tonic::transport::{ClientTlsConfig, Endpoint};
    // TLS is used when the URL says `https://`, or an authority override / insecure is requested — so
    // a bare `host:port` request line can still reach a TLS server just by naming `# @grpc-authority`.
    let want_tls = url.starts_with("https://") || !tls_authority.is_empty() || insecure;
    let uri = if want_tls {
        if url.starts_with("https://") {
            url.to_string()
        } else if let Some(rest) = url.strip_prefix("http://") {
            format!("https://{rest}")
        } else {
            format!("https://{url}")
        }
    } else {
        endpoint_of(url)
    };
    let mut ep = Endpoint::from_shared(uri)?
        .timeout(std::time::Duration::from_millis(timeout_ms.unwrap_or(30_000)));
    if want_tls {
        if insecure {
            return Err(anyhow!(
                "insecure gRPC TLS is not supported yet — name the certificate domain with \
                 `# @grpc-authority <domain>` (e.g. reach a tunnelled server by its real host)"
            ));
        }
        let mut tls = ClientTlsConfig::new().with_webpki_roots();
        if !tls_authority.is_empty() {
            tls = tls.domain_name(tls_authority.to_string());
        }
        ep = ep.tls_config(tls)?;
    }
    Ok(ep)
}

fn find_method(pool: &DescriptorPool, service: &str, method: &str) -> Result<MethodDescriptor> {
    let svc = pool
        .get_service_by_name(service)
        .ok_or_else(|| anyhow!("no service {service} in the descriptors"))?;
    let found = svc.methods().find(|m| m.name() == method);
    found.ok_or_else(|| anyhow!("service {service} has no method {method}"))
}

// ── the calls ────────────────────────────────────────────────────────────────

/// One unary call.
pub async fn call(id: i64, p: GrpcParams, writer: Writer) {
    let started = std::time::Instant::now();
    match call_inner(&p).await {
        Ok(body) => {
            let ms = started.elapsed().as_millis() as u64;
            writer.ok(
                id,
                json!({
                    "status": 200,
                    "status_text": "OK",
                    "headers": [["content-type", "application/grpc"]],
                    "body": body,
                    "url": p.url,
                    "method": "GRPC",
                    "engine": "daemon",
                    "http_version": "2",
                    "timing": { "total": ms, "dns": 0, "connect": 0, "tls": 0, "ttfb": ms },
                    "size": { "down": body.len(), "up": 0 },
                }),
            );
        }
        Err(e) => writer.err(id, format!("{e:#}")),
    }
}

async fn call_inner(p: &GrpcParams) -> Result<String> {
    let (service, method_name) = split_method(&p.method)?;
    let endpoint = endpoint_of(&p.url);

    let pool = if p.proto.is_empty() {
        pool_from_reflection(&endpoint, &service).await?
    } else {
        pool_from_files(&p.proto, &p.import_paths)?
    };
    let method = find_method(&pool, &service, &method_name)?;
    if method.is_client_streaming() || method.is_server_streaming() {
        return Err(anyhow!(
            "{service}/{method_name} is a streaming method — only unary calls are supported"
        ));
    }

    // JSON → DynamicMessage → bytes.
    let message_json = serde_json::to_string(&p.message)?;
    let mut de = serde_json::Deserializer::from_str(&message_json);
    let request_msg = DynamicMessage::deserialize(method.input(), &mut de)
        .with_context(|| format!("the message does not fit {}", method.input().full_name()))?;
    de.end()?;
    let request_bytes = request_msg.encode_to_vec();

    let channel = build_endpoint(&p.url, p.timeout_ms, &p.tls_authority, p.insecure)?
        .connect()
        .await
        .context("could not connect")?;
    let mut client = tonic::client::Grpc::new(channel);
    client
        .ready()
        .await
        .map_err(|e| anyhow!("the channel never became ready: {e}"))?;

    let mut request = Request::new(request_bytes);
    for (k, v) in &p.metadata {
        if let (Ok(key), Ok(value)) = (
            k.parse::<tonic::metadata::MetadataKey<_>>(),
            v.parse::<tonic::metadata::MetadataValue<_>>(),
        ) {
            request.metadata_mut().insert(key, value);
        }
    }

    let path = format!("/{}/{}", service, method_name)
        .parse::<tonic::codegen::http::uri::PathAndQuery>()
        .map_err(|e| anyhow!("bad method path: {e}"))?;
    let response = client
        .unary(request, path, BytesCodec)
        .await
        .map_err(|s| anyhow!("{}: {}", s.code(), s.message()))?;

    // bytes → DynamicMessage → JSON.
    let reply = DynamicMessage::decode(method.output(), &response.into_inner()[..])
        .context("the reply did not decode as the declared output message")?;
    let mut out = Vec::new();
    let mut ser = serde_json::Serializer::pretty(&mut out);
    // `stringify_64_bit_integers` off: a json number is what the rest of the plugin's jq/filters
    // expect, and the dock shows the body verbatim.
    reply.serialize_with_options(
        &mut ser,
        &SerializeOptions::new().stringify_64_bit_integers(false),
    )?;
    Ok(String::from_utf8(out)?)
}

/// List the services a server exposes (and, optionally, their methods).
pub async fn list(id: i64, p: GrpcParams, writer: Writer) {
    match list_inner(&p).await {
        Ok(v) => writer.ok(id, v),
        Err(e) => writer.err(id, format!("{e:#}")),
    }
}

async fn list_inner(p: &GrpcParams) -> Result<Value> {
    let endpoint = endpoint_of(&p.url);
    if !p.proto.is_empty() {
        // With local descriptors there is nothing to ask the server.
        let pool = pool_from_files(&p.proto, &p.import_paths)?;
        return Ok(services_of(&pool, p.methods));
    }
    let names = reflect_services(&endpoint).await?;
    if !p.methods {
        return Ok(json!({ "services": names }));
    }
    // Fetching each service's descriptors is a call apiece; only done when methods were asked for.
    let mut out = HashMap::new();
    for name in &names {
        if let Ok(pool) = pool_from_reflection(&endpoint, name).await {
            if let Some(svc) = pool.get_service_by_name(name) {
                out.insert(
                    name.clone(),
                    svc.methods()
                        .map(|m| m.name().to_string())
                        .collect::<Vec<_>>(),
                );
            }
        }
    }
    Ok(json!({ "services": names, "methods": out }))
}

fn services_of(pool: &DescriptorPool, with_methods: bool) -> Value {
    let names: Vec<String> = pool.services().map(|s| s.full_name().to_string()).collect();
    if !with_methods {
        return json!({ "services": names });
    }
    let mut methods = HashMap::new();
    for svc in pool.services() {
        methods.insert(
            svc.full_name().to_string(),
            svc.methods()
                .map(|m| m.name().to_string())
                .collect::<Vec<_>>(),
        );
    }
    json!({ "services": names, "methods": methods })
}
