-- lvim-rest.vars.env: environment-file discovery + the active-env state.
--
-- kulala/JetBrains `http-client.env.json` (+ `http-client.private.env.json` for secrets) are
-- discovered by walking UP from the .http file to the project root. Each file is a map of named
-- PROFILES (`dev`/`prod`/…) → a flat variable map. `.env` files feed `{{$dotenv VAR}}`.
--
-- The active profile is sticky per project; phase 4 persists it in the plugin store, but the
-- in-memory selection here already drives resolution. This module owns only file loading + the
-- current selection; the resolution ORDER lives in vars/init.lua.
--
---@module "lvim-rest.vars.env"

local config = require("lvim-rest.config")

local M = {}

-- The env-file basenames, in merge order (private overlays public for the same profile).
local ENV_FILES = { "http-client.env.json", "http-client.private.env.json" }

---@type table<string, string>  project-root path → active profile name (in-memory cache)
local active = {}
---@type boolean whether the persisted sticky selections have been loaded from the store
local loaded = false

--- Lazily load the persisted per-project active-env map from the plugin store.
local function ensure_loaded()
    if loaded then
        return
    end
    loaded = true
    local ok, store = pcall(require, "lvim-rest.store")
    if not ok then
        return
    end
    local db = store.get()
    if not db then
        return
    end
    local map = db.env_active
    if type(map) == "table" then
        for root, name in pairs(map) do
            if active[root] == nil then
                active[root] = name
            end
        end
    end
end

--- Persist the per-project active-env map to the store (best-effort).
local function persist()
    local ok, store = pcall(require, "lvim-rest.store")
    if not ok then
        return
    end
    local db = store.get()
    if db then
        db.env_active = vim.deepcopy(active)
    end
end

--- The nearest ancestor directory that looks like a project root (a `.git`, or a discovered env
--- file); falls back to the file's own directory.
---@param start string  a file path or directory
---@return string
local function project_root(start)
    local dir = vim.fn.isdirectory(start) == 1 and start or vim.fs.dirname(start)
    local markers = { ".git", "http-client.env.json", "http-client.private.env.json" }
    local found = vim.fs.find(markers, { path = dir, upward = true })[1]
    if found then
        return vim.fs.dirname(found)
    end
    return dir
end

--- Load and merge the env files discovered upward from `path`. Returns a map profile → vars.
---@param path string  the .http file (or its directory)
---@return table<string, table<string, string>>
function M.load(path)
    local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
    ---@type table<string, table<string, string>>
    local profiles = {}
    for _, base in ipairs(ENV_FILES) do
        local hits = vim.fs.find(base, { path = dir, upward = true, limit = 1 })
        local file = hits[1]
        if file and vim.fn.filereadable(file) == 1 then
            local ok, lines = pcall(vim.fn.readfile, file)
            if ok then
                local dok, doc = pcall(vim.json.decode, table.concat(lines, "\n"))
                if dok and type(doc) == "table" then
                    for prof, vars in pairs(doc) do
                        if type(vars) == "table" then
                            profiles[prof] = profiles[prof] or {}
                            for k, v in pairs(vars) do
                                profiles[prof][k] = type(v) == "table" and vim.json.encode(v) or tostring(v)
                            end
                        end
                    end
                end
            end
        end
    end
    return profiles
end

--- The variable map of the ACTIVE profile for `path` (empty when none is set / found).
---@param path string
---@return table<string, string>
function M.active_vars(path)
    local profiles = M.load(path)
    local name = M.active_name(path)
    return (name and profiles[name]) or {}
end

--- The active profile NAME for the project containing `path` (config default when unset).
---@param path string
---@return string
function M.active_name(path)
    ensure_loaded()
    local root = project_root(path)
    return active[root] or config.env.default
end

--- Set the active profile for the project containing `path` (persisted in the plugin store).
---@param path string
---@param name string
function M.set_active(path, name)
    ensure_loaded()
    active[project_root(path)] = name
    persist()
end

--- The profile names available for `path` (for the env picker).
---@param path string
---@return string[]
function M.names(path)
    local profiles = M.load(path)
    local names = {}
    for k in pairs(profiles) do
        names[#names + 1] = k
    end
    table.sort(names)
    return names
end

--- Load `.env` (dotenv) variables discovered upward from `path` — feeds `{{$dotenv VAR}}`.
---@param path string
---@return table<string, string>
function M.dotenv(path)
    local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
    local hits = vim.fs.find(".env", { path = dir, upward = true, limit = 1 })
    local file = hits[1]
    local out = {}
    if not file or vim.fn.filereadable(file) == 0 then
        return out
    end
    local ok, lines = pcall(vim.fn.readfile, file)
    if not ok then
        return out
    end
    for _, raw in ipairs(lines) do
        local line = vim.trim(raw)
        if line ~= "" and not line:match("^#") then
            local k, v = line:match("^([%w_%.]+)%s*=%s*(.*)$")
            if k then
                -- Strip surrounding quotes and a leading `export `.
                k = k:gsub("^export%s+", "")
                v = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
                out[k] = v
            end
        end
    end
    return out
end

return M
