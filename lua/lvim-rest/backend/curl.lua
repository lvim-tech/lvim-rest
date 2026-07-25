-- lvim-rest.backend.curl: the pure-curl HTTP/GraphQL execution path.
--
-- The graceful fallback engine (`backend = "curl"`, or `"auto"` when the Rust daemon is not built):
-- HTTP and GraphQL only — gRPC/WebSocket/HTTP-3 are daemon-native and health says so. Every call is
-- a LIST-FORM `vim.system` argv (no shell string, ever); the body goes through a temp file
-- (`--data-binary @file`), the response headers through `-D`, the body through `-o`, and the timing
-- through curl's own `--write-out '%{json}'` on stdout — so nothing is interpolated and nothing is
-- parsed out of a mixed stream.
--
---@module "lvim-rest.backend.curl"

local config = require("lvim-rest.config")
local fs = require("lvim-rest.fs")

local M = {}

-- Reason phrases for the common status codes (curl's %{json} reports the code, not the phrase).
local REASON = {
    [200] = "OK",
    [201] = "Created",
    [202] = "Accepted",
    [204] = "No Content",
    [301] = "Moved Permanently",
    [302] = "Found",
    [304] = "Not Modified",
    [307] = "Temporary Redirect",
    [308] = "Permanent Redirect",
    [400] = "Bad Request",
    [401] = "Unauthorized",
    [403] = "Forbidden",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [409] = "Conflict",
    [422] = "Unprocessable Entity",
    [429] = "Too Many Requests",
    [500] = "Internal Server Error",
    [502] = "Bad Gateway",
    [503] = "Service Unavailable",
    [504] = "Gateway Timeout",
}

--- The reason phrase for a status code (best-effort; empty for unknown codes).
---@param code integer
---@return string
function M.reason(code)
    return REASON[code] or ""
end

--- A unique temp file path under the state dir.
---@param tag string
---@return string
local function tmpfile(tag)
    local dir = vim.fn.stdpath("state") .. "/lvim-rest/tmp"
    vim.fn.mkdir(dir, "p")
    return string.format("%s/%s-%d-%d", dir, tag, vim.uv.hrtime(), math.random(1, 1e6))
end

--- Build the GraphQL POST body from a `GRAPHQL` request: the query text, plus an optional trailing
--- `{ … }` JSON variables block (separated from the query by a blank line).
---@param body string?
---@return string
local function graphql_body(body)
    body = body or ""
    local query, vars = body, nil
    -- A trailing JSON object (last blank-line-separated block) is the variables block.
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

--- Parse a `-D` header-dump file into the LAST response's status + ordered headers (redirects leave
--- multiple blocks; the final one is the real response).
---@param path string
---@return { status: integer?, status_line: string?, http_version: string?, headers: LvimRestHeader[] }
local function parse_headers(path)
    local out = { headers = {} }
    if vim.fn.filereadable(path) == 0 then
        return out
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
        return out
    end
    -- Walk forward, resetting on each new `HTTP/…` status line so the final block wins.
    for _, raw in ipairs(lines) do
        local line = raw:gsub("\r$", "")
        local ver, code = line:match("^HTTP/([%d%.]+)%s+(%d%d%d)")
        if ver then
            out.status = tonumber(code)
            out.status_line = line
            out.http_version = ver
            out.headers = {}
        elseif line ~= "" then
            local name, value = line:match("^([^:]+):%s*(.*)$")
            if name then
                out.headers[#out.headers + 1] = { name = name, value = value }
            end
        end
    end
    return out
end

--- Convert curl's `%{json}` timing (seconds) into a ms split.
---@param info table
---@return { total: number, dns: number, connect: number, tls: number, ttfb: number }
local function timing(info)
    local function ms(x)
        return math.floor((tonumber(x) or 0) * 1000 + 0.5)
    end
    local dns = ms(info.time_namelookup)
    local connect = ms(info.time_connect)
    local appconnect = ms(info.time_appconnect)
    return {
        total = ms(info.time_total),
        dns = dns,
        connect = math.max(0, connect - dns),
        tls = appconnect > 0 and math.max(0, appconnect - connect) or 0,
        ttfb = ms(info.time_starttransfer),
    }
end

--- Build the curl argv for a resolved request. Returns the argv plus the temp file paths to read
--- back and clean up.
---@param resolved LvimRestResolvedRequest
---@return string[] argv, { body?: string, header: string, out: string }
function M.build_argv(resolved, files)
    files = files or {}
    files.header = tmpfile("hdr")
    files.out = tmpfile("out")

    local argv = { "curl", "-sS" }
    -- Follow redirects / TLS verification.
    if config.request.follow_redirects then
        argv[#argv + 1] = "-L"
    end
    if config.request.insecure or resolved.directives.curl.insecure ~= nil then
        argv[#argv + 1] = "-k"
    end
    -- HTTP version.
    local hv = resolved.http_version or config.request.http_version
    if hv == "1.1" then
        argv[#argv + 1] = "--http1.1"
    elseif hv == "2" then
        argv[#argv + 1] = "--http2"
    elseif hv == "3" then
        argv[#argv + 1] = "--http3"
    end
    -- Timeout (ms → s).
    local timeout_ms = resolved.directives.timeout or config.request.timeout
    argv[#argv + 1] = "--max-time"
    argv[#argv + 1] = tostring(math.max(1, math.floor(timeout_ms / 1000)))

    -- Method (GraphQL is a POST).
    local method = resolved.method == "GRAPHQL" and "POST" or resolved.method
    argv[#argv + 1] = "-X"
    argv[#argv + 1] = method

    -- Headers.
    local has_ct = false
    for _, h in ipairs(resolved.headers) do
        argv[#argv + 1] = "-H"
        argv[#argv + 1] = h.name .. ": " .. h.value
        if h.name:lower() == "content-type" then
            has_ct = true
        end
    end

    -- Body.
    local body = resolved.body
    if resolved.method == "GRAPHQL" then
        body = graphql_body(resolved.body)
        if not has_ct then
            argv[#argv + 1] = "-H"
            argv[#argv + 1] = "Content-Type: application/json"
        end
    end
    if body and body ~= "" then
        files.body = tmpfile("body")
        fs.write(files.body, body) -- verbatim: `--data-binary @file` sends exactly these bytes
        argv[#argv + 1] = "--data-binary"
        argv[#argv + 1] = "@" .. files.body
    end

    -- Raw curl flags from `@curl-*` directives.
    for flag, value in pairs(resolved.directives.curl or {}) do
        if flag ~= "insecure" then -- already handled via -k
            argv[#argv + 1] = (#flag == 1 and "-" or "--") .. flag
            if type(value) == "string" and value ~= "" then
                argv[#argv + 1] = value
            end
        end
    end

    argv[#argv + 1] = "-D"
    argv[#argv + 1] = files.header
    argv[#argv + 1] = "-o"
    argv[#argv + 1] = files.out
    argv[#argv + 1] = "-w"
    argv[#argv + 1] = "%{json}"
    argv[#argv + 1] = resolved.url
    return argv, files
end

--- Execute a resolved request via curl. `cb(result)` receives the response table (or `{ error = … }`).
--- Returns a handle with `:kill()` for cancellation.
---@param resolved LvimRestResolvedRequest
---@param cb fun(result: table)
---@return { kill: fun() }
function M.run(resolved, cb)
    local files = {}
    local argv = M.build_argv(resolved, files)

    local function cleanup()
        for _, f in pairs(files) do
            pcall(os.remove, f)
        end
    end

    local ok, handle = pcall(vim.system, argv, { text = true }, function(obj)
        vim.schedule(function()
            if obj.code ~= 0 and obj.code ~= nil then
                cleanup()
                cb({ error = vim.trim(obj.stderr or "") ~= "" and vim.trim(obj.stderr) or ("curl exit " .. obj.code) })
                return
            end
            local hdr = parse_headers(files.header)
            -- The body is BYTES: see `lvim-rest.fs` for why readfile cannot be used here.
            local body = fs.read(files.out)
            local jok, decoded = pcall(vim.json.decode, vim.trim(obj.stdout or ""))
            ---@type table<string, any>
            local info = (jok and type(decoded) == "table") and decoded or {}
            cleanup()
            local status = hdr.status or tonumber(info.http_code) or 0
            cb({
                status = status,
                status_text = M.reason(status),
                status_line = hdr.status_line,
                headers = hdr.headers,
                body = body,
                http_version = hdr.http_version or tostring(info.http_version or ""),
                timing = timing(info),
                size = { down = tonumber(info.size_download) or #body, up = tonumber(info.size_upload) or 0 },
                url = resolved.url,
                method = resolved.method,
                request = resolved,
                curl_argv = argv,
                engine = "curl",
            })
        end)
    end)

    if not ok then
        cleanup()
        vim.schedule(function()
            cb({ error = "failed to spawn curl (is it installed?)" })
        end)
        return { kill = function() end }
    end
    return {
        kill = function()
            pcall(function()
                handle:kill(15)
            end)
        end,
    }
end

--- Whether curl is available on PATH.
---@return boolean
function M.available()
    return vim.fn.executable("curl") == 1
end

return M
