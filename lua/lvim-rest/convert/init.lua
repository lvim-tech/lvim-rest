-- lvim-rest.convert: import / export between external formats and lvim-rest.
--
-- The dispatcher + the pure-Lua curl importer (phase 3). Postman v2.1, OpenAPI 3.x and HAR importers
-- + Postman export are added in the import/export phase (their modules register here). `import`
-- offers a format picker; `export` turns the current buffer / a stored collection into a shareable
-- artifact. All transforms are pure-Lua JSON — no third-party library.
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

-- The registry of importers by format id. Extended by the format modules (phase 8).
---@type table<string, { label: string, run: fun() }>
local importers = {
    curl = { label = "curl command", run = M.import_curl },
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

-- The registry of exporters (Postman is added in phase 8).
---@type table<string, { label: string, run: fun() }>
local exporters = {}

--- Register an exporter (phase-8 format modules call this).
---@param id string
---@param label string
---@param run fun()
function M.register_exporter(id, label, run)
    exporters[id] = { label = label, run = run }
end

--- Open the export format picker.
function M.export()
    if vim.tbl_isempty(exporters) then
        vim.notify("lvim-rest: no exporters available yet (Postman export lands in a later phase)", vim.log.levels.INFO)
        return
    end
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
