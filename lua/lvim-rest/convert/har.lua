-- lvim-rest.convert.har: import a HAR (HTTP Archive) as a collection.
--
-- A HAR is a RECORDING — what a browser or proxy actually sent — so it is the one import where the
-- response is as interesting as the request. Each entry becomes a request with the recorded response
-- attached as an EXAMPLE, which is exactly what the library's example rows are for: you get the
-- captured traffic back as something you can re-send and compare against what it did last time.
--
-- Browser recordings are noisy. Requests are grouped into a folder per HOST, and the connection
-- headers a recording carries but a client must not resend (`Host`, `Content-Length`, the HTTP/2
-- pseudo-headers) are dropped — replaying them would either be ignored or be wrong.
--
---@module "lvim-rest.convert.har"

local library = require("lvim-rest.store.library")

local M = {}

--- Notify through the plugin's prefix.
---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-rest: " .. msg, level or vim.log.levels.INFO)
end

-- Headers a recording carries that a client must not resend: the transport sets them itself, and a
-- stale `Content-Length` in particular produces a broken request.
local SKIP_HEADERS = {
    ["host"] = true,
    ["content-length"] = true,
    ["connection"] = true,
    ["keep-alive"] = true,
    ["transfer-encoding"] = true,
    ["upgrade"] = true,
    ["proxy-connection"] = true,
}

--- Convert HAR headers, dropping the ones above and HTTP/2 pseudo-headers.
---@param list table?
---@return LvimRestHeader[]
local function headers_of(list)
    local out = {}
    for _, h in ipairs(list or {}) do
        local name = type(h) == "table" and h.name or nil
        if name and name:sub(1, 1) ~= ":" and not SKIP_HEADERS[name:lower()] then
            out[#out + 1] = { name = name, value = tostring(h.value or "") }
        end
    end
    return out
end

--- The host of a url, for grouping.
---@param url string
---@return string
local function host_of(url)
    return (url:match("^%a[%w+.-]*://([^/?#]+)") or "other"):gsub(":%d+$", "")
end

--- Import a `.har` file into the active workspace.
---@param path string
---@param opts { max?: integer, only_xhr?: boolean }?
---@return integer? collection_id
function M.import_file(path, opts)
    opts = opts or {}
    if vim.fn.filereadable(path) == 0 then
        notify(("no such file: %s"):format(path), vim.log.levels.ERROR)
        return nil
    end
    local ok, doc = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    if not ok or type(doc) ~= "table" or type(doc.log) ~= "table" or type(doc.log.entries) ~= "table" then
        notify("that is not a HAR file (no `log.entries`)", vim.log.levels.ERROR)
        return nil
    end
    local ws = library.active_workspace()
    if not ws then
        notify("no workspace", vim.log.levels.ERROR)
        return nil
    end
    local cid = library.add_collection(ws.id, vim.fn.fnamemodify(path, ":t:r"), {
        description = "Imported from a HAR recording",
    })
    if not cid then
        notify("could not create the collection", vim.log.levels.ERROR)
        return nil
    end

    local folders = {}
    local function folder_for(host)
        if folders[host] == nil then
            folders[host] = library.add_folder(cid, host) or false
        end
        return folders[host] or nil
    end

    local n, examples = 0, 0
    for _, entry in ipairs(doc.log.entries) do
        local req = type(entry) == "table" and entry.request or nil
        if type(req) == "table" and req.url then
            -- A page recording is mostly assets; `only_xhr` keeps just the API calls, which is what
            -- someone importing a HAR into a REST client is nearly always after.
            local is_xhr = entry._resourceType == "xhr" or entry._resourceType == "fetch"
            if not opts.only_xhr or is_xhr then
                local body
                if type(req.postData) == "table" then
                    body = req.postData.text
                    if not body and type(req.postData.params) == "table" then
                        local parts = {}
                        for _, kv in ipairs(req.postData.params) do
                            parts[#parts + 1] = ("%s=%s"):format(kv.name or "", kv.value or "")
                        end
                        body = table.concat(parts, "&")
                    end
                end
                local url = tostring(req.url)
                local rid = library.add_request(cid, {
                    name = ("%s %s"):format(req.method or "GET", (url:match("^%a[%w+.-]*://[^/]+(/[^?#]*)") or "/")),
                    method = (req.method or "GET"):upper(),
                    url = url,
                    headers = headers_of(req.headers),
                    body = body,
                    folder_id = folder_for(host_of(url)),
                })
                n = n + 1
                -- The recorded response, kept as an example: a HAR's whole value is that it says
                -- what came back.
                local res = entry.response
                if rid and type(res) == "table" and res.status then
                    library.add_example(rid, {
                        name = ("recorded %s"):format(tostring(res.status)),
                        status = tonumber(res.status),
                        headers = headers_of(res.headers),
                        body = type(res.content) == "table" and res.content.text or nil,
                        ms = tonumber(entry.time),
                        size = type(res.content) == "table" and tonumber(res.content.size) or nil,
                    })
                    examples = examples + 1
                end
                if opts.max and n >= opts.max then
                    break
                end
            end
        end
    end
    notify(("imported %d request(s) and %d recorded response(s) from the HAR"):format(n, examples))
    return cid
end

return M
