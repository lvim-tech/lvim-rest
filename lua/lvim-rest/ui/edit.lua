-- lvim-rest.ui.edit: the ONLY code that turns an options-form change into `.http` BUFFER TEXT.
--
-- THE RULE of the interactive panels: the document is the single source of truth. A form is a VIEW
-- over the parsed request that writes back into the buffer; it is never a second store. So every
-- read here goes through `parser.parse` and every write edits buffer LINES — the next read re-parses
-- and sees exactly what a send would see. For a LIBRARY request the same holds through the bind
-- buffer: the form edits its text, and `:w` (BufWriteCmd → `store.bind.write_back`) persists it.
-- Nothing in this module ever calls the library.
--
-- TWO PROPERTIES EARN THEIR COMPLEXITY:
--
--   * ANCHORED. The request line carries an extmark, so an edit that adds or removes lines ABOVE it
--     (a directive) does not stale the anchor: the next read re-parses and re-locates the request at
--     the mark's current row. Line numbers captured in a form row are only ever used within the one
--     write that follows them.
--   * GRANULAR. Each facet edits ITS OWN line — the header line, the directive line, the request
--     line. Regenerating the whole block would normalise the blank lines, comments and unknown
--     directives the parser deliberately tolerates; here a line nothing touched is byte-identical
--     afterwards, forever.
--
---@module "lvim-rest.ui.edit"

local api = vim.api
local parser = require("lvim-rest.parser")

local M = {}

local ns = api.nvim_create_namespace("LvimRestEdit")

---@class LvimRestEditor
---@field buf  integer  the `.http` buffer being edited
---@field mark integer  extmark id on the request line
local Editor = {}
Editor.__index = Editor

-- ── reading ─────────────────────────────────────────────────────────────────

--- The buffer's lines.
---@return string[]
function Editor:lines()
    return api.nvim_buf_get_lines(self.buf, 0, -1, false)
end

--- The 1-based row the anchor currently sits on.
---@return integer
function Editor:anchor()
    local pos = api.nvim_buf_get_extmark_by_id(self.buf, ns, self.mark, {})
    return (pos[1] or 0) + 1
end

--- Re-parse the buffer and return the document plus THIS request (re-located at the anchor).
---@return LvimRestDocument doc, LvimRestRequest? req
function Editor:read()
    local doc = parser.parse(self:lines())
    return doc, parser.request_at(doc, self:anchor())
end

--- Re-parse and return just the request.
---@return LvimRestRequest?
function Editor:request()
    local _, req = self:read()
    return req
end

--- Whether the editor still has a live buffer.
---@return boolean
function Editor:valid()
    return api.nvim_buf_is_valid(self.buf)
end

-- ── primitive writes (1-based lines) ────────────────────────────────────────

--- Replace one line's TEXT.
---
--- `nvim_buf_set_text`, not `set_lines`: rewriting a line's content is a text edit, while set_lines
--- is a delete + insert of a whole line — which drags any extmark on it to the start of the NEXT
--- line (right gravity). The anchor sits on the request line, and the request line is exactly what
--- the url/method edits rewrite, so set_lines would push the anchor down once per edit.
---@param lnum integer
---@param text string
function Editor:replace(lnum, text)
    local old = api.nvim_buf_get_lines(self.buf, lnum - 1, lnum, false)[1]
    if old == nil then
        return
    end
    api.nvim_buf_set_text(self.buf, lnum - 1, 0, lnum - 1, #old, { text })
end

--- Delete one line.
---@param lnum integer
function Editor:delete(lnum)
    api.nvim_buf_set_lines(self.buf, lnum - 1, lnum, false, {})
end

--- Insert `text` AFTER line `lnum` (0 = at the top of the buffer).
---@param lnum integer
---@param text string
function Editor:insert_after(lnum, text)
    api.nvim_buf_set_lines(self.buf, lnum, lnum, false, { text })
end

-- ── the request line ────────────────────────────────────────────────────────

--- Rewrite the request line from `method` / `url`, keeping the document's HTTP-version suffix.
---@param method string
---@param url string
---@return boolean ok
function Editor:set_request_line(method, url)
    local req = self:request()
    if not req then
        return false
    end
    local suffix = req.http_version and (" HTTP/" .. req.http_version) or ""
    self:replace(req.line, ("%s %s%s"):format(method:upper(), url, suffix))
    return true
end

-- ── the query string ────────────────────────────────────────────────────────

--- Split a url into its base and its query PAIRS, in order.
---
--- The values are kept EXACTLY as written — no uri-decoding round-trip. A `{{var}}` or an already
--- encoded `%20` is text the user typed, and decoding it on read only to re-encode it on write is
--- how a form silently rewrites a url nobody asked it to touch.
---@param url string
---@return string base, { name: string, value: string }[] params
function M.split_query(url)
    local base, query = url:match("^([^?]*)%?(.*)$")
    if not base then
        return url, {}
    end
    local params = {}
    for pair in query:gmatch("[^&]+") do
        local name, value = pair:match("^([^=]*)=(.*)$")
        params[#params + 1] = { name = name or pair, value = value or "" }
    end
    return base, params
end

--- Reassemble a url from its base and query pairs.
---@param base string
---@param params { name: string, value: string }[]
---@return string
function M.join_query(base, params)
    if #params == 0 then
        return base
    end
    local parts = {}
    for _, p in ipairs(params) do
        parts[#parts + 1] = ("%s=%s"):format(p.name, p.value)
    end
    return base .. "?" .. table.concat(parts, "&")
end

--- Write a new query-parameter list onto the request line.
---@param params { name: string, value: string }[]
---@return boolean ok
function Editor:set_params(params)
    local req = self:request()
    if not req then
        return false
    end
    local base = (M.split_query(req.url))
    return self:set_request_line(req.method, M.join_query(base, params))
end

-- ── headers ─────────────────────────────────────────────────────────────────

--- Every header LINE of the request, including the ones commented out.
---
--- The form shows a `# X-Trace: 1` line as a DISABLED row rather than hiding it: commenting a header
--- out is how the document expresses "off", and a row you can toggle back is the whole point. The
--- block runs from the request line to the blank line that starts the body.
---@return { lnum: integer, name: string, value: string, enabled: boolean }[]
function Editor:headers()
    local doc, req = self:read()
    local _ = doc
    if not req then
        return {}
    end
    local lines = self:lines()
    local out = {}
    for lnum = req.line + 1, math.min(req.end_line, #lines) do
        local text = lines[lnum]
        if vim.trim(text) == "" then
            break -- the blank line starts the body: the header block is over
        end
        local name, value = parser.match_header(text)
        if name then
            out[#out + 1] = { lnum = lnum, name = name, value = value or "", enabled = true }
        else
            -- A commented-out header: `# Name: value` (whatever spacing the user left).
            local bare = text:match("^%s*#+%s*(.*)$") or text:match("^%s*//%s*(.*)$")
            local cname, cvalue
            if bare and not bare:match("^@") then -- `# @directive` is not a commented header
                cname, cvalue = parser.match_header(bare)
            end
            if cname then
                out[#out + 1] = { lnum = lnum, name = cname, value = cvalue or "", enabled = false }
            end
        end
    end
    return out
end

--- The line a new header should be inserted after: the last header line, else the request line.
---@return integer?
function Editor:last_header_line()
    local req = self:request()
    if not req then
        return nil
    end
    local last = req.line
    for _, h in ipairs(self:headers()) do
        last = math.max(last, h.lnum)
    end
    return last
end

--- Rewrite one header line, keeping its enabled/disabled form.
---@param lnum integer
---@param name string
---@param value string
---@param enabled boolean
function Editor:set_header(lnum, name, value, enabled)
    self:replace(lnum, ("%s%s: %s"):format(enabled and "" or "# ", name, value))
end

--- Append a header after the last one.
---@param name string
---@param value string
---@return boolean ok
function Editor:add_header(name, value)
    local after = self:last_header_line()
    if not after then
        return false
    end
    self:insert_after(after, ("%s: %s"):format(name, value))
    return true
end

--- Toggle a header line between active and commented out. The TEXT is preserved either way — that
--- is what makes this different from deleting it.
---@param lnum integer
---@return boolean ok
function Editor:toggle_header(lnum)
    for _, h in ipairs(self:headers()) do
        if h.lnum == lnum then
            self:set_header(lnum, h.name, h.value, not h.enabled)
            return true
        end
    end
    return false
end

-- ── directives ──────────────────────────────────────────────────────────────

--- Render a `# @key value` line (a bare `# @key` when there is no payload).
---@param key string
---@param value string?
---@return string
local function directive_line(key, value)
    if value == nil or value == "" then
        return "# @" .. key
    end
    return ("# @%s %s"):format(key, value)
end

--- The lines a directive key occupies, in document order.
---@param key string
---@return integer[]
function Editor:directive_lines(key)
    local req = self:request()
    return (req and req.directive_lines[key:lower()]) or {}
end

--- The line a NEW directive should be inserted after: the last directive line of the request, else
--- the separator (so directives stay in the block above the request line, where they are read).
---@return integer?
function Editor:last_directive_line()
    local req = self:request()
    if not req then
        return nil
    end
    local last = req.sep_line
    for _, lines in pairs(req.directive_lines) do
        for _, l in ipairs(lines) do
            if l < req.line then
                last = math.max(last, l)
            end
        end
    end
    return last
end

--- Set a SINGLE-valued directive: replace its first line, insert one when absent, or delete every
--- line of it when `value` is nil/false.
---@param key string
---@param value string|boolean|nil
---@return boolean ok
function Editor:set_directive(key, value)
    local lines = self:directive_lines(key)
    if value == nil or value == false or value == "" then
        -- Delete from the bottom up so the earlier line numbers stay valid.
        table.sort(lines, function(a, b)
            return a > b
        end)
        for _, l in ipairs(lines) do
            self:delete(l)
        end
        return #lines > 0
    end
    local text = directive_line(key, value ~= true and tostring(value) or nil)
    if lines[1] then
        self:replace(lines[1], text)
        return true
    end
    local after = self:last_directive_line()
    if not after then
        return false
    end
    self:insert_after(after, text)
    return true
end

--- Append one more line of a REPEATABLE directive (`@prompt`, `@curl-*`, `@grpc-proto`, …).
---@param key string
---@param value string?
---@return boolean ok
function Editor:add_directive(key, value)
    local after = self:last_directive_line()
    if not after then
        return false
    end
    self:insert_after(after, directive_line(key, value))
    return true
end

--- Rewrite one directive line in place (a repeatable directive's Nth entry).
---@param lnum integer
---@param key string
---@param value string?
function Editor:set_directive_line(lnum, key, value)
    self:replace(lnum, directive_line(key, value))
end

-- ── the body ──────────────────────────────────────────────────────────────────

--- Replace the request's BODY (the region after the blank line that separates it from the headers)
--- with `content` — granular, touching only those lines so the request line, headers, directives and
--- the separator to the next request stay put. `content` may be multi-line; "" clears the body. When
--- the request has no body yet, a blank separator (if absent) and the body are inserted after the
--- headers. The anchor sits on the request line above, so it is never disturbed.
---@param content string
---@return boolean ok
function Editor:set_body(content)
    local req = self:request()
    if not req then
        return false
    end
    local new_lines = (content == "") and {} or vim.split(content, "\n", { plain = true })
    if req.body_line then
        api.nvim_buf_set_lines(self.buf, req.body_line - 1, req.end_line, false, new_lines)
        return true
    end
    if #new_lines == 0 then
        return true -- no body and nothing to add
    end
    local after = self:last_header_line() or req.line -- 1-based
    local following = api.nvim_buf_get_lines(self.buf, after, after + 1, false)[1]
    if following ~= nil and vim.trim(following) == "" then
        -- A separator blank already follows the headers: put the body right after it.
        api.nvim_buf_set_lines(self.buf, after + 1, after + 1, false, new_lines)
    else
        -- No separator: insert one, then the body.
        local block = { "" }
        for _, l in ipairs(new_lines) do
            block[#block + 1] = l
        end
        api.nvim_buf_set_lines(self.buf, after, after, false, block)
    end
    return true
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

--- Drop the anchor.
function Editor:detach()
    pcall(api.nvim_buf_del_extmark, self.buf, ns, self.mark)
end

--- Anchor an editor on the request containing `lnum` in `bufnr`.
---@param bufnr integer
---@param lnum integer
---@return LvimRestEditor?
function M.attach(bufnr, lnum)
    if not api.nvim_buf_is_valid(bufnr) then
        return nil
    end
    local doc = parser.parse(api.nvim_buf_get_lines(bufnr, 0, -1, false))
    local req = parser.request_at(doc, lnum)
    if not req or req.method == "" then
        return nil
    end
    local mark = api.nvim_buf_set_extmark(bufnr, ns, req.line - 1, 0, {})
    return setmetatable({ buf = bufnr, mark = mark }, Editor)
end

return M
