-- lvim-rest.ui.views: the response view renderers (body / headers / both / stats / verbose / …).
--
-- Each renderer turns a response result into `{ lines, hls, filetype }`: `lines` is the text,
-- `hls` a list of `{ row, col_start, col_end, group }` byte-column spans the dock paints as
-- extmarks, and `filetype` the REAL buffer filetype (from Content-Type) so the body view gets
-- treesitter highlighting for free. The `body` view leans on treesitter; the header/stats/verbose
-- views paint their own aligned columns.
--
---@module "lvim-rest.ui.views"

local config = require("lvim-rest.config")
local format = require("lvim-rest.format")

local M = {}

--- Case-insensitive header lookup.
---@param headers LvimRestHeader[]?
---@param name string
---@return string?
local function header_value(headers, name)
    for _, h in ipairs(headers or {}) do
        if h.name:lower() == name:lower() then
            return h.value
        end
    end
    return nil
end

--- The status-accent highlight group for a code.
---@param status integer
---@return string
local function status_group(status)
    if status >= 200 and status < 300 then
        return "LvimRestStatus2xx"
    elseif status >= 300 and status < 400 then
        return "LvimRestStatus3xx"
    elseif status >= 400 and status < 500 then
        return "LvimRestStatus4xx"
    end
    return "LvimRestStatus5xx"
end

--- Render the status line row + its highlight.
---@param result table
---@param row integer
---@return string line, table hl
local function status_line(result, row)
    local line = ("HTTP %s %d %s"):format(result.http_version or "", result.status or 0, result.status_text or "")
    return line, { row = row, col_start = 0, col_end = #line, group = status_group(result.status or 0) }
end

--- Body view: the pretty-printed body, filetype from Content-Type.
---@param result table
---@return { lines: string[], hls: table[], filetype: string }
function M.body(result)
    local ct = header_value(result.headers, "content-type")
    local text = format.pretty(result.body or "", ct)
    return {
        lines = vim.split(text, "\n", { plain = true }),
        hls = {},
        filetype = format.content_filetype(ct),
    }
end

--- Headers view: the status line + every response header, name-dim / value-normal.
---@param result table
---@return { lines: string[], hls: table[], filetype: string }
function M.headers(result)
    local lines, hls = {}, {}
    local sline, shl = status_line(result, 0)
    lines[1] = sline
    hls[#hls + 1] = shl
    for _, h in ipairs(result.headers or {}) do
        local row = #lines
        local line = h.name .. ": " .. h.value
        lines[#lines + 1] = line
        hls[#hls + 1] = { row = row, col_start = 0, col_end = #h.name, group = "LvimRestHeaderName" }
        hls[#hls + 1] = { row = row, col_start = #h.name + 2, col_end = #line, group = "LvimRestHeaderValue" }
    end
    return { lines = lines, hls = hls, filetype = "text" }
end

--- Both view: headers block, a blank line, then the pretty body.
---@param result table
---@return { lines: string[], hls: table[], filetype: string }
function M.both(result)
    local h = M.headers(result)
    local b = M.body(result)
    local lines = vim.deepcopy(h.lines)
    local hls = vim.deepcopy(h.hls)
    lines[#lines + 1] = ""
    local offset = #lines
    for _, l in ipairs(b.lines) do
        lines[#lines + 1] = l
    end
    -- Body highlights (currently none) would be shifted by `offset` here.
    for _, hl in ipairs(b.hls) do
        hl.row = hl.row + offset
        hls[#hls + 1] = hl
    end
    return { lines = lines, hls = hls, filetype = "text" }
end

--- Aligned key/value stats rows.
---@param result table
---@return { lines: string[], hls: table[], filetype: string }
function M.stats(result)
    local t = result.timing or {}
    local s = result.size or {}
    local rows = {
        { "Status", ("%d %s"):format(result.status or 0, result.status_text or "") },
        { "HTTP version", result.http_version or "?" },
        { "Total time", (t.total or 0) .. " ms" },
        { "DNS lookup", (t.dns or 0) .. " ms" },
        { "TCP connect", (t.connect or 0) .. " ms" },
        { "TLS handshake", (t.tls or 0) .. " ms" },
        { "Time to first byte", (t.ttfb or 0) .. " ms" },
        { "Downloaded", (s.down or 0) .. " bytes" },
        { "Uploaded", (s.up or 0) .. " bytes" },
        { "Engine", result.engine or "?" },
    }
    local width = 0
    for _, r in ipairs(rows) do
        width = math.max(width, #r[1])
    end
    local lines, hls = {}, {}
    for i, r in ipairs(rows) do
        local label = r[1] .. string.rep(" ", width - #r[1])
        local line = ("%s   %s"):format(label, r[2])
        lines[i] = line
        hls[#hls + 1] = { row = i - 1, col_start = 0, col_end = #r[1], group = "LvimRestStatsKey" }
        hls[#hls + 1] = { row = i - 1, col_start = width + 3, col_end = #line, group = "LvimRestStatsVal" }
    end
    return { lines = lines, hls = hls, filetype = "text" }
end

--- Verbose view: the full request/response transcript.
---@param result table
---@return { lines: string[], hls: table[], filetype: string }
function M.verbose(result)
    local lines, hls = {}, {}
    local ptr = config.icons.pointer
    local req = result.request or {}
    lines[#lines + 1] = ("%s %s %s"):format(ptr, req.method or result.method or "", req.url or result.url or "")
    hls[#hls + 1] = { row = 0, col_start = 0, col_end = #lines[1], group = "LvimRestVerboseReq" }
    for _, h in ipairs(req.headers or {}) do
        lines[#lines + 1] = "> " .. h.name .. ": " .. h.value
        hls[#hls + 1] = { row = #lines - 1, col_start = 0, col_end = #lines[#lines], group = "LvimRestVerboseReq" }
    end
    if req.body and req.body ~= "" then
        lines[#lines + 1] = ""
        for _, l in ipairs(vim.split(req.body, "\n", { plain = true })) do
            lines[#lines + 1] = "> " .. l
        end
    end
    lines[#lines + 1] = ""
    local sline, shl = status_line(result, #lines)
    lines[#lines + 1] = sline
    hls[#hls + 1] = shl
    for _, h in ipairs(result.headers or {}) do
        lines[#lines + 1] = "< " .. h.name .. ": " .. h.value
        hls[#hls + 1] = { row = #lines - 1, col_start = 0, col_end = #lines[#lines], group = "LvimRestVerboseResp" }
    end
    lines[#lines + 1] = ""
    local ct = header_value(result.headers, "content-type")
    for _, l in ipairs(vim.split(format.pretty(result.body or "", ct), "\n", { plain = true })) do
        lines[#lines + 1] = l
    end
    return { lines = lines, hls = hls, filetype = "text" }
end

--- Script-output view (populated in the scripting phase; a placeholder until then).
---@param result table
---@return { lines: string[], hls: table[], filetype: string }
function M.script(result)
    local out = result.script_output
    if not out or out == "" then
        return { lines = { "No script output." }, hls = {}, filetype = "text" }
    end
    return { lines = vim.split(out, "\n", { plain = true }), hls = {}, filetype = "text" }
end

--- Assertions report view (populated in the scripting phase; a placeholder until then).
---@param result table
---@return { lines: string[], hls: table[], filetype: string }
function M.report(result)
    local tests = result.tests
    if not tests or #tests == 0 then
        return { lines = { "No assertions." }, hls = {}, filetype = "text" }
    end
    local lines, hls = {}, {}
    for i, t in ipairs(tests) do
        local mark = t.passed and config.icons.ok or config.icons.fail
        lines[i] = ("%s %s"):format(mark, t.name)
        hls[#hls + 1] =
            { row = i - 1, col_start = 0, col_end = #lines[i], group = t.passed and "LvimRestPass" or "LvimRestFail" }
    end
    return { lines = lines, hls = hls, filetype = "text" }
end

--- Render `view` for a result.
---@param result table
---@param view string
---@return { lines: string[], hls: table[], filetype: string }
function M.render(result, view)
    local fn = M[view]
    if type(fn) ~= "function" then
        fn = M.body
    end
    return fn(result)
end

return M
