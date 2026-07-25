-- lvim-rest.runner.script: the pre-request / post-response SCRIPTING layer.
--
-- Scripts are LUA. kulala and the IntelliJ HTTP client run JavaScript here and ship a JS engine to
-- do it; inside Neovim the host language already IS Lua, so a Lua script needs no engine, no
-- bundling, no process, and the user writes the language they configure the editor in. The block
-- syntax is unchanged (`< {% … %}` before the request, `> {% … %}` after the response, or a
-- `< ./x.lua` / `> ./x.lua` file), so a document reads the same as the format everyone knows.
--
-- The environment is a SANDBOX built per script: a fresh `_ENV` holding the standard-library subset
-- plus `client`, `request` (pre) and `response` (post). It is not a security boundary — a `.http`
-- file you opened is code you chose to run — it is a NAMESPACE: a script cannot accidentally reach
-- for a plugin internal that would then have to stay stable forever.
--
-- Headers are exposed through a case-insensitive PROXY over the parser's ordered array, so
-- `request.headers["X-Trace"] = "1"` reads and writes naturally while duplicates and authored order
-- survive underneath (see `store.bind` for why the array shape is not negotiable).
--
-- Globals set with `client.global.set` live for the SESSION, like the prompt cache: a value a script
-- captured is a runtime fact about this editing session, not a document you would want to diff.
--
---@module "lvim-rest.runner.script"

local M = {}

---@type table<string, string>  session-scoped variables set by `client.global.set`
local globals = {}

--- Every global a script has set this session (the variable engine reads this).
---@return table<string, string>
function M.globals()
    return globals
end

--- Drop every session global (`:LvimRest globals clear`).
---@return nil
function M.clear_globals()
    globals = {}
end

-- ── header proxy ─────────────────────────────────────────────────────────────

--- A case-insensitive view over an ordered `{ { name, value }, … }` header list. Assigning an
--- existing name updates it in place (keeping its position); a new name appends; `nil` removes.
---@param list LvimRestHeader[]
---@return table proxy
local function header_proxy(list)
    return setmetatable({}, {
        __index = function(_, key)
            if type(key) ~= "string" then
                return nil
            end
            local want = key:lower()
            for _, h in ipairs(list) do
                if h.name:lower() == want then
                    return h.value
                end
            end
            return nil
        end,
        __newindex = function(_, key, value)
            if type(key) ~= "string" then
                return
            end
            local want = key:lower()
            for i, h in ipairs(list) do
                if h.name:lower() == want then
                    if value == nil then
                        table.remove(list, i)
                    else
                        h.value = tostring(value)
                    end
                    return
                end
            end
            if value ~= nil then
                list[#list + 1] = { name = key, value = tostring(value) }
            end
        end,
        -- `for name, value in pairs(request.headers)` — the ordered list, flattened.
        __pairs = function()
            local i = 0
            return function()
                i = i + 1
                local h = list[i]
                if h then
                    return h.name, h.value
                end
            end
        end,
    })
end

-- ── the sandbox ──────────────────────────────────────────────────────────────

-- The standard library a script may see. Anything not listed is simply absent — including `require`,
-- `io`, `os.execute` and `loadstring`, none of which a request script has a reason to reach for.
local STDLIB = {
    "assert",
    "error",
    "ipairs",
    "next",
    "pairs",
    "pcall",
    "print",
    "select",
    "tonumber",
    "tostring",
    "type",
    "unpack",
    "xpcall",
    "math",
    "string",
    "table",
}

--- Build the `client` API for one script run, wired to the run's collector.
---@param ctx { log: string[], tests: table[] }
---@return table client
local function make_client(ctx)
    local client = {}

    client.global = {
        ---@param name string
        ---@param value any
        set = function(name, value)
            globals[tostring(name)] = tostring(value)
        end,
        ---@param name string
        ---@return string?
        get = function(name)
            return globals[tostring(name)]
        end,
        ---@param name string
        clear = function(name)
            globals[tostring(name)] = nil
        end,
        clear_all = function()
            globals = {}
        end,
    }

    --- Append a line to the script-output view.
    client.log = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            parts[#parts + 1] = type(v) == "table" and vim.inspect(v) or tostring(v)
        end
        ctx.log[#ctx.log + 1] = table.concat(parts, " ")
    end

    --- Fail the enclosing test when `cond` is falsy. Outside a test it fails the script.
    ---@param cond any
    ---@param message string?
    client.assert = function(cond, message)
        if not cond then
            error(message or "assertion failed", 2)
        end
        return cond
    end

    --- A named test. Never lets a failure escape: it is recorded and the next test still runs — a
    --- report that stopped at the first failure would hide everything after it.
    ---@param name string
    ---@param fn fun()
    client.test = function(name, fn)
        if type(fn) ~= "function" then
            ctx.tests[#ctx.tests + 1] = { name = tostring(name), ok = false, message = "test body is not a function" }
            return
        end
        local ok, err = pcall(fn)
        ctx.tests[#ctx.tests + 1] = {
            name = tostring(name),
            ok = ok,
            message = (not ok) and tostring(err):gsub("^.-:%d+:%s*", "") or nil,
        }
    end

    return client
end

--- Compose the sandbox `_ENV` for one script.
---@param client table
---@param extra table<string, any>  `request` (pre) or `response` (post)
---@return table env
local function make_env(client, extra)
    local env =
        { client = client, vim = { inspect = vim.inspect, json = vim.json, split = vim.split, trim = vim.trim } }
    for _, name in ipairs(STDLIB) do
        env[name] = _G[name]
    end
    for k, v in pairs(extra) do
        env[k] = v
    end
    env._G = env
    return env
end

--- Load and run one script entry in `env`.
---@param entry LvimRestScript
---@param env table
---@param base_dir string  the document's directory (a `file` entry is relative to it)
---@return string? err
local function run_one(entry, env, base_dir)
    local src, chunkname = entry.source, ("script@%d"):format(entry.line or 0)
    local file = entry.file
    if file and file ~= "" then
        local path = file
        if not path:match("^/") then
            path = base_dir .. "/" .. path:gsub("^%./", "")
        end
        if vim.fn.filereadable(path) == 0 then
            return ("script file not found: %s"):format(path)
        end
        src = table.concat(vim.fn.readfile(path), "\n")
        chunkname = path
    end
    if not src or vim.trim(src) == "" then
        return nil
    end
    local fn, load_err = load(src, "@" .. chunkname, "t", env)
    if not fn then
        return tostring(load_err)
    end
    local ok, err = pcall(fn)
    if not ok then
        return tostring(err)
    end
    return nil
end

-- ── the two entry points ─────────────────────────────────────────────────────

--- Run a request's PRE scripts. They see `request` and may mutate `method` / `url` / `headers` /
--- `body`, which is why this runs on the parsed request BEFORE variable resolution: a script that
--- writes `{{token}}` into a header still gets it resolved afterwards.
---@param req LvimRestRequest
---@param base_dir string
---@return { log: string[], tests: table[], errors: string[] }
function M.run_pre(req, base_dir)
    local ctx = { log = {}, tests = {}, errors = {} }
    local list = (req.scripts or {}).pre or {}
    if #list == 0 then
        return ctx
    end
    local request = {
        method = req.method,
        url = req.url,
        body = req.body,
        headers = header_proxy(req.headers),
        variables = {
            ---@param name string
            ---@param value any
            set = function(name, value)
                for _, v in ipairs(req.vars) do
                    if v.name == name then
                        v.value = tostring(value)
                        return
                    end
                end
                req.vars[#req.vars + 1] = { name = tostring(name), value = tostring(value) }
            end,
            ---@param name string
            ---@return string?
            get = function(name)
                for _, v in ipairs(req.vars) do
                    if v.name == name then
                        return v.value
                    end
                end
                return nil
            end,
        },
    }
    local env = make_env(make_client(ctx), { request = request })
    for _, entry in ipairs(list) do
        local err = run_one(entry, env, base_dir)
        if err then
            ctx.errors[#ctx.errors + 1] = err
        end
    end
    -- Write the mutable fields back onto the request (headers were mutated through the proxy).
    req.method = request.method or req.method
    req.url = request.url or req.url
    req.body = request.body
    return ctx
end

--- Run a request's POST scripts against the result. `response.json` is decoded lazily and only once
--- — most scripts touch it, and a body that is not json must not turn into an error at load time.
---@param req LvimRestRequest
---@param result table
---@param base_dir string
---@return { log: string[], tests: table[], errors: string[] }
function M.run_post(req, result, base_dir)
    local ctx = { log = {}, tests = {}, errors = {} }
    local list = (req.scripts or {}).post or {}
    if #list == 0 then
        return ctx
    end
    local response = setmetatable({
        status = result.status,
        status_text = result.status_text,
        body = result.body,
        headers = header_proxy(result.headers or {}),
        content_type = (function()
            for _, h in ipairs(result.headers or {}) do
                if h.name:lower() == "content-type" then
                    return h.value
                end
            end
            return nil
        end)(),
        timing = result.timing,
    }, {
        __index = function(t, key)
            if key ~= "json" then
                return nil
            end
            local ok, decoded = pcall(vim.json.decode, result.body or "")
            local value = ok and decoded or nil
            rawset(t, "json", value)
            return value
        end,
    })
    local env = make_env(make_client(ctx), { response = response })
    for _, entry in ipairs(list) do
        local err = run_one(entry, env, base_dir)
        if err then
            ctx.errors[#ctx.errors + 1] = err
        end
    end
    return ctx
end

return M
