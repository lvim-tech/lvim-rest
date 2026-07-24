-- lvim-rest.store: the plugin's own sqlite database (lvim-utils.store), opened lazily.
--
-- One DB under `stdpath("data")/lvim-rest/lvim-rest.db`, versioned. Version 1 (this phase) holds the
-- `history` table; the Postman request LIBRARY (workspaces / collections / folders / requests /
-- examples / environments / runs) is added by a later version bump + migration (phase 5), so the
-- schema grows without ever rewriting an existing user's DB. Shared is the lvim-utils.store CODE
-- only — this file/DB is the plugin's own, droppable independently.
--
---@module "lvim-rest.store"

local store = require("lvim-utils.store")

local M = {}

-- The current schema version. Bump + add a migration when the tables change.
local VERSION = 1

-- Declared tables (version 1). `history` gets an optional `request_id` FK column now so a later
-- "save an ad-hoc run into a collection" needs no migration for the column itself.
local TABLES = {
    history = {
        id = { "integer", primary = true, autoincrement = true },
        ts = { "integer" },
        file = { "text" },
        name = { "text" },
        method = { "text" },
        url = { "text" },
        status = { "integer" },
        ms = { "integer" },
        size = { "integer" },
        env = { "text" },
        request_id = { "integer" },
        headers = { "text" },
        body = { "text" },
    },
}

---@type table? the open store handle (nil until first use)
local handle

--- The open store handle (opened on first call). Returns nil when sqlite.lua is unavailable.
---@return table?
function M.get()
    if handle then
        return handle
    end
    if not store.available() then
        return nil
    end
    handle = store.new({
        backend = "sqlite",
        name = "lvim-rest",
        version = VERSION,
        tables = TABLES,
        migrations = {},
    })
    return handle
end

--- Whether the sqlite backend is available.
---@return boolean
function M.available()
    return store.available()
end

--- The current schema version (for health).
---@return integer
function M.version()
    return VERSION
end

return M
