-- lvim-rest.spec.diagnostics: surfaces the structural validator (`lvim-rest.spec.validate`) on an
-- http/rest buffer as live `vim.diagnostic` items. This is the ONLY consumer that touches editor
-- diagnostic state — `spec.validate` itself stays pure so the panel can also call it to badge a tab.
--
-- Cadence (user decision): debounced `TextChanged`/`TextChangedI` for live feedback, plus the calm
-- points `InsertLeave` and `BufWritePost` for an immediate refresh. All buffer-local, all cleaned up.
-- Validation is pure/cheap and never networks, so the live cadence costs nothing per keystroke beyond
-- one debounced parse.
--
---@module "lvim-rest.spec.diagnostics"

local spec = require("lvim-rest.spec")

local M = {}

local NS = vim.api.nvim_create_namespace("LvimRestSpec")

---@type table<integer, uv.uv_timer_t>  bufnr → its debounce timer
local timers = {}

--- Parse `bufnr` and publish the structural diagnostics for it. Main thread.
---@param bufnr integer
local function refresh(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    local ok_cfg, config = pcall(require, "lvim-rest.config")
    if ok_cfg and config.diagnostics and config.diagnostics.enabled == false then
        vim.diagnostic.reset(NS, bufnr)
        return
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local ok, doc = pcall(require("lvim-rest.parser").parse, lines)
    if not ok then
        return -- a parse crash must never surface as a diagnostic storm
    end
    local diags = spec.validate_document(doc, { buf = bufnr, path = vim.api.nvim_buf_get_name(bufnr) })
    vim.diagnostic.set(NS, bufnr, diags)
end

--- Debounced refresh: coalesce a burst of edits into one validate pass.
---@param bufnr integer
local function debounced(bufnr)
    local ok_cfg, config = pcall(require, "lvim-rest.config")
    local ms = (ok_cfg and config.diagnostics and config.diagnostics.debounce) or 300
    local t = timers[bufnr]
    if not t then
        t = vim.uv.new_timer()
        timers[bufnr] = t
    end
    t:stop()
    t:start(
        math.max(0, ms),
        0,
        vim.schedule_wrap(function()
            refresh(bufnr)
        end)
    )
end

--- Drop a buffer's timer (on detach / wipeout).
---@param bufnr integer
local function drop(bufnr)
    local t = timers[bufnr]
    if t then
        t:stop()
        if not t:is_closing() then
            t:close()
        end
        timers[bufnr] = nil
    end
end

--- Attach live diagnostics to an http/rest buffer. Idempotent per buffer.
---@param bufnr integer
function M.attach(bufnr)
    if vim.b[bufnr].lvim_rest_diag then
        return
    end
    vim.b[bufnr].lvim_rest_diag = true
    local grp = vim.api.nvim_create_augroup("lvim_rest_diag_" .. bufnr, { clear = true })

    -- Live but coalesced while typing.
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = grp,
        buffer = bufnr,
        callback = function()
            debounced(bufnr)
        end,
    })
    -- Calm points: refresh at once.
    vim.api.nvim_create_autocmd({ "InsertLeave", "BufWritePost" }, {
        group = grp,
        buffer = bufnr,
        callback = function()
            refresh(bufnr)
        end,
    })
    -- Tear down with the buffer.
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
        group = grp,
        buffer = bufnr,
        callback = function()
            drop(bufnr)
            vim.diagnostic.reset(NS, bufnr)
        end,
    })

    refresh(bufnr) -- first paint
end

--- Force a refresh now (e.g. the options panel wrote back a change).
---@param bufnr integer
function M.refresh(bufnr)
    refresh(bufnr)
end

return M
