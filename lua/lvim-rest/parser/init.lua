-- lvim-rest.parser: the .http / .rest document parser.
--
-- This is the EXECUTION parser — the runner depends on THIS, never on a treesitter grammar
-- (the file format is line-regular, so the runner must work with no grammar installed;
-- treesitter is highlighting-only). A document is a list of requests separated by `###`; the
-- first request needs no separator. Each request has a request line (`METHOD url [HTTP/x.y]`),
-- ordered headers, an optional body (after one blank line), metadata directives (`# @…`),
-- request-local variables (`@var = value`), and `run` / `import` directives.
--
-- The parser is intentionally forgiving: an unknown line in the body is literal body text; an
-- unknown `# @directive` is preserved under `directives.extra` rather than dropped, so a later
-- feature (or an import round-trip) never silently loses information.
--
---@module "lvim-rest.parser"

local M = {}

-- A header line: `name: value`, where `name` is an RFC 7230 `token` — alphanumerics plus
-- `!#$%&'*+-.^_`|~`. The obvious `[%w%-]+` is too narrow: `X_Trace_Id` and `Api.Key` headers exist
-- in the wild, and a header the parser does not match is silently DROPPED (from the send, and from
-- the row when a bound buffer is written back), which is the worst way to be strict.
local HEADER_PATTERN = "^%s*([%w!#%$%%&'%*%+%-%.%^_`|~]+)%s*:%s*(.*)$"

--- Read one header line. Exposed because the options FORM has to recognise the same lines this
--- parser does (including the ones it commented out) — two definitions of "a header line" would
--- drift the moment either is touched.
---@param line string
---@return string? name, string? value
function M.match_header(line)
    local name, value = line:match(HEADER_PATTERN)
    if not name then
        return nil, nil
    end
    return name, vim.trim(value)
end

-- Standard HTTP verbs plus the three pseudo-methods every protocol is a first-class request under.
local METHODS = {
    GET = true,
    POST = true,
    PUT = true,
    PATCH = true,
    DELETE = true,
    HEAD = true,
    OPTIONS = true,
    TRACE = true,
    CONNECT = true,
    GRAPHQL = true,
    GRPC = true,
    WEBSOCKET = true,
}

---@class LvimRestPrompt
---@field var  string
---@field desc string?

---@class LvimRestStdinCmd
---@field var string
---@field cmd string

---@class LvimRestDirectives
---@field name          string?              `# @name` chain/replay id (also set from the `###` label)
---@field prompt        LvimRestPrompt[]     `# @prompt var [desc]` interactive inputs
---@field timeout       integer?             `# @timeout ms`
---@field auth          LvimRestAuth?        `# @auth <scheme> [args…]`
---@field grpc          { proto: string[], import: string[], authority: string?, insecure: boolean? }  `# @grpc-*`
---@field no_log        boolean?             `# @no-log`
---@field no_cookie_jar boolean?             `# @no-cookie-jar`
---@field accept        string?              `# @accept chunked` (stream mode)
---@field jq            string?              `# @jq expr` auto-filter
---@field curl          table<string, any>   `# @curl-<flag>[=value]` raw curl flags
---@field stdin_cmd     LvimRestStdinCmd[]   `# @stdin-cmd var shell…`
---@field env_stdin_cmd LvimRestStdinCmd[]   `# @env-stdin-cmd var shell…`
---@field extra         table<string, string> any other `# @x [value]` (preserved, not dropped)

---@class LvimRestAuth
---@field scheme string    none | basic | bearer | apikey | oauth2
---@field args   string[]  the scheme's arguments, still holding any `{{vars}}`

---@class LvimRestScript
---@field source string   inline Lua source (empty when `file` is set)
---@field file   string?  a path to a `.lua` script, resolved relative to the document
---@field line   integer  1-based line the block starts on (for error messages)

---@class LvimRestScripts
---@field pre  LvimRestScript[]  run BEFORE the request is resolved (may mutate it)
---@field post LvimRestScript[]  run AFTER the response arrives (assertions, captures)

---@class LvimRestHeader
---@field name  string
---@field value string
---@field line  integer? 1-based line this header was read from (the options form edits that line); absent on a header synthesised at run time (the cookie jar, a script)

---@class LvimRestVar
---@field name  string
---@field value string

---@class LvimRestRequest
---@field name           string?            display name (`###` label or `# @name`)
---@field method         string             HTTP verb or GRAPHQL/GRPC/WEBSOCKET
---@field url            string             raw URL (may contain `{{vars}}`)
---@field http_version   string?            e.g. "1.1", "2"
---@field headers        LvimRestHeader[]   ordered headers
---@field body           string?            raw body (nil when empty)
---@field body_line      integer?           1-based line where the body (or its `< file` include) begins
---@field body_file      string?            `< ./file` body-from-file path
---@field body_file_var  boolean            `<@ ./file` — substitute `{{vars}}` in the included file
---@field save_to        string?            `>>`/`>>!` response-redirect path
---@field save_overwrite boolean            `>>!` overwrites without prompting
---@field scripts        LvimRestScripts    `< {% … %}` / `> {% … %}` and `< ./x.lua` / `> ./x.lua`
---@field vars           LvimRestVar[]      request-local `@var = value`
---@field directives     LvimRestDirectives
---@field directive_lines table<string, integer[]>  directive key → the 1-based lines it was written on
---@field run            string[]           `run #name` / `run ./file`
---@field line           integer            1-based line of the request line (inline status + jump)
---@field sep_line       integer            1-based line of the `###` separator (or the request line)
---@field end_line       integer            1-based last line of the request block

---@class LvimRestDocument
---@field requests     LvimRestRequest[]
---@field vars         LvimRestVar[]   document-level variables (defined before the first request line)
---@field imports      string[]        `import ./common.http`
---@field has_requests boolean         whether any request line was parsed

--- A fresh empty request table.
---@return LvimRestRequest
local function new_request()
    return {
        method = "",
        url = "",
        headers = {},
        body_file_var = false,
        save_overwrite = false,
        vars = {},
        scripts = { pre = {}, post = {} },
        directives = {
            prompt = {},
            curl = {},
            stdin_cmd = {},
            env_stdin_cmd = {},
            grpc = { proto = {}, import = {} },
            extra = {},
        },
        directive_lines = {},
        run = {},
        line = 0,
        sep_line = 0,
        end_line = 0,
    }
end

--- Split whitespace-delimited args, treating a `{{ … }}` group as ONE token even when it contains
--- spaces — so `# @auth bearer {{vault "rest/x"}}` yields `{ "bearer", '{{vault "rest/x"}}' }`, not a
--- token split down the middle. Used for the auth directive, where a vaulted credential is a
--- space-carrying reference.
---@param s string
---@return string[]
local function split_args(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        while i <= n and s:sub(i, i):match("%s") do
            i = i + 1
        end
        if i > n then
            break
        end
        local start = i
        while i <= n and not s:sub(i, i):match("%s") do
            if s:sub(i, i + 1) == "{{" then
                local close = s:find("}}", i + 2, true)
                i = close and (close + 2) or (n + 1)
            else
                i = i + 1
            end
        end
        out[#out + 1] = s:sub(start, i - 1)
    end
    return out
end

--- Try to read a request line (`METHOD url [HTTP/x.y]`, or a bare URL implying GET).
---@param line string
---@return { method: string, url: string, http_version: string? }?
local function match_request_line(line)
    local trimmed = vim.trim(line)
    if trimmed == "" then
        return nil
    end
    local first = trimmed:match("^(%S+)")
    if first and METHODS[first:upper()] then
        local rest = vim.trim(trimmed:sub(#first + 1))
        local url, ver = rest:match("^(%S+)%s+([Hh][Tt][Tt][Pp]/[%d%.]+)$")
        if url then
            return { method = first:upper(), url = url, http_version = ver:sub(6) }
        end
        local only = rest:match("^(%S+)")
        if only then
            return { method = first:upper(), url = only }
        end
        return nil
    end
    -- A bare URL line (no method token) implies GET.
    if trimmed:match("://") or trimmed:match("^/") then
        local url = trimmed:match("^(%S+)")
        return { method = "GET", url = url }
    end
    return nil
end

--- Parse one `# @directive` payload (the text after the `#`/`//` and the `@`).
---
--- `lnum` is recorded per key in `req.directive_lines` — the options form edits a directive by
--- replacing / deleting THAT line, and only the parser knows which lines it read a directive from
--- (`#` or `//`, any spacing). A key can legitimately repeat (`@prompt`, `@curl-*`), so the record
--- is a LIST in document order.
---@param req LvimRestRequest
---@param payload string  e.g. "name login" or "timeout 5000" or "curl-insecure"
---@param lnum integer    the 1-based line the directive was written on
local function apply_directive(req, payload, lnum)
    local d = req.directives
    local key, rest = payload:match("^([%w_%-%.]+)%s*(.*)$")
    if not key then
        return
    end
    rest = vim.trim(rest or "")
    local lkey = key:lower()
    local lines = req.directive_lines[lkey] or {}
    lines[#lines + 1] = lnum
    req.directive_lines[lkey] = lines
    if lkey == "name" then
        req.name = rest ~= "" and rest or req.name
        d.name = req.name
    elseif lkey == "prompt" then
        local var, desc = rest:match("^(%S+)%s*(.*)$")
        if var then
            d.prompt[#d.prompt + 1] = { var = var, desc = desc ~= "" and desc or nil }
        end
    elseif lkey == "timeout" then
        d.timeout = tonumber(rest)
    elseif lkey == "auth" then
        -- The arguments keep their `{{vars}}` — they are resolved with the rest of the request, so
        -- `# @auth bearer {{token}}` reads the same variables everything else does. `split_args` keeps
        -- a `{{vault "rest/x"}}` reference (which carries a space) as ONE argument.
        local words = split_args(rest)
        local scheme = table.remove(words, 1)
        if scheme and scheme ~= "" then
            d.auth = { scheme = scheme:lower(), args = words }
        end
    elseif lkey == "grpc-proto" then
        -- Naming a `.proto` makes the call independent of whether the server exposes reflection.
        if rest ~= "" then
            d.grpc.proto[#d.grpc.proto + 1] = rest
        end
    elseif lkey == "grpc-import" then
        if rest ~= "" then
            d.grpc.import[#d.grpc.import + 1] = rest
        end
    elseif lkey == "grpc-authority" then
        -- TLS server-name override: reach a TLS gRPC server through a tunnel (connect to localhost,
        -- verify the server's real domain against the public roots).
        if rest ~= "" then
            d.grpc.authority = rest
        end
    elseif lkey == "grpc-insecure" then
        d.grpc.insecure = true
    elseif lkey == "no-log" then
        d.no_log = true
    elseif lkey == "no-cookie-jar" then
        d.no_cookie_jar = true
    elseif lkey == "accept" then
        d.accept = rest ~= "" and rest or "chunked"
    elseif lkey == "jq" then
        d.jq = rest
    elseif lkey == "stdin-cmd" then
        local var, cmd = rest:match("^(%S+)%s+(.*)$")
        if var and cmd then
            d.stdin_cmd[#d.stdin_cmd + 1] = { var = var, cmd = cmd }
        end
    elseif lkey == "env-stdin-cmd" then
        local var, cmd = rest:match("^(%S+)%s+(.*)$")
        if var and cmd then
            d.env_stdin_cmd[#d.env_stdin_cmd + 1] = { var = var, cmd = cmd }
        end
    elseif lkey:match("^curl%-") then
        -- `@curl-<flag>[=value]` — the escape hatch for raw curl flags. BOTH separators mean the same
        -- thing, and the `=` form arrives split: the key pattern stops at the `=`, so the value shows
        -- up at the head of `rest` (`@curl-max-redirs=5` → key "curl-max-redirs", rest "=5"). Without
        -- this the argv became `--max-redirs =5`, which curl rejects.
        local flag = lkey:sub(6)
        local value = rest:match("^=%s*(.*)$") or rest
        d.curl[flag] = value ~= "" and value or true
    else
        -- Unknown directive (e.g. @grpc-*, @postman-test): preserve, never drop.
        d.extra[lkey] = rest
    end
end

--- Parse a full `.http` / `.rest` document into requests + document variables.
---@param text string|string[]  the buffer text (a string or a list of lines)
---@return LvimRestDocument
function M.parse(text)
    ---@type string[]
    local lines
    if type(text) == "table" then
        lines = text
    else
        lines = vim.split(text, "\n", { plain = true })
    end
    ---@type LvimRestDocument
    local doc = { requests = {}, vars = {}, imports = {}, has_requests = false }

    local cur = new_request()
    cur.sep_line = 1
    local phase = "pre" ---@type "pre"|"headers"|"body"
    local body_lines = {} ---@type string[]
    local seen_method = false
    local doc_scope = true -- @var lines before the first request line are document-scoped

    -- An open `{% … %}` script block: everything up to `%}` is captured verbatim, whatever phase we
    -- are in — a script may contain `###`, `>` or a blank line and none of them may be reinterpreted.
    ---@type { kind: "pre"|"post", line: integer, lines: string[] }?
    local script_block

    --- Push the current request (if it has a method) and reset for the next block.
    ---@param end_line integer
    local function flush(end_line)
        if cur.method ~= "" then
            -- Trim trailing blank lines off the accumulated body.
            while #body_lines > 0 and vim.trim(body_lines[#body_lines]) == "" do
                body_lines[#body_lines] = nil
            end
            if #body_lines > 0 then
                cur.body = table.concat(body_lines, "\n")
            end
            cur.end_line = end_line
            doc.requests[#doc.requests + 1] = cur
        end
        cur = new_request()
        body_lines = {}
        phase = "pre"
    end

    --- Start an inline script block, or record a script FILE, from a `<`/`>` marker line.
    --- Returns true when the line was a script marker (so the caller stops interpreting it).
    ---@param kind "pre"|"post"
    ---@param rest string   whatever followed the marker on the same line
    ---@param lnum integer
    ---@return boolean handled
    local function script_marker(kind, rest, lnum)
        local open = rest:match("^{%%(.*)$")
        if open then
            script_block = { kind = kind, line = lnum, lines = {} }
            -- `< {% code %}` on one line closes immediately.
            local body, closed = open:match("^(.-)%%}"), open:find("%%}")
            if closed then
                script_block.lines[1] = body or ""
                cur.scripts[kind][#cur.scripts[kind] + 1] = { source = vim.trim(body or ""), line = lnum }
                script_block = nil
            elseif vim.trim(open) ~= "" then
                script_block.lines[1] = open
            end
            return true
        end
        -- A `.lua` FILE. `< ./body.json` in the body is the body-include and never reaches here:
        -- position disambiguates the two uses of `<`, exactly as the format intends.
        local path = vim.trim(rest)
        if path ~= "" and path:lower():match("%.lua$") then
            cur.scripts[kind][#cur.scripts[kind] + 1] = { source = "", file = path, line = lnum }
            return true
        end
        return false
    end

    for i, raw in ipairs(lines) do
        local line = raw
        local trimmed = vim.trim(line)

        if script_block then
            -- Inside `{% … %}`: capture verbatim until the closing marker.
            local before = line:match("^(.-)%%}")
            if before then
                script_block.lines[#script_block.lines + 1] = before
                local src = vim.trim(table.concat(script_block.lines, "\n"))
                local list = cur.scripts[script_block.kind]
                list[#list + 1] = { source = src, line = script_block.line }
                script_block = nil
            else
                script_block.lines[#script_block.lines + 1] = line
            end
        elseif trimmed:match("^###") then
            -- Separator: flush the previous request, start a new block whose label is the trailing text.
            flush(i - 1)
            local label = vim.trim(trimmed:gsub("^#+%s*", ""))
            cur.sep_line = i
            if label ~= "" then
                cur.name = label
                cur.directives.name = cur.directives.name or label
            end
        elseif phase == "body" then
            -- In the body, lines are literal — except the response-redirect and file-include markers.
            local rd, path = trimmed:match("^(>>!?)%s+(.+)$")
            local post_marker = (not rd) and trimmed:match("^>%s*(.*)$") or nil
            if rd then
                cur.save_to = path
                cur.save_overwrite = rd == ">>!"
            elseif post_marker and script_marker("post", post_marker, i) then
                -- a `> {% … %}` block or a `> ./x.lua` post-response script
            elseif #body_lines == 0 and trimmed:match("^<@?%s") then
                local var, fpath = trimmed:match("^(<@?)%s+(.+)$")
                cur.body_file = fpath
                cur.body_file_var = var == "<@"
                cur.body_line = cur.body_line or i
            else
                -- The first content line anchors the body (json decode diagnostics et al.); the parser
                -- already records source lines for directives/headers, so the body gets one too.
                cur.body_line = cur.body_line or i
                body_lines[#body_lines + 1] = line
            end
        else
            -- pre / headers phase.
            local var_name, var_val = trimmed:match("^@([%w_%-%.]+)%s*=%s*(.*)$")
            local directive = trimmed:match("^#+%s*@(.+)$") or trimmed:match("^//%s*@(.+)$")
            local run_dir = trimmed:match("^run%s+(.+)$")
            local import_dir = trimmed:match("^import%s+(.+)$")

            local pre_marker = trimmed:match("^<%s*(.*)$")
            local post_marker = trimmed:match("^>%s*(.*)$")

            if pre_marker and script_marker("pre", pre_marker, i) then
                -- a `< {% … %}` block or a `< ./x.lua` pre-request script
            elseif post_marker and script_marker("post", post_marker, i) then
                -- a post-response script written before the request line (accepted, not required)
            elseif var_name then
                local entry = { name = var_name, value = var_val }
                if doc_scope then
                    doc.vars[#doc.vars + 1] = entry
                else
                    cur.vars[#cur.vars + 1] = entry
                end
            elseif directive then
                apply_directive(cur, directive, i)
            elseif run_dir then
                cur.run[#cur.run + 1] = run_dir
            elseif import_dir then
                doc.imports[#doc.imports + 1] = import_dir
            elseif trimmed:match("^#") or trimmed:match("^//") then
                -- Plain comment: ignore.
            elseif phase == "pre" then
                local rl = match_request_line(line)
                if rl then
                    cur.method = rl.method
                    cur.url = rl.url
                    cur.http_version = rl.http_version
                    cur.line = i
                    seen_method = true
                    doc_scope = false
                    phase = "headers"
                end
                -- A non-request, non-directive line in `pre` is ignored (blank lines, stray text).
            elseif phase == "headers" then
                if trimmed == "" then
                    phase = "body"
                else
                    local hname, hval = M.match_header(line)
                    if hname then
                        cur.headers[#cur.headers + 1] = { name = hname, value = hval or "", line = i }
                    end
                    -- Non-matching lines in the header block are ignored (tolerant).
                end
            end
        end
        cur.end_line = i
    end
    flush(#lines)
    -- `seen_method` is informational (a document with no request at all still parses to an empty list).
    doc.has_requests = seen_method
    return doc
end

--- The request whose block contains 1-based line `lnum` (for send-under-cursor). Falls back to the
--- nearest preceding request, then the first.
---@param doc LvimRestDocument
---@param lnum integer
---@return LvimRestRequest?
function M.request_at(doc, lnum)
    local best
    for _, r in ipairs(doc.requests) do
        if lnum >= r.sep_line and lnum <= r.end_line then
            return r
        end
        if r.line <= lnum then
            best = r
        end
    end
    return best or doc.requests[1]
end

--- Look up a request by its `@name` / `###` label.
---@param doc LvimRestDocument
---@param name string
---@return LvimRestRequest?
function M.request_by_name(doc, name)
    for _, r in ipairs(doc.requests) do
        if r.name == name or (r.directives and r.directives.name == name) then
            return r
        end
    end
    return nil
end

return M
