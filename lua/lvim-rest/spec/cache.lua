-- lvim-rest.spec.cache: the tiny key→value store behind DYNAMIC spec vocabulary (gRPC reflection, env
-- profile ids). The hard rule (design §4): the VALIDATOR only ever READS this cache — never resolves
-- inline — so a validation pass never blocks or networks; the panel/cmp resolve on demand and `set`
-- the answer here, and a stale entry (older than its ttl) reads as a miss so the next resolve refreshes.
--
---@module "lvim-rest.spec.cache"

local M = {}

---@type table<string, { result: any, at: integer }>
local store = {}

--- The cached result for `key`, or nil on a miss / when older than `ttl` ms.
---@param key string?
---@param ttl integer?  max age in ms (nil = no expiry)
---@return any
function M.get(key, ttl)
    if not key then
        return nil
    end
    local e = store[key]
    if not e then
        return nil
    end
    if ttl and (vim.uv.now() - e.at) > ttl then
        return nil
    end
    return e.result
end

--- Store `result` under `key`, stamped now.
---@param key string?
---@param result any
function M.set(key, result)
    if key then
        store[key] = { result = result, at = vim.uv.now() }
    end
end

--- Drop everything (a full reset, e.g. on `setup`).
function M.clear()
    store = {}
end

return M
