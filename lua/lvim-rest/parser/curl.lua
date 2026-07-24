-- lvim-rest.parser.curl: curl command ↔ request, both directions.
--
--   • to_curl(resolved)  — a shareable `curl …` command from a resolved request (copy-as-curl).
--     Secrets (Authorization / Cookie) are masked when `scrub_secrets` is on, and the command is a
--     LIST joined with shell-escaping — never a hand-spliced shell string.
--   • from_curl(text)    — parse a pasted `curl …` invocation into an `.http` request snippet
--     (import-from-curl). A shell-like tokenizer respects quotes + backslash-newline continuations;
--     `-X`, `-H`, `-d`/`--data*`, `-u`, `-k`, `--url` and the positional URL are understood.
--
---@module "lvim-rest.parser.curl"

local config = require("lvim-rest.config")

local M = {}

--- Whether a header carries a secret that copy-as-curl should mask.
---@param name string
---@return boolean
local function is_secret(name)
    local n = name:lower()
    return n == "authorization" or n == "cookie"
end

--- Build a shareable curl command string from a resolved request.
---@param resolved LvimRestResolvedRequest
---@return string
function M.to_curl(resolved)
    local method = resolved.method == "GRAPHQL" and "POST" or resolved.method
    local parts = { "curl", "-X", method }
    if config.request.follow_redirects then
        parts[#parts + 1] = "-L"
    end
    for _, h in ipairs(resolved.headers or {}) do
        local value = h.value
        if config.scrub_secrets and is_secret(h.name) then
            value = "***"
        end
        parts[#parts + 1] = "-H"
        parts[#parts + 1] = vim.fn.shellescape(h.name .. ": " .. value)
    end
    if resolved.body and resolved.body ~= "" then
        parts[#parts + 1] = "--data-binary"
        parts[#parts + 1] = vim.fn.shellescape(resolved.body)
    end
    parts[#parts + 1] = vim.fn.shellescape(resolved.url)
    return table.concat(parts, " ")
end

--- Tokenize a shell-ish command line, respecting single/double quotes and backslash-newline
--- continuations. Not a full shell parser — enough for a pasted curl command.
---@param text string
---@return string[]
local function tokenize(text)
    -- Join backslash-newline continuations first.
    text = text:gsub("\\\n", " ")
    local tokens = {}
    local i, n = 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c == "'" then
            local j = text:find("'", i + 1, true) or n + 1
            tokens[#tokens + 1] = text:sub(i + 1, j - 1)
            i = j + 1
        elseif c == '"' then
            -- Double quotes: honour backslash escapes minimally.
            local buf, j = {}, i + 1
            while j <= n and text:sub(j, j) ~= '"' do
                local cj = text:sub(j, j)
                if cj == "\\" and j < n then
                    buf[#buf + 1] = text:sub(j + 1, j + 1)
                    j = j + 2
                else
                    buf[#buf + 1] = cj
                    j = j + 1
                end
            end
            tokens[#tokens + 1] = table.concat(buf)
            i = j + 1
        else
            local j = i
            while j <= n and not text:sub(j, j):match("[%s'\"]") do
                j = j + 1
            end
            tokens[#tokens + 1] = text:sub(i, j - 1)
            i = j
        end
    end
    return tokens
end

--- Parse a curl command into a request table.
---@param text string
---@return { method: string, url: string, headers: LvimRestHeader[], body: string? }?
function M.parse_curl(text)
    text = vim.trim(text):gsub("^%s*curl%s+", "")
    if text == "" then
        return nil
    end
    local tokens = tokenize("curl " .. text)
    local req = { method = nil, url = nil, headers = {}, body = nil }
    local i = 2 -- skip "curl"
    local function nextval()
        i = i + 1
        return tokens[i]
    end
    while i <= #tokens do
        local t = tokens[i]
        if t == "-X" or t == "--request" then
            req.method = (nextval() or "GET"):upper()
        elseif t == "-H" or t == "--header" then
            local h = nextval() or ""
            local name, value = h:match("^([^:]+):%s*(.*)$")
            if name then
                req.headers[#req.headers + 1] = { name = vim.trim(name), value = vim.trim(value) }
            end
        elseif t == "-d" or t == "--data" or t == "--data-raw" or t == "--data-binary" or t == "--data-ascii" then
            req.body = nextval() or ""
        elseif t == "-u" or t == "--user" then
            local cred = nextval() or ""
            req.headers[#req.headers + 1] = { name = "Authorization", value = "Basic " .. vim.base64.encode(cred) }
        elseif t == "--url" then
            req.url = nextval()
        elseif t == "-k" or t == "--insecure" or t == "-L" or t == "--location" or t == "--compressed" then
            -- flags with no argument, ignored for the request text (behavioural, not content)
        elseif t:match("^%-") then
            -- Unknown flag: if it clearly takes a value (long option), skip its value heuristically.
            if
                t:match("^%-%-")
                and tokens[i + 1]
                and not tokens[i + 1]:match("^%-")
                and not tokens[i + 1]:match("://")
            then
                i = i + 1
            end
        elseif t:match("://") or not req.url then
            req.url = t
        end
        i = i + 1
    end
    if not req.url then
        return nil
    end
    req.method = req.method or (req.body and "POST" or "GET")
    return req
end

--- Render a parsed curl request as an `.http` snippet (for import-from-curl at the cursor).
---@param text string  the curl command
---@return string[]?  the .http lines
function M.to_http(text)
    local req = M.parse_curl(text)
    if not req then
        return nil
    end
    local lines = { ("%s %s"):format(req.method, req.url) }
    for _, h in ipairs(req.headers) do
        lines[#lines + 1] = ("%s: %s"):format(h.name, h.value)
    end
    if req.body and req.body ~= "" then
        lines[#lines + 1] = ""
        for _, l in ipairs(vim.split(req.body, "\n", { plain = true })) do
            lines[#lines + 1] = l
        end
    end
    return lines
end

return M
