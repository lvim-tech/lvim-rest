-- lvim-rest.cookies: the persistent COOKIE JAR.
--
-- The jar lives HERE, in Lua, for both execution engines. curl has `--cookie-jar` and reqwest has
-- its own in-memory store, but letting each backend keep its own would mean two jars with different
-- contents, different lifetimes and different answers to `# @no-cookie-jar` — a request would behave
-- differently depending on whether the daemon happened to be built. One jar, applied by the runner,
-- keeps the two engines interchangeable, which is the whole premise of having two.
--
-- Storage is the plugin's sqlite DB (a `cookie` table), so the jar survives a restart and is
-- inspectable (`:LvimRest cookies`) — unlike a curl jar file, which is opaque unless you go read it.
--
-- SESSION cookies (no `Expires`/`Max-Age`) are dropped when Neovim starts: an editor session is the
-- session they belong to. Persisting them would silently turn a browser's "until you close it" into
-- "forever", which is the opposite of what the server asked for.
--
-- Matching is the practical RFC 6265 subset: host-or-domain-suffix, path prefix, `Secure` only over
-- https, expiry checked on read. No public-suffix list — a cookie is only ever sent back to a host
-- that already matched the domain the server itself set.
--
---@module "lvim-rest.cookies"

local config = require("lvim-rest.config")
local store = require("lvim-rest.store")

local M = {}

--- The open DB handle, or nil when sqlite is unavailable (the jar then degrades to a no-op).
---@return table?
local function db()
    return store.get()
end

-- ── url parsing ──────────────────────────────────────────────────────────────

--- Split a URL into the parts cookie matching needs.
---@param url string
---@return { host: string, path: string, secure: boolean }?
function M.split_url(url)
    local scheme, rest = url:match("^(%a[%w+.-]*)://(.+)$")
    if not scheme then
        return nil
    end
    local hostport = rest:match("^([^/?#]+)") or ""
    local host = hostport:match("^([^:]+)") or hostport
    local path = rest:match("^[^/?#]*(/[^?#]*)") or "/"
    return { host = host:lower(), path = path, secure = scheme:lower() == "https" }
end

-- ── Set-Cookie parsing ───────────────────────────────────────────────────────

--- Parse one `Set-Cookie` value into a jar row. Returns nil when there is no `name=value` pair.
---@param value string
---@param url_parts { host: string, path: string, secure: boolean }
---@return table? cookie
function M.parse_set_cookie(value, url_parts)
    local parts = vim.split(value, ";", { plain = true })
    local name, val = parts[1]:match("^%s*([^=]+)=(.*)$")
    if not name then
        return nil
    end
    local c = {
        name = vim.trim(name),
        value = vim.trim(val),
        domain = url_parts.host,
        path = "/",
        secure = 0,
        http_only = 0,
        expires = nil, -- nil = a session cookie
        host_only = 1, -- until a `Domain` attribute says otherwise
    }
    for i = 2, #parts do
        local attr = vim.trim(parts[i])
        local k, v = attr:match("^([^=]+)=(.*)$")
        k = vim.trim((k or attr)):lower()
        v = v and vim.trim(v) or nil
        if k == "domain" and v and v ~= "" then
            c.domain = v:gsub("^%.", ""):lower()
            c.host_only = 0
        elseif k == "path" and v and v ~= "" then
            c.path = v
        elseif k == "secure" then
            c.secure = 1
        elseif k == "httponly" then
            c.http_only = 1
        elseif k == "max-age" and v then
            local secs = tonumber(v)
            if secs then
                -- Max-Age wins over Expires per RFC 6265; a non-positive value deletes the cookie.
                c.expires = os.time() + secs
            end
        elseif k == "expires" and v and not c.expires then
            c.expires = M.parse_date(v)
        end
    end
    return c
end

-- Month names as they appear in an HTTP date.
local MONTHS = {
    jan = 1,
    feb = 2,
    mar = 3,
    apr = 4,
    may = 5,
    jun = 6,
    jul = 7,
    aug = 8,
    sep = 9,
    oct = 10,
    nov = 11,
    dec = 12,
}

--- Parse an HTTP-date (`Wdy, DD Mon YYYY HH:MM:SS GMT`, and the two legacy forms) into an epoch.
--- Returns nil when it cannot be read — an unparseable expiry makes the cookie a session cookie,
--- which errs toward forgetting rather than toward keeping something forever.
---@param s string
---@return integer?
function M.parse_date(s)
    local d, mon, y, hh, mm, ss = s:match("(%d+)[%s-](%a+)[%s-](%d+)%s+(%d+):(%d+):(%d+)")
    if not d then
        -- asctime: `Wdy Mon DD HH:MM:SS YYYY`
        mon, d, hh, mm, ss, y = s:match("(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+(%d+)")
    end
    if not d or not mon then
        return nil
    end
    local month = MONTHS[mon:sub(1, 3):lower()]
    if not month then
        return nil
    end
    local year = tonumber(y) or 0
    if year < 100 then -- two-digit years, per RFC 6265's 69/70 rule
        year = year + (year < 70 and 2000 or 1900)
    end
    -- The date is UTC; os.time interprets its table as local time, so correct by the zone offset.
    local t = os.time({
        year = year,
        month = month,
        day = tonumber(d) or 1,
        hour = tonumber(hh) or 0,
        min = tonumber(mm) or 0,
        sec = tonumber(ss) or 0,
        isdst = false,
    })
    if not t then
        return nil
    end
    local utc = os.time(os.date("!*t", t) --[[@as osdateparam]])
    return t + (t - utc)
end

-- ── matching ─────────────────────────────────────────────────────────────────

--- Does `host` match the cookie's domain (exact, or a suffix for a `Domain=` cookie)?
---@param cookie table
---@param host string
---@return boolean
local function domain_match(cookie, host)
    if cookie.domain == host then
        return true
    end
    if cookie.host_only == 1 then
        return false
    end
    return host:sub(-#cookie.domain - 1) == "." .. cookie.domain
end

--- Does `path` fall under the cookie's path?
---@param cookie table
---@param path string
---@return boolean
local function path_match(cookie, path)
    local cp = cookie.path or "/"
    if path == cp then
        return true
    end
    if path:sub(1, #cp) ~= cp then
        return false
    end
    return cp:sub(-1) == "/" or path:sub(#cp + 1, #cp + 1) == "/"
end

-- ── the jar ──────────────────────────────────────────────────────────────────

--- Every stored cookie (expired ones pruned).
---@return table[]
function M.list()
    local d = db()
    if not d then
        return {}
    end
    local rows = d:find("cookie", {})
    if type(rows) ~= "table" then
        return {}
    end
    local now = os.time()
    local out = {}
    for _, r in ipairs(rows) do
        if r.expires and r.expires > 0 and r.expires <= now then
            d:remove("cookie", { id = r.id })
        else
            out[#out + 1] = r
        end
    end
    return out
end

--- The `Cookie:` header value for `url`, or nil when nothing matches. Longer paths come first, as
--- RFC 6265 requires, so a more specific cookie shadows a general one at the server.
---@param url string
---@return string?
function M.header_for(url)
    if not config.cookies.enabled then
        return nil
    end
    local parts = M.split_url(url)
    if not parts then
        return nil
    end
    local hits = {}
    for _, c in ipairs(M.list()) do
        if domain_match(c, parts.host) and path_match(c, parts.path) and (c.secure ~= 1 or parts.secure) then
            hits[#hits + 1] = c
        end
    end
    if #hits == 0 then
        return nil
    end
    table.sort(hits, function(a, b)
        return #(a.path or "/") > #(b.path or "/")
    end)
    local pairs_out = {}
    for _, c in ipairs(hits) do
        pairs_out[#pairs_out + 1] = ("%s=%s"):format(c.name, c.value)
    end
    return table.concat(pairs_out, "; ")
end

--- Store one cookie, replacing any with the same (domain, path, name) triple — that triple is a
--- cookie's identity, so a re-set updates rather than accumulates.
---@param c table
---@return nil
local function put(c)
    local d = db()
    if not d then
        return
    end
    local key = { domain = c.domain, path = c.path, name = c.name }
    d:remove("cookie", key)
    -- A non-positive expiry is the standard way to DELETE a cookie: removing it is the whole action.
    if c.expires and c.expires <= os.time() then
        return
    end
    d:insert("cookie", {
        domain = c.domain,
        path = c.path,
        name = c.name,
        value = c.value,
        expires = c.expires or 0, -- 0 = session cookie (dropped on the next start)
        secure = c.secure or 0,
        http_only = c.http_only or 0,
        host_only = c.host_only or 0,
    })
end

--- Absorb every `Set-Cookie` in a response.
---@param url string
---@param headers LvimRestHeader[]?
---@return integer count  how many cookies were stored or deleted
function M.absorb(url, headers)
    if not config.cookies.enabled then
        return 0
    end
    local parts = M.split_url(url)
    if not parts then
        return 0
    end
    local n = 0
    for _, h in ipairs(headers or {}) do
        if h.name:lower() == "set-cookie" then
            local c = M.parse_set_cookie(h.value, parts)
            -- A server may only set a cookie for a domain it is under; anything else is dropped.
            if c and domain_match(c, parts.host) then
                put(c)
                n = n + 1
            end
        end
    end
    return n
end

--- Drop cookies: all of them, or only those whose domain contains `pattern`.
---@param pattern string?
---@return integer removed
function M.clear(pattern)
    local d = db()
    if not d then
        return 0
    end
    local n = 0
    for _, c in ipairs(M.list()) do
        if not pattern or pattern == "" or (c.domain or ""):find(pattern, 1, true) then
            d:remove("cookie", { id = c.id })
            n = n + 1
        end
    end
    return n
end

--- Drop the session cookies (no expiry). Called once at setup: a new editor session is a new
--- session, and a `Set-Cookie` without an expiry explicitly asked not to outlive it.
---@return integer removed
function M.drop_session_cookies()
    local d = db()
    if not d then
        return 0
    end
    local n = 0
    local rows = d:find("cookie", {})
    for _, c in ipairs(type(rows) == "table" and rows or {}) do
        if not c.expires or c.expires == 0 then
            d:remove("cookie", { id = c.id })
            n = n + 1
        end
    end
    return n
end

return M
