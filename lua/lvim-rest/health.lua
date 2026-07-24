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
    else
        h.warn("sqlite.lua not found — history + the request library are disabled (install kkharji/sqlite.lua)")
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
