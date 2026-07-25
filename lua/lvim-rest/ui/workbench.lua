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

--- The placeholder shown in the editor pane before a request is opened — it tells you what to press.
---@return string[]
local function placeholder()
    return {
        "# lvim-rest workbench",
        "#",
        "#   <CR>  open the request under the cursor in the library",
        "#   S     send it        X  run the whole collection",
        "#   ?     every key the library panel has",
        "#",
        "# Requests are stored in the library — this buffer writes back on :w.",
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
