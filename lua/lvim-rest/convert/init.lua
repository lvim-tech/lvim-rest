-- lvim-rest.convert: import / export between external formats and lvim-rest.
--
-- The dispatcher plus the pure-Lua curl importer. The format modules (`convert.postman`,
-- `convert.openapi`, `convert.har`) register themselves below; `import` offers a picker or takes a
-- format id, and `export` turns a stored collection into a shareable artifact. Every transform is
-- pure-Lua JSON — the one exception is a YAML OpenAPI spec, which is handed to `yq` rather than
-- guessed at (see `convert.openapi` for why).
--
-- Also here: SAVE INTO COLLECTION — the bridge from an ad-hoc `.http` request, or a line of history,
-- into the library. It is the move people actually make ("that worked — keep it"), and without it
-- the library is something you have to populate deliberately instead of by working.
--
---@module "lvim-rest.convert"

local M = {}

--- Import a pasted curl command: parse it and insert the `.http` snippet at the cursor.
function M.import_curl()
    require("lvim-ui").input({
        title = "Paste a curl command",
        height = 6, -- multiline
        filetype = "sh",
        callback = function(ok, text)
            if not ok or not text or vim.trim(text) == "" then
                return
            end
            local lines = require("lvim-rest.parser.curl").to_http(text)
            if not lines then
                vim.notify("lvim-rest: could not parse that curl command", vim.log.levels.WARN)
                return
            end
            -- Insert with a leading separator so it becomes its own request block.
            local snippet = vim.list_extend({ "", "### imported" }, lines)
            local row = vim.api.nvim_win_get_cursor(0)[1]
            vim.api.nvim_buf_set_lines(0, row, row, false, snippet)
            vim.notify("lvim-rest: inserted imported request", vim.log.levels.INFO)
        end,
    })
end

--- Ask for a file path (with completion) and hand it to `fn`.
---@param title string
---@param fn fun(path: string)
local function ask_file(title, fn)
    require("lvim-ui").input({
        title = title,
        default = vim.fn.getcwd() .. "/",
        completion = "file",
        callback = function(ok, path)
            if ok and path and vim.trim(path) ~= "" then
                fn(vim.fn.expand(vim.trim(path)))
            end
        end,
    })
end

--- After an import: show the library so the result is visible rather than merely announced.
---@param cid integer?
local function reveal(cid)
    if not cid then
        return
    end
    local ok, explorer = pcall(require, "lvim-rest.ui.explorer")
    if ok then
        explorer.refresh()
        explorer.open({ enter = true })
    end
end

-- The registry of importers by format id; the format modules are wired in right below.
---@type table<string, { label: string, run: fun() }>
local importers = {
    curl = { label = "curl command", run = M.import_curl },
    postman = {
        label = "Postman collection / environment (v2.1)",
        run = function()
            ask_file("Postman export (.json)", function(path)
                reveal(require("lvim-rest.convert.postman").import_file(path))
            end)
        end,
    },
    openapi = {
        label = "OpenAPI 3.x / Swagger 2.0",
        run = function()
            ask_file("OpenAPI description (.json / .yaml)", function(path)
                reveal(require("lvim-rest.convert.openapi").import_file(path))
            end)
        end,
    },
    har = {
        label = "HAR recording",
        run = function()
            ask_file("HAR file (.har)", function(path)
                reveal(require("lvim-rest.convert.har").import_file(path))
            end)
        end,
    },
}

--- Register an importer (phase-8 format modules call this).
---@param id string
---@param label string
---@param run fun()
function M.register_importer(id, label, run)
    importers[id] = { label = label, run = run }
end

--- Open the import format picker (or run `fmt` directly when given).
---@param fmt string?
function M.import(fmt)
    if fmt and importers[fmt] then
        importers[fmt].run()
        return
    end
    local ids, items = {}, {}
    for id, imp in pairs(importers) do
        ids[#ids + 1] = id
        items[#items + 1] = { label = imp.label, id = id }
    end
    require("lvim-ui").select({
        title = "Import format",
        items = items,
        callback = function(confirmed, index)
            if not confirmed then
                return
            end
            importers[items[index].id].run()
        end,
    })
end

--- Choose one of the workspace's collections, then run `fn(id, name)`.
---@param title string
---@param fn fun(id: integer, name: string)
local function pick_collection(title, fn)
    local library = require("lvim-rest.store.library")
    local ws = library.active_workspace()
    local rows = ws and library.collections(ws.id) or {}
    if #rows == 0 then
        vim.notify("lvim-rest: the workspace has no collections", vim.log.levels.WARN)
        return
    end
    local items = {}
    for _, c in ipairs(rows) do
        items[#items + 1] = { label = c.name, icon = require("lvim-rest.config").icons.collection, _id = c.id }
    end
    require("lvim-ui").select({
        title = title,
        items = items,
        callback = function(confirmed, index)
            if confirmed and index then
                fn(items[index]._id, items[index].label)
            end
        end,
    })
end

M.pick_collection = pick_collection

-- The registry of exporters by format id.
---@type table<string, { label: string, run: fun() }>
local exporters = {
    postman = {
        label = "Postman collection (v2.1)",
        run = function()
            pick_collection("Export which collection?", function(id, name)
                ask_file("Write to", function(path)
                    -- A directory (or a bare name) gets the collection's own filename, so exporting
                    -- is one keystroke away from done.
                    if vim.fn.isdirectory(path) == 1 then
                        path = path:gsub("/$", "") .. "/" .. name:gsub("[^%w%-_. ]", "_") .. ".postman_collection.json"
                    end
                    require("lvim-rest.convert.postman").export_file(id, path)
                end)
            end)
        end,
    },
}

--- Register an exporter (phase-8 format modules call this).
---@param id string
---@param label string
---@param run fun()
function M.register_exporter(id, label, run)
    exporters[id] = { label = label, run = run }
end

-- ── save into collection ─────────────────────────────────────────────────────

--- Choose a folder inside `collection_id` (or its root), then run `fn(folder_id)`.
---@param collection_id integer
---@param fn fun(folder_id: integer?)
local function pick_folder(collection_id, fn)
    local library = require("lvim-rest.store.library")
    local items = { { label = "(collection root)", icon = require("lvim-rest.config").icons.collection } }
    local ids = { false }
    -- Flattened with a breadcrumb path: a nested folder tree in a chooser is a tree you have to
    -- walk, and the point here is to pick a destination in one keystroke.
    local function walk(parent, prefix)
        for _, f in ipairs(library.folders(collection_id, parent)) do
            items[#items + 1] = { label = prefix .. f.name, icon = require("lvim-rest.config").icons.folder }
            ids[#ids + 1] = f.id
            walk(f.id, prefix .. f.name .. " ➤ ")
        end
    end
    walk(nil, "")
    if #items == 1 then
        return fn(nil)
    end
    require("lvim-ui").select({
        title = "Save where?",
        items = items,
        callback = function(confirmed, index)
            if confirmed and index then
                fn(ids[index] or nil)
            end
        end,
    })
end

--- Save a parsed request into the library.
---@param req LvimRestRequest
---@param default_name string?
---@return nil
function M.save_request(req, default_name)
    local library = require("lvim-rest.store.library")
    pick_collection("Save into which collection?", function(cid)
        pick_folder(cid, function(folder_id)
            require("lvim-ui").input({
                title = "Request name",
                default = req.name or default_name or (req.method .. " " .. req.url),
                callback = function(ok, name)
                    if not ok or not name or vim.trim(name) == "" then
                        return
                    end
                    local headers = {}
                    for _, h in ipairs(req.headers or {}) do
                        headers[#headers + 1] = { name = h.name, value = h.value }
                    end
                    local vars = {}
                    for _, v in ipairs(req.vars or {}) do
                        vars[#vars + 1] = { name = v.name, value = v.value }
                    end
                    local id = library.add_request(cid, {
                        name = vim.trim(name),
                        method = req.method,
                        url = req.url,
                        headers = headers,
                        body = req.body,
                        vars = vars,
                        folder_id = folder_id,
                        auth = req.directives and req.directives.auth or nil,
                        pre_script = nil,
                        post_script = nil,
                    })
                    if id then
                        vim.notify(("lvim-rest: saved %q into the library"):format(vim.trim(name)), vim.log.levels.INFO)
                        local ok_ex, explorer = pcall(require, "lvim-rest.ui.explorer")
                        if ok_ex then
                            explorer.refresh()
                        end
                    else
                        vim.notify("lvim-rest: could not save the request", vim.log.levels.ERROR)
                    end
                end,
            })
        end)
    end)
end

--- Save the request under the cursor in `bufnr` into the library.
---@param bufnr integer?
---@param lnum integer?
---@return nil
function M.save_into_collection(bufnr, lnum)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
    local parser = require("lvim-rest.parser")
    local doc = parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    local req = parser.request_at(doc, lnum)
    if not req then
        vim.notify("lvim-rest: no request under the cursor", vim.log.levels.WARN)
        return
    end
    -- A request already bound to a library row would otherwise be duplicated by "save".
    local bound = require("lvim-rest.store.bind").request_of(bufnr)
    if bound then
        vim.notify("lvim-rest: this request is already in the library — `:w` updates it", vim.log.levels.INFO)
        return
    end
    -- Document-level variables are what make the request runnable; they come along as request-local
    -- ones, since a stored request has no document around it.
    local carried = vim.deepcopy(req)
    carried.vars = vim.list_extend(vim.deepcopy(doc.vars or {}), req.vars or {})
    M.save_request(carried)
end

--- Open the export format picker.
function M.export()
    local items = {}
    local ids = {}
    for id, exp in pairs(exporters) do
        ids[#ids + 1] = id
        items[#items + 1] = { label = exp.label, id = id }
    end
    require("lvim-ui").select({
        title = "Export format",
        items = items,
        callback = function(confirmed, index)
            if not confirmed then
                return
            end
            exporters[items[index].id].run()
        end,
    })
end

return M
