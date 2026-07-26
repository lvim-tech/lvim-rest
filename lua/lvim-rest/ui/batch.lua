-- lvim-rest.ui.batch: the collection RUN SHEET.
--
-- Running a folder/collection (`a All` in the tree) opens a READ-ONLY document of all its requests in the
-- editor pane — one `### name` + request line per block. As the run walks them (through the ordinary
-- `runner.iterate`, so it is the exact same send path), each block gains a LIVE inline status (spinner →
-- `➤ 200 OK · 45 ms`, the same lane a single send uses), and the top line carries a running SUMMARY
-- (`done/total · ok · failed`). Every full response also piles into the dock's `log` tab. `<CR>` on a block
-- opens that request's response in the dock.
--
-- So the three views combine: the document is the container (what is running), the inline chips + the log are
-- the live results, and the header is the summary.
--
---@module "lvim-rest.ui.batch"

local api = vim.api
local iterate = require("lvim-rest.runner.iterate")
local inline = require("lvim-rest.ui.inline")
local dock = require("lvim-rest.ui.dock")
local bind = require("lvim-rest.store.bind")

local M = {}

--- The live run's state — one sheet at a time (a new run replaces the last).
---@type { buf: integer?, block: integer[], results: table[], total: integer, done: integer, passed: integer, failed: integer, label: string }
local state = { buf = nil, block = {}, results = {}, total = 0, done = 0, passed = 0, failed = 0, label = "" }

--- A request's method, upper-cased (drives the inline lane's method accent).
---@param req table
---@return string
local function method_of(req)
    return (req.method or "GET"):upper()
end

--- The editor window that hosts the sheet: the workbench centre pane if the workbench is open, else the
--- window the tree was opened from (the same target `open_request` uses for a standalone sidebar).
---@return integer
local function editor_win()
    local ok, wb = pcall(require, "lvim-rest.ui.workbench")
    if ok and wb.is_open() then
        local w = wb.editor_win()
        if w and api.nvim_win_is_valid(w) then
            return w
        end
    end
    local w = vim.fn.win_getid(vim.fn.winnr("#"))
    return (w ~= 0 and api.nvim_win_is_valid(w)) and w or api.nvim_get_current_win()
end

--- The highlight namespace for the summary line's colour spans.
local NS = api.nvim_create_namespace("LvimRestBatch")

--- Repaint the summary line (line 1) in the read-only sheet — `▶ label — done/total · N ok · N failed …` — and
--- COLOUR its parts: the ok count green, the failed count red (dim when 0), the final verdict green/red. The
--- spans are high-priority extmarks so they win over the `# …` comment highlight. Toggles modifiable around
--- the single-line write.
local function set_summary()
    if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
        return
    end
    local running = not (state.done >= state.total and state.total > 0)
    local spans = {} ---@type table[]  { byte_from, byte_to, hl }
    local text = ("# ▶ %s — %d/%d · "):format(state.label, state.done, state.total)
    local ok_str = ("%d ok"):format(state.passed)
    spans[#spans + 1] = { #text, #text + #ok_str, "LvimRestStatus2xx" }
    text = text .. ok_str .. " · "
    local fail_str = ("%d failed"):format(state.failed)
    spans[#spans + 1] = { #text, #text + #fail_str, state.failed > 0 and "LvimRestStatus5xx" or "LvimRestHeaderName" }
    text = text .. fail_str
    if running then
        text = text .. "  …"
    else
        -- Just the verdict GLYPH (the counts are already in "N ok · N failed" — don't repeat the number).
        local verdict = state.failed == 0 and "  ✓" or "  ✗"
        spans[#spans + 1] =
            { #text, #text + #verdict, state.failed == 0 and "LvimRestStatus2xx" or "LvimRestStatus5xx" }
        text = text .. verdict
    end
    vim.bo[state.buf].modifiable = true
    pcall(api.nvim_buf_set_lines, state.buf, 0, 1, false, { text })
    vim.bo[state.buf].modifiable = false
    api.nvim_buf_clear_namespace(state.buf, NS, 0, 1)
    for _, s in ipairs(spans) do
        pcall(api.nvim_buf_set_extmark, state.buf, NS, 0, s[1], { end_col = s[2], hl_group = s[3], priority = 200 })
    end
end

--- The request-block index the cursor line falls in (blocks run from their `###` line to the next), or nil.
---@param line integer  1-based
---@return integer?
local function block_at(line)
    local hit
    for i, ln in ipairs(state.block) do
        if line >= ln then
            hit = i
        else
            break
        end
    end
    return hit
end

--- `<CR>` on a block: open that request's captured response in the dock (no re-send).
local function open_result()
    if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
        return
    end
    local i = block_at(api.nvim_win_get_cursor(0)[1])
    local r = i and state.results[i]
    if r then
        dock.show(r.result, r.meta)
    end
end

--- Run a folder/collection as a SHEET: build the document, host it in the editor, walk the requests.
---@param collection_id integer
---@param folder_id integer?
---@param label string  the folder/collection name (the summary heading)
function M.run(collection_id, folder_id, label)
    local requests = iterate.plan(collection_id, folder_id)
    if #requests == 0 then
        vim.notify("lvim-rest: nothing to run — no requests here", vim.log.levels.WARN)
        return
    end
    state = { block = {}, results = {}, total = #requests, done = 0, passed = 0, failed = 0, label = label or "run" }

    -- Build the document: the summary line, a blank, then one block per request.
    local lines = { "", "" }
    for i, req in ipairs(requests) do
        state.block[i] = #lines + 1 -- the `###` line (1-based)
        lines[#lines + 1] = ("### %s"):format(req.name or ("request " .. i))
        lines[#lines + 1] = ("%s %s"):format(method_of(req), req.url or "")
        lines[#lines + 1] = ""
    end

    local buf = api.nvim_create_buf(false, false) -- unlisted, nameless (like the editor's request scratch)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "http" -- treesitter highlights the request lines
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    state.buf = buf
    set_summary()

    -- `<CR>` opens the focused block's response (once it has one).
    vim.keymap.set(
        "n",
        "<CR>",
        open_result,
        { buffer = buf, nowait = true, silent = true, desc = "lvim-rest: open this response" }
    )

    -- Host it in the editor pane + the blue RUN title band (same canon as the editor's request title).
    local win = editor_win()
    pcall(api.nvim_win_set_buf, win, buf)
    pcall(api.nvim_set_current_win, win)
    vim.wo[win].winhighlight = "WinBar:LvimUiPeekTitleHover,WinBarNC:LvimUiPeekTitle"
    vim.wo[win].winbar = "%=  RUN ▸ " .. (label or "") .. "  %="

    iterate.run({
        collection_id = collection_id,
        folder_id = folder_id,
        -- Before a request runs: spin its block's inline lane.
        on_progress = function(info)
            local ln = state.block[info.index]
            if ln and api.nvim_buf_is_valid(buf) then
                inline.start(buf, ln, method_of(info.request))
            end
        end,
        -- On each result: finish its inline chip, tick the summary, and feed the response into the dock log.
        on_result = function(info, result)
            result = result or {}
            local ln = state.block[info.index]
            if ln and api.nvim_buf_is_valid(buf) then
                inline.finish(buf, ln, result)
            end
            state.done = state.done + 1
            if info.ok then
                state.passed = state.passed + 1
            else
                state.failed = state.failed + 1
            end
            set_summary()
            local meta = {
                title = info.request.name or ("request " .. info.index),
                name = info.request.name,
                -- Re-run from the log re-sends the ORIGINAL request (its bound buffer), not the read-only sheet.
                source = { bufnr = bind.open(info.request.id), lnum = 1 },
            }
            state.results[info.index] = { result = result, meta = meta }
            dock.log_append(result, meta)
        end,
        on_done = function()
            set_summary()
        end,
    })
end

return M
