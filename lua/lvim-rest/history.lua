-- lvim-rest.history: the executed-request log (sqlite via lvim-rest.store).
--
-- One row per executed request — timestamp, file, name, method, url, status, ms, size, env. Bodies
-- and headers are stored ONLY when `history.bodies = true` (off by default — size + secrets). The
-- `@no-log` directive skips a request entirely (the runner gates the call). Retention is capped at
-- `history.max_entries` (oldest pruned). The picker reopens a stored response in the dock.
--
---@module "lvim-rest.history"

local config = require("lvim-rest.config")
local store = require("lvim-rest.store")

local M = {}

--- Record an executed request. No-op when history is disabled or sqlite is unavailable.
---@param result table
---@param meta { name?: string, file?: string, env?: string }
function M.record(result, meta)
    if not config.history.enabled or result.error then
        return
    end
    local db = store.get()
    if not db then
        return
    end
    local row = {
        ts = os.time(),
        file = meta.file or "",
        name = meta.name or "",
        method = result.method or "",
        url = result.url or "",
        status = result.status or 0,
        ms = result.timing and result.timing.total or 0,
        size = result.size and result.size.down or 0,
        env = meta.env or "",
    }
    if config.history.bodies then
        row.headers = vim.json.encode(result.headers or {})
        row.body = result.body or ""
    end
    db:insert("history", row)
    -- Prune to the retention cap.
    local n = db:count("history")
    if n and n > config.history.max_entries then
        local excess = n - config.history.max_entries
        pcall(function()
            db:exec("DELETE FROM history WHERE id IN (SELECT id FROM history ORDER BY id ASC LIMIT :n)", { n = excess })
        end)
    end
end

--- All history rows, newest first.
---@return table[]
function M.list()
    local db = store.get()
    if not db then
        return {}
    end
    local rows = db:find("history")
    if type(rows) ~= "table" then
        return {}
    end
    table.sort(rows, function(a, b)
        return (a.ts or 0) > (b.ts or 0)
    end)
    return rows
end

--- A relative "N ago" label for a timestamp.
---@param ts integer
---@return string
local function ago(ts)
    local d = os.time() - (ts or 0)
    if d < 60 then
        return d .. "s ago"
    elseif d < 3600 then
        return math.floor(d / 60) .. "m ago"
    elseif d < 86400 then
        return math.floor(d / 3600) .. "h ago"
    end
    return math.floor(d / 86400) .. "d ago"
end

--- The status-accent group for a code.
---@param status integer
---@return string
local function status_group(status)
    if status >= 200 and status < 300 then
        return "LvimRestStatus2xx"
    elseif status >= 300 and status < 400 then
        return "LvimRestStatus3xx"
    elseif status >= 400 and status < 500 then
        return "LvimRestStatus4xx"
    end
    return "LvimRestStatus5xx"
end

--- The method glyph for a verb.
---@param method string
---@return string
local function method_icon(method)
    local map = {
        GET = config.icons.get,
        POST = config.icons.post,
        PUT = config.icons.put,
        PATCH = config.icons.patch,
        DELETE = config.icons.delete,
        GRAPHQL = config.icons.graphql,
        GRPC = config.icons.grpc,
        WEBSOCKET = config.icons.ws,
    }
    return map[method] or config.icons.request
end

--- Open the history picker (lvim-ui.select). `<CR>` reopens the stored response in the dock when its
--- body was recorded; otherwise it re-runs is left to the caller (phase 8 adds replay).
function M.pick()
    local rows = M.list()
    if #rows == 0 then
        vim.notify("lvim-rest: history is empty", vim.log.levels.INFO)
        return
    end
    local items = {}
    for _, r in ipairs(rows) do
        items[#items + 1] = {
            label = ("%d %s  %s  %s"):format(
                r.status or 0,
                r.method or "",
                r.name ~= "" and r.name or r.url,
                ago(r.ts)
            ),
            icon = method_icon(r.method or "GET"),
            icon_hl = status_group(r.status or 0),
            row = r,
        }
    end
    require("lvim-ui").select({
        title = "Request history",
        items = items,
        callback = function(confirmed, index)
            if not confirmed then
                return
            end
            local r = items[index].row
            if config.history.bodies and r.body then
                local ok, headers = pcall(vim.json.decode, r.headers or "[]")
                require("lvim-rest.ui.dock").show({
                    status = r.status,
                    status_text = require("lvim-rest.backend.curl").reason(r.status or 0),
                    headers = ok and headers or {},
                    body = r.body,
                    method = r.method,
                    url = r.url,
                    timing = { total = r.ms },
                    size = { down = r.size },
                    engine = "history",
                }, { title = (r.method or "") .. " " .. (r.url or "") })
            else
                vim.notify("lvim-rest: this entry has no stored body (enable history.bodies)", vim.log.levels.INFO)
            end
        end,
    })
end

return M
