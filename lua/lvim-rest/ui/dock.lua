-- lvim-rest.ui.dock: the response surface (the inline dock, and — in phase 5 — the workbench dock).
--
-- A single lvim-ui.surface (never a raw float): the content panel paints the current VIEW of the
-- response (body / headers / both / stats / verbose / script / report), the HEADER bar carries the
-- view-mode buttons (the active one full-accent per the 4-state canon) + a jq filter button, and the
-- FOOTER bar the row actions (yank / save / copy-as-curl / replay / close). The border-title is the
-- request name + method. The body view starts treesitter for the Content-Type's language so JSON /
-- HTML / XML highlight natively; the other views paint their own aligned columns.
--
---@module "lvim-rest.ui.dock"

local api = vim.api
local surface = require("lvim-ui.surface")
local config = require("lvim-rest.config")
local views = require("lvim-rest.ui.views")
local format = require("lvim-rest.format")

local M = {}

-- The view modes, in header-bar order.
local VIEWS = { "body", "headers", "both", "stats", "verbose", "script", "report" }

local state = {
    surface = nil, ---@type table?
    buf = nil, ---@type integer?
    win = nil, ---@type integer?
    ns = api.nvim_create_namespace("LvimRestDock"),
    result = nil, ---@type table?
    meta = nil, ---@type table?
    view = config.default_view,
    jq = nil, ---@type string?  active jq filter (body view)
    ts_active = false, -- whether treesitter is running on the dock buffer
}

--- Whether the dock is currently open.
---@return boolean
local function is_open()
    return state.surface ~= nil and state.buf ~= nil and api.nvim_buf_is_valid(state.buf)
end

--- The method-accent highlight group for the current result.
---@return string
local function method_group()
    local m = (state.result and state.result.method) or "GET"
    return "LvimRest" .. m:sub(1, 1):upper() .. m:sub(2):lower()
end

--- The method glyph for the current result.
---@return string
local function method_icon()
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
    return map[(state.result and state.result.method) or "GET"] or config.icons.request
end

--- Stop any treesitter highlighter on the dock buffer.
local function stop_ts()
    if state.ts_active and state.buf and api.nvim_buf_is_valid(state.buf) then
        pcall(vim.treesitter.stop, state.buf)
    end
    state.ts_active = false
end

--- Paint `lines` + `hls` into the dock buffer, optionally starting treesitter for `ft`.
---@param lines string[]
---@param hls table[]
---@param ft string
local function paint(lines, hls, ft)
    if not state.buf or not api.nvim_buf_is_valid(state.buf) then
        return
    end
    stop_ts()
    vim.bo[state.buf].modifiable = true
    api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    vim.bo[state.buf].modifiable = false
    api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
    for _, h in ipairs(hls) do
        pcall(api.nvim_buf_set_extmark, state.buf, state.ns, h.row, h.col_start, {
            end_col = h.col_end,
            hl_group = h.group,
        })
    end
    -- Treesitter for the body view when a parser for the language exists.
    if ft and ft ~= "text" and ft ~= "" then
        local lang = vim.treesitter.language.get_lang and vim.treesitter.language.get_lang(ft) or ft
        local ok = pcall(vim.treesitter.start, state.buf, lang)
        state.ts_active = ok
    end
end

--- Re-render the current view into the dock.
local function render()
    if not is_open() or not state.result then
        return
    end
    -- Oversized body: the raw response was diverted to a scratch file — the body view is a notice.
    if state.view == "body" and state.oversized then
        paint({
            ("Response body is %d bytes (over the %d cap) — opened raw in a scratch file:"):format(
                #(state.result.body or ""),
                config.format.max_size
            ),
            state.oversized,
            "",
            "Use the headers / stats views here, or open the file above.",
        }, {}, "text")
        return
    end
    -- Body view with an active jq filter: run jq over the raw body and show its output as JSON.
    if state.view == "body" and state.jq and state.jq ~= "" then
        local out, err = format.jq(state.result.body or "", state.jq)
        if out then
            paint(vim.split(out, "\n", { plain = true }), {}, "json")
            return
        end
        paint(
            { "jq: " .. (err or "error") },
            { { row = 0, col_start = 0, col_end = 3, group = "LvimRestFail" } },
            "text"
        )
        return
    end
    local rendered = views.render(state.result, state.view)
    paint(rendered.lines, rendered.hls, rendered.filetype)
end

--- The border-title box: method glyph + request name/line.
---@return table
local function title_box()
    local m = state.result or {}
    local text = (state.meta and state.meta.title) or ((m.method or "") .. " " .. (m.url or ""))
    return { icon = method_icon(), text = text, icon_hl = method_group() }
end

-- ── header (view modes + jq) ────────────────────────────────────────────────

-- Forward declaration: header_spec closes over set_view, set_view over header_spec.
local set_view

--- Build the header bar spec (view buttons + jq).
---@return table
local function header_spec()
    local registry = {}
    local group = {}
    for _, v in ipairs(VIEWS) do
        registry[v] = {
            name = v,
            active = state.view == v,
            run = function()
                set_view(v)
            end,
        }
        group[#group + 1] = v
    end
    registry.jq = {
        name = state.jq and ("jq: " .. state.jq) or "jq",
        active = state.jq ~= nil and state.jq ~= "",
        run = function()
            M.filter()
        end,
    }
    return { bars = { surface.bar({ group, { "jq" } }, registry, { align = "left" }) } }
end

--- Switch the active view and re-render + rebuild the header (so the active button updates).
---@param view string
set_view = function(view)
    state.view = view
    render()
    if state.surface and state.surface.set_header then
        pcall(state.surface.set_header, header_spec())
    end
end

-- ── footer (actions) ────────────────────────────────────────────────────────

--- Yank the response body to the unnamed + system registers.
local function yank_body()
    if not state.result then
        return
    end
    local body = state.result.body or ""
    vim.fn.setreg('"', body)
    vim.fn.setreg("+", body)
    vim.notify("lvim-rest: body yanked", vim.log.levels.INFO)
end

--- Save the response body to a file (prompted).
local function save_body()
    if not state.result then
        return
    end
    require("lvim-ui").input({
        title = "Save response body to",
        default = "response" .. (format.content_filetype(nil) == "json" and ".json" or ".txt"),
        callback = function(ok, path)
            if not ok or not path or path == "" then
                return
            end
            pcall(vim.fn.writefile, vim.split(state.result.body or "", "\n", { plain = true }), vim.fn.expand(path))
            vim.notify("lvim-rest: saved " .. path, vim.log.levels.INFO)
        end,
    })
end

--- Copy the request as a curl command to the clipboard.
local function copy_curl()
    if not state.result or not state.result.request then
        return
    end
    local cmd = require("lvim-rest.parser.curl").to_curl(state.result.request)
    vim.fn.setreg("+", cmd)
    vim.fn.setreg('"', cmd)
    vim.notify("lvim-rest: copied as curl", vim.log.levels.INFO)
end

--- Build the footer bar spec.
---@return table
local function footer_spec()
    local registry = {
        yank = { name = "yank", key = "y", run = yank_body },
        save = { name = "save", key = "s", run = save_body },
        curl = { name = "copy curl", key = "c", run = copy_curl },
        replay = {
            name = "replay",
            key = "r",
            run = function()
                require("lvim-rest.runner").replay()
            end,
        },
        close = {
            name = "close",
            key = "q",
            run = function(s)
                s.close()
            end,
        },
    }
    return { bars = { surface.bar({ { "yank", "save", "curl" }, { "replay", "close" } }, registry) } }
end

-- ── open / show ─────────────────────────────────────────────────────────────

--- The prompt-filter action: ask for a jq expression and re-render the body view through it.
function M.filter()
    require("lvim-ui").input({
        title = "jq filter",
        default = state.jq or ".",
        callback = function(ok, expr)
            if not ok then
                return
            end
            state.jq = (expr and expr ~= "" and expr ~= ".") and expr or nil
            state.view = "body"
            render()
            if state.surface and state.surface.set_header then
                pcall(state.surface.set_header, header_spec())
            end
        end,
    })
end

--- The surface config for the configured inline-dock layout.
---@return table
local function surface_cfg()
    local provider = {
        filetype = "lvim-rest-response",
        cursorline = "LvimRestCursorLine",
        readonly = true,
        update = function(pan)
            state.buf, state.win = pan.buf, pan.win
            vim.bo[pan.buf].buftype = "nofile"
            render()
        end,
        on_close = function()
            stop_ts()
            state.surface, state.buf, state.win, state.result = nil, nil, nil, state.result
            state.surface = nil
        end,
    }
    local cfg = {
        title = title_box(),
        content = { blocks = { { id = "response", provider = provider, border = surface.CONTENT_BORDER } } },
        header = header_spec(),
        footer = footer_spec(),
        close_keys = { "q" },
    }
    local layout = config.dock.layout
    if layout == "float" then
        cfg.mode = "float"
        cfg.size = {
            width = { fixed = config.dock.size.float.width },
            height = { fixed = config.dock.size.float.height },
        }
    elseif layout == "area" then
        cfg.mode = "split"
        cfg.position = "cmdline"
        cfg.size = { height = { fixed = config.dock.size.height } }
    else -- bottom
        cfg.mode = "split"
        cfg.dock = "below"
        cfg.size = { height = { fixed = config.dock.size.height } }
    end
    return cfg
end

--- Show a response result in the dock (opening it if needed, re-rendering if already open).
---@param result table
---@param meta table?  { title?, name? }
function M.show(result, meta)
    state.result = result
    state.meta = meta or {}
    state.jq = nil
    state.oversized = nil
    -- Size cap: divert an oversized body to a scratch file so the dock never stalls on a giant buffer.
    if result.body and #result.body > config.format.max_size then
        local dir = vim.fn.stdpath("state") .. "/lvim-rest"
        vim.fn.mkdir(dir, "p")
        local ct = ""
        for _, h in ipairs(result.headers or {}) do
            if h.name:lower() == "content-type" then
                ct = h.value
            end
        end
        local ext = format.content_filetype(ct)
        local path = ("%s/response-%d.%s"):format(dir, os.time(), ext == "text" and "txt" or ext)
        pcall(vim.fn.writefile, vim.split(result.body, "\n", { plain = true }), path)
        state.oversized = path
    end
    -- Pre-seed the jq filter from a `# @jq` directive.
    if result.request and result.request.directives and result.request.directives.jq then
        state.jq = result.request.directives.jq
    end
    state.view = config.default_view
    if is_open() then
        render()
        if state.surface then
            if state.surface.set_header then
                pcall(state.surface.set_header, header_spec())
            end
            if state.surface.set_title then
                pcall(state.surface.set_title, title_box())
            end
        end
        return
    end
    state.surface = surface.open(surface_cfg())
end

--- Close the dock.
function M.close()
    if state.surface and state.surface.close then
        pcall(state.surface.close)
    end
end

--- Whether the dock is open (exposed for commands / health).
---@return boolean
function M.is_open()
    return is_open()
end

return M
