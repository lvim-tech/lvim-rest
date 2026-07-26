-- lvim-rest.store.library: the request LIBRARY over the plugin's sqlite schema (v2) — the
-- Postman-shaped tree the workbench explorer renders and the collection runner walks:
--
--   workspace ▸ collection ▸ folder* ▸ request ▸ example
--   workspace ▸ environment          run ▸ run_result
--
-- Everything here is plain data access: rows in, rows out, ordering maintained. No UI, no runner
-- logic — those consume this. Two conventions the whole module keeps:
--
--   * `*_json` COLUMNS ARE TABLES at this boundary. Callers pass/receive Lua tables (`headers`,
--     `params`, `vars`, `auth`); encode/decode happens here, so no consumer ever hand-rolls
--     vim.json around a column and no half-encoded value can reach the DB.
--   * `ord` IS THE ORDER. Every child list is sorted by it and new rows land at the end, so the
--     explorer's move up/down is just two `ord` swaps and survives a restart.
--
-- SECRETS: a row may hold a `{{vault "key"}}` MARKER, never a credential. Enforcement lives at the
-- save seam (`vars.vault` + the buffer binder), not here — this layer stores what it is handed.
--
---@module "lvim-rest.store.library"

local store = require("lvim-rest.store")

local M = {}

-- ── helpers ──────────────────────────────────────────────────────────────────

--- The open DB handle, or nil when sqlite is unavailable (every public call degrades to nil/{}).
---@return table?
local function db()
    return store.get()
end

--- Current unix time — every timestamp column goes through here.
---@return integer
local function now()
    return os.time()
end

--- Decode a `*_json` column into a table (always a table, so callers can index it blindly).
---@param s string?
---@return table
local function dec(s)
    if type(s) ~= "string" or s == "" then
        return {}
    end
    local ok, v = pcall(vim.json.decode, s)
    return (ok and type(v) == "table") and v or {}
end

--- Encode a table for a `*_json` column.
---
--- ABSENT vs EMPTY is the whole point here. `nil` means "the caller said nothing about this column"
--- and encodes to nil, which the update helpers read as "leave it alone". A table that IS there
--- always encodes — INCLUDING an empty one: an empty table is the caller saying "this is now empty",
--- and the column must record that. Returning nil for `{}` would put nil into the `set` table, which
--- in Lua simply DELETES the key, so the UPDATE would omit the column entirely and a cleared auth /
--- header list / variable list could never be persisted (the binder deliberately sends `{}` to mean
--- cleared — see `store.bind.fields_of`). `dec` reads "{}" back as an empty table, so nothing
--- downstream can tell the difference between that and a NULL column.
---@param t table?
---@return string?
local function enc(t)
    if t == nil then
        return nil
    end
    if type(t) ~= "table" then
        t = {}
    end
    local ok, s = pcall(vim.json.encode, t)
    -- An unencodable value (a cycle, a function) is a programming error, not user data: clear the
    -- column rather than silently leaving whatever it held before, which would be the same trap.
    return ok and s or "{}"
end

--- Rows of `tbl` matching `where`, sorted by `ord` (then id) — the canonical child ordering.
---@param tbl string
---@param where table?
---@return table[]
local function ordered(tbl, where)
    local d = db()
    if not d then
        return {}
    end
    local rows = d:find(tbl, where) or {}
    table.sort(rows, function(a, b)
        local ao, bo = a.ord or 0, b.ord or 0
        if ao ~= bo then
            return ao < bo
        end
        return (a.id or 0) < (b.id or 0)
    end)
    return rows
end

--- The next free `ord` under a parent (append position).
---@param tbl string
---@param where table
---@return integer
local function next_ord(tbl, where)
    local rows = ordered(tbl, where)
    local last = rows[#rows]
    return (last and (last.ord or 0) or 0) + 1
end

--- Swap two rows' `ord` — the primitive behind move up/down.
---@param tbl string
---@param a table
---@param b table
---@return boolean
local function swap_ord(tbl, a, b)
    local d = db()
    if not d or not a or not b then
        return false
    end
    local ao, bo = a.ord or 0, b.ord or 0
    d:update(tbl, { id = a.id }, { ord = bo })
    d:update(tbl, { id = b.id }, { ord = ao })
    return true
end

--- Move the row with `id` one step within `rows` — the list of its DISPLAYED siblings, in order.
---
--- The sibling list is passed in rather than derived from a where-clause because `ord` is allocated
--- collection-wide while the tree is drawn per FOLDER: `ordered("request", { collection_id })` spans
--- every folder, so its "adjacent" row can live somewhere the user cannot see. Swapping two ords
--- inside one folder leaves every other folder's rows untouched, so the collection-wide sequence
--- stays a valid (sparse) order for all of them.
---@param tbl string
---@param rows table[]  the sibling list, in display order
---@param id integer
---@param dir integer   -1 up, 1 down
---@return boolean moved
local function move_in(tbl, rows, id, dir)
    for i, r in ipairs(rows) do
        if r.id == id then
            local j = i + dir
            if j < 1 or j > #rows then
                return false -- already at the edge
            end
            return swap_ord(tbl, r, rows[j])
        end
    end
    return false
end

-- ── workspaces ───────────────────────────────────────────────────────────────

--- Every workspace, oldest first.
---@return table[]
function M.workspaces()
    local d = db()
    if not d then
        return {}
    end
    local rows = d:find("workspace") or {}
    table.sort(rows, function(a, b)
        return (a.id or 0) < (b.id or 0)
    end)
    return rows
end

--- The active workspace, creating a default one on first use so the library always has a home.
---@return table?
function M.active_workspace()
    local d = db()
    if not d then
        return nil
    end
    local rows = d:find("workspace", { active = 1 }) or {}
    if rows[1] then
        return rows[1]
    end
    local all = M.workspaces()
    if all[1] then
        M.set_active_workspace(all[1].id)
        return all[1]
    end
    local id = M.add_workspace("Default")
    return id and d:find("workspace", { id = id })[1] or nil
end

--- Create a workspace (the first one becomes active).
---@param name string
---@return integer? id
function M.add_workspace(name)
    local d = db()
    if not d or not name or name == "" then
        return nil
    end
    local first = #M.workspaces() == 0
    local id = d:insert("workspace", {
        name = name,
        active = first and 1 or 0,
        created = now(),
        updated = now(),
    })
    return type(id) == "number" and id or nil
end

--- Make `id` the only active workspace.
---@param id integer
---@return boolean
function M.set_active_workspace(id)
    local d = db()
    if not d then
        return false
    end
    for _, w in ipairs(M.workspaces()) do
        d:update("workspace", { id = w.id }, { active = (w.id == id) and 1 or 0 })
    end
    return true
end

--- Rename a workspace.
---@param id integer
---@param name string
---@return boolean
function M.rename_workspace(id, name)
    local d = db()
    if not d or not name or name == "" then
        return false
    end
    return d:update("workspace", { id = id }, { name = name, updated = now() }) ~= false
end

--- Delete a workspace and everything under it (collections → folders/requests/examples, envs).
---@param id integer
---@return boolean
function M.delete_workspace(id)
    local d = db()
    if not d then
        return false
    end
    for _, c in ipairs(M.collections(id)) do
        M.delete_collection(c.id)
    end
    for _, e in ipairs(M.environments(id)) do
        d:remove("environment", { id = e.id })
    end
    return d:remove("workspace", { id = id }) ~= false
end

-- ── collections ──────────────────────────────────────────────────────────────

--- Collections of a workspace, in `ord`.
---@param workspace_id integer
---@return table[]
function M.collections(workspace_id)
    return ordered("collection", { workspace_id = workspace_id })
end

--- One collection by id, with its json columns (`auth`, `vars`) inflated — the sibling of
--- `M.request(id)`, needed by anything that works on a collection it was handed rather than one it
--- just listed (the exporter, the collection runner's report).
---@param id integer
---@return table?
function M.collection(id)
    local d = db()
    if not d then
        return nil
    end
    local row = (d:find("collection", { id = id }) or {})[1]
    if not row then
        return nil
    end
    row.auth = dec(row.auth_json)
    row.vars = dec(row.vars_json)
    row.headers = dec(row.headers_json)
    row.grpc = dec(row.grpc_json)
    return row
end

--- Create a collection at the end of the workspace's list.
---@param workspace_id integer
---@param name string
---@param opts { description?: string, auth?: table, vars?: table, headers?: table, grpc?: table, pre_script?: string, post_script?: string }?
---@return integer? id
function M.add_collection(workspace_id, name, opts)
    local d = db()
    if not d or not name or name == "" then
        return nil
    end
    opts = opts or {}
    local id = d:insert("collection", {
        workspace_id = workspace_id,
        name = name,
        ord = next_ord("collection", { workspace_id = workspace_id }),
        description = opts.description,
        auth_json = enc(opts.auth),
        vars_json = enc(opts.vars),
        headers_json = enc(opts.headers),
        grpc_json = enc(opts.grpc),
        pre_script = opts.pre_script,
        post_script = opts.post_script,
    })
    return type(id) == "number" and id or nil
end

--- Patch a collection. Table fields (`auth`, `vars`, `headers`, `grpc`) are encoded here.
---@param id integer
---@param fields { name?: string, description?: string, auth?: table, vars?: table, headers?: table, grpc?: table, pre_script?: string, post_script?: string }
---@return boolean
function M.update_collection(id, fields)
    local d = db()
    if not d then
        return false
    end
    local set = {}
    for _, k in ipairs({ "name", "description", "pre_script", "post_script" }) do
        if fields[k] ~= nil then
            set[k] = fields[k]
        end
    end
    if fields.auth ~= nil then
        set.auth_json = enc(fields.auth)
    end
    if fields.vars ~= nil then
        set.vars_json = enc(fields.vars)
    end
    if fields.headers ~= nil then
        set.headers_json = enc(fields.headers)
    end
    if fields.grpc ~= nil then
        -- An empty table stores "{}", which `dec` reads back as an empty table — render treats that as
        -- "no defaults" (it guards on a non-empty grpc), so an empty grpc cleanly clears inheritance.
        set.grpc_json = enc(fields.grpc)
    end
    if vim.tbl_isempty(set) then
        return true
    end
    return d:update("collection", { id = id }, set) ~= false
end

--- Delete a collection and its folders / requests / examples.
---@param id integer
---@return boolean
function M.delete_collection(id)
    local d = db()
    if not d then
        return false
    end
    for _, r in ipairs(d:find("request", { collection_id = id }) or {}) do
        d:remove("example", { request_id = r.id })
    end
    d:remove("request", { collection_id = id })
    d:remove("folder", { collection_id = id })
    return d:remove("collection", { id = id }) ~= false
end

--- Move a collection one step within its workspace.
---@param workspace_id integer
---@param id integer
---@param dir integer  -1 up, 1 down
---@return boolean
function M.move_collection(workspace_id, id, dir)
    return move_in("collection", M.collections(workspace_id), id, dir)
end

-- ── folders ──────────────────────────────────────────────────────────────────

--- Folders directly under a collection (`parent_folder_id = nil`) or under a parent folder.
---@param collection_id integer
---@param parent_folder_id integer?
---@return table[]
function M.folders(collection_id, parent_folder_id)
    local rows = ordered("folder", { collection_id = collection_id })
    local out = {}
    for _, f in ipairs(rows) do
        -- sqlite returns NULL as nil; compare loosely so both "root" forms match
        local parent = f.parent_folder_id
        if (parent_folder_id == nil and parent == nil) or (parent_folder_id ~= nil and parent == parent_folder_id) then
            out[#out + 1] = f
        end
    end
    return out
end

--- Create a folder at the end of its parent's list.
---@param collection_id integer
---@param name string
---@param parent_folder_id integer?
---@return integer? id
function M.add_folder(collection_id, name, parent_folder_id)
    local d = db()
    if not d or not name or name == "" then
        return nil
    end
    local id = d:insert("folder", {
        collection_id = collection_id,
        parent_folder_id = parent_folder_id,
        name = name,
        ord = next_ord("folder", { collection_id = collection_id }),
    })
    return type(id) == "number" and id or nil
end

--- Rename a folder.
---@param id integer
---@param name string
---@return boolean
function M.rename_folder(id, name)
    local d = db()
    if not d or not name or name == "" then
        return false
    end
    return d:update("folder", { id = id }, { name = name }) ~= false
end

--- Delete a folder, its nested folders, and every request (and example) inside them.
---@param id integer
---@return boolean
function M.delete_folder(id)
    local d = db()
    if not d then
        return false
    end
    local row = (d:find("folder", { id = id }) or {})[1]
    if not row then
        return false
    end
    for _, child in ipairs(M.folders(row.collection_id, id)) do
        M.delete_folder(child.id)
    end
    for _, r in ipairs(d:find("request", { folder_id = id }) or {}) do
        d:remove("example", { request_id = r.id })
    end
    d:remove("request", { folder_id = id })
    return d:remove("folder", { id = id }) ~= false
end

--- Move a folder one step among its siblings — the folders sharing its `parent_folder_id`.
---@param collection_id integer
---@param id integer
---@param dir integer
---@return boolean
function M.move_folder(collection_id, id, dir)
    local d = db()
    if not d then
        return false
    end
    local row = (d:find("folder", { id = id }) or {})[1]
    if not row then
        return false
    end
    return move_in("folder", M.folders(collection_id, row.parent_folder_id), id, dir)
end

-- ── requests ─────────────────────────────────────────────────────────────────

--- Decode a request row's json columns into tables (`headers`, `params`, `auth`, `vars`).
---@param row table?
---@return table?
local function inflate(row)
    if not row then
        return nil
    end
    row.headers = dec(row.headers_json)
    row.params = dec(row.params_json)
    row.auth = dec(row.auth_json)
    row.vars = dec(row.vars_json)
    return row
end

--- Requests directly under a collection (`folder_id = nil`) or inside a folder, in `ord`.
---@param collection_id integer
---@param folder_id integer?
---@return table[]
function M.requests(collection_id, folder_id)
    local rows = ordered("request", { collection_id = collection_id })
    local out = {}
    for _, r in ipairs(rows) do
        local f = r.folder_id
        if (folder_id == nil and f == nil) or (folder_id ~= nil and f == folder_id) then
            out[#out + 1] = inflate(r)
        end
    end
    return out
end

--- One request by id, with its json columns inflated.
---@param id integer
---@return table?
function M.request(id)
    local d = db()
    if not d then
        return nil
    end
    return inflate((d:find("request", { id = id }) or {})[1])
end

--- Create a request at the end of its parent's list.
---@param collection_id integer
---@param fields { name: string, method?: string, url?: string, folder_id?: integer, headers?: table, params?: table, body?: string, body_type?: string, auth?: table, pre_script?: string, post_script?: string, docs?: string, vars?: table }
---@return integer? id
function M.add_request(collection_id, fields)
    local d = db()
    if not d or not fields or not fields.name or fields.name == "" then
        return nil
    end
    local id = d:insert("request", {
        collection_id = collection_id,
        folder_id = fields.folder_id,
        ord = next_ord("request", { collection_id = collection_id }),
        name = fields.name,
        method = fields.method or "GET",
        url = fields.url,
        headers_json = enc(fields.headers),
        params_json = enc(fields.params),
        body = fields.body,
        body_type = fields.body_type,
        auth_json = enc(fields.auth),
        pre_script = fields.pre_script,
        post_script = fields.post_script,
        docs = fields.docs,
        vars_json = enc(fields.vars),
    })
    return type(id) == "number" and id or nil
end

--- Patch a request — the write-back target of the bound `.http` buffer.
---@param id integer
---@param fields table  any subset of the add_request fields
---@return boolean
function M.update_request(id, fields)
    local d = db()
    if not d then
        return false
    end
    local set = {}
    for _, k in ipairs({ "name", "method", "url", "body", "body_type", "pre_script", "post_script", "docs" }) do
        if fields[k] ~= nil then
            set[k] = fields[k]
        end
    end
    if fields.folder_id ~= nil then
        set.folder_id = fields.folder_id
    end
    for col, key in pairs({ headers_json = "headers", params_json = "params", auth_json = "auth", vars_json = "vars" }) do
        if fields[key] ~= nil then
            set[col] = enc(fields[key])
        end
    end
    if vim.tbl_isempty(set) then
        return true
    end
    return d:update("request", { id = id }, set) ~= false
end

--- Delete a request and its saved examples.
---@param id integer
---@return boolean
function M.delete_request(id)
    local d = db()
    if not d then
        return false
    end
    d:remove("example", { request_id = id })
    return d:remove("request", { id = id }) ~= false
end

--- Move a request one step among its siblings — the requests sharing its `folder_id`.
---@param collection_id integer
---@param id integer
---@param dir integer
---@return boolean
function M.move_request(collection_id, id, dir)
    local d = db()
    if not d then
        return false
    end
    local row = (d:find("request", { id = id }) or {})[1]
    if not row then
        return false
    end
    return move_in("request", M.requests(collection_id, row.folder_id), id, dir)
end

--- Re-parent a request (drop it into another folder / collection), appended at the end there.
---@param id integer
---@param collection_id integer
---@param folder_id integer?
---@return boolean
function M.reparent_request(id, collection_id, folder_id)
    local d = db()
    if not d then
        return false
    end
    return d:update("request", { id = id }, {
        collection_id = collection_id,
        folder_id = folder_id,
        ord = next_ord("request", { collection_id = collection_id }),
    }) ~= false
end

-- ── examples (saved responses) ───────────────────────────────────────────────

--- Saved examples of a request, newest first.
---@param request_id integer
---@return table[]
function M.examples(request_id)
    local d = db()
    if not d then
        return {}
    end
    local rows = d:find("example", { request_id = request_id }) or {}
    for _, r in ipairs(rows) do
        r.headers = dec(r.headers_json)
    end
    table.sort(rows, function(a, b)
        return (a.created or 0) > (b.created or 0)
    end)
    return rows
end

--- Attach a response to a request as a named example.
---@param request_id integer
---@param fields { name?: string, status?: integer, headers?: table, body?: string, ms?: integer, size?: integer }
---@return integer? id
function M.add_example(request_id, fields)
    local d = db()
    if not d then
        return nil
    end
    fields = fields or {}
    local id = d:insert("example", {
        request_id = request_id,
        name = fields.name,
        status = fields.status,
        headers_json = enc(fields.headers),
        body = fields.body,
        ms = fields.ms,
        size = fields.size,
        created = now(),
    })
    return type(id) == "number" and id or nil
end

--- Delete one saved example.
---@param id integer
---@return boolean
function M.delete_example(id)
    local d = db()
    return d and d:remove("example", { id = id }) ~= false or false
end

-- ── environments ─────────────────────────────────────────────────────────────

--- Environments of a workspace, with `vars` inflated.
---@param workspace_id integer
---@return table[]
function M.environments(workspace_id)
    local d = db()
    if not d then
        return {}
    end
    local rows = d:find("environment", { workspace_id = workspace_id }) or {}
    for _, e in ipairs(rows) do
        e.vars = dec(e.vars_json)
    end
    table.sort(rows, function(a, b)
        return (a.id or 0) < (b.id or 0)
    end)
    return rows
end

--- The active environment of a workspace, or nil.
---@param workspace_id integer
---@return table?
function M.active_environment(workspace_id)
    for _, e in ipairs(M.environments(workspace_id)) do
        if e.active == 1 then
            return e
        end
    end
    return nil
end

--- Create an environment.
---@param workspace_id integer
---@param name string
---@param vars table?
---@param is_private boolean?
---@return integer? id
function M.add_environment(workspace_id, name, vars, is_private)
    local d = db()
    if not d or not name or name == "" then
        return nil
    end
    local id = d:insert("environment", {
        workspace_id = workspace_id,
        name = name,
        vars_json = enc(vars),
        is_private = is_private and 1 or 0,
        active = 0,
    })
    return type(id) == "number" and id or nil
end

--- Replace an environment's variables.
---@param id integer
---@param vars table
---@return boolean
function M.update_environment(id, vars)
    local d = db()
    if not d then
        return false
    end
    return d:update("environment", { id = id }, { vars_json = enc(vars) }) ~= false
end

--- Make `id` the only active environment of its workspace.
---@param workspace_id integer
---@param id integer?  nil = deactivate all
---@return boolean
function M.set_active_environment(workspace_id, id)
    local d = db()
    if not d then
        return false
    end
    for _, e in ipairs(M.environments(workspace_id)) do
        d:update("environment", { id = e.id }, { active = (e.id == id) and 1 or 0 })
    end
    return true
end

--- Delete an environment.
---@param id integer
---@return boolean
function M.delete_environment(id)
    local d = db()
    return d and d:remove("environment", { id = id }) ~= false or false
end

-- ── runs (collection runner history) ─────────────────────────────────────────

--- Open a run row; returns its id so results can be appended as they finish.
---@param fields { collection_id?: integer, folder_id?: integer, env_id?: integer, iterations?: integer }
---@return integer? id
function M.start_run(fields)
    local d = db()
    if not d then
        return nil
    end
    fields = fields or {}
    local id = d:insert("run", {
        collection_id = fields.collection_id,
        folder_id = fields.folder_id,
        env_id = fields.env_id,
        started = now(),
        iterations = fields.iterations or 1,
        passed = 0,
        failed = 0,
    })
    return type(id) == "number" and id or nil
end

--- Append one request × iteration result to a run.
---@param run_id integer
---@param fields { request_id?: integer, iteration?: integer, status?: integer, ms?: integer, passed?: integer, failed?: integer, error?: string }
---@return boolean
function M.add_run_result(run_id, fields)
    local d = db()
    if not d then
        return false
    end
    fields = fields or {}
    return d:insert("run_result", {
        run_id = run_id,
        request_id = fields.request_id,
        iteration = fields.iteration or 1,
        status = fields.status,
        ms = fields.ms,
        passed = fields.passed or 0,
        failed = fields.failed or 0,
        error = fields.error,
    }) ~= false
end

--- Close a run, stamping the aggregate pass/fail totals.
---@param run_id integer
---@param totals { passed?: integer, failed?: integer }?
---@return boolean
function M.finish_run(run_id, totals)
    local d = db()
    if not d then
        return false
    end
    totals = totals or {}
    return d:update("run", { id = run_id }, {
        finished = now(),
        passed = totals.passed or 0,
        failed = totals.failed or 0,
    }) ~= false
end

--- Runs, newest first (optionally only a collection's).
---@param collection_id integer?
---@return table[]
function M.runs(collection_id)
    local d = db()
    if not d then
        return {}
    end
    local rows = d:find("run", collection_id and { collection_id = collection_id } or nil) or {}
    table.sort(rows, function(a, b)
        return (a.started or 0) > (b.started or 0)
    end)
    return rows
end

--- Results of one run, in execution order.
---@param run_id integer
---@return table[]
function M.run_results(run_id)
    local d = db()
    if not d then
        return {}
    end
    local rows = d:find("run_result", { run_id = run_id }) or {}
    table.sort(rows, function(a, b)
        return (a.id or 0) < (b.id or 0)
    end)
    return rows
end

--- The whole tree of a workspace, ready for the explorer: collections → folders → requests.
--- One call, so the panel never issues per-node queries while rendering.
---@param workspace_id integer
---@return table[]  { { collection, folders = { { folder, folders = {…}, requests = {…} } }, requests = {…} } }
function M.tree(workspace_id)
    local out = {}
    for _, c in ipairs(M.collections(workspace_id)) do
        local function walk(parent_id)
            local nodes = {}
            for _, f in ipairs(M.folders(c.id, parent_id)) do
                nodes[#nodes + 1] = {
                    folder = f,
                    folders = walk(f.id),
                    requests = M.requests(c.id, f.id),
                }
            end
            return nodes
        end
        out[#out + 1] = {
            collection = c,
            folders = walk(nil),
            requests = M.requests(c.id, nil),
        }
    end
    return out
end

return M
