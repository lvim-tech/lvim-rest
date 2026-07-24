-- lvim-rest.vars.vault: the `{{vault "…"}}` verb + secret detection for save-into-library.
--
-- Every long-lived secret is vaulted through lvim-keyring — NEVER stored plaintext in the sqlite
-- library. `resolve` reads a vault entry (sync, no prompt) for substitution; `detect_secrets` scans
-- a request for secret-shaped fields (Authorization / Cookie / password|token|secret|apikey values,
-- Basic-auth creds) so the save flow (phase 5) can offer to move each into the wallet, rewriting the
-- stored value to a `{{vault "…"}}` reference. When lvim-keyring is absent, vaulting is unavailable
-- and the save flow refuses to persist a secret inline (never a silent plaintext write).
--
---@module "lvim-rest.vars.vault"

local config = require("lvim-rest.config")

local M = {}

-- All lvim-rest vault entries live under this namespace in the wallet.
local NAMESPACE = "rest"

--- The wallet key for a bare name (namespaced so a `{{vault "rest/x"}}` verb resolves the same).
---@param name string
---@return string
function M.key(name)
    if name:match("^" .. NAMESPACE .. "/") then
        return name
    end
    return NAMESPACE .. "/" .. name
end

--- Whether lvim-keyring is available.
---@return boolean
function M.available()
    return (pcall(require, "lvim-keyring"))
end

--- Resolve a `{{vault "key"}}` reference (sync, no prompt). nil when vaulting is disabled, keyring
--- is absent, or the wallet is locked (the caller then keeps the token verbatim).
---@param key string
---@return string?
function M.resolve(key)
    if not config.vault.enabled then
        return nil
    end
    local ok, kr = pcall(require, "lvim-keyring")
    if not ok or type(kr.get_sync) ~= "function" then
        return nil
    end
    local val = kr.get_sync(M.key(key), 3000)
    return val
end

--- Store a secret in the wallet under the rest namespace. `cb(ok, err)`.
---@param name string
---@param value string
---@param cb fun(ok: boolean, err: string?)?
function M.store(name, value, cb)
    cb = cb or function() end
    local ok, kr = pcall(require, "lvim-keyring")
    if not ok then
        cb(false, "lvim-keyring not available")
        return
    end
    kr.set(M.key(name), value, { url = "lvim-rest" }, cb)
end

--- Whether a header name is secret-shaped.
---@param name string
---@return boolean
local function secret_header(name)
    local n = name:lower()
    return n == "authorization" or n == "cookie" or n:match("api%-?key") ~= nil or n:match("token") ~= nil
end

--- Whether a variable name looks like it holds a secret.
---@param name string
---@return boolean
function M.secret_var(name)
    local n = name:lower()
    return n:match("password") ~= nil
        or n:match("secret") ~= nil
        or n:match("token") ~= nil
        or n:match("apikey") ~= nil
        or n:match("api_key") ~= nil
        or n:match("client_secret") ~= nil
end

--- Whether a value is already a vault reference (must not be re-vaulted).
---@param value string
---@return boolean
local function is_vault_ref(value)
    return value:match("{{%s*vault") ~= nil
end

--- Detect secret-shaped fields in a parsed request (for save-into-library vaulting).
--- Returns a list of `{ field, name, value }` where `field` is the stored column context.
---@param req LvimRestRequest
---@return { field: string, name: string, value: string }[]
function M.detect_secrets(req)
    local hits = {}
    for _, h in ipairs(req.headers or {}) do
        if secret_header(h.name) and not is_vault_ref(h.value) and h.value ~= "" then
            hits[#hits + 1] = { field = "header", name = h.name, value = h.value }
        end
    end
    for _, v in ipairs(req.vars or {}) do
        if M.secret_var(v.name) and not is_vault_ref(v.value) and v.value ~= "" then
            hits[#hits + 1] = { field = "var", name = v.name, value = v.value }
        end
    end
    return hits
end

return M
