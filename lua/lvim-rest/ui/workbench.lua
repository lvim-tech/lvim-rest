-- lvim-rest.ui.workbench: the dedicated full-tab workbench — the Postman face of the plugin.
--
--   ┌───────────────┬──────────────────────────────────────────┐
--   │  explorer     │  request editor (the bound `.http` buf)  │
--   │  (library     │                                          │
--   │   tree)       │  …the response dock opens per its own    │
--   │               │   configured layout over/under this      │
--   └───────────────┴──────────────────────────────────────────┘
--
-- It OWNS A TABPAGE, never the user's layout: `open()` creates one and `close()` drops it, putting
-- the previous tab back. That is the whole reason a workbench exists — a library browser plus an
-- editor plus a response pane cannot share a window with the code you were reading.
--
-- The left pane hosts the SAME `ui.explorer` provider the standalone sidebar uses (one tree, two
-- hosts): the surface chassis owns the window, the fold state lives in the tree handle, so opening
-- the workbench after using the sidebar keeps every fold exactly where it was.
--
---@module "lvim-rest.ui.workbench"

local api = vim.api
local config = require("lvim-rest.config")
local explorer = require("lvim-rest.ui.explorer")
local bind = require("lvim-rest.store.bind")

local M = {}

---@class LvimRestWorkbenchState
---@field tab integer?         the tabpage the workbench owns
---@field editor integer?      the CENTER window requests open into
---@field surface table?       the explorer surface (left pane)
---@field prev_tab integer?    the tabpage to return to on close
local state = { tab = nil, editor = nil, surface = nil, prev_tab = nil }

--- Is the workbench tab still alive?
---@return boolean
function M.is_open()
    return state.tab ~= nil and api.nvim_tabpage_is_valid(state.tab)
end

--- The workbench's editor window, when it is open and still valid.
---@return integer?
function M.editor_win()
    if state.editor and api.nvim_win_is_valid(state.editor) then
        return state.editor
    end
    return nil
end

--- A placeholder buffer for the centre pane before anything is opened — it tells you what to press
--- rather than showing an empty unnamed buffer.
---@return integer bufnr
local function placeholder()
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "http"
    api.nvim_buf_set_lines(buf, 0, -1, false, {
        "# lvim-rest workbench",
        "#",
        "#   <CR>  open the request under the cursor in the library",
        "#   S     send it        X  run the whole collection",
        "#   ?     every key the library panel has",
        "#",
        "# Requests are stored in the library — this buffer writes back on :w.",
    })
    vim.bo[buf].modifiable = false
    return buf
end

--- Open (or focus) the workbench tab.
---@return boolean ok
function M.open()
    if M.is_open() then
        api.nvim_set_current_tabpage(state.tab)
        return true
    end
    state.prev_tab = api.nvim_get_current_tabpage()

    -- A tab of our own: created, never stolen. `noautocmd` would suppress the FileType/BufEnter the
    -- panes rely on, so let the events fire normally.
    vim.cmd("tabnew")
    state.tab = api.nvim_get_current_tabpage()
    state.editor = api.nvim_get_current_win()

    -- Centre pane: nothing is bound yet, so show the key legend.
    pcall(api.nvim_win_set_buf, state.editor, placeholder())

    -- Left pane: the library tree, through the shared explorer provider + the surface chassis.
    local wb = config.workbench or {}
    local ok, surf = pcall(explorer.open, {
        side = "left",
        width = wb.explorer_width or 34,
        enter = false, -- open with the cursor in the EDITOR, not the tree
    })
    state.surface = ok and surf or nil
    if not ok then
        vim.notify("lvim-rest: could not open the library pane: " .. tostring(surf), vim.log.levels.ERROR)
    end

    -- Keep the cursor in the editor pane.
    if M.editor_win() then
        pcall(api.nvim_set_current_win, state.editor)
    end
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
    local win = M.editor_win()
    if not win then
        -- The editor pane was closed by hand: fall back to the current window inside the tab.
        win = api.nvim_get_current_win()
        state.editor = win
    end
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
    api.nvim_set_current_tabpage(state.tab)
    local surf = state.surface
    if surf and surf.win and api.nvim_win_is_valid(surf.win) then
        pcall(api.nvim_set_current_win, surf.win)
    end
end

--- Close the workbench: drop its tabpage and return to the tab it was opened from.
---@return nil
function M.close()
    if not M.is_open() then
        return
    end
    local tab = state.tab
    state.tab, state.editor, state.surface = nil, nil, nil
    -- Closing the tabpage tears down its windows (and with them the explorer surface). Guarded:
    -- `tabclose` on the LAST tab errors, and that must not leave the state half-cleared.
    pcall(function()
        if #api.nvim_list_tabpages() > 1 then
            api.nvim_set_current_tabpage(tab)
            vim.cmd("tabclose")
        end
    end)
    if state.prev_tab and api.nvim_tabpage_is_valid(state.prev_tab) then
        pcall(api.nvim_set_current_tabpage, state.prev_tab)
    end
    state.prev_tab = nil
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
