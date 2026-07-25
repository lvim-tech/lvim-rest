-- lvim-rest.ws: WebSocket sessions — the editor half.
--
-- A `WEBSOCKET wss://…` request does not "send and get a response"; it OPENS something that then
-- lives until one side closes it. So this module keeps sessions, not results: `open` starts one and
-- every frame afterwards arrives as a daemon NOTIFICATION and is appended to that session's log.
--
-- The log is shown through the ordinary response dock, in a view of its own, so a WebSocket needs no
-- second window concept — the place you look at a response is the place you watch a stream.
--
-- Daemon-only, and the Lua side says so before opening rather than after: curl cannot hold a duplex
-- connection and report frames as they arrive, so there is nothing to fall back to.
--
---@module "lvim-rest.ws"

local config = require("lvim-rest.config")
local rpc = require("lvim-rest.backend.rpc")
local views = require("lvim-rest.ui.views")

local M = {}

---@class LvimRestWsSession
---@field id       integer            the daemon request id that opened it (also its handle)
---@field url      string
---@field open     boolean
---@field messages { dir: string, kind: string, data: string, ts: integer }[]
---@field closed   { code: integer, reason: string? }?

---@type table<integer, LvimRestWsSession>
local sessions = {}

---@type integer? the session the UI is currently showing
local current

---@type boolean one-time notification subscription guard
local subscribed = false

--- Notify through the plugin's prefix.
---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-rest: " .. msg, level or vim.log.levels.INFO)
end

--- Every live or finished session, newest first.
---@return LvimRestWsSession[]
function M.list()
    local out = {}
    for _, s in pairs(sessions) do
        out[#out + 1] = s
    end
    table.sort(out, function(a, b)
        return a.id > b.id
    end)
    return out
end

--- The session the UI is showing (the most recent when nothing was chosen).
---@return LvimRestWsSession?
function M.current()
    if current and sessions[current] then
        return sessions[current]
    end
    return M.list()[1]
end

--- Repaint the dock when it is showing this session's stream.
---@param session LvimRestWsSession
local function refresh(session)
    local dock = require("lvim-rest.ui.dock")
    if dock.is_open and dock.is_open() and M.current() == session then
        dock.show(M.result(session), { title = "WEBSOCKET " .. session.url, name = session.url })
    end
end

--- A session rendered as a dock RESULT, so every existing view (and the footer, and the copy
--- actions) works on a stream without knowing what a stream is.
---@param session LvimRestWsSession?
---@return table
function M.result(session)
    session = session or M.current()
    if not session then
        return { error = "no websocket session" }
    end
    -- ONE transcript formatter, in the view layer: what the dock paints (with per-direction accents)
    -- and what `yank` / `save` copy are the same text by construction.
    local lines = views.transcript(session).lines
    return {
        status = session.open and 101 or 0,
        status_text = session.open and "Switching Protocols" or "closed",
        headers = {},
        body = table.concat(lines, "\n"),
        url = session.url,
        method = "WEBSOCKET",
        engine = "daemon",
        ws = session,
        timing = { total = 0 },
        size = { down = #table.concat(lines, "\n"), up = 0 },
    }
end

--- Subscribe to the daemon's websocket notifications (once).
local function subscribe()
    if subscribed then
        return
    end
    subscribed = true
    -- An open session lives in the DAEMON with no pending request to show for it, so the idle-stop
    -- timer has to be told: stopping the daemon under a live socket would drop the connection.
    rpc.keep_alive(function()
        for _, s in pairs(sessions) do
            if s.open then
                return true
            end
        end
        return false
    end)
    rpc.on("ws.message", function(p)
        local s = sessions[p.id]
        if not s then
            return
        end
        s.messages[#s.messages + 1] = { dir = p.dir, kind = p.kind, data = p.data or "", ts = os.time() }
        -- A stream that grows without bound would eventually be the only thing in memory.
        local cap = config.ws.max_messages
        while cap > 0 and #s.messages > cap do
            table.remove(s.messages, 1)
        end
        refresh(s)
    end)
    rpc.on("ws.closed", function(p)
        local s = sessions[p.id]
        if not s or not s.open then
            return
        end
        s.open = false
        s.closed = { code = p.code, reason = p.reason or p.error }
        notify(("websocket closed (%s)%s"):format(tostring(p.code), p.error and (": " .. p.error) or ""))
        refresh(s)
    end)
end

--- Open a session for a resolved WEBSOCKET request.
---@param resolved table
---@param cb fun(result: table)?
---@return nil
function M.open(resolved, cb)
    subscribe()
    local headers = {}
    for _, h in ipairs(resolved.headers or {}) do
        headers[#headers + 1] = { h.name, h.value }
    end
    -- `Sec-WebSocket-Protocol` written as an ordinary header is the natural way to ask for a
    -- subprotocol in a .http document, so it is accepted as one rather than needing a directive.
    local subprotocols = {}
    for _, h in ipairs(resolved.headers or {}) do
        if h.name:lower() == "sec-websocket-protocol" then
            for _, p in ipairs(vim.split(h.value, ",", { plain = true })) do
                subprotocols[#subprotocols + 1] = vim.trim(p)
            end
        end
    end

    -- The daemon stamps every later notification with the id that OPENED the session, so the third
    -- callback argument is the session handle — nothing has to be invented or looked up.
    rpc.request(
        "ws.open",
        { url = resolved.url, headers = headers, subprotocols = subprotocols },
        function(res, err, id)
            if err then
                if cb then
                    cb({ error = err })
                end
                return
            end
            local session = { id = id, url = resolved.url, open = true, messages = {} }
            sessions[id] = session
            current = id
            notify(("websocket open → %s"):format(resolved.url))
            if cb then
                cb(M.result(session))
            end
        end
    )
end

--- Send a frame on a session (the current one by default).
---@param data string
---@param opts { id?: integer, kind?: string }?
---@return boolean started
function M.send(data, opts)
    opts = opts or {}
    local s = opts.id and sessions[opts.id] or M.current()
    if not s or not s.open then
        notify("no open websocket session", vim.log.levels.WARN)
        return false
    end
    rpc.request("ws.send", { id = s.id, data = data, kind = opts.kind or "text" }, function(_, err)
        if err then
            notify("websocket send: " .. err, vim.log.levels.ERROR)
        end
    end)
    return true
end

--- Close a session (the current one by default).
---@param opts { id?: integer, code?: integer, reason?: string }?
---@return nil
function M.close(opts)
    opts = opts or {}
    local s = opts.id and sessions[opts.id] or M.current()
    if not s or not s.open then
        return
    end
    rpc.request("ws.close", { id = s.id, code = opts.code or 1000, reason = opts.reason }, function() end)
end

--- Make `id` the session the UI shows.
---@param id integer
---@return nil
function M.focus(id)
    if sessions[id] then
        current = id
        refresh(sessions[id])
    end
end

--- Drop finished sessions from the list.
---@return integer removed
function M.prune()
    local n = 0
    for id, s in pairs(sessions) do
        if not s.open then
            sessions[id] = nil
            n = n + 1
        end
    end
    if current and not sessions[current] then
        current = nil
    end
    return n
end

return M
