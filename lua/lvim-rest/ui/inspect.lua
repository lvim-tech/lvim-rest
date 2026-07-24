-- lvim-rest.ui.inspect: the fully-resolved request preview (`:LvimRest inspect`).
--
-- Shows the request under the cursor with every variable substituted, headers merged and (later)
-- auth applied, in a read-only lvim-ui.info window. Secrets are MASKED per `scrub_secrets` — an
-- Authorization / Cookie value, or any vault/prompt-flagged variable, renders as `***` so the
-- resolved view never echoes a token.
--
---@module "lvim-rest.ui.inspect"

local config = require("lvim-rest.config")

local M = {}

--- Whether a header carries a secret that should be masked.
---@param name string
---@return boolean
local function is_secret_header(name)
    local n = name:lower()
    return n == "authorization" or n == "cookie" or n == "set-cookie" or n:match("api%-?key") ~= nil
end

--- Build the resolved-request text for a request under `lnum` in `bufnr`.
---@param bufnr integer
---@param lnum integer
---@return string[]?
function M.build(bufnr, lnum)
    local parser = require("lvim-rest.parser")
    local vars = require("lvim-rest.vars")
    local doc = parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    local req = parser.request_at(doc, lnum)
    if not req or req.method == "" then
        return nil
    end
    local ctx = vars.build_context(doc, req, { path = vim.api.nvim_buf_get_name(bufnr) })
    local resolved = vars.resolve_request(req, ctx)

    local lines = {}
    lines[#lines + 1] = ("# %s"):format(resolved.name or "request")
    lines[#lines + 1] = ("%s %s"):format(resolved.method, resolved.url)
    for _, h in ipairs(resolved.headers) do
        local value = h.value
        if config.scrub_secrets and is_secret_header(h.name) then
            value = "***"
        end
        lines[#lines + 1] = ("%s: %s"):format(h.name, value)
    end
    if resolved.body and resolved.body ~= "" then
        lines[#lines + 1] = ""
        for _, l in ipairs(vim.split(resolved.body, "\n", { plain = true })) do
            lines[#lines + 1] = l
        end
    end
    return lines
end

--- Open the resolved-request inspect window for the request under the cursor.
---@param bufnr integer
---@param lnum integer
function M.show(bufnr, lnum)
    local lines = M.build(bufnr, lnum)
    if not lines then
        vim.notify("lvim-rest: no request under the cursor", vim.log.levels.WARN)
        return
    end
    require("lvim-ui").info(table.concat(lines, "\n"), { title = "Resolved request", filetype = "http" })
end

return M
