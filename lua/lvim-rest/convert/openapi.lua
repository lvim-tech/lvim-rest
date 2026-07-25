-- lvim-rest.convert.openapi: import an OpenAPI 3.x / Swagger 2.0 description as a collection.
--
-- One request per operation, grouped into a folder per TAG — which is how the documents themselves
-- are organised and therefore how people already think about the API. The server url becomes a
-- collection variable `{{baseUrl}}` so switching environments changes one value, not every request.
--
-- Path parameters keep their braces (`/users/{id}` is already `{id}`) but are ALSO declared as
-- request-local variables, so the request is runnable after filling one obvious blank rather than
-- after hunting through the url. Required query parameters are appended with empty values for the
-- same reason.
--
-- YAML is not parsed here. A correct YAML parser is a real piece of work and a subtly wrong one
-- would silently import a wrong API, so a `.yaml` spec is converted with `yq` when it is installed
-- and otherwise refused with a message that says exactly what to do. JSON needs nothing.
--
---@module "lvim-rest.convert.openapi"

local library = require("lvim-rest.store.library")

local M = {}

--- Notify through the plugin's prefix.
---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-rest: " .. msg, level or vim.log.levels.INFO)
end

-- The HTTP methods an OpenAPI path item may carry.
local METHODS = { "get", "put", "post", "delete", "options", "head", "patch", "trace" }

--- Read a spec: json directly, yaml through `yq` when it is available.
---@param path string
---@return table?, string? err
function M.read_spec(path)
    if vim.fn.filereadable(path) == 0 then
        return nil, ("no such file: %s"):format(path)
    end
    local text = table.concat(vim.fn.readfile(path), "\n")
    local lower = path:lower()
    if lower:match("%.ya?ml$") then
        if vim.fn.executable("yq") == 0 then
            return nil,
                "that is a YAML spec and `yq` is not installed — convert it first (`yq -o=json spec.yaml > spec.json`) or install yq"
        end
        local res = vim.system({ "yq", "-o=json", path }, { text = true }):wait()
        if res.code ~= 0 then
            return nil, ("yq could not read the spec: %s"):format(vim.trim(res.stderr or ""))
        end
        text = res.stdout or ""
    end
    local ok, decoded = pcall(vim.json.decode, text)
    if not ok or type(decoded) ~= "table" then
        return nil, "the spec is not valid json"
    end
    return decoded
end

--- The base url: OpenAPI 3 `servers[1].url`, or Swagger 2's host/basePath/schemes.
---@param spec table
---@return string
local function base_url(spec)
    if type(spec.servers) == "table" and type(spec.servers[1]) == "table" and spec.servers[1].url then
        local url = tostring(spec.servers[1].url)
        -- A server url may itself be templated (`https://{region}.api…`); the variables' defaults
        -- make it concrete, and anything left over stays a `{{var}}` the user fills in.
        for name, var in pairs(spec.servers[1].variables or {}) do
            if type(var) == "table" and var.default then
                url = url:gsub("{" .. name .. "}", tostring(var.default))
            end
        end
        return url
    end
    if spec.host then
        local scheme = (type(spec.schemes) == "table" and spec.schemes[1]) or "https"
        return ("%s://%s%s"):format(scheme, spec.host, spec.basePath or "")
    end
    return ""
end

--- A tiny example value for a schema, so a generated body is runnable rather than empty.
---@param schema table?
---@param depth integer?
---@return any
local function sample(schema, depth)
    depth = (depth or 0) + 1
    if type(schema) ~= "table" or depth > 6 then
        return vim.NIL
    end
    if schema.example ~= nil then
        return schema.example
    end
    if schema.default ~= nil then
        return schema.default
    end
    if type(schema.enum) == "table" and schema.enum[1] ~= nil then
        return schema.enum[1]
    end
    local t = schema.type
    if t == "object" or (schema.properties and not t) then
        local out = {}
        for name, prop in pairs(schema.properties or {}) do
            out[name] = sample(prop, depth)
        end
        return next(out) and out or vim.empty_dict()
    elseif t == "array" then
        return { sample(schema.items, depth) }
    elseif t == "integer" or t == "number" then
        return 0
    elseif t == "boolean" then
        return false
    elseif t == "string" then
        return schema.format and ("<" .. schema.format .. ">") or ""
    end
    -- A `$ref` is left as a marker: resolving refs properly means a full resolver, and a wrong
    -- guess would produce a body that looks right and is not.
    if schema["$ref"] then
        return tostring(schema["$ref"])
    end
    return vim.NIL
end

--- Turn one operation into a request row for `collection_id`.
---@param collection_id integer
---@param folder_id integer?
---@param path string
---@param method string
---@param op table
---@param shared table[]  path-level parameters
local function add_operation(collection_id, folder_id, path, method, op, shared)
    local url = "{{baseUrl}}" .. path
    local headers, vars = {}, {}
    local query = {}

    local params = {}
    for _, p in ipairs(shared or {}) do
        params[#params + 1] = p
    end
    for _, p in ipairs(op.parameters or {}) do
        params[#params + 1] = p
    end
    for _, p in ipairs(params) do
        if type(p) == "table" and p.name then
            local where = p["in"]
            if where == "path" then
                -- Declared as a request-local variable AND left in the url: the request is then one
                -- obvious blank away from running.
                vars[#vars + 1] =
                    { name = p.name, value = tostring(sample(p.schema) ~= vim.NIL and sample(p.schema) or "") }
                url = url:gsub("{" .. p.name .. "}", "{{" .. p.name .. "}}")
            elseif where == "query" and p.required then
                query[#query + 1] = ("%s="):format(p.name)
            elseif where == "header" then
                headers[#headers + 1] = { name = p.name, value = "" }
            end
        end
    end
    if #query > 0 then
        url = url .. (url:find("?", 1, true) and "&" or "?") .. table.concat(query, "&")
    end

    local body
    local content = type(op.requestBody) == "table" and op.requestBody.content or nil
    if type(content) == "table" then
        local json_media = content["application/json"] or content["application/problem+json"]
        if type(json_media) == "table" then
            local value = sample(json_media.schema)
            body = vim.json.encode(value ~= vim.NIL and value or vim.empty_dict())
            headers[#headers + 1] = { name = "Content-Type", value = "application/json" }
        else
            local media = next(content)
            if media then
                headers[#headers + 1] = { name = "Content-Type", value = media }
            end
        end
    end

    local docs = {}
    if op.summary then
        docs[#docs + 1] = tostring(op.summary)
    end
    if op.description then
        docs[#docs + 1] = tostring(op.description)
    end

    library.add_request(collection_id, {
        name = op.summary or op.operationId or (method:upper() .. " " .. path),
        method = method:upper(),
        url = url,
        headers = headers,
        body = body,
        vars = vars,
        folder_id = folder_id,
        docs = #docs > 0 and table.concat(docs, "\n\n") or nil,
    })
end

--- Import an OpenAPI / Swagger description into the active workspace.
---@param path string
---@return integer? collection_id
function M.import_file(path)
    local spec, err = M.read_spec(path)
    if not spec then
        notify(err or "could not read the spec", vim.log.levels.ERROR)
        return nil
    end
    if type(spec.paths) ~= "table" then
        notify("that does not look like an OpenAPI description (no `paths`)", vim.log.levels.ERROR)
        return nil
    end
    local ws = library.active_workspace()
    if not ws then
        notify("no workspace", vim.log.levels.ERROR)
        return nil
    end
    local info = type(spec.info) == "table" and spec.info or {}
    local cid = library.add_collection(ws.id, info.title or vim.fn.fnamemodify(path, ":t:r"), {
        description = info.description,
        vars = { { name = "baseUrl", value = base_url(spec) } },
    })
    if not cid then
        notify("could not create the collection", vim.log.levels.ERROR)
        return nil
    end

    -- One folder per tag, created on first use so an untagged API stays flat.
    local folders = {}
    local function folder_for(tag)
        if not tag then
            return nil
        end
        if folders[tag] == nil then
            folders[tag] = library.add_folder(cid, tag) or false
        end
        return folders[tag] or nil
    end

    local n = 0
    for p, item in pairs(spec.paths) do
        if type(item) == "table" then
            local shared = item.parameters or {}
            for _, method in ipairs(METHODS) do
                local op = item[method]
                if type(op) == "table" then
                    local tag = type(op.tags) == "table" and op.tags[1] or nil
                    add_operation(cid, folder_for(tag), p, method, op, shared)
                    n = n + 1
                end
            end
        end
    end
    notify(("imported %q — %d operation(s)"):format(info.title or "API", n))
    return cid
end

return M
