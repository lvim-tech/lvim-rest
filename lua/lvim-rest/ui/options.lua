-- lvim-rest.ui.options: the request OPTIONS form — the Postman face of the request under the cursor.
--
-- A `ui.tabs` panel over ONE request: its query Params, its Headers, and its per-request Settings
-- (the `# @…` directives). It is a VIEW, never a store: every row is built from a fresh
-- `parser.parse` of the buffer and every change is written back as BUFFER TEXT through
-- `lvim-rest.ui.edit` — so the form and a send always agree, and a request opened from the library
-- persists exactly the way a hand-edited one does (`:w` → the existing bind write-back). This module
-- never calls the library.
--
-- WHAT THE DOCUMENT CANNOT SAY, THE FORM DOES NOT INVENT:
--   * a HEADER can be switched off, because commenting the line out is how the format expresses that
--     — the text survives and `t` brings it back;
--   * a QUERY PARAMETER cannot (a url has no "disabled" form), so there is no toggle for one: the
--     honest operations are edit, add and delete. A form-local "disabled" flag that evaporated when
--     the panel closed would be a lie about where the truth lives.
--
---@module "lvim-rest.ui.options"

local api = vim.api
local config = require("lvim-rest.config")
local edit = require("lvim-rest.ui.edit")
local spec = require("lvim-rest.spec")
local highlight = require("lvim-utils.highlight")
local ui = require("lvim-ui")

local M = {}

---@type { editor: LvimRestEditor?, handle: table?, tabs: table[]?, layout: string?, folds: table<string, boolean> }
local state = { editor = nil, handle = nil, tabs = nil, layout = nil, folds = {} }

--- Notify through the plugin's prefix.
---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-rest: " .. msg, level or vim.log.levels.INFO)
end

--- Ask for a line of text through the canonical input.
---@param title string
---@param default string
---@param fn fun(value: string)
local function ask(title, default, fn)
    ui.input({
        title = title,
        default = default,
        callback = function(confirmed, value)
            if confirmed and type(value) == "string" then
                fn(vim.trim(value))
            end
        end,
    })
end

-- ── rows ────────────────────────────────────────────────────────────────────

--- A canonical collapsible SECTION header. The plugin owns only the caret BOX (a glyph padded to a
--- fixed width, in the section's own accent) and the accent; the band, the hover and the label
--- colours are global (`lvim-utils.highlight.section_accent`), so these folds look like every other
--- fold in the ecosystem.
---
--- `expanded` is only the DEFAULT: a section the user collapsed stays collapsed across the rebuild
--- that follows every edit (`state.folds`), because a form that re-opened its folds each time you
--- changed a value would be unusable.
---@param opts { name: string, label: string, count: integer, accent: string, expanded: boolean, children: table[] }
---@return table
local function fold(opts)
    local remembered = state.folds[opts.name]
    if remembered ~= nil then
        opts.expanded = remembered
    end
    local caret = opts.expanded and config.icons.expand_open or config.icons.expand_closed
    return ui.section({
        name = opts.name,
        icon = " " .. caret .. " ",
        box_hl = highlight.section_accent(opts.accent).text,
        label = opts.label,
        count = opts.count,
        accent = opts.accent,
        expanded = opts.expanded,
        children = opts.children,
    })
end

--- A row that only says something (no value, not activatable). `tag` keeps the row NAMEABLE: which
--- tab a key acts on is read off the focused row's name, so even an empty tab must identify itself.
---@param text string
---@param tag string
---@return table
local function note(text, tag)
    return { type = "action", name = "note:" .. tag, label = text, disabled = true, flat = true }
end

--- The Params tab: one row per query parameter of the request line.
---@param req LvimRestRequest
---@return table[]
local function params_rows(req)
    local _, params = edit.split_query(req.url)
    if #params == 0 then
        return { note("no query parameters — press " .. config.ui.options.keys.add .. " to add one", "params") }
    end
    local rows = {}
    for i, p in ipairs(params) do
        rows[i] = {
            type = "string",
            name = "param:" .. i,
            label = p.name,
            value = p.value,
            run = function(value)
                local ed = state.editor
                if not ed then
                    return
                end
                local _, list = edit.split_query((ed:request() or req).url)
                if list[i] then
                    list[i].value = value
                    ed:set_params(list)
                end
                M.refresh()
            end,
        }
    end
    return rows
end

--- The Headers tab: one row per header LINE, including the commented-out ones.
---@return table[]
local function headers_rows()
    local ed = state.editor
    local headers = ed and ed:headers() or {}
    if #headers == 0 then
        return { note("no headers — press " .. config.ui.options.keys.add .. " to add one", "headers") }
    end
    local rows = {}
    for i, h in ipairs(headers) do
        rows[i] = {
            type = "string",
            name = "header:" .. i,
            label = h.name,
            value = h.value,
            -- A commented-out header renders dimmed + struck through, which is exactly what it is.
            -- It stays focusable, so `t` can switch it back on.
            disabled = not h.enabled,
            run = function(value)
                if state.editor then
                    state.editor:set_header(h.lnum, h.name, value, h.enabled)
                end
                M.refresh()
            end,
        }
    end
    return rows
end

--- The spec read-context for the current request: the buffer + its path (env lookups, dynamic resolve).
---@return LvimRestSpecCtx
local function spec_ctx()
    local ed = state.editor
    local buf = ed and ed.buf
    return { buf = buf, path = buf and api.nvim_buf_get_name(buf) or nil }
end

--- The Auth tab: the `# @auth` scheme select + the selected scheme's fields, ALL from the shared
--- spec (`lvim-rest.spec`) so it can never disagree with the validator. Every edit reassembles the
--- one directive line through the write-back engine — the panel invents no auth syntax of its own.
---@param req LvimRestRequest
---@return table[]
local function auth_rows(req)
    local disc = spec.schema().auth.discriminator.key
    local ctx = spec_ctx()
    -- Warm any dynamic select options (the oauth2 profile ids) and repaint when they land.
    spec.resolve_options("auth", req, ctx, function()
        M.refresh()
    end)
    local rows = {}
    for _, sr in ipairs(spec.rows("auth", req, ctx)) do
        local field = sr.field
        local r = vim.tbl_extend("force", {}, sr.row)
        if field.key == disc then
            -- The scheme select: switch schemes. "none" removes the directive; any other writes the
            -- bare `# @auth <scheme>` and the rebuild shows that scheme's (empty) fields.
            r.name = "auth:scheme"
            r.run = function(value)
                local ed = state.editor
                if not ed then
                    return
                end
                if value == "none" then
                    ed:set_directive("auth", nil)
                else
                    ed:set_directive("auth", spec.assemble_auth(value, {}))
                end
                M.refresh()
            end
        else
            -- A field of the selected scheme: reassemble the whole line from the live values with this
            -- one changed, then write it back. Secret fields are eligible for the keyring footer button.
            r.name = "auth:field:" .. field.key
            r.secret = field.secret == true
            r.run = function(value)
                local ed = state.editor
                if not ed then
                    return
                end
                local cur = ed:request() or req
                local scheme = spec.variant("auth", cur)
                local values = spec.values("auth", cur)
                values[field.key] = value
                ed:set_directive("auth", spec.assemble_auth(scheme, values))
                M.refresh()
            end
        end
        rows[#rows + 1] = r
    end
    return rows
end

--- Ensure the header a body variant declares (`Content-Type`) is present + enabled — the CONSEQUENCE
--- of picking that body type, written as an ordinary header line (never hidden state).
---@param ed LvimRestEditor
---@param variant table
local function ensure_variant_headers(ed, variant)
    if not variant.headers then
        return
    end
    for name, value in pairs(variant.headers) do
        local has = false
        for _, h in ipairs(ed:headers()) do
            if h.enabled and h.name:lower() == name:lower() then
                has = true
                break
            end
        end
        if not has then
            ed:add_header(name, value)
        end
    end
end

--- Apply the consequences of switching the body TYPE (the inferred discriminator carries no token, so
--- flipping it writes real buffer changes: the Content-Type header, a starter body, or the include
--- marker — never a phantom directive).
---@param ed LvimRestEditor
---@param kind string
local function apply_body_kind(ed, kind)
    local variant = spec.schema().body.variants[kind] or {}
    ensure_variant_headers(ed, variant) -- header first, so set_body's insert point is settled
    if kind == "none" then
        ed:set_body("")
    elseif kind == "file" then
        local req = ed:request()
        if not (req and req.body_file) then
            ed:set_body("< ./body") -- a placeholder path so `detect` reads this as the file variant
        end
    elseif kind == "json" then
        local req = ed:request()
        if not req or not req.body or req.body == "" then
            ed:set_body("{}")
        end
    end
end

--- The Body tab: the type select (INFERRED — flipping it writes consequences) + the active variant's
--- fields, all from the shared spec. json/graphql/raw/form edit the body block; file edits the
--- `< path` include marker.
---@param req LvimRestRequest
---@return table[]
local function body_rows(req)
    local disc = spec.schema().body.discriminator.key
    local rows = {}
    for _, sr in ipairs(spec.rows("body", req, spec_ctx())) do
        local field = sr.field
        local r = vim.tbl_extend("force", {}, sr.row)
        if field.key == disc then
            r.name = "body:kind"
            r.run = function(value)
                if state.editor then
                    apply_body_kind(state.editor, value)
                    M.refresh()
                end
            end
        elseif field.key == "path" then
            r.name = "body:path"
            r.run = function(value)
                local ed = state.editor
                if not ed then
                    return
                end
                local cur = ed:request() or req
                local sub = spec.values("body", cur).substitute == true
                ed:set_body(("%s %s"):format(sub and "<@" or "<", value))
                M.refresh()
            end
        elseif field.key == "substitute" then
            r.name = "body:substitute"
            r.run = function(value)
                local ed = state.editor
                if not ed then
                    return
                end
                local cur = ed:request() or req
                local path = spec.values("body", cur).path or ""
                if path ~= "" then
                    ed:set_body(("%s %s"):format((value == true or value == "true") and "<@" or "<", path))
                    M.refresh()
                end
            end
        else
            -- json / graphql / grpc message / form / raw: the body is multi-line, so it CANNOT be an
            -- inline value row — nvim_buf_set_lines rejects embedded newlines when the panel paints it.
            -- The row is an ACTION showing a one-line preview; <CR> opens the scratch body editor.
            local raw = type(r.value) == "string" and r.value or ""
            local preview = (raw:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
            if preview == "" then
                preview = "(empty) — press " .. config.ui.options.keys.edit_body .. " to edit"
            elseif vim.fn.strdisplaywidth(preview) > 60 then
                preview = vim.fn.strcharpart(preview, 0, 60) .. "…"
            end
            r = {
                type = "action",
                name = "body:content:" .. field.key,
                icon = sr.row.icon,
                label = (field.label or field.key) .. ":  " .. preview,
                run = function()
                    local ed = state.editor
                    if not ed then
                        return
                    end
                    local buf, lnum = ed.buf, ed:anchor()
                    M.close()
                    vim.schedule(function()
                        require("lvim-rest.ui.body_editor").open(buf, lnum)
                    end)
                end,
            }
        end
        rows[#rows + 1] = r
    end
    return rows
end

--- Split a gRPC request URL into endpoint / service / method: `host:port/pkg.Service/Method`.
---@param url string
---@return string endpoint, string service, string method
local function parse_grpc(url)
    local endpoint, rest = url:match("^([^/]+)/(.+)$")
    if not endpoint then
        return url, "", ""
    end
    local service, method = rest:match("^(.+)/([^/]+)$")
    if not service then
        return endpoint, rest, ""
    end
    return endpoint, service, method
end

--- Reassemble a gRPC URL from its parts (empty parts dropped).
---@param endpoint string
---@param service string
---@param method string
---@return string
local function build_grpc(endpoint, service, method)
    local u = endpoint
    if service ~= "" then
        u = u .. "/" .. service
    end
    if method ~= "" then
        u = u .. "/" .. method
    end
    return u
end

--- The gRPC tab: the endpoint / service / method of the request line. When the daemon can reflect the
--- request's `.proto` files (or the server), service and method are SELECTS of the real vocabulary;
--- otherwise they are plain text fields (always editable). Each edit rewrites exactly its URL segment
--- through the write-back engine. Only a GRPC request has this tab.
---@param req LvimRestRequest
---@return table[]
local function grpc_rows(req)
    if req.method ~= "GRPC" then
        return { note("not a gRPC request — its request line must start with GRPC", "grpc") }
    end
    local grpc = require("lvim-rest.spec.grpc")
    local ctx = spec_ctx()
    local refl = grpc.cached(req, ctx)
    -- Warm the cache ONLY when cold — otherwise a warm hit calls the callback synchronously and
    -- M.refresh → grpc_rows → reflect → refresh would loop. On the repaint after a cold resolve lands,
    -- the cache is warm, so no further reflect is kicked.
    if not refl then
        grpc.reflect(req, ctx, function()
            M.refresh()
        end)
    end
    local endpoint, service, method = parse_grpc(req.url or "")

    local function setter(which)
        return function(value)
            local ed = state.editor
            if not ed then
                return
            end
            local e, s, m = parse_grpc((ed:request() or req).url or "")
            if which == "endpoint" then
                e = value
            elseif which == "service" then
                s, m = value, "" -- a new service invalidates the old method
            else
                m = value
            end
            ed:set_request_line("GRPC", build_grpc(e, s, m))
            M.refresh()
        end
    end

    local svc_row = { name = "grpc:service", label = "Service", value = service, run = setter("service") }
    if refl and refl.services and #refl.services > 0 then
        svc_row.type, svc_row.options = "select", refl.services
    else
        svc_row.type = "string"
    end
    local mth_row = { name = "grpc:method", label = "Method", value = method, run = setter("method") }
    local methods = refl and refl.methods and refl.methods[service]
    if methods and #methods > 0 then
        mth_row.type, mth_row.options = "select", methods
    else
        mth_row.type = "string"
    end

    return {
        {
            type = "string",
            name = "grpc:endpoint",
            label = "Endpoint (host:port)",
            value = endpoint,
            run = setter("endpoint"),
        },
        svc_row,
        mth_row,
        note(
            refl and "services + methods from the request's protos / reflection"
                or "name a .proto with @grpc-proto (Settings) for service/method lists",
            "grpc"
        ),
    }
end

-- The REPEATABLE directives, as one declarative table: the accordion label, the directive key, how
-- an entry is read out of the parsed request, and how a new one is written. One table drives the
-- rows, the `add` key and the help — they cannot drift apart.
---@type { key: string, label: string, accent: string, prompt: string, entries: (fun(req: LvimRestRequest): { label: string, value: string }[]) }[]
local LISTS = {
    {
        key = "prompt",
        label = "@prompt",
        accent = "blue",
        prompt = "New @prompt (var [description])",
        entries = function(req)
            local out = {}
            for _, p in ipairs(req.directives.prompt) do
                out[#out + 1] = { label = p.var, value = p.desc or "" }
            end
            return out
        end,
    },
    {
        key = "stdin-cmd",
        label = "@stdin-cmd",
        accent = "yellow",
        prompt = "New @stdin-cmd (var shell…)",
        entries = function(req)
            local out = {}
            for _, c in ipairs(req.directives.stdin_cmd) do
                out[#out + 1] = { label = c.var, value = c.cmd }
            end
            return out
        end,
    },
    {
        key = "env-stdin-cmd",
        label = "@env-stdin-cmd",
        accent = "yellow",
        prompt = "New @env-stdin-cmd (var shell…)",
        entries = function(req)
            local out = {}
            for _, c in ipairs(req.directives.env_stdin_cmd) do
                out[#out + 1] = { label = c.var, value = c.cmd }
            end
            return out
        end,
    },
}

--- One accordion of a repeatable directive. Its children are the entries in document order, each
--- bound to the line it was read from.
---@param req LvimRestRequest
---@param spec table  a LISTS entry
---@return table
local function list_section(req, spec)
    local entries = spec.entries(req)
    local lines = req.directive_lines[spec.key] or {}
    local children = {}
    for i, e in ipairs(entries) do
        local lnum = lines[i]
        children[i] = {
            type = "string",
            name = ("dir:%s:%d"):format(spec.key, i),
            label = e.label,
            value = e.value,
            disabled = lnum == nil, -- no anchor (a malformed line): show it, never rewrite it
            run = function(value)
                if state.editor and lnum then
                    state.editor:set_directive_line(lnum, spec.key, vim.trim(e.label .. " " .. value))
                end
                M.refresh()
            end,
        }
    end
    if #children == 0 then
        children[1] = note("none", "dir:" .. spec.key)
    end
    return fold({
        name = "sec:" .. spec.key,
        label = spec.label,
        count = #entries,
        accent = spec.accent,
        expanded = #entries > 0,
        children = children,
    })
end

--- The raw `@curl-*` flags (a map, so it is listed sorted rather than in document order).
---@param req LvimRestRequest
---@return table
local function curl_section(req)
    local flags = {}
    for flag in pairs(req.directives.curl) do
        flags[#flags + 1] = flag
    end
    table.sort(flags)
    local children = {}
    for _, flag in ipairs(flags) do
        local value = req.directives.curl[flag]
        local lines = req.directive_lines["curl-" .. flag] or {}
        local lnum = lines[1]
        children[#children + 1] = {
            type = "string",
            name = "curl:" .. flag,
            label = flag,
            value = value == true and "" or tostring(value),
            disabled = lnum == nil,
            run = function(v)
                if state.editor and lnum then
                    state.editor:set_directive_line(lnum, "curl-" .. flag, v ~= "" and v or nil)
                end
                M.refresh()
            end,
        }
    end
    if #children == 0 then
        children[1] = note("none", "curl")
    end
    return fold({
        name = "sec:curl",
        label = "@curl-*",
        count = #flags,
        accent = "green",
        expanded = #flags > 0,
        children = children,
    })
end

--- The Settings tab: the single-valued directives, the repeatable ones as accordions, and the
--- directives this plugin does not know — shown, never touched.
---@param req LvimRestRequest
---@return table[]
local function settings_rows(req)
    local d = req.directives
    --- A row whose edit writes one single-valued directive.
    ---@param name string
    ---@param label string
    ---@param rtype string
    ---@param value any
    ---@return table
    local function directive_row(name, label, rtype, value)
        return {
            type = rtype,
            name = "set:" .. name,
            label = label,
            value = value,
            run = function(v)
                if not state.editor then
                    return
                end
                if rtype == "bool" then
                    state.editor:set_directive(name, v == true or nil)
                elseif rtype == "int" then
                    -- 0 means "no timeout directive": a form needs a way to say NONE, and an
                    -- explicit `# @timeout 0` would be a request that times out instantly.
                    state.editor:set_directive(name, (v and v > 0) and tostring(math.floor(v)) or nil)
                else
                    state.editor:set_directive(name, v ~= "" and v or nil)
                end
                M.refresh()
            end,
        }
    end
    local rows = {
        directive_row("timeout", "timeout (ms, 0 = none)", "int", d.timeout or 0),
        directive_row("no-log", "no-log", "bool", d.no_log == true),
        directive_row("no-cookie-jar", "no-cookie-jar", "bool", d.no_cookie_jar == true),
        directive_row("accept", "accept", "string", d.accept or ""),
        directive_row("jq", "jq filter", "string", d.jq or ""),
        { type = "spacer_line" },
    }
    for _, spec in ipairs(LISTS) do
        rows[#rows + 1] = list_section(req, spec)
    end
    rows[#rows + 1] = curl_section(req)

    -- Directives the parser preserved but this plugin has no meaning for. They are READ-ONLY here:
    -- the form must never be the reason a `# @postman-test` line changes.
    local extra = {}
    for key, value in pairs(d.extra) do
        extra[#extra + 1] = { key = key, value = value }
    end
    table.sort(extra, function(a, b)
        return a.key < b.key
    end)
    if #extra > 0 then
        local children = {}
        for _, e in ipairs(extra) do
            children[#children + 1] = note(("# @%s %s"):format(e.key, e.value), "extra:" .. e.key)
        end
        rows[#rows + 1] = fold({
            name = "sec:extra",
            label = "other directives (read-only)",
            count = #extra,
            accent = "magenta",
            expanded = false,
            children = children,
        })
    end
    return rows
end

-- ── the panel ───────────────────────────────────────────────────────────────

--- Tab name → its row builder, so M.open and M.refresh agree and a conditional tab (gRPC) is handled
--- by presence, not a fixed index.
M._builders = {
    params = params_rows,
    headers = headers_rows,
    auth = auth_rows,
    body = body_rows,
    grpc = grpc_rows,
    settings = settings_rows,
}

--- Rebuild every tab's rows from a fresh parse, keeping the cursor row. The panel always shows what
--- the parser sees — which is the whole point of writing back into the buffer instead of a store.
function M.refresh()
    local h, ed = state.handle, state.editor
    if not (h and h.valid and h.valid() and ed and ed:valid() and state.tabs) then
        return
    end
    local req = ed:request()
    if not req then
        return M.close()
    end
    local idx = h.cursor_index()
    -- Rebuild each present tab's rows by NAME (the gRPC tab is only present for a GRPC request).
    for _, tab in ipairs(state.tabs) do
        local b = M._builders[tab.name]
        if b then
            tab.rows = b(req)
        end
    end
    h.recalc()
    h.focus_index(idx)
end

--- Refresh AFTER the form has finished its own repaint of the row that was just edited.
local function refresh_soon()
    vim.schedule(function()
        M.refresh()
    end)
end

--- The `name` of the focused row ("" when there is none).
---
--- Every row is named after WHAT it is (`param:3`, `header:2`, `set:timeout`, `dir:prompt:1`,
--- `curl:proxy`, `note:headers`), so a key acts on the thing under the cursor rather than on a
--- guessed tab. That is also the only honest reading: the panel's tabs are one form, and the cursor
--- is the selection.
---@return string
local function focused_name()
    local h = state.handle
    local name = h and h.cursor_name and h.cursor_name()
    return type(name) == "string" and name or ""
end

--- Which tab the focused row belongs to.
---@return "params"|"headers"|"settings"
local function focused_tab()
    local name = focused_name()
    if name:match("^param:%d+$") or name == "note:params" then
        return "params"
    end
    if name:match("^header:%d+$") or name == "note:headers" then
        return "headers"
    end
    return "settings"
end

--- The 1-based index encoded in the focused row's name (`param:3` → 3).
---@param prefix string
---@return integer?
local function focused(prefix)
    return tonumber(focused_name():match("^" .. prefix .. ":(%d+)$"))
end

-- The panel's ACTIONS: one table drives the buffer keys, the footer legend and the help window.
---@type { key: string, name: string, desc: string, fn: fun() }[]
local ACTIONS = {}

--- Add a row in the active tab.
local function action_add()
    local ed = state.editor
    local h = state.handle
    if not (ed and h) then
        return
    end
    if focused_tab() == "params" then
        return ask("New query parameter (name=value)", "", function(text)
            local name, value = text:match("^([^=]+)=(.*)$")
            if not name then
                return notify("write it as name=value", vim.log.levels.WARN)
            end
            local req = ed:request()
            local _, params = edit.split_query(req and req.url or "")
            params[#params + 1] = { name = vim.trim(name), value = value }
            ed:set_params(params)
            refresh_soon()
        end)
    elseif focused_tab() == "headers" then
        return ask("New header (Name: value)", "", function(text)
            local name, value = text:match("^([^:]+):%s*(.*)$")
            if not name then
                return notify("write it as Name: value", vim.log.levels.WARN)
            end
            ed:add_header(vim.trim(name), value)
            refresh_soon()
        end)
    end
    -- Settings: which repeatable directive gets a new entry is decided by the section the cursor is in.
    local name = focused_name()
    local key = name:match("^dir:([%w%-]+):%d+$") or name:match("^sec:([%w%-]+)$") or name:match("^note:dir:(.+)$")
    for _, spec in ipairs(LISTS) do
        if key == spec.key then
            return ask(spec.prompt, "", function(text)
                if text ~= "" then
                    ed:add_directive(spec.key, text)
                    refresh_soon()
                end
            end)
        end
    end
    if key == "curl" or name:match("^curl:") or name == "note:curl" then
        return ask("New @curl flag (flag[=value])", "", function(text)
            if text ~= "" then
                ed:add_directive("curl-" .. text, nil)
                refresh_soon()
            end
        end)
    end
    notify("put the cursor in a @prompt / @stdin-cmd / @curl section first", vim.log.levels.WARN)
end

--- Delete the row under the cursor (its LINE, for anything line-backed).
local function action_delete()
    local ed, h = state.editor, state.handle
    if not (ed and h) then
        return
    end
    local tab = focused_tab()
    if tab == "params" then
        local i = focused("param")
        if not i then
            return
        end
        local req = ed:request()
        local _, params = edit.split_query(req and req.url or "")
        table.remove(params, i)
        ed:set_params(params)
        return refresh_soon()
    elseif tab == "headers" then
        local i = focused("header")
        local h_row = i and ed:headers()[i]
        if not h_row then
            return
        end
        ed:delete(h_row.lnum)
        return refresh_soon()
    end
    local name = focused_name()
    local key, idx = name:match("^dir:([%w%-]+):(%d+)$")
    if key then
        local lines = ed:directive_lines(key)
        local lnum = lines[tonumber(idx)]
        if lnum then
            ed:delete(lnum)
            return refresh_soon()
        end
    end
    local flag = name:match("^curl:(.+)$")
    if flag then
        ed:set_directive("curl-" .. flag, nil)
        return refresh_soon()
    end
    local single = name:match("^set:(.+)$")
    if single then
        ed:set_directive(single, nil)
        return refresh_soon()
    end
end

--- Comment a header line out / back in.
local function action_toggle()
    local ed, h = state.editor, state.handle
    if not (ed and h) then
        return
    end
    if focused_tab() ~= "headers" then
        return notify("only a header line can be switched off (a url has no disabled parameter)", vim.log.levels.WARN)
    end
    local i = focused("header")
    local row = i and ed:headers()[i]
    if row then
        ed:toggle_header(row.lnum)
        refresh_soon()
    end
end

--- Rename the row under the cursor (a parameter's name, a header's name).
local function action_rename()
    local ed, h = state.editor, state.handle
    if not (ed and h) then
        return
    end
    local tab = focused_tab()
    if tab == "params" then
        local i = focused("param")
        local req = ed:request()
        local _, params = edit.split_query(req and req.url or "")
        if not (i and params[i]) then
            return
        end
        return ask("Parameter name", params[i].name, function(name)
            if name ~= "" then
                params[i].name = name
                ed:set_params(params)
                refresh_soon()
            end
        end)
    elseif tab == "headers" then
        local i = focused("header")
        local row = i and ed:headers()[i]
        if not row then
            return
        end
        return ask("Header name", row.name, function(name)
            if name ~= "" then
                ed:set_header(row.lnum, name, row.value, row.enabled)
                refresh_soon()
            end
        end)
    end
    notify("nothing to rename on this row", vim.log.levels.WARN)
end

--- Open the request's body in a multi-line scratch editor (json/graphql highlighted). The panel
--- closes first — the body is best edited in a real buffer, and reopened options reflect the change.
local function action_edit_body()
    local ed = state.editor
    if not ed then
        return
    end
    local buf, lnum = ed.buf, ed:anchor()
    M.close()
    vim.schedule(function()
        require("lvim-rest.ui.body_editor").open(buf, lnum)
    end)
end

--- Send the request the form is editing, and close (the response belongs in the dock, not here).
local function action_send()
    local ed = state.editor
    if not ed then
        return
    end
    local buf, lnum = ed.buf, ed:anchor()
    M.close()
    vim.schedule(function()
        require("lvim-rest.runner").send(buf, lnum)
    end)
end

--- Move the focused Auth SECRET field into the lvim-keyring wallet, then rewrite it in the `# @auth`
--- line to a `{{vault "…"}}` reference — so the credential lives encrypted and the buffer keeps only
--- the marker (the lvim-db `store_in_keyring` pattern, over the shared vault seam). Only acts on an
--- Auth secret field with a literal (non-templated) value.
local function action_keyring()
    local ed = state.editor
    if not ed then
        return
    end
    local fkey = focused_name():match("^auth:field:(.+)$")
    if not fkey then
        return notify("move to an Auth secret field (Password / Token / …) first", vim.log.levels.WARN)
    end
    local req = ed:request()
    if not req then
        return
    end
    local scheme = spec.variant("auth", req)
    local variant = spec.schema().auth.variants[scheme] or {}
    local field
    for _, f in ipairs(variant.fields or {}) do
        if f.key == fkey then
            field = f
            break
        end
    end
    if not (field and field.secret) then
        return notify("this Auth field is not a secret", vim.log.levels.WARN)
    end
    local vault = require("lvim-rest.vars.vault")
    if not vault.available() then
        return notify("lvim-keyring is not installed", vim.log.levels.WARN)
    end
    local secret = tostring(spec.values("auth", req)[fkey] or "")
    if secret == "" then
        return notify("no value in the Auth field to store", vim.log.levels.WARN)
    end
    if secret:match("^%s*{{") then
        return notify("the field is already a {{ … }} reference", vim.log.levels.INFO)
    end
    local base = (req.name and req.name ~= "" and req.name:gsub("%s+", "-")) or "request"
    local key = vault.key(base .. "/" .. fkey)
    vault.store(key, secret, function(ok, err)
        if not ok then
            return notify("keyring — " .. (err or "store failed"), vim.log.levels.WARN)
        end
        vim.schedule(function()
            local cur = state.editor and state.editor:request()
            if not cur then
                return
            end
            local values = spec.values("auth", cur)
            values[fkey] = ('{{vault "%s"}}'):format(key)
            state.editor:set_directive("auth", spec.assemble_auth(scheme, values))
            M.refresh()
            notify(('stored in the keyring — %s is now {{vault "%s"}}'):format(field.label or fkey, key))
        end)
    end)
end

--- The panel's help window — the shared cheatsheet component, built from the same ACTIONS table.
local function show_help()
    local items = {}
    for _, a in ipairs(ACTIONS) do
        items[#items + 1] = { a.key, a.desc }
    end
    items[#items + 1] = { "<CR>", "edit the focused row (a header/param VALUE, a directive)" }
    items[#items + 1] = { "h / l", "switch tab" }
    items[#items + 1] = { "q", "close" }
    ui.help({ title = "Request options", items = items, close_keys = { "q", "<Esc>", "?" } })
end

ACTIONS = {
    {
        key = config.ui.options.keys.add,
        name = "add",
        desc = "add a parameter / header / directive entry",
        fn = action_add,
    },
    { key = config.ui.options.keys.delete, name = "del", desc = "delete the row under the cursor", fn = action_delete },
    {
        key = config.ui.options.keys.toggle,
        name = "toggle",
        desc = "switch a header line off / on (it is commented out, never lost)",
        fn = action_toggle,
    },
    { key = config.ui.options.keys.rename, name = "rename", desc = "rename a parameter / header", fn = action_rename },
    { key = config.ui.options.keys.send, name = "send", desc = "send this request and close", fn = action_send },
    {
        key = config.ui.options.keys.keyring,
        name = "keyring",
        desc = "store the focused Auth secret in the keyring (rewrites it to a vault reference)",
        fn = action_keyring,
    },
    {
        key = config.ui.options.keys.edit_body,
        name = "body",
        desc = "edit the request body in a multi-line scratch editor",
        fn = action_edit_body,
    },
}

--- Bind the panel keys on its buffer.
---@param buf integer
local function wire_keys(buf)
    for _, a in ipairs(ACTIONS) do
        if a.key and a.key ~= "" then
            vim.keymap.set("n", a.key, a.fn, { buffer = buf, nowait = true, silent = true })
        end
    end
    local help = config.ui.options.keys.help
    if help and help ~= "" then
        vim.keymap.set("n", help, show_help, { buffer = buf, nowait = true, silent = true })
    end
end

--- Close the panel.
function M.close()
    if state.handle and state.handle.valid and state.handle.valid() then
        state.handle.close()
    end
end

--- Open the options form for the request under the cursor of `bufnr` at `lnum`.
---@param bufnr integer?
---@param lnum integer?
---@param layout string?  "float" | "area" | "bottom" (a per-command override, sticky for the session)
---@return nil
function M.open(bufnr, lnum, layout)
    bufnr = bufnr or api.nvim_get_current_buf()
    lnum = lnum or api.nvim_win_get_cursor(0)[1]
    if state.handle and state.handle.valid and state.handle.valid() then
        M.close()
    end
    local ed = edit.attach(bufnr, lnum)
    if not ed then
        return notify("no request under the cursor", vim.log.levels.WARN)
    end
    local req = ed:request()
    if not req then
        return notify("no request under the cursor", vim.log.levels.WARN)
    end
    state.editor = ed
    if layout then
        state.layout = layout
    end
    local t = config.ui.options.tabs
    -- The tab set: the common ones, plus a gRPC tab ONLY for a GRPC request (built by name so refresh
    -- and open never drift). Settings is always last.
    local names = { "params", "headers", "auth", "body" }
    if req.method == "GRPC" then
        names[#names + 1] = "grpc"
    end
    names[#names + 1] = "settings"
    state.tabs = {}
    for _, name in ipairs(names) do
        state.tabs[#state.tabs + 1] =
            { label = t[name].label, icon = t[name].icon, name = name, menu = true, rows = M._builders[name](req) }
    end
    local footer = {}
    for _, a in ipairs(ACTIONS) do
        footer[#footer + 1] = { key = a.key, label = a.name, run = a.fn, no_hotkey = true }
    end
    footer[#footer + 1] = { key = config.ui.options.keys.help, label = "keys", run = show_help, no_hotkey = true }
    state.handle = ui.tabs({
        -- The border title says WHICH request is being edited: the panel is modal over one of them.
        title = { icon = config.icons.request, text = req.name or ((req.method or "") .. " " .. (req.url or "")) },
        tabs = state.tabs,
        layout = state.layout or config.ui.options.layout,
        cursorline_hl = "LvimUiCursorLine",
        footer_hints = footer,
        -- A fold is a change too: remember it, so the rebuild after the next edit keeps it.
        on_change = function(row)
            if row and row.children and row.name then
                state.folds[row.name] = row.expanded
            end
        end,
        on_open = function(buf)
            wire_keys(buf)
        end,
        callback = function()
            if state.editor then
                state.editor:detach()
            end
            state.editor, state.handle, state.tabs = nil, nil, nil
            state.folds = {}
        end,
    })
end

return M
