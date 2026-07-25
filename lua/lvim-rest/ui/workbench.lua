-- lvim-rest.ui.workbench: the dedicated full-tab workbench — the Postman face of the plugin.
--
--   ┌───────────────┬──────────────────────────────────────────┐
--   │  explorer     │  request editor (the bound `.http` buf)  │
--   │  (library     ├──────────────────────────────────────────┤
--   │   tree,       │  response dock — PERSISTENT, stacked in   │
--   │   full        │  the right column below the editor        │
--   │   height)     │  (editor 1/3 · response 2/3 by default)   │
--   └───────────────┴──────────────────────────────────────────┘
--
-- The tab lifecycle, the editor pane and the chrome guard belong to the SHARED `lvim-ui.workspace`
-- shell (the same primitive lvim-db / lvim-git / lvim-forge use); this module is a thin consumer that
-- fills the regions: the LEFT sidebar with the shared `ui.explorer` tree, and the response DOCK below
-- the editor (`ui.dock` workbench host, anchored to the editor window so it never spans under the tree).
-- The library browser plus editor plus response pane cannot share a window with the code you were
-- reading — hence the dedicated tab.
--
---@module "lvim-rest.ui.workbench"

local api = vim.api
local config = require("lvim-rest.config")
local explorer = require("lvim-rest.ui.explorer")
local dock = require("lvim-rest.ui.dock")
local bind = require("lvim-rest.store.bind")
local workspace = require("lvim-ui.workspace")

local M = {}

-- The workspace id (its tab marker). One workbench per session.
local ID = "lvim-rest"

-- The explorer surface of the current workbench (for `focus_library`). Re-set on each open, cleared on
-- close — the tab/editor are owned by `lvim-ui.workspace` and found by marker, this is the only local.
---@type table?
local sidebar = nil

--- Paint the editor pane's blue TITLE band — the same native-split-title canon lvim-db's editor / drawer /
--- result bands use (`LvimUiPeekTitle`, deepening to `…Hover` when the window is current), centred text.
--- Matches the tree ("REST") and response dock bands so all three panes read alike.
---@param win integer?
---@param text string
local function set_editor_title(win, text)
    if not (win and api.nvim_win_is_valid(win)) then
        return
    end
    vim.wo[win].winhighlight = "WinBar:LvimUiPeekTitleHover,WinBarNC:LvimUiPeekTitle"
    vim.wo[win].winbar = "%=" .. text .. "%="
end

-- ── the editor footer button bar (lvim-ui.winfooter) ─────────────────────────
-- The editor pane carries a bottom chip bar — send / save / send all / options — exactly like the lvim-db
-- editor's footer. The chips are display + click; the keys themselves are the buffer-local maps installed by
-- `attach_buffer` (init.lua), so the bar just mirrors them and every click routes through the SAME handler as
-- the key. Each handler resolves the editor's CURRENT buffer/line, so it follows whichever request is open.

--- A key's DISPLAY form for the footer chips: `<localleader>` → the user's real local leader (space reads
--- "SPC"), `<CR>` → the return glyph — so a chip shows the key a finger presses, not the mapping notation.
---@param lhs string?
---@return string?
local function pretty_key(lhs)
    if type(lhs) ~= "string" or lhs == "" then
        return nil
    end
    local ll = vim.g.maplocalleader or "\\"
    if ll == " " then
        ll = "SPC "
    end
    local lead = vim.g.mapleader or "\\"
    if lead == " " then
        lead = "SPC "
    end
    return (lhs:gsub("<localleader>", ll):gsub("<leader>", lead):gsub("<[Cc]%-CR>", "⌃⏎"):gsub("<CR>", "⏎"))
end

---@type table?  the attached footer-bar handle (an LvimUiWinFooter; closed with its window)
local footer_handle = nil

--- The editor window's current buffer + cursor line, for a footer handler to act on the open request.
---@return integer? buf, integer line
local function editor_target()
    local win = M.editor_win()
    if not (win and api.nvim_win_is_valid(win)) then
        return nil, 1
    end
    return api.nvim_win_get_buf(win), api.nvim_win_get_cursor(win)[1]
end

--- The editor footer chips, from the LIVE `config.keys` (a key left empty drops its chip). Display + click
--- only — each `run` calls the same code the buffer-local key does.
---@return table[]
local function footer_items()
    local surface = require("lvim-ui.surface")
    local k = config.keys
    local defs = {
        {
            key = k.send,
            name = "send",
            run = function()
                local buf, line = editor_target()
                if buf then
                    require("lvim-rest.runner").send(buf, line)
                end
            end,
        },
        {
            key = k.save,
            name = "save",
            run = function()
                local buf = editor_target()
                if buf and bind.request_of(buf) then
                    bind.write_back(buf)
                end
            end,
        },
        {
            key = k.send_all,
            name = "send all",
            run = function()
                local buf = editor_target()
                if buf then
                    require("lvim-rest.runner").send_all(buf)
                end
            end,
        },
        {
            key = k.options,
            name = "options",
            run = function()
                local buf, line = editor_target()
                if buf then
                    require("lvim-rest.ui.options").open(buf, line)
                end
            end,
        },
    }
    local items = {}
    for _, d in ipairs(defs) do
        local disp = pretty_key(d.key)
        if disp then
            items[#items + 1] = surface.button({ name = d.name, key = disp, style = "action", run = d.run }, "action")
        end
    end
    return items
end

--- Attach (or re-attach) the footer chip bar to the editor window. The bar auto-closes with its window, so a
--- re-open just attaches a fresh one; safe to call on every open/show.
---@param win integer?
local function attach_footer(win)
    if not (win and api.nvim_win_is_valid(win)) then
        return
    end
    if footer_handle then
        pcall(footer_handle.close)
        footer_handle = nil
    end
    footer_handle = require("lvim-ui.winfooter").attach(win, { items = footer_items(), align = "center" })
end

--- The placeholder shown in the editor pane before a request is opened — it tells you what to press.
---@return string[]
local function placeholder()
    return {
        "# lvim-rest workbench",
        "#",
        "#   <CR>  open the request under the cursor in the library",
        "#   S     send it        X  run the whole collection",
        "#   g?    every key the library panel has",
        "#",
        ("# Requests live in the library database — edit here and save with %s (no file on disk)."):format(
            config.keys.save or "<localleader>w"
        ),
    }
end

--- Is the workbench tab still alive?
---@return boolean
function M.is_open()
    return workspace.is_open(ID)
end

--- The workbench's editor window, when it is open and still valid.
---@return integer?
function M.editor_win()
    return workspace.editor(ID)
end

--- Open (or focus) the workbench tab.
---@return boolean ok
function M.open()
    workspace.open({
        id = ID,
        layout = ((config.workbench or {}).dock or {}).span == "full" and "full" or "stacked",
        editor = { placeholder = placeholder(), filetype = "http", name = "lvim-rest" },
        -- Appear in the shared <Leader>m dock menu; restorable (reopen) even after it was closed.
        menu = { name = "REST workbench", icon = (config.icons or {}).request },
        restore = function()
            M.open()
        end,
        -- LEFT: the library tree, through the shared explorer provider + the surface chassis.
        sidebar = function()
            local ok, surf = pcall(explorer.open, {
                side = "left",
                width = (config.workbench or {}).explorer_width or 34,
                enter = false, -- open with the cursor in the EDITOR, not the tree
            })
            sidebar = ok and surf or nil
            if not ok then
                vim.notify("lvim-rest: could not open the library pane: " .. tostring(surf), vim.log.levels.ERROR)
            end
            return sidebar
        end,
        -- RIGHT column, below the editor: the PERSISTENT response dock, anchored to the editor window.
        dock = function(editor)
            pcall(dock.open_workbench, editor, ID)
            return true
        end,
    })
    -- Blue title band on the editor pane (the tree + response dock carry their own) — until a request is
    -- opened it reads "EDITOR", then the request name (see `show_request`).
    set_editor_title(M.editor_win(), "EDITOR")
    attach_footer(M.editor_win()) -- the bottom chip bar: send / save / send all / options
    return true
end

--- Show a stored request in the workbench's centre pane (opening the workbench when needed).
---@param id integer  request id
---@return boolean ok
function M.show_request(id)
    if not M.is_open() then
        M.open()
    end
    local buf = bind.open(id)
    if not buf then
        return false
    end
    -- The editor pane was closed by hand: fall back to the current window inside the tab.
    local win = M.editor_win() or api.nvim_get_current_win()
    pcall(api.nvim_win_set_buf, win, buf)
    pcall(api.nvim_set_current_win, win)
    -- The editor title band names the open request (from its `### <name>` first line).
    local row = require("lvim-rest.store.library").request(id)
    set_editor_title(win, "  " .. ((row and row.name) or "request") .. "  ")
    attach_footer(win) -- keep the chip bar riding the (possibly re-resolved) editor window
    return true
end

--- Focus the workbench's library pane (going to its tab first). `:LvimRest library` while the
--- workbench is open means "show me the library", and it is already there.
---@return nil
function M.focus_library()
    if not M.is_open() then
        return
    end
    workspace.focus(ID)
    -- Find the tree window by its filetype in the workbench tab (a native-split surface doesn't expose its
    -- window on the handle reliably); fall back to the stored sidebar handle.
    local tab = workspace.tab_for(ID)
    if tab then
        for _, w in ipairs(api.nvim_tabpage_list_wins(tab)) do
            if api.nvim_win_is_valid(w) and vim.bo[api.nvim_win_get_buf(w)].filetype == "LvimRestLibrary" then
                pcall(api.nvim_set_current_win, w)
                return
            end
        end
    end
    if sidebar and sidebar.win and api.nvim_win_is_valid(sidebar.win) then
        pcall(api.nvim_set_current_win, sidebar.win)
    end
end

--- Close the workbench: drop its tabpage and return to the tab it was opened from. The response dock is
--- torn down first (deterministic state reset) before the shared shell closes the tab.
---@return nil
function M.close()
    if not M.is_open() then
        return
    end
    workspace.close(ID, function()
        pcall(dock.close)
        sidebar = nil
    end)
end

--- Open when closed, close when open — what a single launcher key should do.
---@return nil
function M.toggle()
    if M.is_open() then
        M.close()
    else
        M.open()
    end
end

return M
