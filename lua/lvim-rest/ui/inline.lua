-- lvim-rest.ui.inline: the per-request status lane (kulala's icon lane, our canon glyphs).
--
-- An end-of-line extmark on the request line: a braille spinner (method-accent) while the request
-- runs, then `➤ 200 OK · 132 ms` in the status accent when it finishes (or a red error chip). One
-- animation timer per running request; both are cleared on cancel / re-send.
--
---@module "lvim-rest.ui.inline"

local config = require("lvim-rest.config")

local M = {}

local NS = vim.api.nvim_create_namespace("lvim_rest_inline")

---@type table<string, { id: integer, timer: uv.uv_timer_t?, frame: integer }>
local marks = {}

--- Key a lane by buffer + line.
---@param bufnr integer
---@param line integer
---@return string
local function key(bufnr, line)
    return bufnr .. ":" .. line
end

--- The highlight group for a method's accent (LvimRestGet, LvimRestPost, …).
---@param method string
---@return string
local function method_hl(method)
    return "LvimRest" .. method:sub(1, 1):upper() .. method:sub(2):lower()
end

--- The status-accent group for a code (2xx→green … 5xx→red).
---@param status integer
---@return string
local function status_hl(status)
    if status >= 200 and status < 300 then
        return "LvimRestStatus2xx"
    elseif status >= 300 and status < 400 then
        return "LvimRestStatus3xx"
    elseif status >= 400 and status < 500 then
        return "LvimRestStatus4xx"
    end
    return "LvimRestStatus5xx"
end

--- Set (or replace) the lane extmark on `line` (1-based) with `chunks` (virt_text).
---@param bufnr integer
---@param line integer
---@param chunks table[]
---@param existing integer?
---@return integer?
local function set_mark(bufnr, line, chunks, existing)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end
    local lc = vim.api.nvim_buf_line_count(bufnr)
    local row = math.min(line - 1, lc - 1)
    if row < 0 then
        return nil
    end
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
        id = existing,
        virt_text = chunks,
        virt_text_pos = "eol",
        hl_mode = "combine",
    })
    return ok and id or nil
end

--- Clear EVERY lane extmark physically sitting on `line`'s row — not just the one keyed by this line number.
--- A lane is keyed by line in `marks`, but its extmark MOVES with the text when the buffer is edited (nvim
--- shifts it). So after an edit between sends, the old lane's key no longer matches its extmark's current row;
--- keying alone would leave a stale chip that then stacks under the new one. This clears by ROW, dropping any
--- drifted lane's stale `marks` entry (and its timer) too.
---@param bufnr integer
---@param line integer
local function clear_row(bufnr, line)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    local row = line - 1
    if row < 0 then
        return
    end
    local ex = vim.api.nvim_buf_get_extmarks(bufnr, NS, { row, 0 }, { row, -1 }, {})
    if #ex == 0 then
        return
    end
    local dead = {}
    for _, m in ipairs(ex) do
        dead[m[1]] = true
        pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, m[1])
    end
    for k, e in pairs(marks) do
        if e.id and dead[e.id] then
            if e.timer and not e.timer:is_closing() then
                e.timer:stop()
                e.timer:close()
            end
            marks[k] = nil
        end
    end
end

--- Start the running spinner on a request line.
---@param bufnr integer
---@param line integer
---@param method string
function M.start(bufnr, line, method)
    M.clear(bufnr, line)
    clear_row(bufnr, line) -- also drop any lane whose extmark DRIFTED onto this row after an edit between sends
    local frames = config.icons.spinner
    local hl = method_hl(method)
    local id = set_mark(bufnr, line, { { "  " .. frames[1] .. " sending", hl } })
    if not id then
        return
    end
    local entry = { id = id, frame = 1, timer = nil }
    marks[key(bufnr, line)] = entry
    local timer = vim.uv.new_timer()
    if not timer then
        return
    end
    entry.timer = timer
    timer:start(
        80,
        80,
        vim.schedule_wrap(function()
            local e = marks[key(bufnr, line)]
            if not e or not vim.api.nvim_buf_is_valid(bufnr) then
                if timer and not timer:is_closing() then
                    timer:stop()
                    timer:close()
                end
                return
            end
            e.frame = (e.frame % #frames) + 1
            set_mark(bufnr, line, { { "  " .. frames[e.frame] .. " sending", hl } }, e.id)
        end)
    )
end

--- Stop a lane's spinner timer (if any).
---@param bufnr integer
---@param line integer
local function stop_timer(bufnr, line)
    local e = marks[key(bufnr, line)]
    if e and e.timer and not e.timer:is_closing() then
        e.timer:stop()
        e.timer:close()
        e.timer = nil
    end
end

--- Finish a lane: replace the spinner with the status chip (or an error chip).
---@param bufnr integer
---@param line integer
---@param result table
function M.finish(bufnr, line, result)
    stop_timer(bufnr, line)
    local e = marks[key(bufnr, line)]
    local existing = e and e.id
    local ptr = config.icons.pointer
    if result.error then
        local id = set_mark(bufnr, line, { { "  " .. ptr .. " " .. result.error, "LvimRestStatus5xx" } }, existing)
        marks[key(bufnr, line)] = id and { id = id, frame = 0 } or nil
        return
    end
    local status = result.status or 0
    local text = ("  %s %d %s · %d ms"):format(
        ptr,
        status,
        result.status_text or "",
        result.timing and result.timing.total or 0
    )
    local id = set_mark(bufnr, line, { { text, status_hl(status) } }, existing)
    marks[key(bufnr, line)] = id and { id = id, frame = 0 } or nil
end

--- Clear a request line's lane (extmark + timer).
---@param bufnr integer
---@param line integer
function M.clear(bufnr, line)
    stop_timer(bufnr, line)
    local e = marks[key(bufnr, line)]
    if e and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, e.id)
    end
    marks[key(bufnr, line)] = nil
end

--- Clear every lane in a buffer.
---@param bufnr integer
function M.clear_all(bufnr)
    for k, e in pairs(marks) do
        if k:match("^" .. bufnr .. ":") then
            if e.timer and not e.timer:is_closing() then
                e.timer:stop()
                e.timer:close()
            end
            if vim.api.nvim_buf_is_valid(bufnr) then
                pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, e.id)
            end
            marks[k] = nil
        end
    end
end

return M
