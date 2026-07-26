-- lvim-rest.store.bind: the seam between a LIBRARY request row and an editable `.http` BUFFER.
--
-- A stored request has no file on disk. Opening one renders it as a normal `.http` document in a
-- NAMELESS `nofile` scratch buffer tagged with `b:lvim_rest_request_id` (the lvim-db editor model, so the
-- statusline never mistakes it for a file). The save key (not `:w`, which `nofile` disables) calls
-- `write_back`, which re-parses the buffer with the ordinary execution parser and UPDATEs the row. So the
-- request BUILDER is just the editor: treesitter highlight, the buffer-local send maps and the
-- variable completion all work exactly as they do for a real `.http` file, and there is no second
-- form UI to keep in sync with the parser.
--
-- HEADERS ARE AN ORDERED ARRAY (`{ { name, value }, … }`) — the parser's own shape. A map would
-- silently drop duplicates (two `Set-Cookie`s) and the authored order, which is HTTP-visible.
--
-- SECRETS NEVER REACH THE DATABASE. Every save runs `vars.vault.detect_secrets`; a hit is either
-- moved into lvim-keyring and rewritten to a `{{vault "…"}}` reference (`vault.auto`), or the save
-- is REFUSED with the offending fields named. There is no path that writes a credential inline —
-- refusing is deliberate: silently stripping or silently storing would both lose the user's intent.
--
---@module "lvim-rest.store.bind"

local api = vim.api
local config = require("lvim-rest.config")
local library = require("lvim-rest.store.library")
local parser = require("lvim-rest.parser")
local vault = require("lvim-rest.vars.vault")

local M = {}

local AUGROUP = "LvimRestBind"

---@type table<integer, integer>  request id → the buffer currently bound to it
local bound = {}

--- Notify through the plugin's prefix.
---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-rest: " .. msg, level or vim.log.levels.INFO)
end

--- The `@grpc-*` directive lines for a gRPC config table (proto / import / authority / insecure), in the
--- order the parser reads them back. Shared by `render` (collection-level inheritance) and `docs_text`
--- (the request's own, serialised into the `docs` column) so the two can never disagree on the wire form.
---@param g table?  { proto?: string[], import?: string[], authority?: string, insecure?: boolean }
---@return string[]
local function grpc_lines(g)
    local lines = {}
    if type(g) ~= "table" then
        return lines
    end
    for _, p in ipairs(g.proto or {}) do
        lines[#lines + 1] = "@grpc-proto " .. p
    end
    for _, i in ipairs(g.import or {}) do
        lines[#lines + 1] = "@grpc-import " .. i
    end
    if g.authority and g.authority ~= "" then
        lines[#lines + 1] = "@grpc-authority " .. g.authority
    end
    if g.insecure then
        lines[#lines + 1] = "@grpc-insecure"
    end
    return lines
end

-- ── render: row → `.http` text ───────────────────────────────────────────────

--- Render a stored request as an `.http` document. The output is exactly what the parser accepts,
--- so `render → parse → render` is stable and a user can edit any part of it by hand.
---@param row table  a library request row (json columns already inflated)
---@return string[] lines
function M.render(row)
    local out = {}
    out[#out + 1] = "### " .. (row.name or "request")

    -- The owning collection, fetched ONCE — every collection-level default (vars, auth, headers, gRPC)
    -- reads from it, and each is INHERITED the same way: rendered into the document so you can see what
    -- will be sent and override it by editing the line (saving then makes the inherited value the
    -- request's own — the document is the truth). A request always wins over its collection.
    local col = row.collection_id and library.collection(row.collection_id) or nil

    -- Request-local variables come before the request line, like a hand-written document; then the
    -- collection's variables the request does NOT itself define (a same-named request var overrides).
    local own_var = {}
    for _, v in ipairs(row.vars or {}) do
        if type(v) == "table" and v.name then
            own_var[v.name] = true
            out[#out + 1] = ("@%s = %s"):format(v.name, v.value or "")
        end
    end
    for _, v in ipairs((col and col.vars) or {}) do
        if type(v) == "table" and v.name and not own_var[v.name] then
            out[#out + 1] = ("@%s = %s"):format(v.name, v.value or "")
        end
    end

    -- Auth is a DIRECTIVE in the document form, so a stored request carries its scheme the same way a
    -- hand-written one does — and editing the line is editing the row. A request with no auth of its own
    -- inherits its collection's (Postman's rule, and the reason a collection-level scheme exists at all).
    local auth = row.auth
    if (type(auth) ~= "table" or not auth.scheme) and col then
        auth = col.auth or nil
    end
    if type(auth) == "table" and auth.scheme then
        local parts = { "# @auth", auth.scheme }
        for _, a in ipairs(auth.args or {}) do
            parts[#parts + 1] = a
        end
        out[#out + 1] = table.concat(parts, " ")
    end
    -- A stored script is rendered as the document form of itself, so a request that came from the
    -- library is indistinguishable from one typed by hand — and editing the block IS editing the row.
    if row.pre_script and vim.trim(row.pre_script) ~= "" then
        out[#out + 1] = "< {%"
        for _, l in ipairs(vim.split(row.pre_script, "\n", { plain = true })) do
            out[#out + 1] = l
        end
        out[#out + 1] = "%}"
    end
    -- gRPC config INHERITANCE: a GRPC request that carries no `@grpc-*` of its own takes its collection's
    -- defaults (proto / import / authority / insecure) — the same "collection-level scheme, rendered into
    -- the document" rule as auth. Set the config once on the collection and every request inherits it; a
    -- per-request directive still wins, because then `@grpc-` is already in `row.docs` and this is skipped.
    -- (Saving makes the inherited lines the request's own — the document is the truth, as with auth.)
    if row.method == "GRPC" and not (row.docs and row.docs:match("@grpc%-")) and col then
        for _, l in ipairs(grpc_lines(col.grpc)) do
            out[#out + 1] = "# " .. l
        end
    end
    if row.docs and row.docs ~= "" then
        for _, l in ipairs(vim.split(row.docs, "\n", { plain = true })) do
            out[#out + 1] = "# " .. l
        end
    end
    out[#out + 1] = ("%s %s"):format(row.method or "GET", row.url or "")
    -- The request's own headers, then the collection's headers it does NOT itself set — a same-named
    -- request header (case-insensitively) overrides the collection's, so a shared `Accept` / base
    -- `Authorization` set once on the collection reaches every request that hasn't defined its own.
    local own_header = {}
    for _, h in ipairs(row.headers or {}) do
        if type(h) == "table" and h.name then
            own_header[h.name:lower()] = true
            out[#out + 1] = ("%s: %s"):format(h.name, h.value or "")
        end
    end
    for _, h in ipairs((col and col.headers) or {}) do
        if type(h) == "table" and h.name and not own_header[h.name:lower()] then
            out[#out + 1] = ("%s: %s"):format(h.name, h.value or "")
        end
    end
    if row.body and row.body ~= "" then
        out[#out + 1] = "" -- the blank line that starts the body
        for _, l in ipairs(vim.split(row.body, "\n", { plain = true })) do
            out[#out + 1] = l
        end
    end
    if row.post_script and vim.trim(row.post_script) ~= "" then
        -- The post block lives after the body, which means the body must have started: a request
        -- with a script but no body still needs the blank separator line.
        if not (row.body and row.body ~= "") then
            out[#out + 1] = ""
        end
        out[#out + 1] = ""
        out[#out + 1] = "> {%"
        for _, l in ipairs(vim.split(row.post_script, "\n", { plain = true })) do
            out[#out + 1] = l
        end
        out[#out + 1] = "%}"
    end
    return out
end

-- ── write-back: buffer → row ─────────────────────────────────────────────────

--- Rebuild the `docs` column — the `# …` lines rendered BEFORE the request line: the gRPC config
--- (`@grpc-proto` / `@grpc-import` / `@grpc-authority` / `@grpc-insecure`) plus any plain doc comments. The
--- parser reads `# @grpc-*` back as `req.directives.grpc`, so without serialising them here an edit to a
--- gRPC directive (the endpoint's authority, its proto paths) would NOT persist — `fields_of` dropped both
--- `docs` and the grpc directives, so `update_request` left the column at its old value.
---@param req table
---@return string
local function docs_text(req)
    local lines = grpc_lines(req.directives and req.directives.grpc)
    if req.docs and req.docs ~= "" then
        for _, l in ipairs(vim.split(req.docs, "\n", { plain = true })) do
            lines[#lines + 1] = l
        end
    end
    return table.concat(lines, "\n")
end

--- The library fields a parsed request maps onto.
---@param req table  LvimRestRequest
---@return table fields
local function fields_of(req)
    local headers = {}
    for _, h in ipairs(req.headers or {}) do
        headers[#headers + 1] = { name = h.name, value = h.value }
    end
    local vars = {}
    for _, v in ipairs(req.vars or {}) do
        vars[#vars + 1] = { name = v.name, value = v.value }
    end
    -- Several blocks of the same kind concatenate: the columns are one text each, and running them
    -- in sequence is what the document form does anyway.
    local function join(list)
        local parts = {}
        for _, sc in ipairs(list or {}) do
            -- A `< ./x.lua` FILE reference is kept verbatim as its own line, so the row records the
            -- reference rather than inlining a copy that would go stale.
            parts[#parts + 1] = sc.file and ("< " .. sc.file) or sc.source
        end
        -- "" not nil: `update_request` treats nil as "leave this column alone", so a nil here would
        -- make DELETING a script block from the buffer un-saveable. The buffer is the whole truth for
        -- every field the document form expresses — absent must mean empty, not unchanged.
        return table.concat(parts, "\n")
    end
    local scripts = req.scripts or {}
    return {
        -- `false` not nil: `update_request` encodes json columns only when the key is present, and
        -- removing the directive from the buffer has to clear the column (see the body/scripts note).
        auth = req.directives and req.directives.auth or vim.empty_dict(),
        pre_script = join(scripts.pre),
        post_script = join(scripts.post),
        name = req.name,
        method = req.method,
        url = req.url,
        headers = headers,
        body = req.body or "", -- same reason as the scripts above: a deleted body must clear the column
        vars = vars,
        -- The gRPC directives + doc comments, so editing a `@grpc-*` line (endpoint authority, proto paths)
        -- and saving actually persists — see `docs_text`. "" clears the column when the last one is removed.
        docs = docs_text(req),
    }
end

--- Persist `fields` onto `id` and clear the buffer's modified flag (the save key drives the write).
---@param id integer
---@param bufnr integer
---@param fields table
local function persist(id, bufnr, fields)
    if library.update_request(id, fields) then
        if api.nvim_buf_is_valid(bufnr) then
            vim.bo[bufnr].modified = false
        end
        notify(("saved %s"):format(fields.name or "request"))
    else
        notify("could not save the request", vim.log.levels.ERROR)
    end
end

--- Move every detected secret into lvim-keyring, rewriting its value to a `{{vault "…"}}` marker,
--- then persist. Async: the wallet write has a callback, so the row is written once all land.
---
--- A FAILED wallet write REFUSES THE WHOLE SAVE. The value is still the raw credential at that
--- point, so persisting anyway would write the very thing this module exists to keep out of the
--- database — and it would do it while telling the user "saved". Refusing leaves the buffer modified
--- with the text intact, which is the same answer the unavailable-wallet path already gives.
---@param id integer
---@param bufnr integer
---@param fields table
---@param hits table[]
local function vault_then_persist(id, bufnr, fields, hits)
    local pending = #hits
    ---@type string[] the secrets whose wallet write failed (the save is refused when any did)
    local failed = {}
    for _, hit in ipairs(hits) do
        local key = ("lvim-rest/%d/%s"):format(id, hit.name)
        vault.store(key, hit.value, function(ok, err)
            if ok then
                local marker = ('{{vault "%s"}}'):format(key)
                if hit.field == "header" then
                    for _, h in ipairs(fields.headers) do
                        if h.name == hit.name and h.value == hit.value then
                            h.value = marker
                        end
                    end
                else
                    for _, v in ipairs(fields.vars) do
                        if v.name == hit.name and v.value == hit.value then
                            v.value = marker
                        end
                    end
                end
            else
                failed[#failed + 1] = ("%s (%s)"):format(hit.name, tostring(err))
            end
            pending = pending - 1
            if pending == 0 then
                vim.schedule(function()
                    if #failed > 0 then
                        notify(
                            ("refusing to save — %s could not be moved into the wallet, and saving now would store them in plain text"):format(
                                table.concat(failed, ", ")
                            ),
                            vim.log.levels.ERROR
                        )
                        return
                    end
                    persist(id, bufnr, fields)
                end)
            end
        end)
    end
end

--- Parse `bufnr` and write it back onto its bound request row. Called by the editor's save key.
---@param bufnr integer
---@return nil
function M.write_back(bufnr)
    local id = vim.b[bufnr].lvim_rest_request_id
    if not id then
        return
    end
    local text = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    local doc = parser.parse(text)
    local req = doc and doc.requests and doc.requests[1]
    if not req then
        notify("nothing to save — the buffer holds no request line", vim.log.levels.WARN)
        return
    end
    local fields = fields_of(req)

    local hits = config.vault.enabled and vault.detect_secrets(req) or {}
    if #hits == 0 then
        return persist(id, bufnr, fields)
    end
    local names = {}
    for _, h in ipairs(hits) do
        names[#names + 1] = h.name
    end
    if not vault.available() then
        notify(
            ("refusing to save — %s would be stored in plain text and lvim-keyring is not available"):format(
                table.concat(names, ", ")
            ),
            vim.log.levels.ERROR
        )
        return
    end
    if not config.vault.auto then
        notify(
            ('refusing to save — %s look like secrets. Replace them with {{vault "key"}} yourself, or set vault.auto = true to move them into the wallet automatically.'):format(
                table.concat(names, ", ")
            ),
            vim.log.levels.WARN
        )
        return
    end
    vault_then_persist(id, bufnr, fields, hits)
end

-- ── open: row → buffer ───────────────────────────────────────────────────────

--- Open the stored request `id` as an editable `.http` buffer, reusing the one already bound to it.
--- The buffer is a scratch (`acwrite`) with a name of its own, so `:w` is intercepted rather than
--- writing a file, and the row is the only storage.
---@param id integer
---@return integer? bufnr
function M.open(id)
    local row = library.request(id)
    if not row then
        notify("no such request", vim.log.levels.ERROR)
        return nil
    end
    local existing = bound[id]
    if existing and api.nvim_buf_is_valid(existing) then
        api.nvim_buf_set_lines(existing, 0, -1, false, M.render(row))
        vim.bo[existing].modified = false
        return existing
    end

    -- A NAMELESS, unlisted `nofile` scratch — exactly the lvim-db editor model. It is deliberately NOT a named
    -- buffer: any name (even a `scheme://` one) is rendered by the statusline as a cwd-relative FILE path, which
    -- made the request read as a real file on disk. Nameless + `nofile` keeps the statusline clean (just the
    -- filetype), and the request name lives where it belongs — the editor's blue title band (winbar). The buffer
    -- is found by `bound[id]` + `b:lvim_rest_request_id`, never by name, so losing the name costs nothing.
    local buf = api.nvim_create_buf(false, false)
    api.nvim_buf_set_lines(buf, 0, -1, false, M.render(row))
    vim.bo[buf].buftype = "nofile" -- not a file: `:w` is disabled; saving goes through the save key → write_back
    vim.bo[buf].bufhidden = "hide" -- keep unsaved edits when the pane switches requests (bound[id] caches it)
    vim.bo[buf].filetype = "http"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modified = false
    vim.b[buf].lvim_rest_request_id = id

    local grp = api.nvim_create_augroup(AUGROUP .. "_" .. id, { clear = true })
    api.nvim_create_autocmd("BufWipeout", {
        group = grp,
        buffer = buf,
        callback = function()
            bound[id] = nil
        end,
    })

    bound[id] = buf
    return buf
end

--- The buffer currently bound to request `id`, if any.
---@param id integer
---@return integer?
function M.buffer_for(id)
    local b = bound[id]
    return (b and api.nvim_buf_is_valid(b)) and b or nil
end

--- The request id a buffer is bound to, if any.
---@param bufnr integer?
---@return integer?
function M.request_of(bufnr)
    return vim.b[bufnr or api.nvim_get_current_buf()].lvim_rest_request_id
end

return M
