-- lvim-rest.ui.options: the request OPTIONS form — the Postman face of the request under the cursor.
--
-- A `ui.tabs` panel over ONE request: its query Params, its Headers, and its per-request Settings
-- (the `# @…` directives). It is a VIEW, never a store: every row is built from a fresh
-- `parser.parse` of the buffer and every change is written back as BUFFER TEXT through
-- `lvim-rest.ui.edit` — so the form and a send always agree, and a request opened from the library
-- persists exactly the way a hand-edited one does (`:w` → the existing bind write-back). This module
-- never calls the library.
--
-- WHAT THE DOCUMENT CANNOT SAY, THE FORM DOES NOT INVENT:
--   * a HEADER can be switched off, because commenting the line out is how the format expresses that
--     — the text survives and `t` brings it back;
--   * a QUERY PARAMETER cannot (a url has no "disabled" form), so there is no toggle for one: the
--     honest operations are edit, add and delete. A form-local "disabled" flag that evaporated when
--     the panel closed would be a lie about where the truth lives.
--
---@module "lvim-rest.ui.options"

local api = vim.api
local config = require("lvim-rest.config")
local edit = require("lvim-rest.ui.edit")
local highlight = require("lvim-utils.highlight")
local ui = require("lvim-ui")

local M = {}

---@type { editor: LvimRestEditor?, handle: table?, tabs: table[]?, layout: string?, folds: table<string, boolean> }
local state = { editor = nil, handle = nil, tabs = nil, layout = nil, folds = {} }

--- Notify through the plugin's prefix.
---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-rest: " .. msg, level or vim.log.levels.INFO)
end

--- Ask for a line of text through the canonical input.
---@param title string
---@param default string
---@param fn fun(value: string)
local function ask(title, default, fn)
    ui.input({
        title = title,
        default = default,
        callback = function(confirmed, value)
            if confirmed and type(value) == "string" then
                fn(vim.trim(value))
            end
        end,
    })
end

-- ── rows ────────────────────────────────────────────────────────────────────

--- A canonical collapsible SECTION header. The plugin owns only the caret BOX (a glyph padded to a
--- fixed width, in the section's own accent) and the accent; the band, the hover and the label
--- colours are global (`lvim-utils.highlight.section_accent`), so these folds look like every other
--- fold in the ecosystem.
---
--- `expanded` is only the DEFAULT: a section the user collapsed stays collapsed across the rebuild
--- that follows every edit (`state.folds`), because a form that re-opened its folds each time you
--- changed a value would be unusable.
---@param opts { name: string, label: string, count: integer, accent: string, expanded: boolean, children: table[] }
---@return table
local function fold(opts)
    local remembered = state.folds[opts.name]
    if remembered ~= nil then
        opts.expanded = remembered
    end
    local caret = opts.expanded and config.icons.expand_open or config.icons.expand_closed
    return ui.section({
        name = opts.name,
        icon = " " .. caret .. " ",
        box_hl = highlight.section_accent(opts.accent).text,
        label = opts.label,
        count = opts.count,
        accent = opts.accent,
        expanded = opts.expanded,
        children = opts.children,
    })
end

--- A row that only says something (no value, not activatable). `tag` keeps the row NAMEABLE: which
--- tab a key acts on is read off the focused row's name, so even an empty tab must identify itself.
---@param text string
---@param tag string
---@return table
local function note(text, tag)
    return { type = "action", name = "note:" .. tag, label = text, disabled = true, flat = true }
end

--- The Params tab: one row per query parameter of the request line.
---@param req LvimRestRequest
---@return table[]
local function params_rows(req)
    local _, params = edit.split_query(req.url)
    if #params == 0 then
        return { note("no query parameters — press " .. config.ui.options.keys.add .. " to add one", "params") }
    end
    local rows = {}
    for i, p in ipairs(params) do
        rows[i] = {
            type = "string",
            name = "param:" .. i,
            label = p.name,
            value = p.value,
            run = function(value)
                local ed = state.editor
                if not ed then
                    return
                end
                local _, list = edit.split_query((ed:request() or req).url)
                if list[i] then
                    list[i].value = value
                    ed:set_params(list)
                end
                M.refresh()
            end,
        }
    end
    return rows
end

--- The Headers tab: one row per header LINE, including the commented-out ones.
---@return table[]
local function headers_rows()
    local ed = state.editor
    local headers = ed and ed:headers() or {}
    if #headers == 0 then
        return { note("no headers — press " .. config.ui.options.keys.add .. " to add one", "headers") }
    end
    local rows = {}
    for i, h in ipairs(headers) do
        rows[i] = {
            type = "string",
            name = "header:" .. i,
            label = h.name,
            value = h.value,
            -- A commented-out header renders dimmed + struck through, which is exactly what it is.
            -- It stays focusable, so `t` can switch it back on.
            disabled = not h.enabled,
            run = function(value)
                if state.editor then
                    state.editor:set_header(h.lnum, h.name, value, h.enabled)
                end
                M.refresh()
            end,
        }
    end
    return rows
end

-- The REPEATABLE directives, as one declarative table: the accordion label, the directive key, how
-- an entry is read out of the parsed request, and how a new one is written. One table drives the
-- rows, the `add` key and the help — they cannot drift apart.
---@type { key: string, label: string, accent: string, prompt: string, entries: (fun(req: LvimRestRequest): { label: string, value: string }[]) }[]
local LISTS = {
    {
        key = "prompt",
        label = "@prompt",
        accent = "blue",
        prompt = "New @prompt (var [description])",
        entries = function(req)
            local out = {}
            for _, p in ipairs(req.directives.prompt) do
                out[#out + 1] = { label = p.var, value = p.desc or "" }
            end
            return out
        end,
    },
    {
        key = "stdin-cmd",
        label = "@stdin-cmd",
        accent = "yellow",
        prompt = "New @stdin-cmd (var shell…)",
        entries = function(req)
            local out = {}
            for _, c in ipairs(req.directives.stdin_cmd) do
                out[#out + 1] = { label = c.var, value = c.cmd }
            end
            return out
        end,
    },
    {
        key = "env-stdin-cmd",
        label = "@env-stdin-cmd",
        accent = "yellow",
        prompt = "New @env-stdin-cmd (var shell…)",
        entries = function(req)
            local out = {}
            for _, c in ipairs(req.directives.env_stdin_cmd) do
                out[#out + 1] = { label = c.var, value = c.cmd }
            end
            return out
        end,
    },
}

--- One accordion of a repeatable directive. Its children are the entries in document order, each
--- bound to the line it was read from.
---@param req LvimRestRequest
---@param spec table  a LISTS entry
---@return table
local function list_section(req, spec)
    local entries = spec.entries(req)
    local lines = req.directive_lines[spec.key] or {}
    local children = {}
    for i, e in ipairs(entries) do
        local lnum = lines[i]
        children[i] = {
            type = "string",
            name = ("dir:%s:%d"):format(spec.key, i),
            label = e.label,
            value = e.value,
            disabled = lnum == nil, -- no anchor (a malformed line): show it, never rewrite it
            run = function(value)
                if state.editor and lnum then
                    state.editor:set_directive_line(lnum, spec.key, vim.trim(e.label .. " " .. value))
                end
                M.refresh()
            end,
        }
    end
    if #children == 0 then
        children[1] = note("none", "dir:" .. spec.key)
    end
    return fold({
        name = "sec:" .. spec.key,
        label = spec.label,
        count = #entries,
        accent = spec.accent,
        expanded = #entries > 0,
        children = children,
    })
end

--- The raw `@curl-*` flags (a map, so it is listed sorted rather than in document order).
---@param req LvimRestRequest
---@return table
local function curl_section(req)
    local flags = {}
    for flag in pairs(req.directives.curl) do
        flags[#flags + 1] = flag
    end
    table.sort(flags)
    local children = {}
    for _, flag in ipairs(flags) do
        local value = req.directives.curl[flag]
        local lines = req.directive_lines["curl-" .. flag] or {}
        local lnum = lines[1]
        children[#children + 1] = {
            type = "string",
            name = "curl:" .. flag,
            label = flag,
            value = value == true and "" or tostring(value),
            disabled = lnum == nil,
            run = function(v)
                if state.editor and lnum then
                    state.editor:set_directive_line(lnum, "curl-" .. flag, v ~= "" and v or nil)
                end
                M.refresh()
            end,
        }
    end
    if #children == 0 then
        children[1] = note("none", "curl")
    end
    return fold({
        name = "sec:curl",
        label = "@curl-*",
        count = #flags,
        accent = "green",
        expanded = #flags > 0,
        children = children,
    })
end

--- The Settings tab: the single-valued directives, the repeatable ones as accordions, and the
--- directives this plugin does not know — shown, never touched.
---@param req LvimRestRequest
---@return table[]
local function settings_rows(req)
    local d = req.directives
    --- A row whose edit writes one single-valued directive.
    ---@param name string
    ---@param label string
    ---@param rtype string
    ---@param value any
    ---@return table
    local function directive_row(name, label, rtype, value)
        return {
            type = rtype,
            name = "set:" .. name,
            label = label,
            value = value,
            run = function(v)
                if not state.editor then
                    return
                end
                if rtype == "bool" then
                    state.editor:set_directive(name, v == true or nil)
                elseif rtype == "int" then
                    -- 0 means "no timeout directive": a form needs a way to say NONE, and an
                    -- explicit `# @timeout 0` would be a request that times out instantly.
                    state.editor:set_directive(name, (v and v > 0) and tostring(math.floor(v)) or nil)
                else
                    state.editor:set_directive(name, v ~= "" and v or nil)
                end
                M.refresh()
            end,
        }
    end
    local rows = {
        directive_row("timeout", "timeout (ms, 0 = none)", "int", d.timeout or 0),
        directive_row("no-log", "no-log", "bool", d.no_log == true),
        directive_row("no-cookie-jar", "no-cookie-jar", "bool", d.no_cookie_jar == true),
        directive_row("accept", "accept", "string", d.accept or ""),
        directive_row("jq", "jq filter", "string", d.jq or ""),
        { type = "spacer_line" },
    }
    for _, spec in ipairs(LISTS) do
        rows[#rows + 1] = list_section(req, spec)
    end
    rows[#rows + 1] = curl_section(req)

    -- Directives the parser preserved but this plugin has no meaning for. They are READ-ONLY here:
    -- the form must never be the reason a `# @postman-test` line changes.
    local extra = {}
    for key, value in pairs(d.extra) do
        extra[#extra + 1] = { key = key, value = value }
    end
    table.sort(extra, function(a, b)
        return a.key < b.key
    end)
    if #extra > 0 then
        local children = {}
        for _, e in ipairs(extra) do
            children[#children + 1] = note(("# @%s %s"):format(e.key, e.value), "extra:" .. e.key)
        end
        rows[#rows + 1] = fold({
            name = "sec:extra",
            label = "other directives (read-only)",
            count = #extra,
            accent = "magenta",
            expanded = false,
            children = children,
        })
    end
    return rows
end

-- ── the panel ───────────────────────────────────────────────────────────────

--- Rebuild every tab's rows from a fresh parse, keeping the cursor row. The panel always shows what
--- the parser sees — which is the whole point of writing back into the buffer instead of a store.
function M.refresh()
    local h, ed = state.handle, state.editor
    if not (h and h.valid and h.valid() and ed and ed:valid() and state.tabs) then
        return
    end
    local req = ed:request()
    if not req then
        return M.close()
    end
    local idx = h.cursor_index()
    state.tabs[1].rows = params_rows(req)
    state.tabs[2].rows = headers_rows()
    state.tabs[3].rows = settings_rows(req)
    h.recalc()
    h.focus_index(idx)
end

--- Refresh AFTER the form has finished its own repaint of the row that was just edited.
local function refresh_soon()
    vim.schedule(function()
        M.refresh()
    end)
end

--- The `name` of the focused row ("" when there is none).
---
--- Every row is named after WHAT it is (`param:3`, `header:2`, `set:timeout`, `dir:prompt:1`,
--- `curl:proxy`, `note:headers`), so a key acts on the thing under the cursor rather than on a
--- guessed tab. That is also the only honest reading: the panel's tabs are one form, and the cursor
--- is the selection.
---@return string
local function focused_name()
    local h = state.handle
    local name = h and h.cursor_name and h.cursor_name()
    return type(name) == "string" and name or ""
end

--- Which tab the focused row belongs to.
---@return "params"|"headers"|"settings"
local function focused_tab()
    local name = focused_name()
    if name:match("^param:%d+$") or name == "note:params" then
        return "params"
    end
    if name:match("^header:%d+$") or name == "note:headers" then
        return "headers"
    end
    return "settings"
end

--- The 1-based index encoded in the focused row's name (`param:3` → 3).
---@param prefix string
---@return integer?
local function focused(prefix)
    return tonumber(focused_name():match("^" .. prefix .. ":(%d+)$"))
end

-- The panel's ACTIONS: one table drives the buffer keys, the footer legend and the help window.
---@type { key: string, name: string, desc: string, fn: fun() }[]
local ACTIONS = {}

--- Add a row in the active tab.
local function action_add()
    local ed = state.editor
    local h = state.handle
    if not (ed and h) then
        return
    end
    if focused_tab() == "params" then
        return ask("New query parameter (name=value)", "", function(text)
            local name, value = text:match("^([^=]+)=(.*)$")
            if not name then
                return notify("write it as name=value", vim.log.levels.WARN)
            end
            local req = ed:request()
            local _, params = edit.split_query(req and req.url or "")
            params[#params + 1] = { name = vim.trim(name), value = value }
            ed:set_params(params)
            refresh_soon()
        end)
    elseif focused_tab() == "headers" then
        return ask("New header (Name: value)", "", function(text)
            local name, value = text:match("^([^:]+):%s*(.*)$")
            if not name then
                return notify("write it as Name: value", vim.log.levels.WARN)
            end
            ed:add_header(vim.trim(name), value)
            refresh_soon()
        end)
    end
    -- Settings: which repeatable directive gets a new entry is decided by the section the cursor is in.
    local name = focused_name()
    local key = name:match("^dir:([%w%-]+):%d+$") or name:match("^sec:([%w%-]+)$") or name:match("^note:dir:(.+)$")
    for _, spec in ipairs(LISTS) do
        if key == spec.key then
            return ask(spec.prompt, "", function(text)
                if text ~= "" then
                    ed:add_directive(spec.key, text)
                    refresh_soon()
                end
            end)
        end
    end
    if key == "curl" or name:match("^curl:") or name == "note:curl" then
        return ask("New @curl flag (flag[=value])", "", function(text)
            if text ~= "" then
                ed:add_directive("curl-" .. text, nil)
                refresh_soon()
            end
        end)
    end
    notify("put the cursor in a @prompt / @stdin-cmd / @curl section first", vim.log.levels.WARN)
end

--- Delete the row under the cursor (its LINE, for anything line-backed).
local function action_delete()
    local ed, h = state.editor, state.handle
    if not (ed and h) then
        return
    end
    local tab = focused_tab()
    if tab == "params" then
        local i = focused("param")
        if not i then
            return
        end
        local req = ed:request()
        local _, params = edit.split_query(req and req.url or "")
        table.remove(params, i)
        ed:set_params(params)
        return refresh_soon()
    elseif tab == "headers" then
        local i = focused("header")
        local h_row = i and ed:headers()[i]
        if not h_row then
            return
        end
        ed:delete(h_row.lnum)
        return refresh_soon()
    end
    local name = focused_name()
    local key, idx = name:match("^dir:([%w%-]+):(%d+)$")
    if key then
        local lines = ed:directive_lines(key)
        local lnum = lines[tonumber(idx)]
        if lnum then
            ed:delete(lnum)
            return refresh_soon()
        end
    end
    local flag = name:match("^curl:(.+)$")
    if flag then
        ed:set_directive("curl-" .. flag, nil)
        return refresh_soon()
    end
    local single = name:match("^set:(.+)$")
    if single then
        ed:set_directive(single, nil)
        return refresh_soon()
    end
end

--- Comment a header line out / back in.
local function action_toggle()
    local ed, h = state.editor, state.handle
    if not (ed and h) then
        return
    end
    if focused_tab() ~= "headers" then
        return notify("only a header line can be switched off (a url has no disabled parameter)", vim.log.levels.WARN)
    end
    local i = focused("header")
    local row = i and ed:headers()[i]
    if row then
        ed:toggle_header(row.lnum)
        refresh_soon()
    end
end

--- Rename the row under the cursor (a parameter's name, a header's name).
local function action_rename()
    local ed, h = state.editor, state.handle
    if not (ed and h) then
        return
    end
    local tab = focused_tab()
    if tab == "params" then
        local i = focused("param")
        local req = ed:request()
        local _, params = edit.split_query(req and req.url or "")
        if not (i and params[i]) then
            return
        end
        return ask("Parameter name", params[i].name, function(name)
            if name ~= "" then
                params[i].name = name
                ed:set_params(params)
                refresh_soon()
            end
        end)
    elseif tab == "headers" then
        local i = focused("header")
        local row = i and ed:headers()[i]
        if not row then
            return
        end
        return ask("Header name", row.name, function(name)
            if name ~= "" then
                ed:set_header(row.lnum, name, row.value, row.enabled)
                refresh_soon()
            end
        end)
    end
    notify("nothing to rename on this row", vim.log.levels.WARN)
end

--- Send the request the form is editing, and close (the response belongs in the dock, not here).
local function action_send()
    local ed = state.editor
    if not ed then
        return
    end
    local buf, lnum = ed.buf, ed:anchor()
    M.close()
    vim.schedule(function()
        require("lvim-rest.runner").send(buf, lnum)
    end)
end

--- The panel's help window — the shared cheatsheet component, built from the same ACTIONS table.
local function show_help()
    local items = {}
    for _, a in ipairs(ACTIONS) do
        items[#items + 1] = { a.key, a.desc }
    end
    items[#items + 1] = { "<CR>", "edit the focused row (a header/param VALUE, a directive)" }
    items[#items + 1] = { "h / l", "switch tab" }
    items[#items + 1] = { "q", "close" }
    ui.help({ title = "Request options", items = items, close_keys = { "q", "<Esc>", "?" } })
end

ACTIONS = {
    {
        key = config.ui.options.keys.add,
        name = "add",
        desc = "add a parameter / header / directive entry",
        fn = action_add,
    },
    { key = config.ui.options.keys.delete, name = "del", desc = "delete the row under the cursor", fn = action_delete },
    {
        key = config.ui.options.keys.toggle,
        name = "toggle",
        desc = "switch a header line off / on (it is commented out, never lost)",
        fn = action_toggle,
    },
    { key = config.ui.options.keys.rename, name = "rename", desc = "rename a parameter / header", fn = action_rename },
    { key = config.ui.options.keys.send, name = "send", desc = "send this request and close", fn = action_send },
}

--- Bind the panel keys on its buffer.
---@param buf integer
local function wire_keys(buf)
    for _, a in ipairs(ACTIONS) do
        if a.key and a.key ~= "" then
            vim.keymap.set("n", a.key, a.fn, { buffer = buf, nowait = true, silent = true })
        end
    end
    local help = config.ui.options.keys.help
    if help and help ~= "" then
        vim.keymap.set("n", help, show_help, { buffer = buf, nowait = true, silent = true })
    end
end

--- Close the panel.
function M.close()
    if state.handle and state.handle.valid and state.handle.valid() then
        state.handle.close()
    end
end

--- Open the options form for the request under the cursor of `bufnr` at `lnum`.
---@param bufnr integer?
---@param lnum integer?
---@param layout string?  "float" | "area" | "bottom" (a per-command override, sticky for the session)
---@return nil
function M.open(bufnr, lnum, layout)
    bufnr = bufnr or api.nvim_get_current_buf()
    lnum = lnum or api.nvim_win_get_cursor(0)[1]
    if state.handle and state.handle.valid and state.handle.valid() then
        M.close()
    end
    local ed = edit.attach(bufnr, lnum)
    if not ed then
        return notify("no request under the cursor", vim.log.levels.WARN)
    end
    local req = ed:request()
    if not req then
        return notify("no request under the cursor", vim.log.levels.WARN)
    end
    state.editor = ed
    if layout then
        state.layout = layout
    end
    local t = config.ui.options.tabs
    state.tabs = {
        { label = t.params.label, icon = t.params.icon, name = "params", menu = true, rows = params_rows(req) },
        { label = t.headers.label, icon = t.headers.icon, name = "headers", menu = true, rows = headers_rows() },
        { label = t.settings.label, icon = t.settings.icon, name = "settings", menu = true, rows = settings_rows(req) },
    }
    local footer = {}
    for _, a in ipairs(ACTIONS) do
        footer[#footer + 1] = { key = a.key, label = a.name, run = a.fn, no_hotkey = true }
    end
    footer[#footer + 1] = { key = config.ui.options.keys.help, label = "keys", run = show_help, no_hotkey = true }
    state.handle = ui.tabs({
        -- The border title says WHICH request is being edited: the panel is modal over one of them.
        title = { icon = config.icons.request, text = req.name or ((req.method or "") .. " " .. (req.url or "")) },
        tabs = state.tabs,
        layout = state.layout or config.ui.options.layout,
        cursorline_hl = "LvimUiCursorLine",
        footer_hints = footer,
        -- A fold is a change too: remember it, so the rebuild after the next edit keeps it.
        on_change = function(row)
            if row and row.children and row.name then
                state.folds[row.name] = row.expanded
            end
        end,
        on_open = function(buf)
            wire_keys(buf)
        end,
        callback = function()
            if state.editor then
                state.editor:detach()
            end
            state.editor, state.handle, state.tabs = nil, nil, nil
            state.folds = {}
        end,
    })
end

return M
