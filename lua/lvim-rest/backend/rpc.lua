-- lvim-rest.backend.rpc: the newline-delimited JSON-RPC client for the lvim-rest-core daemon.
--
-- Spawns the Rust daemon (`core/build/lvim-rest-daemon`) once per Neovim and speaks
-- newline-delimited JSON on its stdin/stdout — the lvim-db transport shape (the plan mentions
-- msgpack; the proven lvim-db JSON framing is reused instead, with base64 bodies for binary safety,
-- and the deviation is recorded in the work log). Request specs go down, responses (and, in a later
-- phase, streamed events) come up, correlated by id; a request is cancellable by id. The daemon
-- receives already-resolved values and stores no secrets.
--
---@module "lvim-rest.backend.rpc"

local uv = vim.uv or vim.loop
local config = require("lvim-rest.config")

local M = {}

-- The minimum daemon protocol this Lua understands.
local PROTO_MIN = 1

---@type integer? the running job handle
local job
---@type boolean whether the rpc.hello handshake completed
local ready = false
---@type integer? negotiated protocol version
local proto
---@type table? the daemon's hello result (engine/version/protocols)
local hello
---@type string trailing partial stdout line carried between chunks
local stdout_tail = ""
---@type integer monotonic request id
local id_seq = 0
---@type table<integer, fun(result: any, err: string?)> id → pending callback
local pending = {}
---@type fun(ok: boolean, err: string?)[] handshake waiters
local ensure_waiters = {}

-- ── binary discovery ────────────────────────────────────────────────────────

--- Candidate daemon binary paths, in probe order.
---@return string[]
local function candidates()
    local paths = {}
    if config.daemon.bin and config.daemon.bin ~= "" then
        paths[#paths + 1] = config.daemon.bin
    end
    local env = vim.env.LVIM_REST_DAEMON
    if env and env ~= "" then
        paths[#paths + 1] = env
    end
    -- this file → the plugin root
    local src = vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))
    local root = src:gsub("/lua/lvim%-rest/backend/rpc%.lua$", "")
    paths[#paths + 1] = root .. "/core/build/lvim-rest-daemon"
    paths[#paths + 1] = root .. "/core/target/release/lvim-rest-daemon"
    return paths
end

--- The first existing daemon binary path, or nil.
---@return string?
function M.binary_path()
    for _, p in ipairs(candidates()) do
        if uv.fs_stat(p) then
            return p
        end
    end
    return nil
end

-- ── stdout parsing ──────────────────────────────────────────────────────────

--- Handle one decoded message.
---@param msg table
local function on_message(msg)
    if msg.id ~= nil then
        local cb = pending[msg.id]
        pending[msg.id] = nil
        if cb then
            if msg.ok then
                cb(msg.result, nil)
            else
                cb(nil, msg.error or "unknown error")
            end
        end
    end
    -- Notifications (msg.method, no id) are streamed events — handled in a later phase.
end

--- Reassemble newline-delimited JSON across chunk boundaries.
---@param data string[]
local function on_stdout(data)
    if not data then
        return
    end
    data[1] = stdout_tail .. data[1]
    stdout_tail = table.remove(data)
    for _, line in ipairs(data) do
        line = vim.trim(line)
        if line ~= "" then
            local ok, msg = pcall(vim.json.decode, line)
            if ok and type(msg) == "table" then
                on_message(msg)
            end
        end
    end
end

--- Tear down after the process exits / fails.
---@param err string?
local function teardown(err)
    ready = false
    job = nil
    stdout_tail = ""
    local dead = pending
    pending = {}
    for _, cb in pairs(dead) do
        pcall(cb, nil, err or "daemon stopped")
    end
    local waiters = ensure_waiters
    ensure_waiters = {}
    for _, cb in ipairs(waiters) do
        pcall(cb, false, err or "daemon stopped")
    end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

--- Send a raw request object (only when `job` is live).
---@param obj table
local function send(obj)
    vim.fn.chansend(job, vim.json.encode(obj) .. "\n")
end

--- The rpc.hello handshake, then flush the ensure waiters.
local function handshake()
    id_seq = id_seq + 1
    local hid = id_seq
    pending[hid] = function(result, err)
        local waiters = ensure_waiters
        ensure_waiters = {}
        if err or type(result) ~= "table" then
            local msg = err or "handshake failed"
            teardown(msg)
            for _, cb in ipairs(waiters) do
                pcall(cb, false, msg)
            end
            return
        end
        proto = tonumber(result.proto)
        if not proto or proto < PROTO_MIN then
            local msg = ("daemon protocol %s too old (need >= %d)"):format(tostring(proto), PROTO_MIN)
            teardown(msg)
            for _, cb in ipairs(waiters) do
                pcall(cb, false, msg)
            end
            return
        end
        hello = result
        ready = true
        for _, cb in ipairs(waiters) do
            pcall(cb, true, nil)
        end
    end
    send({ id = hid, method = "rpc.hello", params = vim.empty_dict() })
end

--- Ensure the daemon is spawned + handshaken. `cb(ok, err)`.
---@param cb fun(ok: boolean, err: string?)
function M.ensure(cb)
    if ready and job then
        cb(true, nil)
        return
    end
    ensure_waiters[#ensure_waiters + 1] = cb
    if job then
        return
    end
    local bin = M.binary_path()
    if not bin then
        local waiters = ensure_waiters
        ensure_waiters = {}
        for _, w in ipairs(waiters) do
            pcall(w, false, "daemon binary not found")
        end
        return
    end
    local ok, handle = pcall(vim.fn.jobstart, { bin }, {
        on_stdout = function(_, data, _)
            on_stdout(data)
        end,
        on_exit = function()
            teardown("daemon exited")
        end,
        stdout_buffered = false,
    })
    if not ok or type(handle) ~= "number" or handle <= 0 then
        job = nil
        local waiters = ensure_waiters
        ensure_waiters = {}
        for _, w in ipairs(waiters) do
            pcall(w, false, "failed to spawn daemon")
        end
        return
    end
    job = handle
    handshake()
end

--- Issue one RPC request. `cb(result, err)`.
---@param method string
---@param params table?
---@param cb fun(result: any, err: string?)
function M.request(method, params, cb)
    M.ensure(function(ok, err)
        if not ok then
            cb(nil, err)
            return
        end
        id_seq = id_seq + 1
        local rid = id_seq
        pending[rid] = cb
        send({ id = rid, method = method, params = params or vim.empty_dict() })
    end)
end

--- The daemon's hello info (engine/version/protocols), or nil before handshake.
---@return table?
function M.info()
    return hello
end

--- Whether the daemon is up + handshaken.
---@return boolean
function M.is_running()
    return ready and job ~= nil
end

-- ── the execution seam (used by backend.init) ───────────────────────────────

--- Build the GraphQL POST body (query + optional trailing JSON variables block).
---@param body string?
---@return string
local function graphql_body(body)
    body = body or ""
    local query, vars = body, nil
    local qpart, vpart = body:match("^(.-)\n%s*\n(%b{})%s*$")
    if qpart and vpart then
        query, vars = qpart, vpart
    end
    local payload = { query = vim.trim(query) }
    if vars then
        local ok, decoded = pcall(vim.json.decode, vars)
        if ok then
            payload.variables = decoded
        end
    end
    return vim.json.encode(payload)
end

--- The status reason phrase (delegated to the curl module's table).
---@param code integer
---@return string
local function reason(code)
    return require("lvim-rest.backend.curl").reason(code)
end

--- Run a resolved request on the daemon. `cb(result)` receives the same result shape the curl path
--- produces. Returns a handle with `:kill()` (sends `http.cancel`).
---@param resolved LvimRestResolvedRequest
---@param cb fun(result: table)
---@return { kill: fun() }
function M.run(resolved, cb)
    -- Map GRAPHQL → POST + build its body (the daemon speaks real HTTP methods).
    local method = resolved.method == "GRAPHQL" and "POST" or resolved.method
    local body = resolved.body
    local headers = {}
    local has_ct = false
    for _, h in ipairs(resolved.headers) do
        headers[#headers + 1] = { h.name, h.value }
        if h.name:lower() == "content-type" then
            has_ct = true
        end
    end
    if resolved.method == "GRAPHQL" then
        body = graphql_body(resolved.body)
        if not has_ct then
            headers[#headers + 1] = { "Content-Type", "application/json" }
        end
    end

    local params = {
        method = method,
        url = resolved.url,
        headers = headers,
        body = body,
        timeout_ms = resolved.directives.timeout or config.request.timeout,
        follow_redirects = config.request.follow_redirects,
        insecure = config.request.insecure or resolved.directives.curl.insecure ~= nil,
        http_version = resolved.http_version or config.request.http_version,
    }

    -- Translate a daemon response into the shared result shape.
    local function translate(result, err)
        vim.schedule(function()
            if err then
                cb({ error = err })
                return
            end
            local decoded_body = ""
            if result.body_b64 and result.body_b64 ~= "" then
                local ok, raw = pcall(vim.base64.decode, result.body_b64)
                decoded_body = ok and raw or ""
            end
            local resp_headers = {}
            for _, kv in ipairs(result.headers or {}) do
                resp_headers[#resp_headers + 1] = { name = kv[1], value = kv[2] }
            end
            local status = tonumber(result.status) or 0
            cb({
                status = status,
                status_text = reason(status),
                headers = resp_headers,
                body = decoded_body,
                http_version = tostring(result.http_version or ""),
                timing = {
                    total = (result.timing and result.timing.total) or 0,
                    dns = (result.timing and result.timing.dns) or 0,
                    connect = (result.timing and result.timing.connect) or 0,
                    tls = (result.timing and result.timing.tls) or 0,
                    ttfb = (result.timing and result.timing.ttfb) or 0,
                },
                size = {
                    down = (result.size and result.size.down) or #decoded_body,
                    up = (result.size and result.size.up) or 0,
                },
                url = resolved.url,
                method = resolved.method,
                request = resolved,
                engine = "daemon",
            })
        end)
    end

    -- Track our own request id so http.cancel can target it precisely.
    local sent_id
    M.ensure(function(ok, err)
        if not ok then
            translate(nil, err)
            return
        end
        id_seq = id_seq + 1
        sent_id = id_seq
        pending[sent_id] = translate
        send({ id = sent_id, method = "http.send", params = params })
    end)

    return {
        kill = function()
            if sent_id then
                pending[sent_id] = nil -- drop the callback so a late response is ignored
                M.request("http.cancel", { id = sent_id }, function() end)
            end
        end,
    }
end

--- Stop the daemon (closes its stdin → it exits). Idempotent.
function M.stop()
    if job then
        pcall(vim.fn.chanclose, job, "stdin")
        pcall(vim.fn.jobstop, job)
    end
    teardown("daemon stopped")
end

return M
