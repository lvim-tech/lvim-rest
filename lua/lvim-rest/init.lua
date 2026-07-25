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
    map(k.save, function()
        -- A LIBRARY-bound buffer is a nameless `nofile` scratch (no `:w`); saving re-parses it back onto its
        -- row. A loose `.http` file on disk keeps the ordinary `:w` semantics.
        local bind = require("lvim-rest.store.bind")
        if bind.request_of(bufnr) then
            bind.write_back(bufnr)
        else
            vim.cmd.write()
        end
    end, "save request")
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
    map(k.save_into, function()
        require("lvim-rest.convert").save_into_collection(bufnr, vim.api.nvim_win_get_cursor(0)[1])
    end, "save into a collection")
    map(k.options, function()
        require("lvim-rest.ui.options").open(bufnr, vim.api.nvim_win_get_cursor(0)[1])
    end, "request options form")
    map(k.explorer, function()
        local wb = require("lvim-rest.ui.workbench")
        wb.open()
        wb.focus_library()
    end, "the library tree")
    map(k.run_collection, function()
        require("lvim-rest.convert").pick_collection("Run which collection?", function(cid)
            require("lvim-rest.runner.iterate").run({ collection_id = cid })
        end)
    end, "run a collection")
end

-- ── :LvimRest command ───────────────────────────────────────────────────────

--- The subcommand table: name → handler(arg).
---@type table<string, fun(arg: string?, rest: string?)>
-- Bare `:LvimRest` OPENS the client (see the command handler); these are the explicit subcommands.
local subcommands = {
    -- Toggle the workbench response dock between spanning UNDER THE EDITOR only (tree full-height) and
    -- FULL width under tree+editor (the lvim-db shape). Workbench-only.
    dock = function()
        require("lvim-rest.ui.dock").toggle_layout()
    end,
    -- Run a whole collection. `arg` is an optional data file (json array / csv with a header) —
    -- one pass per row, its values entering the top-priority `data` variable scope.
    run = function(arg)
        local lib = require("lvim-rest.store.library")
        local ws = lib.active_workspace()
        local first = ws and lib.collections(ws.id)[1]
        if not first then
            return vim.notify("lvim-rest: no collection to run", vim.log.levels.WARN)
        end
        require("lvim-rest.runner.iterate").run({ collection_id = first.id, data_file = arg })
    end,
    -- `cookies` lists the jar; `cookies clear [text]` drops all of them, or those whose domain
    -- contains `text`.
    cookies = function(arg)
        local jar = require("lvim-rest.cookies")
        if arg == "clear" then
            return vim.notify(("lvim-rest: dropped %d cookie(s)"):format(jar.clear()), vim.log.levels.INFO)
        end
        local rows = jar.list()
        if #rows == 0 then
            return vim.notify("lvim-rest: the cookie jar is empty", vim.log.levels.INFO)
        end
        local items = {}
        for _, c in ipairs(rows) do
            items[#items + 1] = {
                label = ("%s%s  %s"):format(c.domain, c.path ~= "/" and c.path or "", c.name),
                icon = config.icons.env,
                _c = c,
            }
        end
        require("lvim-ui").select({
            title = "Cookies",
            items = items,
            callback = function(confirmed, index)
                if not confirmed or not index then
                    return
                end
                local c = items[index]._c
                jar.clear(c.domain)
                vim.notify(("lvim-rest: dropped the cookies for %s"):format(c.domain), vim.log.levels.INFO)
            end,
        })
    end,
    -- `grpc <endpoint>` lists a server's services and methods (through its reflection service, or
    -- through a `# @grpc-proto` in the current buffer's request when it names one).
    grpc = function(_, rest)
        local url = rest
        if not url or url == "" then
            -- Default to the endpoint of the request under the cursor: listing a server you are
            -- already writing against should not need it typed again.
            local buf = vim.api.nvim_get_current_buf()
            local doc = require("lvim-rest.parser").parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
            local req = require("lvim-rest.parser").request_at(doc, vim.api.nvim_win_get_cursor(0)[1])
            url = req and req.url or ""
        end
        if url == "" then
            return vim.notify("lvim-rest: :LvimRest grpc <host:port>", vim.log.levels.WARN)
        end
        local endpoint = url:gsub("^%a[%w+.-]*://", ""):match("^([^/]+)") or url
        require("lvim-rest.backend.rpc").request("grpc.list", { url = endpoint, methods = true }, function(res, err)
            if err then
                return vim.notify("lvim-rest: " .. err, vim.log.levels.ERROR)
            end
            local items = {}
            for _, svc in ipairs(res.services or {}) do
                for _, m in ipairs((res.methods or {})[svc] or {}) do
                    items[#items + 1] = { label = ("%s/%s"):format(svc, m), icon = config.icons.grpc }
                end
            end
            if #items == 0 then
                return vim.notify("lvim-rest: the server advertises no methods", vim.log.levels.INFO)
            end
            require("lvim-ui").select({
                title = "gRPC — " .. endpoint,
                items = items,
                -- Choosing one writes the request skeleton at the cursor: the point of listing
                -- is to then call it, and retyping a fully-qualified method is where typos live.
                callback = function(confirmed, index)
                    if not confirmed or not index then
                        return
                    end
                    local lines = {
                        "### " .. items[index].label,
                        ("GRPC %s/%s"):format(endpoint, items[index].label),
                        "",
                        "{}",
                    }
                    vim.api.nvim_put(lines, "l", true, true)
                end,
            })
        end)
    end,
    -- `ws <text>` sends a frame on the current session; `ws close` closes it; bare `ws` lists them.
    ws = function(arg, rest)
        local sock = require("lvim-rest.ws")
        if arg == "close" then
            return sock.close()
        end
        if rest and rest ~= "" then
            sock.send(rest)
            return
        end
        local rows = sock.list()
        if #rows == 0 then
            return vim.notify("lvim-rest: no websocket sessions", vim.log.levels.INFO)
        end
        local items = {}
        for _, s in ipairs(rows) do
            items[#items + 1] = {
                label = ("%s  %s  (%d msg)"):format(s.open and "open" or "closed", s.url, #s.messages),
                icon = config.icons.ws,
                _id = s.id,
            }
        end
        require("lvim-ui").select({
            title = "WebSocket sessions",
            items = items,
            callback = function(confirmed, index)
                if confirmed and index then
                    sock.focus(items[index]._id)
                    require("lvim-rest.ui.dock").show(sock.result(), { title = items[index].label })
                end
            end,
        })
    end,
    -- OAuth2 tokens: `auth` shows what is cached, `auth clear` forgets it.
    auth = function(arg)
        local a = require("lvim-rest.auth")
        if arg == "clear" then
            return vim.notify(("lvim-rest: forgot %d cached token(s)"):format(a.forget()), vim.log.levels.INFO)
        end
        local path = vim.api.nvim_buf_get_name(0)
        local profiles = a.profiles(path)
        local o2 = require("lvim-rest.auth.oauth2")
        local lines = {}
        for id, p in pairs(profiles) do
            local t = o2.cached(id)
            lines[#lines + 1] = ("%s (%s): %s"):format(
                id,
                o2.grant_of(p),
                t and (o2.fresh(t) and "token cached" or "token expired") or "no token"
            )
        end
        vim.notify(
            #lines > 0 and ("lvim-rest auth:\n" .. table.concat(lines, "\n"))
                or "lvim-rest: no Security.Auth profiles in the active environment",
            vim.log.levels.INFO
        )
    end,
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
    -- The request OPTIONS form (params / headers / directives) over the request under the cursor.
    -- `arg` is an optional layout token, per the panel canon.
    options = function(arg)
        local layout = (arg == "float" or arg == "area" or arg == "bottom") and arg or nil
        require("lvim-rest.ui.options").open(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1], layout)
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
    save = function()
        require("lvim-rest.convert").save_into_collection()
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
        -- Everything after the subcommand, verbatim: a websocket frame or a jq filter is text with
        -- spaces in it, and `fargs[2]` would silently keep only the first word.
        local rest = sub and vim.trim((cmd.args or ""):sub(#sub + 1)) or ""
        if not sub then
            -- Bare `:LvimRest` OPENS the client (like `:LvimDb`) — the common case deserves the short verb.
            local wb = require("lvim-rest.ui.workbench")
            wb.open()
            wb.focus_library()
            return
        end
        local handler = subcommands[sub]
        if handler then
            handler(arg, rest)
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

    -- The library panel is a PERSISTENT side panel, so its filetype goes in `panel_ft`: the cursor is
    -- hidden only while the panel is the CURRENT window, never globally — the code beside it keeps
    -- its cursor. Self-registration, so installing the plugin needs no edit to any central config.
    pcall(function()
        require("lvim-utils.cursor").register({ panel_ft = { "LvimRestLibrary" } })
    end)

    -- A `Set-Cookie` with no expiry asked to live for the session; an editor session is that session.
    if config.cookies.enabled then
        require("lvim-rest.cookies").drop_session_cookies()
    end

    local grp = vim.api.nvim_create_augroup("lvim_rest", { clear = true })
    -- Attach the buffer-local maps whenever an http/rest buffer gets its filetype.
    vim.api.nvim_create_autocmd("FileType", {
        group = grp,
        pattern = FILETYPES,
        callback = function(ev)
            attach_buffer(ev.buf)
            require("lvim-rest.spec.diagnostics").attach(ev.buf) -- live structural validation
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

    -- Register the lvim-cmp completion source (directives / auth schemes / methods / enum values from
    -- the shared spec). No-op when lvim-cmp is absent.
    require("lvim-rest.cmp").setup()

    -- NOTE: the `http` / `graphql` treesitter grammars are for HIGHLIGHTING only (the execution
    -- parser never depends on them). lvim-ts has no runtime grammar-add API, so a user who wants the
    -- highlight adds `"http"` / `"graphql"` to lvim-ts `ensure_installed` (documented in the README +
    -- reported by `:checkhealth lvim-rest`).
end

return M
