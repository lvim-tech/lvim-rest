-- lvim-rest.ui.explorer: the LIBRARY tree — workspace ▸ collection ▸ folder ▸ request.
--
-- Content only. The nodes are built from `store.library` and rendered through the SHARED tree layer
-- (`lvim-ui.tree`), the same one the lvim-files tree, the lvim-lsp outline and the lvim-db drawer
-- use — so folds, indent guides, the follow mark, the scrollbar, the canonical `l`/`<CR>`/`h` keys
-- and the mouse all behave identically here, and none of it is re-implemented.
--
-- The handle's `provider` is a surface CONTENT PROVIDER: `M.open()` plugs it into a persistent
-- docked split (the outline's shape), and the workbench hosts the same panel in its left pane.
--
-- The panel is a SINGLETON. A tree handle is bound to the window it renders into, so two live hosts
-- sharing one handle would fight over whose cursor `selected()` reads — and a handle cached past its
-- panel's teardown renders nothing at all (an empty sidebar, which is exactly what that bug looked
-- like). So: one panel at a time, the handle dies with it, and only the FOLD STATE survives.
--
-- Node ids are typed and STABLE (`c:12`, `f:3`, `r:47`) because the tree keys fold state, focus and
-- the mark by id: an id that changed between renders would reset every fold on refresh.
--
---@module "lvim-rest.ui.explorer"

local config = require("lvim-rest.config")
local library = require("lvim-rest.store.library")
local bind = require("lvim-rest.store.bind")

local M = {}

---@type table? the live tree handle (nil until built, and dropped when its panel closes)
local tree

---@type table? the live docked surface (the panel is a SINGLETON — see `M.open`)
local panel

---@type table<string, boolean> fold state, kept ACROSS panel lifetimes
--- The handle is bound to the window that hosts it, so it cannot outlive its panel; the folds can,
--- and should — reopening the library with every collection collapsed again would be a regression
--- disguised as a fresh start. Tracked through the tree's own expand/collapse hooks and fed back in
--- as `opts.expanded`.
local folds = {}

---@type integer? the workspace whose tree is shown
local workspace_id

--- Notify through the plugin's prefix.
---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-rest: " .. msg, level or vim.log.levels.INFO)
end

--- The method's icon + highlight — the same accents the inline status lane and history rows use, so
--- a verb reads the same colour everywhere in the plugin.
---@param method string?
---@return string icon, string hl
local function method_look(method)
    local ic = config.icons or {}
    local m = (method or "GET"):upper()
    local map = {
        GET = { ic.get, "LvimRestGet" },
        POST = { ic.post, "LvimRestPost" },
        PUT = { ic.put, "LvimRestPut" },
        PATCH = { ic.patch, "LvimRestPatch" },
        DELETE = { ic.delete, "LvimRestDelete" },
        GRAPHQL = { ic.graphql, "LvimRestGraphql" },
        GRPC = { ic.grpc, "LvimRestGrpc" },
        WEBSOCKET = { ic.ws, "LvimRestGrpc" },
    }
    local hit = map[m] or { ic.request, "LvimRestGet" }
    return hit[1] or "", hit[2]
end

-- ── node building ────────────────────────────────────────────────────────────

--- A request leaf. `data` carries the row so an action never re-queries to learn what it is on.
---@param row table
---@return table node
local function request_node(row)
    local icon, hl = method_look(row.method)
    return {
        id = "r:" .. row.id,
        label = row.name or "request",
        icon = icon,
        icon_hl = hl,
        kind = "request",
        detail = (row.method or "GET"):upper(),
        data = row,
    }
end

--- A folder node (recursive: nested folders first, then its requests).
---@param entry table  a `library.tree` folder entry
---@return table node
local function folder_node(entry)
    local children = {}
    for _, sub in ipairs(entry.folders or {}) do
        children[#children + 1] = folder_node(sub)
    end
    for _, r in ipairs(entry.requests or {}) do
        children[#children + 1] = request_node(r)
    end
    return {
        id = "f:" .. entry.folder.id,
        label = entry.folder.name,
        icon = (config.icons or {}).folder,
        kind = "folder",
        expandable = true,
        children = children,
        data = entry.folder,
    }
end

--- The top level: one node per collection, each holding its folders then its loose requests.
---@return table[] nodes
local function build_root()
    local ws = library.active_workspace()
    workspace_id = ws and ws.id or nil
    if not ws then
        return {}
    end
    local nodes = {}
    for _, entry in ipairs(library.tree(ws.id)) do
        local children = {}
        for _, f in ipairs(entry.folders or {}) do
            children[#children + 1] = folder_node(f)
        end
        for _, r in ipairs(entry.requests or {}) do
            children[#children + 1] = request_node(r)
        end
        nodes[#nodes + 1] = {
            id = "c:" .. entry.collection.id,
            label = entry.collection.name,
            icon = (config.icons or {}).collection,
            kind = "collection",
            expandable = true,
            children = children,
            data = entry.collection,
        }
    end
    return nodes
end

-- ── actions ──────────────────────────────────────────────────────────────────

--- Re-read the library and repaint, keeping folds (they are keyed by the stable ids).
local function refresh()
    if tree then
        tree.set_root(build_root)
        tree.refresh()
    end
end

M.refresh = refresh

--- The collection a node belongs to — a request/folder answers with its own collection_id.
---@param node table?
---@return integer?
local function collection_of(node)
    if not node or not node.data then
        return nil
    end
    if node.kind == "collection" then
        return node.data.id
    end
    return node.data.collection_id
end

--- Ask for a name through the canonical input, then run `fn(name)`. Never `vim.ui.input`.
---@param prompt string
---@param default string?
---@param fn fun(name: string)
local function ask(prompt, default, fn)
    require("lvim-ui").input({
        title = prompt,
        default = default,
        callback = function(confirmed, value)
            if confirmed and type(value) == "string" and vim.trim(value) ~= "" then
                fn(vim.trim(value))
            end
        end,
    })
end

--- Open a request in its bound `.http` buffer (the editor IS the request builder).
---@param node table?
local function open_request(node)
    if not node or node.kind ~= "request" then
        return
    end
    -- Inside the workbench the request belongs in its CENTRE pane; as a standalone sidebar it goes to
    -- the window you came from. Asking the workbench first keeps the tree from ever painting a
    -- request over itself.
    local wb = require("lvim-rest.ui.workbench")
    if wb.is_open() then
        wb.show_request(node.data.id)
        return
    end
    local buf = bind.open(node.data.id)
    if not buf then
        return
    end
    local win = vim.fn.win_getid(vim.fn.winnr("#"))
    if win == 0 or not vim.api.nvim_win_is_valid(win) then
        vim.cmd("wincmd p")
        win = vim.api.nvim_get_current_win()
    end
    pcall(vim.api.nvim_win_set_buf, win, buf)
    pcall(vim.api.nvim_set_current_win, win)
end

--- Send the request under the cursor straight from the tree.
---@param node table?
local function send_request(node)
    if not node or node.kind ~= "request" then
        return notify("put the cursor on a request first", vim.log.levels.WARN)
    end
    local buf = bind.open(node.data.id)
    if buf then
        require("lvim-rest.runner").send(buf, 1)
    end
end

--- New request under the node's collection/folder.
---@param node table?
local function new_request(node)
    local cid = collection_of(node)
    if not cid then
        return notify("select a collection first", vim.log.levels.WARN)
    end
    -- On a folder the request lands INSIDE it; on a collection/request it lands at the collection root.
    local folder_id = (node and node.kind == "folder") and node.data.id or nil
    ask("New request", "", function(name)
        if library.add_request(cid, { name = name, method = "GET", url = "", folder_id = folder_id }) then
            refresh()
        end
    end)
end

--- New folder under the node's collection (nested when the node is a folder).
---@param node table?
local function new_folder(node)
    local cid = collection_of(node)
    if not cid then
        return notify("select a collection first", vim.log.levels.WARN)
    end
    local parent = (node and node.kind == "folder") and node.data.id or nil
    ask("New folder", "", function(name)
        if library.add_folder(cid, name, parent) then
            refresh()
        end
    end)
end

--- New collection in the active workspace.
local function new_collection()
    local ws = library.active_workspace()
    if not ws then
        return notify("no workspace", vim.log.levels.ERROR)
    end
    ask("New collection", "", function(name)
        if library.add_collection(ws.id, name) then
            refresh()
        end
    end)
end

--- Rename whatever the cursor is on.
---@param node table?
local function rename(node)
    if not node or not node.data then
        return
    end
    ask("Rename", node.label, function(name)
        local ok = false
        if node.kind == "collection" then
            ok = library.update_collection(node.data.id, { name = name })
        elseif node.kind == "folder" then
            ok = library.rename_folder(node.data.id, name)
        elseif node.kind == "request" then
            ok = library.update_request(node.data.id, { name = name })
        end
        if ok then
            refresh()
        end
    end)
end

--- Delete whatever the cursor is on — with a confirm unless `library.confirm_delete` is off (a
--- collection/folder takes its children with it, which is why asking is the default).
---@param node table?
local function delete(node)
    if not node or not node.data then
        return
    end
    local function do_delete()
        if node.kind == "collection" then
            library.delete_collection(node.data.id)
        elseif node.kind == "folder" then
            library.delete_folder(node.data.id)
        elseif node.kind == "request" then
            library.delete_request(node.data.id)
        end
        refresh()
    end
    if not config.library.confirm_delete then
        return do_delete()
    end
    require("lvim-ui").confirm({
        title = ("Delete %s %q?"):format(node.kind, node.label),
        callback = function(yes)
            if yes then
                do_delete()
            end
        end,
    })
end

--- Move a node one step among its siblings (persisted as an `ord` swap).
---@param node table?
---@param dir integer  -1 up, 1 down
local function move(node, dir)
    if not node or not node.data then
        return
    end
    if node.kind == "collection" then
        if not workspace_id then
            return
        end
        library.move_collection(workspace_id, node.data.id, dir)
    elseif node.kind == "folder" then
        library.move_folder(node.data.collection_id, node.data.id, dir)
    elseif node.kind == "request" then
        library.move_request(node.data.collection_id, node.data.id, dir)
    end
    refresh()
end

--- Switch the active workspace through the canonical chooser.
local function switch_workspace()
    local rows = library.workspaces()
    local items = {}
    for _, w in ipairs(rows) do
        items[#items + 1] = { label = w.name, icon = (config.icons or {}).workspace, _id = w.id }
    end
    items[#items + 1] = { label = "New workspace…", icon = (config.icons or {}).workspace, _new = true }
    require("lvim-ui").select({
        title = "Workspace",
        items = items,
        callback = function(confirmed, idx)
            if not confirmed or not idx then
                return
            end
            local it = items[idx]
            if it._new then
                return ask("New workspace", "", function(name)
                    local id = library.add_workspace(name)
                    if id then
                        library.set_active_workspace(id)
                        refresh()
                    end
                end)
            end
            library.set_active_workspace(it._id)
            refresh()
        end,
    })
end

-- ── the tree handle ──────────────────────────────────────────────────────────

--- Run the collection the cursor is inside (a folder runs just its subtree).
---@param node table?
local function run_collection(node)
    local cid = collection_of(node)
    if not cid then
        return notify("select a collection first", vim.log.levels.WARN)
    end
    require("lvim-rest.runner.iterate").run({
        collection_id = cid,
        folder_id = (node and node.kind == "folder") and node.data.id or nil,
    })
end

--- The panel's actions. ONE table drives the keymaps, the footer chips and the help window, so a
--- key, its button and its documentation can never drift apart.
---
--- `bar = true` marks the two that FIT a ~34-column sidebar footer beside the `?` chip. A bar that
--- overflows into chevrons shows a few chips and hides the rest, which is worse than a short bar
--- plus a help window that lists everything.
---@type { key: string, name: string, desc: string, bar?: boolean, fn: fun(node: table?) }[]
local ACTIONS = {
    { key = "S", name = "send", desc = "send the request under the cursor", bar = true, fn = send_request },
    {
        key = "X",
        name = "run",
        desc = "run the collection (on a folder: that subtree)",
        bar = true,
        fn = run_collection,
    },
    { key = "a", name = "new", desc = "new request", fn = new_request },
    { key = "d", name = "del", desc = "delete (asks first)", fn = delete },
    { key = "A", name = "folder", desc = "new folder", fn = new_folder },
    { key = "n", name = "collection", desc = "new collection", fn = new_collection },
    { key = "r", name = "rename", desc = "rename", fn = rename },
    { key = "w", name = "workspace", desc = "switch / create a workspace", fn = switch_workspace },
    { key = "R", name = "refresh", desc = "re-read the library", fn = refresh },
}

-- Keys the tree itself owns, listed in the help so the window is the whole truth about the panel.
local INHERITED = {
    { key = "<CR> / l", desc = "open the request (or expand a folder)" },
    { key = "h", desc = "collapse / jump to the parent" },
    { key = "]e / [e", desc = "move the item among its siblings" },
    { key = "g?", desc = "this window" },
    { key = "q", desc = "close the client" },
}

--- Close the client: inside the workbench the tree is one of three panes, so `q` tears the WHOLE tab down
--- (closing just this panel would strand the editor + response); as a standalone panel it closes itself.
local function request_close()
    local wb = require("lvim-rest.ui.workbench")
    if wb.is_open() then
        wb.close()
    elseif panel and panel.close then
        pcall(panel.close)
    end
end

--- The panel's help window — the SHARED cheatsheet component (`lvim-ui.help`), the same one the
--- lvim-lsp outline uses: striped key/description rows in a framed float, nothing hand-rolled.
local function show_help()
    local items = {}
    for _, a in ipairs(ACTIONS) do
        items[#items + 1] = { a.key, a.desc }
    end
    for _, a in ipairs(INHERITED) do
        items[#items + 1] = { a.key, a.desc }
    end
    require("lvim-ui").help({ title = "REST library", items = items, close_keys = { "q", "<Esc>", "g?" } })
end

--- Build (once) and return the tree handle. `handle.provider` is what a host surface renders.
---@return table handle
function M.handle()
    if tree then
        return tree
    end
    tree = require("lvim-ui").tree({
        root = build_root,
        default_expanded = true, -- a library is for browsing: show the requests, not just the folders
        filetype = "LvimRestLibrary", -- what the cursor module registers below
        cursorline = true,
        connectors = true,
        empty = " No collections",
        -- `l` / `<CR>` on a request opens it; on a folder the tree's own fold handling runs first and
        -- only reaches here for a leaf.
        on_activate = function(node)
            if node and node.kind == "request" then
                open_request(node)
            end
        end,
        -- The consumer's keys go through `on_keys` — the tree binds them on ITS buffer after the
        -- canonical ones, so a config key can override a default on the same lhs.
        expanded = folds, -- restore the fold state from the previous panel lifetime
        -- Remember folds so reopening the library does not collapse everything again.
        on_expand = function(node)
            folds[node.id] = true
        end,
        on_collapse = function(node)
            folds[node.id] = false
        end,
        -- The handle cannot outlive its window: drop it so the next open builds a live one.
        on_close = function()
            tree, panel = nil, nil
        end,
        on_keys = function(map)
            map("g?", show_help)
            map("q", request_close)
            for _, action in ipairs(ACTIONS) do
                map(action.key, function()
                    action.fn(tree and tree.selected() or nil)
                end)
            end
            map("]e", function()
                move(tree and tree.selected() or nil, 1)
            end)
            map("[e", function()
                move(tree and tree.selected() or nil, -1)
            end)
        end,
    })
    return tree
end

--- The footer button band: the same actions the keys run, as clickable chips. DISPLAY plus click —
--- the keys are already bound on the panel, so a chip's `run` is the mouse path to the same thing.
---@return table[]
local function footer_bars()
    local surface = require("lvim-ui.surface")
    local items = {}
    for _, action in ipairs(ACTIONS) do
        if action.bar then
            items[#items + 1] = surface.button({
                name = action.name,
                key = action.key,
                no_hotkey = true, -- the tree already owns the key; the chip must not bind it twice
                run = function()
                    action.fn(tree and tree.selected() or nil)
                end,
            })
        end
    end
    items[#items + 1] = surface.button({ name = "help", key = "g?", no_hotkey = true, run = show_help })
    items[#items + 1] = surface.button({ name = "close", key = "q", no_hotkey = true, run = request_close })
    return { { align = "center", items = items } }
end

--- The surface content provider — for a host (the workbench) that owns its own window.
---@return table
function M.provider()
    return M.handle().provider
end

--- Open the explorer as a PERSISTENT docked sidebar (the lvim-lsp outline's shape). The workbench
--- uses `M.provider()` instead and owns its own layout.
---@param opts { side?: string, width?: integer, enter?: boolean }?
---@return table? surface
function M.open(opts)
    opts = opts or {}
    -- Already open? Focus it. The workbench hosts the panel in a tab of its own, so "show me the
    -- library" there means going to that tab, not opening a second copy beside the code.
    if panel then
        local wb = require("lvim-rest.ui.workbench")
        if wb.is_open() then
            wb.focus_library()
            return panel
        end
        if panel.win and vim.api.nvim_win_is_valid(panel.win) then
            pcall(vim.api.nvim_set_current_win, panel.win)
            return panel
        end
        -- A stale handle whose window is gone: fall through and rebuild.
        panel, tree = nil, nil
    end
    local surface = require("lvim-ui.surface")
    local handle = M.handle()
    panel = surface.open({
        mode = "split",
        native = true,
        dock = opts.side or "left",
        enter = opts.enter ~= false,
        persistent = true,
        normal_hl = "NormalSB",
        title = "REST",
        size = { width = { fixed = opts.width or 34 } },
        content = { blocks = { { id = "library", provider = handle.provider } } },
        close_keys = {},
        footer = { bars = footer_bars() },
    })
    return panel
end

--- Is a library panel currently open?
---@return boolean
function M.is_open()
    return panel ~= nil
end

return M
