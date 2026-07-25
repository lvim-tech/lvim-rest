-- lvim-rest.backend: execution-engine selection + lifecycle.
--
-- Two engines behind one `run` seam: the native Rust daemon `lvim-rest-core` (all four protocols;
-- wired in phase 2 via backend/rpc.lua) and the pure-curl HTTP/GraphQL fallback (backend/curl.lua).
-- `backend = "auto"` prefers the daemon when it is built, else curl for HTTP with a one-time notice;
-- `"daemon"` requires the daemon; `"curl"` forces the fallback. gRPC/WebSocket/HTTP-3 are
-- daemon-only — the fallback rejects them with a clear error rather than pretending.
--
---@module "lvim-rest.backend"

local config = require("lvim-rest.config")
local curl = require("lvim-rest.backend.curl")

local M = {}

-- Protocols the curl fallback cannot do (daemon-only).
local DAEMON_ONLY = { GRPC = true, WEBSOCKET = true }

---@type boolean one-shot guard for the "daemon not built, using curl" notice
local warned_fallback = false

--- Whether the daemon RPC client is present and its binary is built. (Purely "is it there" — health
--- reports this; whether it may be USED also depends on `daemon.autostart`.)
---@return boolean
function M.daemon_available()
    local ok, rpc = pcall(require, "lvim-rest.backend.rpc")
    return ok and rpc.binary_path and rpc.binary_path() ~= nil
end

--- The engine that WILL run a request of `method`: "daemon" or "curl".
---@param method string?
---@return "daemon"|"curl"
function M.select(method)
    if config.backend == "curl" then
        return "curl"
    end
    if config.backend == "daemon" then
        return "daemon"
    end
    -- auto: the daemon only when it exists AND may be spawned. With `autostart = false` the user
    -- asked for no background process, so HTTP goes to curl rather than failing.
    if M.daemon_available() and config.daemon.autostart then
        return "daemon"
    end
    return "curl"
end

--- Execute a resolved request on the selected engine. `cb(result)` receives the response table
--- (`{ error = … }` on failure). Returns a handle with `:kill()`.
---@param resolved LvimRestResolvedRequest
---@param cb fun(result: table)
---@return { kill: fun() }
function M.run(resolved, cb)
    local engine = M.select(resolved.method)

    if engine == "daemon" then
        local ok, rpc = pcall(require, "lvim-rest.backend.rpc")
        if ok and rpc.run then
            return rpc.run(resolved, cb)
        end
        -- Configured for the daemon but the client is missing: fail loudly (never silently curl).
        if config.backend == "daemon" then
            vim.schedule(function()
                cb({ error = "lvim-rest-core daemon not available (build it via lvim-installer)" })
            end)
            return { kill = function() end }
        end
    end

    -- curl fallback.
    if DAEMON_ONLY[resolved.method] then
        vim.schedule(function()
            cb({
                error = resolved.method
                    .. " requires the lvim-rest-core daemon (the curl fallback is HTTP/GraphQL only)",
            })
        end)
        return { kill = function() end }
    end
    if not curl.available() then
        vim.schedule(function()
            cb({ error = "curl not found on PATH" })
        end)
        return { kill = function() end }
    end
    if config.backend == "auto" and not warned_fallback and not M.daemon_available() then
        warned_fallback = true
        vim.schedule(function()
            vim.notify(
                "lvim-rest: lvim-rest-core daemon not built — using the curl fallback (HTTP/GraphQL only). "
                    .. "Build the daemon for gRPC/WebSocket/HTTP-3.",
                vim.log.levels.INFO
            )
        end)
    end
    return curl.run(resolved, cb)
end

return M
