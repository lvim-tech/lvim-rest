-- lvim-rest: a kulala-parity `.http` client + a Postman-class API workbench, over one runner and
-- one variable engine, with its own native Rust daemon (`lvim-rest-core`) as the primary execution
-- engine and a pure-curl HTTP/GraphQL fallback.
--
-- This module IS the public API + entry point. `setup()` merges user opts into the live config,
-- self-themes, registers the `:LvimRest` command, and installs the buffer-local keymaps for
-- `http`/`rest` buffers (every map configurable). The heavy lifting lives in the submodules:
-- parser (the execution parser), vars (resolution), backend (curl / daemon), runner (send/replay/
-- cancel), ui.dock / ui.inline (response), history, format.
--
---@module "lvim-rest"

local config = require("lvim-rest.config")
local utils = require("lvim-utils.utils")

local M = {}

---@type boolean one-time registration guard
local registered = false

-- The filetypes the plugin owns (buffer-local maps + send flow attach here).
local FILETYPES = { "http", "rest" }

--- Self-theme: install the ColorScheme autocmd + bind the highlight factory.
local function set_highlights()
    local hl = require("lvim-utils.highlight")
    hl.setup()
    hl.bind(require("lvim-rest.highlights").build)
end

-- ── request navigation (buffer-local) ───────────────────────────────────────

--- Jump to the next / previous request line in the current buffer.
---@param dir 1|-1
local function jump_request(dir)
    local bufnr = vim.api.nvim_get_current_buf()
    local doc = require("lvim-rest.parser").parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local target
    if dir == 1 then
        for _, r in ipairs(doc.requests) do
            if r.line > cur then
                target = r.line
                break
            end
        end
    else
        for i = #doc.requests, 1, -1 do
            if doc.requests[i].line < cur then
                target = doc.requests[i].line
                break
            end
        end
    end
    if target then
        vim.api.nvim_win_set_cursor(0, { target, 0 })
    end
end

--- Install the buffer-local maps on an http/rest buffer.
---@param bufnr integer
local function attach_buffer(bufnr)
    local k = config.keys
    local function map(lhs, fn, desc)
        if lhs and lhs ~= "" then
            vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, desc = "lvim-rest: " .. desc })
        end
    end
    local runner = require("lvim-rest.runner")
    map(k.send, function()
        runner.send(bufnr, vim.api.nvim_win_get_cursor(0)[1])
    end, "send request")
    map(k.send_all, function()
        runner.send_all(bufnr)
    end, "send all")
    map(k.replay, function()
        runner.replay()
    end, "replay last")
    map(k.cancel, function()
        runner.cancel()
    end, "cancel")
    map(k.inspect, function()
        require("lvim-rest.ui.inspect").show(bufnr, vim.api.nvim_win_get_cursor(0)[1])
    end, "inspect resolved request")
    map(k.jump_next, function()
        jump_request(1)
    end, "next request")
    map(k.jump_prev, function()
        jump_request(-1)
    end, "prev request")
end

-- ── :LvimRest command ───────────────────────────────────────────────────────

--- The subcommand table: name → handler(arg).
---@type table<string, fun(arg: string?)>
local subcommands = {
    send = function()
        require("lvim-rest.runner").send(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1])
    end,
    all = function()
        require("lvim-rest.runner").send_all(vim.api.nvim_get_current_buf())
    end,
    replay = function()
        require("lvim-rest.runner").replay()
    end,
    cancel = function()
        require("lvim-rest.runner").cancel()
    end,
    inspect = function()
        require("lvim-rest.ui.inspect").show(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1])
    end,
    history = function()
        require("lvim-rest.history").pick()
    end,
    close = function()
        require("lvim-rest.ui.dock").close()
    end,
    env = function(arg)
        local buf = vim.api.nvim_get_current_buf()
        local path = vim.api.nvim_buf_get_name(buf)
        local env = require("lvim-rest.vars.env")
        if arg and arg ~= "" then
            env.set_active(path, arg)
            vim.notify("lvim-rest: env → " .. arg, vim.log.levels.INFO)
            return
        end
        local names = env.names(path)
        if #names == 0 then
            vim.notify("lvim-rest: no env files found (http-client.env.json)", vim.log.levels.INFO)
            return
        end
        local current = env.active_name(path)
        local items, current_item = {}, nil
        for _, n in ipairs(names) do
            local item = { label = n, icon = config.icons.env, name = n }
            items[#items + 1] = item
            if n == current then
                current_item = item
            end
        end
        require("lvim-ui").select({
            title = "Environment",
            items = items,
            current_item = current_item,
            callback = function(confirmed, index)
                if not confirmed then
                    return
                end
                env.set_active(path, items[index].name)
                vim.notify("lvim-rest: env → " .. items[index].name, vim.log.levels.INFO)
            end,
        })
    end,
    import = function(arg)
        require("lvim-rest.convert").import(arg)
    end,
    export = function()
        require("lvim-rest.convert").export()
    end,
    scratch = function()
        local path = vim.fn.stdpath("state") .. "/lvim-rest"
        vim.fn.mkdir(path, "p")
        vim.cmd("edit " .. vim.fn.fnameescape(path .. "/scratch.http"))
    end,
    next = function()
        jump_request(1)
    end,
    prev = function()
        jump_request(-1)
    end,
}

--- Register the `:LvimRest` command (once).
local function register_command()
    vim.api.nvim_create_user_command("LvimRest", function(cmd)
        local sub = cmd.fargs[1]
        local arg = cmd.fargs[2]
        if not sub then
            vim.notify(
                ("lvim-rest: engine=%s  in-flight=%d  (subcommands: %s)"):format(
                    require("lvim-rest.backend").select(),
                    require("lvim-rest.runner").inflight_count(),
                    table.concat(vim.tbl_keys(subcommands), " ")
                ),
                vim.log.levels.INFO
            )
            return
        end
        local handler = subcommands[sub]
        if handler then
            handler(arg)
        else
            vim.notify("lvim-rest: unknown subcommand '" .. sub .. "'", vim.log.levels.WARN)
        end
    end, {
        nargs = "*",
        complete = function(arglead)
            return vim.tbl_filter(function(c)
                return c:find(arglead, 1, true) == 1
            end, vim.tbl_keys(subcommands))
        end,
        desc = "lvim-rest: send / all / replay / cancel / inspect / history / scratch / close",
    })
end

--- Configure and start lvim-rest. Idempotent — re-merges config + re-themes; the command / autocmds
--- are registered once.
---@param opts LvimRestConfig?
function M.setup(opts)
    utils.merge(config, opts or {})
    set_highlights()
    if registered then
        return
    end
    registered = true

    register_command()

    local grp = vim.api.nvim_create_augroup("lvim_rest", { clear = true })
    -- Attach the buffer-local maps whenever an http/rest buffer gets its filetype.
    vim.api.nvim_create_autocmd("FileType", {
        group = grp,
        pattern = FILETYPES,
        callback = function(ev)
            attach_buffer(ev.buf)
        end,
    })
    -- Clean up the inline status lanes when a buffer is wiped.
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = grp,
        pattern = { "*.http", "*.rest" },
        callback = function(ev)
            require("lvim-rest.ui.inline").clear_all(ev.buf)
        end,
    })

    -- NOTE: the `http` / `graphql` treesitter grammars are for HIGHLIGHTING only (the execution
    -- parser never depends on them). lvim-ts has no runtime grammar-add API, so a user who wants the
    -- highlight adds `"http"` / `"graphql"` to lvim-ts `ensure_installed` (documented in the README +
    -- reported by `:checkhealth lvim-rest`).
end

return M
