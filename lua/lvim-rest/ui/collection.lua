-- lvim-rest.ui.collection: the COLLECTION SETTINGS form — collection-level defaults inherited by its
-- requests.
--
-- A collection's Headers, Variables and gRPC defaults are set ONCE here and every request in the
-- collection inherits them at render time (see `store.bind` render — the same "collection-level scheme,
-- rendered into the document" rule that `# @auth` uses). A request that sets the same header / variable,
-- or carries its own `@grpc-*`, overrides. Because a collection has no editable buffer (unlike the request
-- `options` form, which writes back into the `.http` text), this form writes STRAIGHT to the library
-- through `update_collection` — the store is the truth, and there is nothing to write back into.
--
-- Tabs are ADAPTIVE (`applicable_tabs`): Headers and Variables apply to every collection; the gRPC tab
-- appears only when the collection actually holds a gRPC request (a REST-only collection has no gRPC
-- config to set), exactly as the request options form shows its gRPC tab only for a GRPC request.
--
---@module "lvim-rest.ui.collection"

local config = require("lvim-rest.config")
local library = require("lvim-rest.store.library")
local highlight = require("lvim-utils.highlight")
local ui = require("lvim-ui")

local M = {}

---@type { id: integer?, name: string?, headers: table[], vars: table[], grpc: table, handle: table?, tabs: table[]?, folds: table<string, boolean> }
local state = { id = nil, name = nil, headers = {}, vars = {}, grpc = {}, handle = nil, tabs = nil, folds = {} }

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

--- Persist the whole working copy to the collection. The gRPC config collapses empty lists / fields to
--- nil (so a fully cleared config stores `{}` — read back as "no defaults"); headers / vars persist as
--- their lists (an empty list is simply no inheritance).
local function save()
    if not state.id then
        return
    end
    local g = state.grpc
    library.update_collection(state.id, {
        headers = state.headers,
        vars = state.vars,
        grpc = {
            proto = (g.proto and #g.proto > 0) and g.proto or nil,
            import = (g.import and #g.import > 0) and g.import or nil,
            authority = (g.authority and g.authority ~= "") and g.authority or nil,
            insecure = g.insecure or nil,
        },
    })
end

-- ── rows ────────────────────────────────────────────────────────────────────

--- A canonical collapsible SECTION header — the same fold the request `options` form uses, so the two
--- read alike. `expanded` is only the DEFAULT: a section the user collapsed stays collapsed across the
--- rebuild that follows every edit (`state.folds`).
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

--- A row that only says something (no value, not activatable). `tag` keeps the row NAMEABLE.
---@param text string
---@param tag string
---@return table
local function note(text, tag)
    return { type = "action", name = "note:" .. tag, label = text, disabled = true, flat = true }
end

--- The Headers tab: one row per collection header (`Name: value`). Inherited by every request that does
--- not set the same header (case-insensitively). Edit a value with `<CR>`, its name with the rename key.
---@return table[]
local function headers_rows()
    local list = state.headers
    if #list == 0 then
        return {
            note(
                "no headers — press " .. config.ui.collection.keys.add .. " to add one (every request inherits it)",
                "headers"
            ),
        }
    end
    local rows = {}
    for i, h in ipairs(list) do
        rows[i] = {
            type = "string",
            name = "header:" .. i,
            label = h.name,
            value = h.value,
            run = function(value)
                list[i].value = value
                save()
                M.refresh()
            end,
        }
    end
    return rows
end

--- The Variables tab: one row per collection variable (`@name = value`). A request variable of the same
--- name overrides. `{{name}}` in any request in the collection resolves to it.
---@return table[]
local function vars_rows()
    local list = state.vars
    if #list == 0 then
        return {
            note(
                "no variables — press " .. config.ui.collection.keys.add .. " to add one (e.g. base = https://api…)",
                "vars"
            ),
        }
    end
    local rows = {}
    for i, v in ipairs(list) do
        rows[i] = {
            type = "string",
            name = "var:" .. i,
            label = v.name,
            value = v.value,
            run = function(value)
                list[i].value = value
                save()
                M.refresh()
            end,
        }
    end
    return rows
end

--- One accordion of a repeatable gRPC path list (`proto` / `import`). Each child is an editable path
--- bound to its slot; `<CR>` rewrites the slot, the `add` / `delete` keys grow / shrink the list.
---@param key "proto"|"import"
---@param label string
---@param accent string
---@return table
local function list_fold(key, label, accent)
    local list = state.grpc[key] or {}
    local children = {}
    for i, v in ipairs(list) do
        children[i] = {
            type = "string",
            name = ("grpclist:%s:%d"):format(key, i),
            label = tostring(i),
            value = v,
            run = function(value)
                list[i] = vim.trim(value)
                state.grpc[key] = list
                save()
                M.refresh()
            end,
        }
    end
    if #children == 0 then
        children[1] = note("none — press " .. config.ui.collection.keys.add .. " to add one", "grpclist:" .. key)
    end
    return fold({
        name = "sec:" .. key,
        label = label,
        count = #list,
        accent = accent,
        expanded = #list > 0,
        children = children,
    })
end

--- The gRPC tab: the collection's gRPC defaults — authority + insecure as single fields, the proto files
--- and import dirs as accordions.
---@return table[]
local function grpc_rows()
    local g = state.grpc
    return {
        {
            -- `@grpc-authority` — the TLS SNI / HTTP2 `:authority`. The common collection-level value when a
            -- grpc front (e.g. nginx) routes by a vhost that differs from the endpoint host.
            type = "string",
            name = "grpc:authority",
            label = "Authority (TLS SNI / :authority)",
            value = g.authority or "",
            run = function(value)
                g.authority = value ~= "" and vim.trim(value) or nil
                save()
                M.refresh()
            end,
        },
        {
            -- `@grpc-insecure` — plaintext (no TLS) for the whole collection.
            type = "bool",
            name = "grpc:insecure",
            label = "Insecure (plaintext, no TLS)",
            value = g.insecure == true,
            run = function(value)
                g.insecure = value == true or nil
                save()
                M.refresh()
            end,
        },
        { type = "spacer_line" },
        list_fold("proto", "@grpc-proto (.proto files)", "blue"),
        list_fold("import", "@grpc-import (import dirs)", "yellow"),
        note(
            "set once here — every GRPC request in this collection inherits it; a request's own @grpc-* wins",
            "grpc"
        ),
    }
end

-- ── the panel ───────────────────────────────────────────────────────────────

--- Tab name → its row builder, so open + refresh agree and an adaptive tab set is handled by presence.
M._builders = {
    headers = headers_rows,
    vars = vars_rows,
    grpc = grpc_rows,
}

--- Rebuild every present tab's rows, keeping the cursor row.
function M.refresh()
    local h = state.handle
    if not (h and h.valid and h.valid() and state.tabs) then
        return
    end
    local idx = h.cursor_index()
    for _, tab in ipairs(state.tabs) do
        local b = M._builders[tab.name]
        if b then
            tab.rows = b()
        end
    end
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
---@return string
local function focused_name()
    local h = state.handle
    local name = h and h.cursor_name and h.cursor_name()
    return type(name) == "string" and name or ""
end

--- Which tab the focused row belongs to (read off the row name prefix — the honest reading of what the
--- cursor is on, so a key acts on the thing under it rather than a guessed tab).
---@return "headers"|"vars"|"grpc"
local function focused_tab()
    local n = focused_name()
    if n:match("^header:%d+$") or n == "note:headers" then
        return "headers"
    end
    if n:match("^var:%d+$") or n == "note:vars" then
        return "vars"
    end
    return "grpc"
end

--- The gRPC list key (`proto` / `import`) the cursor is in, from an entry / an empty section / its note.
---@return string?
local function focused_list_key()
    local name = focused_name()
    return name:match("^grpclist:([%w]+):%d+$") or name:match("^sec:([%w]+)$") or name:match("^note:grpclist:([%w]+)$")
end

-- The panel's ACTIONS: one table drives the buffer keys, the footer legend and the help window.
---@type { key: string, name: string, desc: string, fn: fun() }[]
local ACTIONS = {}

--- Add an entry to the tab under the cursor: a header (`Name: value`), a variable (`name = value`), or a
--- gRPC proto / import path.
local function action_add()
    local tab = focused_tab()
    if tab == "headers" then
        return ask("New header (Name: value)", "", function(text)
            local name, value = text:match("^([^:]+):%s*(.*)$")
            if not name then
                return notify("write it as Name: value", vim.log.levels.WARN)
            end
            state.headers[#state.headers + 1] = { name = vim.trim(name), value = value }
            save()
            refresh_soon()
        end)
    elseif tab == "vars" then
        return ask("New variable (name = value)", "", function(text)
            local name, value = text:match("^([^=]+)=(.*)$")
            if not name then
                return notify("write it as name = value", vim.log.levels.WARN)
            end
            state.vars[#state.vars + 1] = { name = vim.trim(name), value = vim.trim(value) }
            save()
            refresh_soon()
        end)
    end
    local key = focused_list_key()
    if not key then
        return notify("put the cursor in the @grpc-proto or @grpc-import section first", vim.log.levels.WARN)
    end
    local title = key == "proto" and "New .proto file (absolute path)" or "New import dir (absolute path)"
    ask(title, "", function(text)
        if text == "" then
            return
        end
        local list = state.grpc[key] or {}
        list[#list + 1] = text
        state.grpc[key] = list
        save()
        refresh_soon()
    end)
end

--- Delete the entry under the cursor (a header / variable / gRPC path).
local function action_delete()
    local tab = focused_tab()
    if tab == "headers" then
        local i = tonumber(focused_name():match("^header:(%d+)$"))
        if i then
            table.remove(state.headers, i)
            save()
            refresh_soon()
        end
        return
    elseif tab == "vars" then
        local i = tonumber(focused_name():match("^var:(%d+)$"))
        if i then
            table.remove(state.vars, i)
            save()
            refresh_soon()
        end
        return
    end
    local key, idx = focused_name():match("^grpclist:([%w]+):(%d+)$")
    if not key then
        return notify("move to a header / variable / path entry to delete it", vim.log.levels.WARN)
    end
    local list = state.grpc[key] or {}
    table.remove(list, tonumber(idx))
    state.grpc[key] = list
    save()
    refresh_soon()
end

--- Rename the NAME of the focused header / variable (its value is edited with `<CR>`).
local function action_rename()
    local tab = focused_tab()
    if tab == "headers" then
        local i = tonumber(focused_name():match("^header:(%d+)$"))
        local h = i and state.headers[i]
        if not h then
            return notify("move to a header to rename it", vim.log.levels.WARN)
        end
        return ask("Header name", h.name, function(name)
            if name ~= "" then
                h.name = name
                save()
                refresh_soon()
            end
        end)
    elseif tab == "vars" then
        local i = tonumber(focused_name():match("^var:(%d+)$"))
        local v = i and state.vars[i]
        if not v then
            return notify("move to a variable to rename it", vim.log.levels.WARN)
        end
        return ask("Variable name", v.name, function(name)
            if name ~= "" then
                v.name = name
                save()
                refresh_soon()
            end
        end)
    end
    notify("only a header or variable has a name to rename", vim.log.levels.WARN)
end

--- Clear ALL entries of the tab under the cursor (headers / variables / gRPC defaults).
local function action_clear()
    local tab = focused_tab()
    if tab == "headers" then
        if #state.headers == 0 then
            return notify("no headers to clear", vim.log.levels.INFO)
        end
        state.headers = {}
        save()
        notify("cleared this collection's headers")
        return refresh_soon()
    elseif tab == "vars" then
        if #state.vars == 0 then
            return notify("no variables to clear", vim.log.levels.INFO)
        end
        state.vars = {}
        save()
        notify("cleared this collection's variables")
        return refresh_soon()
    end
    if vim.tbl_isempty(state.grpc) then
        return notify("no gRPC defaults to clear", vim.log.levels.INFO)
    end
    state.grpc = {}
    save()
    notify("cleared this collection's gRPC defaults")
    refresh_soon()
end

--- The panel's help window — the shared cheatsheet component, built from the same ACTIONS table.
local function show_help()
    local items = {}
    for _, a in ipairs(ACTIONS) do
        items[#items + 1] = { a.key, a.desc }
    end
    items[#items + 1] = { "<CR>", "edit the focused value / field / path" }
    items[#items + 1] = { "h / l", "switch tab" }
    items[#items + 1] = { "q", "close" }
    ui.help({ title = "Collection settings", items = items, close_keys = { "q", "<Esc>", "?" } })
end

ACTIONS = {
    {
        key = config.ui.collection.keys.add,
        name = "add",
        desc = "add a header / variable / gRPC path",
        fn = action_add,
    },
    { key = config.ui.collection.keys.delete, name = "del", desc = "delete the focused entry", fn = action_delete },
    {
        key = config.ui.collection.keys.rename,
        name = "rename",
        desc = "rename the focused header / variable",
        fn = action_rename,
    },
    {
        key = config.ui.collection.keys.clear,
        name = "clear",
        desc = "clear every entry in the current tab",
        fn = action_clear,
    },
}

--- Bind the panel keys on its buffer.
---@param buf integer
local function wire_keys(buf)
    for _, a in ipairs(ACTIONS) do
        if a.key and a.key ~= "" then
            vim.keymap.set("n", a.key, a.fn, { buffer = buf, nowait = true, silent = true })
        end
    end
    local help = config.ui.collection.keys.help
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

--- Whether the collection holds at least one GRPC request (anywhere in its folder tree). The gRPC
--- defaults tab is only relevant then — a REST-only collection has nothing gRPC to set — exactly as the
--- request options form shows its gRPC tab only for a GRPC request.
---@param id integer
---@return boolean
local function collection_has_grpc(id)
    local function walk(fid)
        for _, r in ipairs(library.requests(id, fid)) do
            if (r.method or "") == "GRPC" then
                return true
            end
        end
        for _, f in ipairs(library.folders(id, fid)) do
            if walk(f.id) then
                return true
            end
        end
        return false
    end
    return walk(nil)
end

--- The tab names that APPLY to this collection. Headers and Variables apply to EVERY collection; the
--- gRPC tab only when the collection has a gRPC request.
---@param id integer
---@return string[]
local function applicable_tabs(id)
    local names = { "headers", "vars" }
    if collection_has_grpc(id) then
        names[#names + 1] = "grpc"
    end
    return names
end

--- Open the collection settings form for collection `id`.
---@param id integer
---@return nil
function M.open(id)
    local col = library.collection(id)
    if not col then
        return notify("no such collection", vim.log.levels.WARN)
    end
    local names = applicable_tabs(id)
    if #names == 0 then
        return notify("no collection settings apply here yet", vim.log.levels.INFO)
    end
    if state.handle and state.handle.valid and state.handle.valid() then
        M.close()
    end
    state.id = id
    state.name = col.name
    -- DEEP copies: the form edits a working copy and persists on every change, so it never mutates the
    -- live inflated row in place before `save` writes it.
    state.headers = vim.deepcopy(col.headers or {})
    state.vars = vim.deepcopy(col.vars or {})
    state.grpc = vim.deepcopy(col.grpc or {})
    state.folds = {}

    local t = config.ui.collection.tabs
    state.tabs = {}
    for _, name in ipairs(names) do
        state.tabs[#state.tabs + 1] =
            { label = t[name].label, icon = t[name].icon, name = name, menu = true, rows = M._builders[name]() }
    end

    local footer = {}
    for _, a in ipairs(ACTIONS) do
        footer[#footer + 1] = { key = a.key, label = a.name, run = a.fn, no_hotkey = true }
    end
    footer[#footer + 1] = { key = config.ui.collection.keys.help, label = "keys", run = show_help, no_hotkey = true }

    state.handle = ui.tabs({
        title = { icon = config.icons.collection, text = col.name .. " — settings" },
        tabs = state.tabs,
        layout = config.ui.collection.layout,
        cursorline_hl = "LvimUiCursorLine",
        footer_hints = footer,
        on_change = function(row)
            if row and row.children and row.name then
                state.folds[row.name] = row.expanded
            end
        end,
        on_open = function(buf)
            wire_keys(buf)
        end,
        callback = function()
            state.id, state.name, state.handle, state.tabs = nil, nil, nil, nil
            state.headers, state.vars, state.grpc, state.folds = {}, {}, {}, {}
        end,
    })
end

return M
