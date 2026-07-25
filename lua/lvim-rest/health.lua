-- lvim-rest.health: the `:checkhealth lvim-rest` report.
--
-- Reports the execution engine (daemon presence/version + installer hint; the curl fallback is
-- mandatory only for `backend = "curl"` / an unbuilt daemon under `"auto"`), the optional tools
-- (jq / xmllint) with a per-feature impact line, the sqlite request-library DB, lvim-keyring (all
-- secrets are vaulted — effectively required), the lvim-ts `http` grammar (highlight only), and the
-- optional lvim-cmp variable source.
--
---@module "lvim-rest.health"

local config = require("lvim-rest.config")

local M = {}

--- Whether a treesitter parser for `lang` is installed.
---@param lang string
---@return boolean
local function has_parser(lang)
    local ok, has = pcall(function()
        return vim.treesitter.language.add and vim.treesitter.language.add(lang) or vim.treesitter.get_string_parser
    end)
    if not ok then
        return false
    end
    -- The reliable check: a parser file exists on the runtimepath.
    return #vim.api.nvim_get_runtime_file("parser/" .. lang .. ".*", true) > 0
end

--- Run the health report.
function M.check()
    local h = vim.health
    h.start("lvim-rest")

    -- Backend engine.
    local engine = require("lvim-rest.backend").select()
    local daemon_available = require("lvim-rest.backend").daemon_available()
    if daemon_available then
        h.ok("lvim-rest-core daemon: found")
    elseif config.backend == "daemon" then
        h.error("backend = 'daemon' but lvim-rest-core is not built — build it via lvim-installer")
    else
        h.info("lvim-rest-core daemon: not built (build via lvim-installer for gRPC/WebSocket/HTTP-3)")
    end
    -- `autostart = false` is the reason a BUILT daemon still never runs; without this line that
    -- looks like the daemon is broken.
    if not config.daemon.autostart then
        h.warn(
            "daemon.autostart = false — the daemon is never spawned (HTTP/GraphQL use curl; gRPC/WebSocket cannot run)"
        )
    elseif daemon_available then
        local rpc = require("lvim-rest.backend.rpc")
        h.info(
            ("daemon: %s%s"):format(
                rpc.is_running() and "running" or "not started yet (spawned on first use)",
                (config.daemon.idle_timeout or 0) > 0
                        and (", idle-stopped after %ds"):format(math.floor(config.daemon.idle_timeout / 1000))
                    or ", never idle-stopped"
            )
        )
    end

    -- curl fallback.
    local curl_ok = vim.fn.executable("curl") == 1
    if curl_ok then
        h.ok("curl: found (HTTP/GraphQL fallback engine)")
    elseif engine == "curl" then
        h.error("curl not found — the fallback engine cannot run (install curl, or build the daemon)")
    else
        h.warn("curl not found — the HTTP/GraphQL fallback is unavailable")
    end
    h.info("active engine for HTTP: " .. engine)

    -- Optional formatting tools.
    if vim.fn.executable(config.format.jq_bin) == 1 then
        h.ok("jq: found (JSON pretty-print + @jq / jq-filter view)")
    else
        h.info("jq not found — JSON still pretty-prints via the built-in encoder, but the jq filter is disabled")
    end
    if vim.fn.executable(config.format.xmllint_bin) == 1 then
        h.ok("xmllint: found (XML pretty-print)")
    else
        h.info("xmllint not found — XML responses show raw (no reformat)")
    end

    -- The request library DB.
    if require("lvim-rest.store").available() then
        h.ok(("sqlite.lua: found (request library + history, schema v%d)"):format(require("lvim-rest.store").version()))
        -- What is actually IN the library — an empty one is the usual reason `:LvimRest run` says
        -- there is nothing to run.
        local ok_lib, lib = pcall(require, "lvim-rest.store.library")
        if ok_lib then
            local ws = lib.active_workspace()
            if ws then
                local cols = lib.collections(ws.id)
                local n = 0
                for _, c in ipairs(cols) do
                    n = n + #require("lvim-rest.runner.iterate").plan(c.id)
                end
                h.info(("library: workspace %q, %d collection(s), %d request(s)"):format(ws.name, #cols, n))
            else
                h.info("library: empty (a workspace is created on first use)")
            end
        end
    else
        h.warn("sqlite.lua not found — history + the request library are disabled (install kkharji/sqlite.lua)")
    end

    -- Daemon-only protocols: saying "gRPC needs the daemon" HERE is cheaper than finding out at
    -- send time, since a curl-only install can still do everything else.
    if not daemon_available then
        h.info("gRPC + WebSocket: unavailable (they need the daemon — curl can do neither)")
    else
        h.ok("gRPC + WebSocket: available (dynamic protobuf via reflection or a .proto)")
    end

    -- OAuth2 profiles of the ACTIVE environment, and whether a token is held.
    if config.auth.enabled then
        local ok_auth, auth = pcall(require, "lvim-rest.auth")
        -- The CWD, not the current buffer: `:checkhealth` runs in its own buffer, so asking about
        -- "this file" would always look next to the health window instead of next to the project.
        local profiles = ok_auth and auth.profiles(vim.fn.getcwd()) or {}
        local n = vim.tbl_count(profiles)
        if n > 0 then
            local o2 = require("lvim-rest.auth.oauth2")
            local held = 0
            for id in pairs(profiles) do
                if o2.fresh(o2.cached(id)) then
                    held = held + 1
                end
            end
            h.info(("auth: %d OAuth2 profile(s) in the active environment, %d with a live token"):format(n, held))
        else
            h.info("auth: no Security.Auth profiles in the active environment (the other schemes need none)")
        end
    else
        h.info("auth: disabled (auth.enabled = false)")
    end

    -- The cookie jar (a stale jar is a common reason a request is unexpectedly authenticated).
    if config.cookies.enabled then
        local ok_ck, jar = pcall(require, "lvim-rest.cookies")
        h.info(("cookie jar: enabled, %d cookie(s)"):format(ok_ck and #jar.list() or 0))
    else
        h.info("cookie jar: disabled (cookies.enabled = false)")
    end

    -- lvim-keyring (secret vaulting).
    local kr_ok = pcall(require, "lvim-keyring")
    if kr_ok then
        h.ok('lvim-keyring: found ({{vault "…"}} resolution + secret vaulting on save)')
    elseif config.vault.enabled then
        h.warn("lvim-keyring not found — secrets cannot be vaulted; secret-bearing requests will not persist secrets")
    else
        h.info("lvim-keyring not found — vaulting is disabled in config")
    end

    -- Treesitter http grammar (highlight only).
    if has_parser("http") then
        h.ok("treesitter 'http' grammar: installed (syntax highlight for .http/.rest)")
    else
        h.info("treesitter 'http' grammar not installed — add \"http\" to lvim-ts ensure_installed for highlight")
    end

    -- lvim-cmp variable source (enhancement).
    if pcall(require, "lvim-cmp") then
        h.ok("lvim-cmp: found (the .http variable completion source can register)")
    else
        h.info("lvim-cmp not found — the variable completion source is disabled (optional)")
    end
end

return M
