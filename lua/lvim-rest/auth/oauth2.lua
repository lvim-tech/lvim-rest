-- lvim-rest.auth.oauth2: OAuth 2.0 token acquisition, caching and refresh.
--
-- Four grants: `client_credentials`, `password`, `refresh_token`, and `authorization_code` — the
-- last with PKCE (RFC 7636), which needs a browser and a one-shot LOOPBACK listener to catch the
-- redirect. The listener is a raw `vim.uv` TCP server that answers exactly one request and closes:
-- an editor must not leave a port open a second longer than the handshake needs.
--
-- TOKENS ARE SECRETS, so they follow the plugin's rule — never the database. They live in a
-- session-scoped in-memory cache, and, when lvim-keyring is available, ALSO in the wallet so they
-- survive a restart. The sqlite side holds only the metadata a cache needs to reason about a token
-- it cannot see: which profile, which scope, when it expires. Losing that is harmless; leaking the
-- token would not be.
--
-- A cached token is used until it is within `config.auth.oauth2.leeway` seconds of expiry, then a
-- `refresh_token` grant is tried, and only if that fails is the original grant re-run. Anything else
-- would either send a token the server is about to reject or re-authorise on every request.
--
---@module "lvim-rest.auth.oauth2"

local uv = vim.uv or vim.loop
local config = require("lvim-rest.config")
local store = require("lvim-rest.store")
local vault = require("lvim-rest.vars.vault")

local M = {}

---@class LvimRestToken
---@field access_token  string
---@field refresh_token string?
---@field expires_at    integer?  epoch seconds (nil = no expiry known)
---@field token_type    string?

---@type table<string, LvimRestToken>  profile id → the token held for this session
local cache = {}

--- Notify through the plugin's prefix.
---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-rest: " .. msg, level or vim.log.levels.INFO)
end

-- ── profile fields ───────────────────────────────────────────────────────────

-- The IntelliJ / JetBrains HTTP-client env files people already have write these keys with spaces
-- and capitals (`"Token URL"`); ours are snake_case. Both name the same thing, so lookup is
-- normalised rather than duplicated.
---@param profile table
---@param name string  the snake_case field name
---@return any
local function field(profile, name)
    local want = name:gsub("_", ""):lower()
    for k, v in pairs(profile) do
        if type(k) == "string" and k:gsub("[%s_%-]", ""):lower() == want then
            return v
        end
    end
    return nil
end

M.field = field

--- The grant type, normalised (`authorization_code`, `client_credentials`, `password`, `implicit`).
---@param profile table
---@return string
function M.grant_of(profile)
    local g = field(profile, "grant_type") or "client_credentials"
    return tostring(g):gsub("[%s%-]", "_"):lower()
end

-- ── the token cache ──────────────────────────────────────────────────────────

--- The keyring key a profile's tokens live under.
---@param id string
---@param kind "access"|"refresh"
---@return string
local function vault_key(id, kind)
    return ("lvim-rest/oauth2/%s/%s"):format(id, kind)
end

--- Persist a token: the wallet holds the secret, sqlite only the metadata.
---@param id string
---@param token LvimRestToken
local function persist(id, token)
    cache[id] = token
    local d = store.get()
    if d then
        d:remove("auth_token", { profile = id })
        d:insert("auth_token", {
            profile = id,
            expires_at = token.expires_at or 0,
            token_type = token.token_type or "Bearer",
            has_refresh = token.refresh_token and 1 or 0,
        })
    end
    if vault.available() then
        vault.store(vault_key(id, "access"), token.access_token, function() end)
        if token.refresh_token then
            vault.store(vault_key(id, "refresh"), token.refresh_token, function() end)
        end
    end
end

--- The cached token for `id` — from this session, or rebuilt from the wallet + metadata after a
--- restart. Returns nil when there is nothing usable.
---@param id string
---@return LvimRestToken?
function M.cached(id)
    if cache[id] then
        return cache[id]
    end
    local d = store.get()
    if not d or not vault.available() then
        return nil
    end
    local rows = d:find("auth_token", { profile = id })
    local row = type(rows) == "table" and rows[1] or nil
    if not row then
        return nil
    end
    local access = vault.resolve(vault_key(id, "access"))
    if not access or access == "" then
        return nil
    end
    local token = {
        access_token = access,
        refresh_token = row.has_refresh == 1 and vault.resolve(vault_key(id, "refresh")) or nil,
        expires_at = (row.expires_at and row.expires_at > 0) and row.expires_at or nil,
        token_type = row.token_type,
    }
    cache[id] = token
    return token
end

--- Is a token still usable, allowing for the configured leeway?
---@param token LvimRestToken?
---@return boolean
function M.fresh(token)
    if not token or not token.access_token or token.access_token == "" then
        return false
    end
    if not token.expires_at then
        return true -- no expiry given: the server will say if it disagrees
    end
    return token.expires_at - (config.auth.oauth2.leeway or 60) > os.time()
end

--- Forget tokens: one profile, or every profile.
---@param id string?
---@return integer removed
function M.forget(id)
    local n = 0
    for k in pairs(cache) do
        if not id or k == id then
            cache[k] = nil
            n = n + 1
        end
    end
    local d = store.get()
    if d then
        if id then
            d:remove("auth_token", { profile = id })
        else
            for _, row in ipairs(type(d:find("auth_token", {})) == "table" and d:find("auth_token", {}) or {}) do
                d:remove("auth_token", { id = row.id })
            end
        end
    end
    return n
end

-- ── the token endpoint ───────────────────────────────────────────────────────

--- POST a form to the token endpoint and hand back the parsed token.
---
--- It goes through the plugin's own BACKEND rather than a bare curl call, so a token request obeys
--- the same timeout, proxy, TLS and engine choice as every other request the plugin makes.
---@param profile table
---@param form table<string, string>
---@param cb fun(token: LvimRestToken?, err: string?)
local function token_request(profile, form, cb)
    local url = field(profile, "token_url")
    if not url or url == "" then
        return cb(nil, "the auth profile has no Token URL")
    end
    local body = {}
    for k, v in pairs(form) do
        if v ~= nil and v ~= "" then
            body[#body + 1] = ("%s=%s"):format(k, vim.uri_encode(tostring(v), "rfc2396"))
        end
    end
    local headers = { { name = "Content-Type", value = "application/x-www-form-urlencoded" } }
    -- `client_secret_basic` puts the credentials in the Authorization header instead of the body;
    -- servers differ on which they accept, so the profile chooses and the body form is the default.
    if tostring(field(profile, "client_auth") or ""):lower() == "basic" then
        local id, secret = field(profile, "client_id"), field(profile, "client_secret")
        headers[#headers + 1] = {
            name = "Authorization",
            value = "Basic " .. vim.base64.encode(("%s:%s"):format(id or "", secret or "")),
        }
    end
    require("lvim-rest.backend").run({
        method = "POST",
        url = url,
        headers = headers,
        body = table.concat(body, "&"),
        -- A FULL resolved request: the backends read `directives.curl` / `directives.timeout`
        -- unguarded. An empty directive set is also the right semantics — the user's `# @timeout`
        -- or `@curl-*` flags belong to their request, not to fetching a token for it.
        directives = {
            prompt = {},
            curl = {},
            stdin_cmd = {},
            env_stdin_cmd = {},
            grpc = { proto = {}, import = {} },
            extra = {},
        },
        save_overwrite = false,
    }, function(result)
        if result.error then
            return cb(nil, result.error)
        end
        local ok, decoded = pcall(vim.json.decode, result.body or "")
        if not ok or type(decoded) ~= "table" then
            return cb(nil, ("the token endpoint answered %s with a non-json body"):format(tostring(result.status)))
        end
        if decoded.error then
            return cb(
                nil,
                ("%s%s"):format(decoded.error, decoded.error_description and (": " .. decoded.error_description) or "")
            )
        end
        if not decoded.access_token then
            return cb(nil, "the token response carried no access_token")
        end
        cb({
            access_token = decoded.access_token,
            refresh_token = decoded.refresh_token,
            token_type = decoded.token_type or "Bearer",
            expires_at = decoded.expires_in and (os.time() + math.floor(tonumber(decoded.expires_in) or 0)) or nil,
        })
    end)
end

-- ── PKCE + the loopback listener ─────────────────────────────────────────────

-- The unreserved alphabet a PKCE verifier is drawn from (RFC 7636 §4.1).
local VERIFIER_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

--- A fresh PKCE verifier and its S256 challenge.
---@return string verifier, string challenge
function M.pkce()
    local bytes = {}
    for i = 1, 64 do
        local n = math.random(1, #VERIFIER_CHARS)
        bytes[i] = VERIFIER_CHARS:sub(n, n)
    end
    local verifier = table.concat(bytes)
    -- base64url of the raw sha256, unpadded — the challenge is a URL parameter.
    local digest = vim.fn.sha256(verifier)
    local raw = digest:gsub("%x%x", function(cc)
        return string.char(tonumber(cc, 16))
    end)
    local challenge = vim.base64.encode(raw):gsub("%+", "-"):gsub("/", "_"):gsub("=+$", "")
    return verifier, challenge
end

--- Listen on `127.0.0.1:port` for exactly ONE request, answer it with a small page, and hand the
--- query parameters to `cb`. Closes itself on the first hit or after `timeout` ms.
---
--- A failure to BIND is synchronous and total, so it comes back as `nil, err` instead of through
--- `cb`: the caller has to know before it decides to open a browser, and a scheduled callback can
--- only tell it afterwards — which is how a user ended up authorising into a dead port.
---@param port integer
---@param timeout integer
---@param cb fun(params: table<string, string>?, err: string?)
---@return function? cancel, string? err
function M.loopback(port, timeout, cb)
    local server = uv.new_tcp()
    local done = false
    local timer = uv.new_timer()

    local function finish(params, err)
        if done then
            return
        end
        done = true
        pcall(function()
            timer:stop()
            timer:close()
        end)
        pcall(function()
            server:close()
        end)
        vim.schedule(function()
            cb(params, err)
        end)
    end

    -- luv REPORTS BY RETURN VALUE (`nil, err`), it does not raise: a `pcall` around bind/listen
    -- catches nothing, which is how an occupied or privileged port used to look exactly like a
    -- successful listen — right up to the timeout, browser and all.
    local bound, bind_err = server:bind("127.0.0.1", port)
    local listening, listen_start_err
    if bound then
        listening, listen_start_err = server:listen(1, function(listen_err)
            if listen_err then
                return finish(nil, tostring(listen_err))
            end
            local client = uv.new_tcp()
            server:accept(client)
            client:read_start(function(read_err, chunk)
                if read_err or not chunk then
                    pcall(function()
                        client:close()
                    end)
                    return
                end
                local target = chunk:match("^%a+%s+(%S+)")
                local params = {}
                for k, v in (target or ""):gmatch("[?&]([^=&]+)=([^&]*)") do
                    params[k] = vim.uri_decode((v:gsub("%+", " ")))
                end
                local page = params.error and ("Authorisation failed: " .. params.error)
                    or "Authorised — you can close this tab."
                local body = ("<!doctype html><meta charset=utf-8><title>lvim-rest</title><p>%s</p>"):format(page)
                client:write(
                    ("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"):format(
                        #body,
                        body
                    )
                )
                client:shutdown(function()
                    pcall(function()
                        client:close()
                    end)
                end)
                finish(params)
            end)
        end)
    end
    if not bound or not listening then
        done = true -- nothing may reach `cb`: the failure is the return value
        pcall(function()
            timer:close()
        end)
        pcall(function()
            server:close()
        end)
        return nil, ("could not listen on 127.0.0.1:%d — %s"):format(port, tostring(bind_err or listen_start_err))
    end

    timer:start(timeout, 0, function()
        finish(nil, "the authorisation redirect never arrived")
    end)
    return function()
        finish(nil, "cancelled")
    end
end

--- Open `url` in the system browser.
---
--- `browser_cmd` is a command WORD LIST; the url is appended as its last argument (`firefox` →
--- `firefox <url>`), which is what every browser and every opener takes. It is never interpolated
--- into a shell string — an authorisation url is full of `&` and `?`.
---@param url string
---@return boolean ok
local function open_browser(url)
    local cmd = config.auth.oauth2.browser_cmd
    if cmd and cmd ~= "" then
        local argv = vim.split(cmd, " ", { plain = true, trimempty = true })
        argv[#argv + 1] = url
        return pcall(vim.system, argv) and true or false
    end
    if vim.ui.open then
        local ok = pcall(vim.ui.open, url)
        return ok
    end
    return false
end

-- ── the grants ───────────────────────────────────────────────────────────────

--- Build the authorisation URL for the `authorization_code` grant.
---@param profile table
---@param redirect string
---@param state string
---@param challenge string?
---@return string?
local function authorize_url(profile, redirect, state, challenge)
    local base = field(profile, "auth_url")
    if not base or base == "" then
        return nil
    end
    local q = {
        response_type = "code",
        client_id = field(profile, "client_id"),
        redirect_uri = redirect,
        scope = field(profile, "scope"),
        state = state,
        audience = field(profile, "audience"),
    }
    if challenge then
        q.code_challenge = challenge
        q.code_challenge_method = "S256"
    end
    local parts = {}
    for k, v in pairs(q) do
        if v ~= nil and v ~= "" then
            parts[#parts + 1] = ("%s=%s"):format(k, vim.uri_encode(tostring(v), "rfc2396"))
        end
    end
    return base .. (base:find("?", 1, true) and "&" or "?") .. table.concat(parts, "&")
end

--- The interactive grant: open the browser, catch the redirect, exchange the code.
---@param id string
---@param profile table
---@param cb fun(token: LvimRestToken?, err: string?)
local function authorization_code(id, profile, cb)
    local port = tonumber(field(profile, "redirect_port")) or config.auth.oauth2.redirect_port
    local redirect = field(profile, "redirect_uri") or ("http://127.0.0.1:%d/callback"):format(port)
    -- `state` is a CSRF check: the redirect must carry back the value we sent.
    local state = tostring(math.random(100000, 999999))
    local verifier, challenge
    if field(profile, "pkce") ~= false then
        verifier, challenge = M.pkce()
    end
    local url = authorize_url(profile, redirect, state, challenge)
    if not url then
        return cb(nil, "the auth profile has no Auth URL")
    end

    local listening, listen_err = M.loopback(port, config.auth.oauth2.timeout, function(params, err)
        if err then
            return cb(nil, err)
        end
        params = params or {}
        if params.error then
            return cb(nil, params.error_description or params.error)
        end
        if params.state ~= state then
            return cb(nil, "the redirect carried the wrong state — the response is not ours")
        end
        if not params.code then
            return cb(nil, "the redirect carried no authorisation code")
        end
        token_request(profile, {
            grant_type = "authorization_code",
            code = params.code,
            redirect_uri = redirect,
            client_id = field(profile, "client_id"),
            client_secret = field(profile, "client_secret"),
            code_verifier = verifier,
        }, cb)
    end)
    -- No listener, no grant: walking the user through a consent screen whose redirect lands nowhere
    -- wastes a minute and teaches them the plugin is broken.
    if not listening then
        return cb(nil, listen_err or "could not start the redirect listener")
    end

    notify("opening the browser to authorise…")
    if not open_browser(url) then
        notify("could not open a browser — authorise here:\n" .. url, vim.log.levels.WARN)
    end
end

--- Acquire a token for `id` by running its grant.
---@param id string
---@param profile table
---@param cb fun(token: LvimRestToken?, err: string?)
local function acquire(id, profile, cb)
    local grant = M.grant_of(profile)
    if grant == "client_credentials" then
        return token_request(profile, {
            grant_type = "client_credentials",
            client_id = field(profile, "client_id"),
            client_secret = field(profile, "client_secret"),
            scope = field(profile, "scope"),
            audience = field(profile, "audience"),
        }, cb)
    elseif grant == "password" then
        return token_request(profile, {
            grant_type = "password",
            username = field(profile, "username"),
            password = field(profile, "password"),
            client_id = field(profile, "client_id"),
            client_secret = field(profile, "client_secret"),
            scope = field(profile, "scope"),
        }, cb)
    elseif grant == "authorization_code" then
        return authorization_code(id, profile, cb)
    end
    cb(nil, ("unsupported grant type %q"):format(grant))
end

--- The access token for auth profile `id`: cached when fresh, refreshed when it can be, acquired
--- otherwise.
---@param id string
---@param profile table
---@param cb fun(token: LvimRestToken?, err: string?)
---@return nil
function M.token(id, profile, cb)
    local token = M.cached(id)
    if M.fresh(token) then
        return cb(token)
    end
    local function acquired(new, err)
        if new then
            persist(id, new)
            return cb(new)
        end
        cb(nil, err)
    end
    if token and token.refresh_token then
        return token_request(profile, {
            grant_type = "refresh_token",
            refresh_token = token.refresh_token,
            client_id = field(profile, "client_id"),
            client_secret = field(profile, "client_secret"),
            scope = field(profile, "scope"),
        }, function(new, err)
            if new then
                -- A refresh response may omit the refresh token, which means "keep the one you have".
                new.refresh_token = new.refresh_token or token.refresh_token
                return acquired(new)
            end
            notify(("refresh failed (%s) — re-authorising"):format(tostring(err)), vim.log.levels.WARN)
            acquire(id, profile, acquired)
        end)
    end
    acquire(id, profile, acquired)
end

return M
