-- lvim-rest.auth: the authentication layer — `# @auth <scheme> [args…]`.
--
-- Five schemes: `none`, `basic`, `bearer`, `apikey` and `oauth2`. The first four are pure string
-- work and resolve instantly; `oauth2` names a profile in the environment file and may have to talk
-- to a token endpoint or open a browser, so the whole layer is ASYNC — the runner awaits it before
-- sending. Making the fast schemes synchronous too would mean two code paths for one concept.
--
-- OAuth2 profiles live in the env file under `Security.Auth.<id>`, the shape the JetBrains HTTP
-- client uses, so a project that already has one needs no second file; the key lookup is normalised
-- so `"Token URL"`, `"token_url"` and `"tokenUrl"` all name the same field.
--
-- A credential in a profile is written `{{vault "key"}}` like anywhere else: the auth layer resolves
-- the profile's values through the ordinary variable engine before using them, so a client secret is
-- never a literal in a file. Acquired tokens follow the same rule — see `auth.oauth2`.
--
-- An `Authorization` header written by hand always wins. The document is the most specific statement
-- of intent there is, and silently overwriting it would make a deliberate override look broken.
--
---@module "lvim-rest.auth"

local config = require("lvim-rest.config")
local env = require("lvim-rest.vars.env")
local vars = require("lvim-rest.vars")
local oauth2 = require("lvim-rest.auth.oauth2")

local M = {}

--- The `Security.Auth` table of the active environment profile, if any.
---@param path string  the .http file
---@return table<string, table>
function M.profiles(path)
    local raw = env.active_raw(path)
    local sec = raw and raw.Security or raw and raw.security
    if type(sec) ~= "table" then
        return {}
    end
    local auth = sec.Auth or sec.auth
    return type(auth) == "table" and auth or {}
end

--- One OAuth2 profile by id, with every `{{…}}` in it already resolved (so a `{{vault "key"}}`
--- client secret is a real secret by the time a grant runs).
---@param path string
---@param id string
---@param ctx LvimRestVarContext?
---@return table?
function M.profile(path, id, ctx)
    local p = M.profiles(path)[id]
    if type(p) ~= "table" then
        return nil
    end
    local out = {}
    for k, v in pairs(p) do
        out[k] = (type(v) == "string" and ctx) and vars.substitute(v, ctx) or v
    end
    return out
end

--- Whether `headers` already carries an Authorization header.
---@param headers LvimRestHeader[]?
---@return boolean
local function has_authorization(headers)
    for _, h in ipairs(headers or {}) do
        if h.name:lower() == "authorization" then
            return true
        end
    end
    return false
end

-- ── the schemes ──────────────────────────────────────────────────────────────

--- Apply the resolved auth directive to `resolved`, then call `cb(ok, err)`.
---
--- The directive's arguments are substituted HERE. `resolve_request` covers the url, headers and
--- body — the parts that go on the wire — and knows nothing about a directive's payload, so the
--- layer that gives those arguments meaning is the one that has to resolve them.
---@param resolved table          the resolved request (mutated in place)
---@param auth { scheme: string, args: string[] }?
---@param path string             the .http file (for the env profiles)
---@param ctx LvimRestVarContext?
---@param cb fun(ok: boolean, err: string?)
---@return nil
function M.apply(resolved, auth, path, ctx, cb)
    if not config.auth.enabled or not auth or not auth.scheme then
        return cb(true)
    end
    local scheme = auth.scheme:lower()
    local args = {}
    for i, a in ipairs(auth.args or {}) do
        args[i] = ctx and vars.substitute(a, ctx) or a
    end

    if scheme == "none" then
        return cb(true)
    end
    -- Every scheme below writes a header, so an explicit one in the document ends it here.
    if has_authorization(resolved.headers) and scheme ~= "apikey" then
        return cb(true)
    end

    if scheme == "basic" then
        local user, pass = args[1] or "", args[2] or ""
        resolved.headers[#resolved.headers + 1] = {
            name = "Authorization",
            value = "Basic " .. vim.base64.encode(("%s:%s"):format(user, pass)),
        }
        return cb(true)
    elseif scheme == "bearer" then
        local token = args[1]
        if not token or token == "" then
            return cb(false, "# @auth bearer needs a token")
        end
        resolved.headers[#resolved.headers + 1] = { name = "Authorization", value = "Bearer " .. token }
        return cb(true)
    elseif scheme == "apikey" then
        -- `# @auth apikey <name> <value> [header|query]` — a key is not always a header, and where
        -- it goes is the server's choice, not ours.
        local name, value, where = args[1], args[2], (args[3] or "header"):lower()
        if not name or not value then
            return cb(false, "# @auth apikey needs a name and a value")
        end
        if where == "query" then
            local sep = resolved.url:find("?", 1, true) and "&" or "?"
            resolved.url = resolved.url .. sep .. name .. "=" .. vim.uri_encode(value, "rfc2396")
        else
            resolved.headers[#resolved.headers + 1] = { name = name, value = value }
        end
        return cb(true)
    elseif scheme == "oauth2" then
        local id = args[1]
        if not id or id == "" then
            return cb(false, "# @auth oauth2 needs a profile id from the env file's Security.Auth")
        end
        local profile = M.profile(path, id, ctx)
        if not profile then
            return cb(false, ("no auth profile %q in the active environment's Security.Auth"):format(id))
        end
        return oauth2.token(id, profile, function(token, err)
            if not token then
                return cb(false, err or "could not obtain a token")
            end
            resolved.headers[#resolved.headers + 1] = {
                name = "Authorization",
                value = ("%s %s"):format(token.token_type or "Bearer", token.access_token),
            }
            cb(true)
        end)
    end
    cb(false, ("unknown auth scheme %q"):format(scheme))
end

--- Drop cached OAuth2 tokens (one profile, or all).
---@param id string?
---@return integer
function M.forget(id)
    return oauth2.forget(id)
end

return M
