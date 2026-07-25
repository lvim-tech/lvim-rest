-- lvim-rest.store: the plugin's own sqlite database (lvim-utils.store), opened lazily.
--
-- One DB under `stdpath("data")/lvim-rest/lvim-rest.db`, versioned. Version 1 held `history`;
-- version 2 adds the Postman-shaped request LIBRARY — workspaces / collections / folders /
-- requests / examples / environments / runs — so the schema GROWS without ever rewriting an
-- existing user's DB (declared tables are created on open; `PRAGMA user_version` drives the
-- migration steps). Shared is the lvim-utils.store CODE only — this file/DB is the plugin's own,
-- droppable independently.
--
-- SECRETS ARE NEVER STORED HERE. A request/collection/environment may reference a secret only as a
-- `{{vault "key"}}` marker; the value itself lives in lvim-keyring. See `vars.vault` — the binder
-- scans on save and refuses to persist an inline credential.
--
---@module "lvim-rest.store"

local store = require("lvim-utils.store")

local M = {}

-- The current schema version. Bump + add a migration when the tables change. v3 adds the cookie jar.
local VERSION = 4

-- Declared tables. `history.request_id` is the FK that lets an ad-hoc run be saved into a
-- collection later. Every `*_json` column holds an encoded Lua table (the library layer
-- encodes/decodes, so callers only ever see tables); `ord` is the manual sort position within a
-- parent, which is what makes the explorer's move up/down persistent.
local TABLES = {
    -- The cookie jar (see `lvim-rest.cookies`). `expires = 0` marks a SESSION cookie, dropped at the
    -- next start; (domain, path, name) is a cookie's identity, so a re-set replaces rather than adds.
    cookie = {
        id = { "integer", primary = true, autoincrement = true },
        domain = { "text" },
        path = { "text" },
        name = { "text" },
        value = { "text" },
        expires = { "integer" },
        secure = { "integer" },
        http_only = { "integer" },
        host_only = { "integer" },
    },
    -- OAuth2 token METADATA only — the token itself is a secret and lives in lvim-keyring (see
    -- `auth.oauth2`). Losing this table costs a re-authorisation; it can never leak a credential.
    auth_token = {
        id = { "integer", primary = true, autoincrement = true },
        profile = { "text" },
        expires_at = { "integer" },
        token_type = { "text" },
        has_refresh = { "integer" },
    },
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
    -- ── the request library (v2) ────────────────────────────────────────────
    workspace = {
        id = { "integer", primary = true, autoincrement = true },
        name = { "text", required = true },
        active = { "integer" }, -- 1 on exactly one row
        created = { "integer" },
        updated = { "integer" },
    },
    collection = {
        id = { "integer", primary = true, autoincrement = true },
        workspace_id = { "integer", required = true },
        name = { "text", required = true },
        ord = { "integer" },
        description = { "text" },
        auth_json = { "text" },
        vars_json = { "text" },
        pre_script = { "text" },
        post_script = { "text" },
    },
    folder = {
        id = { "integer", primary = true, autoincrement = true },
        collection_id = { "integer", required = true },
        parent_folder_id = { "integer" }, -- nil = directly under the collection
        name = { "text", required = true },
        ord = { "integer" },
    },
    request = {
        id = { "integer", primary = true, autoincrement = true },
        collection_id = { "integer", required = true },
        folder_id = { "integer" },
        ord = { "integer" },
        name = { "text", required = true },
        method = { "text" }, -- incl. the pseudo-methods GRAPHQL / GRPC / WEBSOCKET
        url = { "text" },
        headers_json = { "text" },
        params_json = { "text" },
        body = { "text" },
        body_type = { "text" },
        auth_json = { "text" },
        pre_script = { "text" },
        post_script = { "text" },
        docs = { "text" },
        vars_json = { "text" },
    },
    example = { -- a saved response attached to a request (Postman "examples")
        id = { "integer", primary = true, autoincrement = true },
        request_id = { "integer", required = true },
        name = { "text" },
        status = { "integer" },
        headers_json = { "text" },
        body = { "text" },
        ms = { "integer" },
        size = { "integer" },
        created = { "integer" },
    },
    environment = {
        id = { "integer", primary = true, autoincrement = true },
        workspace_id = { "integer", required = true },
        name = { "text", required = true },
        vars_json = { "text" },
        is_private = { "integer" },
        active = { "integer" },
    },
    run = { -- one collection-runner execution
        id = { "integer", primary = true, autoincrement = true },
        collection_id = { "integer" },
        folder_id = { "integer" },
        env_id = { "integer" },
        started = { "integer" },
        finished = { "integer" },
        iterations = { "integer" },
        passed = { "integer" },
        failed = { "integer" },
    },
    run_result = { -- one request × iteration inside a run
        id = { "integer", primary = true, autoincrement = true },
        run_id = { "integer", required = true },
        request_id = { "integer" },
        iteration = { "integer" },
        status = { "integer" },
        ms = { "integer" },
        passed = { "integer" },
        failed = { "integer" },
        error = { "text" },
    },
}

-- Version steps. v2, v3 and v4 only ADD tables, and declared tables are created by the handles on
-- open, so the steps themselves have nothing to alter — they exist to move `user_version` forward.
local MIGRATIONS = {
    [2] = function(_) end,
    [3] = function(_) end,
    [4] = function(_) end,
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
        migrations = MIGRATIONS,
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
