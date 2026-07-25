-- lvim-rest.cmp: the lvim-cmp completion source for `.http` / `.rest` buffers. It completes directive
-- keys, auth schemes, HTTP methods and enum values from the SHARED spec (`lvim-rest.spec.complete`) —
-- the THIRD consumer of the one schema, so a completion can never offer something the validator would
-- reject. Registered through `lvim-cmp.register_source`; a no-op when lvim-cmp is not installed
-- (completion is an optional enhancement, reported by `:checkhealth`).
--
---@module "lvim-rest.cmp"

local M = {}

-- Our completion kind → LSP CompletionItemKind number (glyph/accent come from lvim-cmp.kinds).
local KIND = {
    directive = 14, -- Keyword
    scheme = 20, -- EnumMember
    method = 14, -- Keyword
    value = 12, -- Value
}

---@type table<string, boolean>
local FT = { http = true, rest = true }

-- The LvimCmpSource contract: name / enabled / get.
local source = {
    name = "lvim_rest",

    --- Only on our filetypes; the `b:lvim_cmp_enable` seam can still switch it off per buffer.
    ---@param ctx LvimCmpContext
    ---@return boolean
    enabled = function(ctx)
        if not FT[vim.bo[ctx.bufnr].filetype] then
            return false
        end
        return vim.b[ctx.bufnr].lvim_cmp_enable ~= false
    end,

    --- Map the spec's position-aware completions into lvim-cmp items.
    ---@param ctx LvimCmpContext
    ---@param cb fun(items: table[], incomplete: boolean)
    get = function(ctx, cb)
        local col = (ctx.cursor and ctx.cursor[2]) or #(ctx.line or "")
        local before = (ctx.line or ""):sub(1, col)
        local spec = require("lvim-rest.spec")
        local req
        local ok, parser = pcall(require, "lvim-rest.parser")
        if ok then
            local doc = parser.parse(vim.api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false))
            req = parser.request_at(doc, (ctx.cursor and ctx.cursor[1]) or 1)
        end
        spec.complete({ buf = ctx.bufnr, line = before, req = req }, function(comps)
            local items = {}
            for _, c in ipairs(comps) do
                items[#items + 1] = {
                    raw = { label = c.label, documentation = c.doc },
                    label = c.label,
                    filter_text = c.label,
                    sort_text = c.label,
                    kind = KIND[c.kind] or 1,
                }
            end
            cb(items, false)
        end)
    end,
}

--- Register the source with lvim-cmp. No-op when lvim-cmp is absent.
---@return nil
function M.setup()
    local ok, cmp = pcall(require, "lvim-cmp")
    if ok and type(cmp.register_source) == "function" then
        cmp.register_source(source)
    end
end

return M
