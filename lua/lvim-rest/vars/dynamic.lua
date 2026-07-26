-- lvim-rest.vars.dynamic: the built-in dynamic `{{$…}}` variables, computed in Lua.
--
-- Each is a function of its space-separated arguments. The set is user-extensible at runtime
-- (`require("lvim-rest.vars.dynamic").register("$myvar", fn)`) so a project can add its own
-- generators without a fork — the resolution pipeline calls `M.resolve("$name", args)`.
--
---@module "lvim-rest.vars.dynamic"

local M = {}

--- RFC-4122 v4 UUID from math.random (seeded once per session below).
---@return string
local function uuid4()
    return (
        string.gsub("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx", "[xy]", function(c)
            local v = c == "x" and math.random(0, 15) or math.random(8, 11)
            return string.format("%x", v)
        end)
    )
end

math.randomseed(vim.uv.hrtime() % 2147483647)

---@type table<string, fun(args: string[]): string>
local registry = {
    ["$uuid"] = function()
        return uuid4()
    end,
    ["$guid"] = function()
        return uuid4()
    end,
    ["$timestamp"] = function()
        return tostring(os.time())
    end,
    ["$isoTimestamp"] = function()
        return os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
    end,
    ["$date"] = function(args)
        local fmt = (args and args[1]) or "%Y-%m-%d"
        return os.date(fmt) --[[@as string]]
    end,
    ["$localDatetime"] = function(args)
        local fmt = (args and args[1]) or "%Y-%m-%d %H:%M:%S"
        return os.date(fmt) --[[@as string]]
    end,
    ["$randomInt"] = function(args)
        local min = tonumber(args and args[1]) or 0
        local max = tonumber(args and args[2]) or 1000
        if min > max then
            min, max = max, min
        end
        return tostring(math.random(math.floor(min), math.floor(max)))
    end,
    ["$random"] = function(args)
        local min = tonumber(args and args[1]) or 0
        local max = tonumber(args and args[2]) or 1000
        return tostring(math.random(math.floor(min), math.floor(max)))
    end,
}

--- Register (or override) a dynamic variable generator. Name includes the leading `$`.
---@param name string
---@param fn fun(args: string[]): string
function M.register(name, fn)
    registry[name] = fn
end

--- Whether `name` (with leading `$`) is a known dynamic variable.
---@param name string
---@return boolean
function M.has(name)
    return registry[name] ~= nil
end

--- Resolve a dynamic variable. Returns nil when the name is unknown (the caller then leaves the
--- `{{…}}` token untouched rather than emptying it).
---@param name string  e.g. "$uuid"
---@param args string[]?
---@return string?
function M.resolve(name, args)
    local fn = registry[name]
    if not fn then
        return nil
    end
    local ok, val = pcall(fn, args or {})
    return ok and val or nil
end

return M
