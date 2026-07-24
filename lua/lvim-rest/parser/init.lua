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
---@field no_log        boolean?             `# @no-log`
---@field no_cookie_jar boolean?             `# @no-cookie-jar`
---@field accept        string?              `# @accept chunked` (stream mode)
---@field jq            string?              `# @jq expr` auto-filter
---@field curl          table<string, any>   `# @curl-<flag>[=value]` raw curl flags
---@field stdin_cmd     LvimRestStdinCmd[]   `# @stdin-cmd var shell…`
---@field env_stdin_cmd LvimRestStdinCmd[]   `# @env-stdin-cmd var shell…`
---@field extra         table<string, string> any other `# @x [value]` (preserved, not dropped)

---@class LvimRestHeader
---@field name  string
---@field value string

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
---@field body_file      string?            `< ./file` body-from-file path
---@field body_file_var  boolean            `<@ ./file` — substitute `{{vars}}` in the included file
---@field save_to        string?            `>>`/`>>!` response-redirect path
---@field save_overwrite boolean            `>>!` overwrites without prompting
---@field vars           LvimRestVar[]      request-local `@var = value`
---@field directives     LvimRestDirectives
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
        directives = { prompt = {}, curl = {}, stdin_cmd = {}, env_stdin_cmd = {}, extra = {} },
        run = {},
        line = 0,
        sep_line = 0,
        end_line = 0,
    }
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
---@param req LvimRestRequest
---@param payload string  e.g. "name login" or "timeout 5000" or "curl-insecure"
local function apply_directive(req, payload)
    local d = req.directives
    local key, rest = payload:match("^([%w_%-%.]+)%s*(.*)$")
    if not key then
        return
    end
    rest = vim.trim(rest or "")
    local lkey = key:lower()
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
        -- `@curl-<flag>[=value]` — the escape hatch for raw curl flags.
        local flag = lkey:sub(6)
        local fname, fval = flag:match("^([^=]+)=(.*)$")
        if fname then
            d.curl[fname] = fval
        else
            d.curl[flag] = rest ~= "" and rest or true
        end
    else
        -- Unknown directive (e.g. @grpc-*, @postman-test): preserve, never drop.
        d.extra[lkey] = rest
    end
end

--- Parse a full `.http` / `.rest` document into requests + document variables.
---@param text string|string[]  the buffer text (a string or a list of lines)
---@return LvimRestDocument
function M.parse(text)
    local lines = type(text) == "table" and text or vim.split(text, "\n", { plain = true })
    ---@type LvimRestDocument
    local doc = { requests = {}, vars = {}, imports = {}, has_requests = false }

    local cur = new_request()
    cur.sep_line = 1
    local phase = "pre" ---@type "pre"|"headers"|"body"
    local body_lines = {} ---@type string[]
    local seen_method = false
    local doc_scope = true -- @var lines before the first request line are document-scoped

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

    for i, raw in ipairs(lines) do
        local line = raw
        local trimmed = vim.trim(line)

        if trimmed:match("^###") then
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
            if rd then
                cur.save_to = path
                cur.save_overwrite = rd == ">>!"
            elseif #body_lines == 0 and trimmed:match("^<@?%s") then
                local var, fpath = trimmed:match("^(<@?)%s+(.+)$")
                cur.body_file = fpath
                cur.body_file_var = var == "<@"
            else
                body_lines[#body_lines + 1] = line
            end
        else
            -- pre / headers phase.
            local var_name, var_val = trimmed:match("^@([%w_%-%.]+)%s*=%s*(.*)$")
            local directive = trimmed:match("^#+%s*@(.+)$") or trimmed:match("^//%s*@(.+)$")
            local run_dir = trimmed:match("^run%s+(.+)$")
            local import_dir = trimmed:match("^import%s+(.+)$")

            if var_name then
                local entry = { name = var_name, value = var_val }
                if doc_scope then
                    doc.vars[#doc.vars + 1] = entry
                else
                    cur.vars[#cur.vars + 1] = entry
                end
            elseif directive then
                apply_directive(cur, directive)
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
                    local hname, hval = line:match("^%s*([%w%-]+)%s*:%s*(.*)$")
                    if hname then
                        cur.headers[#cur.headers + 1] = { name = hname, value = vim.trim(hval) }
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
