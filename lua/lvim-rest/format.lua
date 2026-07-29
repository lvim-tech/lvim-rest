-- lvim-rest.format: response body pretty-printing + content-type → filetype mapping.
--
-- JSON is pretty-printed by a deterministic Lua encoder (honouring `format.indent` / `sort_keys`)
-- so formatting needs no external tool; XML uses `xmllint --format` when available (health-gated),
-- and everything else is passed through verbatim. The size cap that diverts oversized bodies to a
-- raw scratch file lives in the dock — this module only formats.
--
---@module "lvim-rest.format"

local config = require("lvim-rest.config")

local M = {}

--- The REAL buffer filetype for a Content-Type (drives treesitter highlight in the dock).
---@param content_type string?
---@return string
function M.content_filetype(content_type)
    content_type = (content_type or ""):lower()
    if content_type:match("json") then
        return "json"
    elseif content_type:match("html") then
        return "html"
    elseif content_type:match("xml") then
        return "xml"
    elseif content_type:match("javascript") then
        return "javascript"
    elseif content_type:match("css") then
        return "css"
    elseif content_type:match("csv") then
        return "csv"
    end
    return "text"
end

--- Whether a decoded table is a JSON array (list) rather than an object.
---@param t table
---@return boolean
local function is_array(t)
    -- `vim.tbl_islist` is gone from the supported Neovim, so there is no fallback to keep — the
    -- branch could only ever have run on a version this set does not support.
    return vim.islist(t)
end

--- Encode a decoded JSON value with indentation. `sort_keys` orders object keys.
---@param value any
---@param indent integer
---@param sort_keys boolean
---@param level integer
---@return string
local function encode_pretty(value, indent, sort_keys, level)
    if value == nil or value == vim.NIL then
        return "null"
    end
    local t = type(value)
    if t == "boolean" then
        return tostring(value)
    elseif t == "number" then
        return tostring(value)
    elseif t == "string" then
        return vim.json.encode(value)
    elseif t ~= "table" then
        return vim.json.encode(value)
    end

    local pad = string.rep(" ", indent * (level + 1))
    local closepad = string.rep(" ", indent * level)

    if next(value) == nil then
        -- Empty table: distinguish an empty dict marker from an empty array.
        return (getmetatable(value) == getmetatable(vim.empty_dict())) and "{}" or (is_array(value) and "[]" or "{}")
    end

    if is_array(value) then
        local parts = {}
        for _, v in ipairs(value) do
            parts[#parts + 1] = pad .. encode_pretty(v, indent, sort_keys, level + 1)
        end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. closepad .. "]"
    end

    local keys = {}
    for k in pairs(value) do
        keys[#keys + 1] = k
    end
    if sort_keys then
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)
    end
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = pad
            .. vim.json.encode(tostring(k))
            .. ": "
            .. encode_pretty(value[k], indent, sort_keys, level + 1)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. closepad .. "}"
end

--- Pretty-print a JSON string; returns nil when it is not valid JSON.
---@param body string
---@return string?
function M.pretty_json(body)
    local ok, decoded = pcall(vim.json.decode, body, { luanil = { object = false, array = false } })
    if not ok then
        return nil
    end
    return encode_pretty(decoded, config.format.indent, config.format.sort_keys, 0)
end

--- Pretty-print XML via xmllint when available.
---@param body string
---@return string?
local function pretty_xml(body)
    if vim.fn.executable(config.format.xmllint_bin) ~= 1 then
        return nil
    end
    local res = vim.system({ config.format.xmllint_bin, "--format", "-" }, { stdin = body, text = true }):wait()
    if res.code == 0 and res.stdout and res.stdout ~= "" then
        return vim.trim(res.stdout)
    end
    return nil
end

--- Pretty-print a body for a content type. Returns the formatted text (or the original on failure).
---@param body string
---@param content_type string?
---@return string
function M.pretty(body, content_type)
    if not body or body == "" then
        return body or ""
    end
    local ft = M.content_filetype(content_type)
    if ft == "json" then
        return M.pretty_json(body) or body
    elseif ft == "xml" then
        return pretty_xml(body) or body
    end
    return body
end

--- Run a jq filter over a JSON body. Returns (output, err).
---@param body string
---@param filter string
---@return string?, string?
function M.jq(body, filter)
    if vim.fn.executable(config.format.jq_bin) ~= 1 then
        return nil, "jq not found on PATH"
    end
    local res = vim.system({ config.format.jq_bin, filter }, { stdin = body, text = true }):wait()
    if res.code ~= 0 then
        return nil, vim.trim(res.stderr or "jq error")
    end
    return vim.trim(res.stdout or ""), nil
end

return M
