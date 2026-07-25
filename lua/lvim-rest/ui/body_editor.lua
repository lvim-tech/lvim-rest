-- lvim-rest.ui.body_editor: edit a request's BODY in a scratch split with the right filetype (json /
-- graphql for syntax highlight + the spec's own JSON diagnostic), then write it back through the
-- anchored editor's `set_body`. Multi-line and isolated from the `.http`, which a single-line panel row
-- cannot be. `:w` / `<C-s>` commits, `q` cancels. The `.http` buffer is edited ONLY on commit, only in
-- the body region (the request-line anchor is never disturbed).
--
---@module "lvim-rest.ui.body_editor"

local edit = require("lvim-rest.ui.edit")
local spec = require("lvim-rest.spec")

local M = {}

-- Body variant → scratch filetype (highlight + any ft-scoped diagnostics).
---@type table<string, string>
local FT = { json = "json", grpc_message = "json", graphql = "graphql" }

--- Open the body editor for the request at (`bufnr`, `lnum`).
---@param bufnr integer
---@param lnum integer
---@return nil
function M.open(bufnr, lnum)
    local ed = edit.attach(bufnr, lnum)
    if not ed then
        return vim.notify("lvim-rest: no request under the cursor", vim.log.levels.WARN)
    end
    local req = ed:request()
    if not req then
        return
    end
    local kind = spec.variant("body", req)
    if kind == "file" then
        return vim.notify(
            "lvim-rest: this request's body is a `< file` include — edit the file itself",
            vim.log.levels.INFO
        )
    end

    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].filetype = FT[kind] or "text"
    vim.bo[scratch].buftype = "acwrite" -- so `:w` fires BufWriteCmd (commit), never touches disk
    vim.bo[scratch].bufhidden = "wipe"
    vim.api.nvim_buf_set_name(scratch, ("lvim-rest://body/%s"):format(req.name or ("req@" .. lnum)))
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, vim.split(req.body or "", "\n", { plain = true }))
    vim.bo[scratch].modified = false

    vim.cmd("botright 14split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, scratch)

    local closed = false
    local function close()
        if closed then
            return
        end
        closed = true
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end
    local function commit()
        local content = table.concat(vim.api.nvim_buf_get_lines(scratch, 0, -1, false), "\n")
        if ed:valid() then
            ed:set_body(content)
        end
        vim.bo[scratch].modified = false
        close()
        vim.notify("lvim-rest: body updated", vim.log.levels.INFO)
    end

    vim.keymap.set("n", "<C-s>", commit, { buffer = scratch, silent = true })
    vim.keymap.set("n", "q", close, { buffer = scratch, silent = true })
    vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = scratch, callback = commit })
    vim.notify("lvim-rest: edit the body — :w / <C-s> saves, q cancels", vim.log.levels.INFO)
end

return M
