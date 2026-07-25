-- lvim-rest.fs: raw BYTE file io.
--
-- Every path in this plugin that touches a response body needs bytes, not lines. `vim.fn.readfile`
-- and `vim.fn.writefile` are line-oriented: they represent an embedded NUL as a newline and decide
-- for themselves whether the file ends in one, so a `concat(readfile(p), "\n")` round-trip cannot
-- reproduce an image, a gzip stream or a protobuf. The daemon engine is byte-exact (base64 on the
-- wire), so the curl engine, the `>>` redirect and the dock's save action have to be too — otherwise
-- the same request would produce two different files depending on the engine.
--
---@module "lvim-rest.fs"

local M = {}

--- Read a whole file as bytes. Returns "" when it cannot be opened (a missing body file is an empty
--- body here; every caller already treats it that way).
---@param path string
---@return string
function M.read(path)
    local fd = io.open(path, "rb")
    if not fd then
        return ""
    end
    local data = fd:read("*a")
    fd:close()
    return data or ""
end

--- Write `data` to `path` verbatim, creating/truncating it.
---@param path string
---@param data string
---@return boolean ok, string? err
function M.write(path, data)
    local fd, err = io.open(path, "wb")
    if not fd then
        return false, tostring(err)
    end
    local ok, werr = fd:write(data)
    fd:close()
    return ok and true or false, ok and nil or tostring(werr)
end

return M
