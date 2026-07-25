-- lvim-rest.convert.postman: Postman collection v2.1 — import and export.
--
-- The library was shaped after Postman's model (workspace ▸ collection ▸ folder ▸ request ▸ example)
-- precisely so this could be a mapping rather than a translation: an item with `item` is a folder, an
-- item with `request` is a request, `response[]` are examples, `variable[]` are collection variables.
-- Postman's `{{var}}` is our `{{var}}`, so nothing has to be rewritten.
--
-- SCRIPTS ARE NOT TRANSLATED. Postman's `event` scripts are JavaScript and ours are Lua; converting
-- one to the other is not something an importer can do correctly, and importing them as if they were
-- Lua would produce a request that fails the moment it runs. So an imported script is preserved
-- VERBATIM in the request's docs, clearly labelled and never executed — lossless, and honest about
-- what it is. On export our Lua scripts go back out as events typed `text/lua`, so a round-trip
-- through this plugin keeps them.
--
---@module "lvim-rest.convert.postman"

local library = require("lvim-rest.store.library")

local M = {}

--- Notify through the plugin's prefix.
---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-rest: " .. msg, level or vim.log.levels.INFO)
end

--- Read and decode a json file.
---@param path string
---@return table?, string? err
local function read_json(path)
    if vim.fn.filereadable(path) == 0 then
        return nil, ("no such file: %s"):format(path)
    end
    local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    if not ok or type(decoded) ~= "table" then
        return nil, "the file is not valid json"
    end
    return decoded
end

M.read_json = read_json

-- ── import ───────────────────────────────────────────────────────────────────

--- Postman's url is either a raw string or an object; the raw form is authoritative when present
--- because it is what the user actually typed, query string and all.
---@param url any
---@return string
local function url_of(url)
    if type(url) == "string" then
        return url
    end
    if type(url) ~= "table" then
        return ""
    end
    if type(url.raw) == "string" and url.raw ~= "" then
        return url.raw
    end
    local host = type(url.host) == "table" and table.concat(url.host, ".") or tostring(url.host or "")
    local path = type(url.path) == "table" and table.concat(url.path, "/") or tostring(url.path or "")
    local out = ("%s://%s%s%s"):format(
        url.protocol or "https",
        host,
        url.port and (":" .. url.port) or "",
        path ~= "" and ("/" .. path) or ""
    )
    local query = {}
    for _, q in ipairs(url.query or {}) do
        if not q.disabled and q.key then
            query[#query + 1] = ("%s=%s"):format(q.key, q.value or "")
        end
    end
    if #query > 0 then
        out = out .. "?" .. table.concat(query, "&")
    end
    return out
end

--- Headers, keeping order and dropping the ones Postman marked disabled.
---@param list table?
---@return LvimRestHeader[]
local function headers_of(list)
    local out = {}
    for _, h in ipairs(list or {}) do
        if type(h) == "table" and h.key and not h.disabled then
            out[#out + 1] = { name = h.key, value = tostring(h.value or "") }
        end
    end
    return out
end

--- The body, in whichever of Postman's modes it was written.
---@param body table?
---@return string?, LvimRestHeader[] implied  extra headers the mode implies
local function body_of(body)
    if type(body) ~= "table" then
        return nil, {}
    end
    local mode = body.mode
    if mode == "raw" then
        return body.raw, {}
    elseif mode == "urlencoded" then
        local parts = {}
        for _, kv in ipairs(body.urlencoded or {}) do
            if not kv.disabled and kv.key then
                parts[#parts + 1] = ("%s=%s"):format(kv.key, vim.uri_encode(tostring(kv.value or ""), "rfc2396"))
            end
        end
        return table.concat(parts, "&"), { { name = "Content-Type", value = "application/x-www-form-urlencoded" } }
    elseif mode == "formdata" then
        -- A multipart body cannot be reproduced as text; the fields are preserved as a readable
        -- form so nothing is lost, and the user can turn it into a real upload deliberately.
        local parts = {}
        for _, kv in ipairs(body.formdata or {}) do
            if not kv.disabled and kv.key then
                parts[#parts + 1] = ("%s=%s"):format(kv.key, kv.src or kv.value or "")
            end
        end
        return table.concat(parts, "\n"), {}
    elseif mode == "graphql" and type(body.graphql) == "table" then
        return body.graphql.query, {}
    elseif mode == "file" and type(body.file) == "table" then
        return nil, {}
    end
    return body.raw, {}
end

--- Postman auth → our `# @auth` directive shape. Unknown schemes are dropped rather than guessed.
---@param auth table?
---@return table? { scheme: string, args: string[] }
local function auth_of(auth)
    if type(auth) ~= "table" or not auth.type then
        return nil
    end
    --- Postman stores a scheme's parameters as a list of `{ key, value }`.
    ---@param list table?
    ---@return table<string, string>
    local function kv(list)
        local out = {}
        for _, e in ipairs(list or {}) do
            if type(e) == "table" and e.key then
                out[e.key] = tostring(e.value or "")
            end
        end
        return out
    end
    local t = tostring(auth.type):lower()
    if t == "bearer" then
        return { scheme = "bearer", args = { kv(auth.bearer).token or "" } }
    elseif t == "basic" then
        local p = kv(auth.basic)
        return { scheme = "basic", args = { p.username or "", p.password or "" } }
    elseif t == "apikey" then
        local p = kv(auth.apikey)
        return { scheme = "apikey", args = { p.key or "", p.value or "", (p["in"] or "header"):lower() } }
    elseif t == "oauth2" then
        -- The grant's own settings live in the environment file, so the directive only needs a
        -- profile id; the collection name is the natural default.
        return { scheme = "oauth2", args = { kv(auth.oauth2).profile or "default" } }
    elseif t == "noauth" then
        return { scheme = "none", args = {} }
    end
    return nil
end

--- Postman `event` scripts, rendered as documentation. See the module header for why they are not
--- translated into Lua.
---@param events table?
---@return string?
local function scripts_as_docs(events)
    local out = {}
    for _, e in ipairs(events or {}) do
        local src = type(e.script) == "table" and e.script.exec or nil
        local text = type(src) == "table" and table.concat(src, "\n") or (type(src) == "string" and src or nil)
        if text and vim.trim(text) ~= "" then
            out[#out + 1] = ("Postman %s script (JavaScript — imported for reference, not executed):"):format(
                e.listen or "event"
            )
            out[#out + 1] = text
        end
    end
    return #out > 0 and table.concat(out, "\n") or nil
end

--- Import one item tree into `collection_id` under `folder_id`.
---@param items table[]
---@param collection_id integer
---@param folder_id integer?
---@param counts { folders: integer, requests: integer, examples: integer }
local function import_items(items, collection_id, folder_id, counts)
    for _, item in ipairs(items or {}) do
        if type(item) ~= "table" then
            goto continue
        end
        if type(item.item) == "table" then
            local id = library.add_folder(collection_id, item.name or "folder", folder_id)
            counts.folders = counts.folders + 1
            if id then
                import_items(item.item, collection_id, id, counts)
            end
        elseif type(item.request) == "table" or type(item.request) == "string" then
            local req = type(item.request) == "table" and item.request or { method = "GET", url = item.request }
            local body, implied = body_of(req.body)
            local headers = headers_of(req.header)
            for _, h in ipairs(implied) do
                local present = false
                for _, existing in ipairs(headers) do
                    if existing.name:lower() == h.name:lower() then
                        present = true
                    end
                end
                if not present then
                    headers[#headers + 1] = h
                end
            end
            local docs = {}
            if type(req.description) == "string" and req.description ~= "" then
                docs[#docs + 1] = req.description
            elseif type(req.description) == "table" and req.description.content then
                docs[#docs + 1] = req.description.content
            end
            local scripts = scripts_as_docs(item.event)
            if scripts then
                docs[#docs + 1] = scripts
            end
            local rid = library.add_request(collection_id, {
                name = item.name or (req.method or "GET"),
                method = (req.method or "GET"):upper(),
                url = url_of(req.url),
                headers = headers,
                body = body,
                folder_id = folder_id,
                auth = auth_of(req.auth),
                docs = #docs > 0 and table.concat(docs, "\n\n") or nil,
            })
            counts.requests = counts.requests + 1
            -- Saved responses become examples — the same thing under a different name.
            for _, ex in ipairs(item.response or {}) do
                if rid and type(ex) == "table" then
                    library.add_example(rid, {
                        name = ex.name or "example",
                        status = tonumber(ex.code) or nil,
                        headers = headers_of(ex.header),
                        body = ex.body,
                    })
                    counts.examples = counts.examples + 1
                end
            end
        end
        ::continue::
    end
end

--- Import a Postman v2.1 collection file into the active workspace.
---@param path string
---@return integer? collection_id
function M.import_file(path)
    local doc, err = read_json(path)
    if not doc then
        notify(err or "could not read the file", vim.log.levels.ERROR)
        return nil
    end
    -- An ENVIRONMENT export has `values`, not `item`; it is a different file with the same extension,
    -- so it is recognised rather than rejected as a broken collection.
    if type(doc.values) == "table" and not doc.item then
        return M.import_environment(doc)
    end
    if type(doc.item) ~= "table" then
        notify("that is not a Postman collection (no `item` array)", vim.log.levels.ERROR)
        return nil
    end
    local ws = library.active_workspace()
    if not ws then
        notify("no workspace", vim.log.levels.ERROR)
        return nil
    end
    local name = (type(doc.info) == "table" and doc.info.name) or vim.fn.fnamemodify(path, ":t:r")
    local vars = {}
    for _, v in ipairs(doc.variable or {}) do
        if type(v) == "table" and v.key then
            vars[#vars + 1] = { name = v.key, value = tostring(v.value or "") }
        end
    end
    local cid = library.add_collection(ws.id, name, {
        description = type(doc.info) == "table" and doc.info.description or nil,
        vars = vars,
        auth = auth_of(doc.auth),
    })
    if not cid then
        notify("could not create the collection", vim.log.levels.ERROR)
        return nil
    end
    local counts = { folders = 0, requests = 0, examples = 0 }
    import_items(doc.item, cid, nil, counts)
    notify(
        ("imported %q — %d request(s), %d folder(s), %d example(s)"):format(
            name,
            counts.requests,
            counts.folders,
            counts.examples
        )
    )
    return cid
end

--- Import a Postman ENVIRONMENT export (`{ name, values: [{key, value, enabled}] }`).
---@param doc table
---@return integer? environment_id
function M.import_environment(doc)
    local ws = library.active_workspace()
    if not ws then
        return nil
    end
    local vars = {}
    for _, v in ipairs(doc.values or {}) do
        if type(v) == "table" and v.key and v.enabled ~= false then
            vars[#vars + 1] = { name = v.key, value = tostring(v.value or "") }
        end
    end
    local id = library.add_environment(ws.id, doc.name or "imported", vars)
    notify(("imported the environment %q (%d variable(s))"):format(doc.name or "imported", #vars))
    return id
end

-- ── export ───────────────────────────────────────────────────────────────────

--- Our request row → a Postman item.
---@param row table
---@return table
local function item_of(row)
    local header = {}
    for _, h in ipairs(row.headers or {}) do
        header[#header + 1] = { key = h.name, value = h.value }
    end
    local item = {
        name = row.name or "request",
        request = {
            method = (row.method or "GET"):upper(),
            header = header,
            url = { raw = row.url or "" },
            description = row.docs,
        },
    }
    if row.body and row.body ~= "" then
        item.request.body = { mode = "raw", raw = row.body }
    end
    if type(row.auth) == "table" and row.auth.scheme then
        local a, args = row.auth.scheme, row.auth.args or {}
        if a == "bearer" then
            item.request.auth = { type = "bearer", bearer = { { key = "token", value = args[1] or "" } } }
        elseif a == "basic" then
            item.request.auth = {
                type = "basic",
                basic = { { key = "username", value = args[1] or "" }, { key = "password", value = args[2] or "" } },
            }
        elseif a == "apikey" then
            item.request.auth = {
                type = "apikey",
                apikey = {
                    { key = "key", value = args[1] or "" },
                    { key = "value", value = args[2] or "" },
                    { key = "in", value = args[3] or "header" },
                },
            }
        elseif a == "none" then
            item.request.auth = { type = "noauth" }
        end
    end
    -- Our scripts are Lua; they go out typed as such rather than mislabelled as Postman JavaScript,
    -- so a round-trip through this plugin keeps them and Postman simply does not run them.
    local events = {}
    if row.pre_script and vim.trim(row.pre_script) ~= "" then
        events[#events + 1] = {
            listen = "prerequest",
            script = { type = "text/lua", exec = vim.split(row.pre_script, "\n", { plain = true }) },
        }
    end
    if row.post_script and vim.trim(row.post_script) ~= "" then
        events[#events + 1] = {
            listen = "test",
            script = { type = "text/lua", exec = vim.split(row.post_script, "\n", { plain = true }) },
        }
    end
    if #events > 0 then
        item.event = events
    end
    local examples = {}
    for _, ex in ipairs(library.examples(row.id) or {}) do
        local eh = {}
        for _, h in ipairs(ex.headers or {}) do
            eh[#eh + 1] = { key = h.name, value = h.value }
        end
        examples[#examples + 1] = {
            name = ex.name or "example",
            code = ex.status,
            status = ex.status_text,
            header = eh,
            body = ex.body,
        }
    end
    if #examples > 0 then
        item.response = examples
    end
    return item
end

--- A folder subtree → Postman items.
---@param collection_id integer
---@param folder_id integer?
---@return table[]
local function items_of(collection_id, folder_id)
    local out = {}
    for _, r in ipairs(library.requests(collection_id, folder_id)) do
        out[#out + 1] = item_of(r)
    end
    for _, f in ipairs(library.folders(collection_id, folder_id)) do
        out[#out + 1] = { name = f.name, item = items_of(collection_id, f.id) }
    end
    return out
end

--- Build the Postman v2.1 document for a stored collection.
---@param collection_id integer
---@return table?
function M.collection_document(collection_id)
    local col = library.collection(collection_id)
    if not col then
        return nil
    end
    local variable = {}
    for _, v in ipairs(col.vars or {}) do
        variable[#variable + 1] = { key = v.name, value = v.value }
    end
    return {
        info = {
            name = col.name,
            description = col.description,
            schema = "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
        },
        item = items_of(collection_id, nil),
        variable = variable,
    }
end

--- Export a stored collection to a file.
---@param collection_id integer
---@param path string
---@return boolean ok
function M.export_file(collection_id, path)
    local doc = M.collection_document(collection_id)
    if not doc then
        notify("no such collection", vim.log.levels.ERROR)
        return false
    end
    local ok = pcall(vim.fn.writefile, vim.split(vim.json.encode(doc), "\n", { plain = true }), path)
    if ok then
        notify(("exported to %s"):format(path))
    else
        notify(("could not write %s"):format(path), vim.log.levels.ERROR)
    end
    return ok
end

return M
