-- lvim-rest.spec: the ONE declarative schema read by three consumers that therefore cannot disagree —
-- the interactive options panel (rows), the hand-written-request validator (`vim.diagnostic`), and the
-- cmp source (completions). This module owns the schema (static `spec.schema` merged with user
-- `config.spec`) and exposes the read-contracts; it NEVER writes a buffer and NEVER blocks or networks.
--
-- Invariants (design §7): validation is STRUCTURAL only (required/enum/type/format/arity — never "will
-- the server accept this"); an UNKNOWN `# @x` directive is tolerated (at most a near-miss INFO, foreign
-- keys silent) and never edited; the panel is the only writer (rows carry a `write` descriptor, no
-- callbacks); dynamic vocabulary (gRPC reflection, env profiles) is read from a cache in `validate`,
-- resolved live only for the panel/cmp.
--
-- This increment ships `validate`/`validate_document`; `rows` (panel) and `complete` (cmp) land next.
--
---@module "lvim-rest.spec"

local formats = require("lvim-rest.spec.formats")

local M = {}

-- ── shapes ─────────────────────────────────────────────────────────────────────────────
---@class LvimRestSpecField
---@field key       string
---@field type      "string"|"int"|"bool"|"select"|"json"
---@field label?    string
---@field required? boolean|fun(values: table<string, any>): boolean
---@field options?  string[]|fun(ctx: LvimRestSpecCtx): string[]
---@field format?   string
---@field default?  any
---@field secret?   boolean
---@field hint?     string
---@field dynamic?  LvimRestSpecDynamic
---@field validate? fun(value: any, values: table<string, any>): string?

---@class LvimRestSpecVariant
---@field label?   string
---@field args?    string[]
---@field fields   LvimRestSpecField[]
---@field group?   table<string, LvimRestSpecGroup>
---@field headers? table<string, string>

---@class LvimRestSpecGroup
---@field discriminator { key: string, label: string }
---@field variants      table<string, LvimRestSpecVariant>
---@field detect?       fun(req: LvimRestRequest): string?
---@field dynamic?      LvimRestSpecDynamic

---@class LvimRestSpecDynamic
---@field resolve fun(ctx: LvimRestSpecCtx, cb: fun(result: any, err: string?))
---@field key     fun(ctx: LvimRestSpecCtx): string?
---@field ttl?    integer

---@class LvimRestSpecCtx
---@field buf?    integer
---@field path?   string
---@field req?    LvimRestRequest
---@field values? table<string, any>

-- ── the merged schema (static + user config.spec) ──────────────────────────────────────
---@type table?
local merged

--- The effective schema: the shipped static grammar with `config.spec` merged over it. Cached; a
--- `setup()` that re-merges should call `M.invalidate()`.
---@return table
function M.schema()
    if merged then
        return merged
    end
    local static = require("lvim-rest.spec.schema")
    local ok_cfg, config = pcall(require, "lvim-rest.config")
    local overrides = (ok_cfg and config.spec) or nil
    if not overrides then
        merged = static
        return merged
    end
    local ok_merge, utils = pcall(require, "lvim-utils.utils")
    local copy = vim.deepcopy(static)
    if ok_merge and utils.merge then
        utils.merge(copy, overrides)
    else
        copy = vim.tbl_deep_extend("force", copy, overrides)
    end
    merged = copy
    return merged
end

--- Drop the cached merge (after a re-`setup()`).
function M.invalidate()
    merged = nil
end

-- ── helpers ─────────────────────────────────────────────────────────────────────────────
--- A value the user templated with `{{ … }}` is OPAQUE: format/enum/type checks are skipped on it,
--- because its resolved value is unknown at edit time (validating it would be semantic, §7.1).
---@param v any
---@return boolean
local function is_template(v)
    return type(v) == "string" and v:find("{{", 1, true) ~= nil
end

--- Levenshtein distance, capped — enough to decide "near-miss" (≤ 2) for unknown-directive hints.
---@param a string
---@param b string
---@return integer
local function edit_distance(a, b)
    local la, lb = #a, #b
    if math.abs(la - lb) > 2 then
        return 3
    end
    local prev = {}
    for j = 0, lb do
        prev[j] = j
    end
    for i = 1, la do
        local cur = { [0] = i }
        for j = 1, lb do
            local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
            cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        end
        prev = cur
    end
    return prev[lb]
end

--- One diagnostic, on the recorded 1-based `lnum`, spanning the whole line.
---@param buf integer?
---@param lnum integer
---@param severity integer
---@param code string
---@param message string
---@return vim.Diagnostic
local function diag(buf, lnum, severity, code, message)
    local text = ""
    if buf and vim.api.nvim_buf_is_valid(buf) then
        text = (vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false) or {})[1] or ""
    end
    return {
        lnum = lnum - 1,
        col = 0,
        end_lnum = lnum - 1,
        end_col = #text,
        severity = severity,
        source = "lvim-rest",
        code = code,
        message = message,
    }
end

--- The first recorded line for a directive key (written key, lowercased with hyphens).
---@param req LvimRestRequest
---@param key string
---@return integer?
local function directive_line(req, key)
    local lines = req.directive_lines and req.directive_lines[key]
    return lines and lines[1] or nil
end

-- ── auth validation ─────────────────────────────────────────────────────────────────────
--- A case/separator-insensitive lookup of `key` in an env profile table (JetBrains keys vary in case).
---@param prof table
---@param key string
---@return any
local function profile_field(prof, key)
    local want = key:lower():gsub("[-_]", "")
    for k, v in pairs(prof) do
        if type(k) == "string" and k:lower():gsub("[-_]", "") == want then
            return v
        end
    end
    return nil
end

--- Validate the referenced oauth2 PROFILE against the env file: it must exist, and its grant's required
--- fields must be present. Diagnostics land on the `# @auth oauth2 <id>` line (the profile itself lives
--- in a separate JSON env document). The env read is LOCAL and sync — not the networked resolve the
--- cache-only rule guards against.
---@param profile_id string
---@param ctx LvimRestSpecCtx?
---@param buf integer?
---@param lnum integer
---@param out vim.Diagnostic[]
local function validate_oauth2_profile(profile_id, ctx, buf, lnum, out)
    if profile_id == "" or is_template(profile_id) then
        return
    end
    local ok_auth, auth = pcall(require, "lvim-rest.auth")
    local profiles = (ok_auth and auth.profiles and auth.profiles(ctx and ctx.path or "")) or {}
    local prof = profiles[profile_id]
    if not prof then
        if next(profiles) then -- an env file with Security.Auth exists but lacks this id
            out[#out + 1] = diag(
                buf,
                lnum,
                vim.diagnostic.severity.WARN,
                "auth.oauth2.profile.unknown",
                ('auth profile "%s" is not under Security.Auth in the environment file'):format(profile_id)
            )
        end
        return
    end
    local ok_o2, oauth2 = pcall(require, "lvim-rest.auth.oauth2")
    local grant = ok_o2 and oauth2.grant_of and oauth2.grant_of(prof) or "client_credentials"
    local pvariant = (((M.schema().auth.variants.oauth2 or {}).profile or {}).variants or {})[grant]
    if not pvariant then
        return
    end
    local missing = {}
    for _, f in ipairs(pvariant.fields or {}) do
        -- A `{{vault …}}` value is present (not missing); only nil/empty counts.
        if f.required then
            local v = profile_field(prof, f.key)
            if v == nil or v == "" then
                missing[#missing + 1] = (f.label or f.key)
            end
        end
    end
    if #missing > 0 then
        out[#out + 1] = diag(
            buf,
            lnum,
            vim.diagnostic.severity.ERROR,
            "auth.oauth2.profile." .. grant .. ".required",
            ('auth profile "%s": %s required for grant %s'):format(profile_id, table.concat(missing, ", "), grant)
        )
    end
end

--- Validate the `# @auth` directive against the auth group: scheme ∈ variants (a KNOWN directive with
--- a bad VALUE is an error, not tolerated), then the selected variant's required positional args.
---@param req LvimRestRequest
---@param ctx LvimRestSpecCtx?
---@param out vim.Diagnostic[]
local function validate_auth(req, ctx, out)
    local buf = ctx and ctx.buf
    local auth = req.directives and req.directives.auth
    if not auth then
        return
    end
    local lnum = directive_line(req, "auth")
    if not lnum then
        return
    end
    local group = M.schema().auth
    local scheme = auth.scheme or ""
    local variant = group.variants[scheme]
    if not variant then
        local valid = vim.tbl_keys(group.variants)
        table.sort(valid)
        out[#out + 1] = diag(
            buf,
            lnum,
            vim.diagnostic.severity.ERROR,
            "auth.scheme.enum",
            ('unknown auth scheme "%s" — one of: %s'):format(scheme, table.concat(valid, ", "))
        )
        return
    end
    -- Required positional args: a field marked required whose positional arg is missing/empty. A
    -- `{{template}}` arg counts as present (opaque).
    local missing = {}
    local args = auth.args or {}
    for i, argkey in ipairs(variant.args or {}) do
        local field
        for _, f in ipairs(variant.fields) do
            if f.key == argkey then
                field = f
                break
            end
        end
        if field and field.required then
            local v = args[i]
            if v == nil or v == "" then
                missing[#missing + 1] = (field.label or argkey):lower()
            end
        end
    end
    if #missing > 0 then
        out[#out + 1] = diag(
            buf,
            lnum,
            vim.diagnostic.severity.ERROR,
            "auth." .. scheme .. ".args.required",
            ("auth %s needs %s"):format(scheme, table.concat(missing, " and "))
        )
        return
    end
    -- oauth2 carries a profile id whose own table (in the env file) is validated against the grant.
    if scheme == "oauth2" then
        validate_oauth2_profile(args[1] or "", ctx, buf, lnum, out)
    end
end

-- ── body validation ──────────────────────────────────────────────────────────────────────
--- Structural body checks: a JSON-typed body must parse (json / grpc message). GraphQL / raw / form
--- carry no structural check here. A `{{…}}`-containing body is opaque (skipped).
---@param req LvimRestRequest
---@param buf integer?
---@param out vim.Diagnostic[]
local function validate_body(req, buf, out)
    local body = req.body
    if not body or body == "" or is_template(body) then
        return
    end
    local group = M.schema().body
    local kind = group.detect and group.detect(req) or "raw"
    if kind ~= "json" and kind ~= "grpc_message" then
        return
    end
    local ok = pcall(vim.json.decode, body)
    if not ok then
        local lnum = req.body_line or req.line
        local ok2, err = pcall(vim.json.decode, body)
        local detail = (not ok2 and type(err) == "string") and err:gsub("^.-:%d+: ", "") or "invalid JSON"
        out[#out + 1] = diag(
            buf,
            lnum,
            vim.diagnostic.severity.ERROR,
            "body." .. (kind == "json" and "json" or "grpc") .. ".parse",
            "body is not valid JSON: " .. detail
        )
    end
end

-- ── unknown-directive tolerance (near-miss INFO) ──────────────────────────────────────────
--- An unknown `# @x` is TOLERATED. When it is a near-miss (edit distance ≤ 2) of a known directive
--- key, emit an INFO hint; a genuinely foreign key (e.g. `# @postman-test`) gets nothing.
---@param req LvimRestRequest
---@param buf integer?
---@param out vim.Diagnostic[]
local function validate_unknown(req, buf, out)
    local known = M.schema().directives
    for key, lines in pairs(req.directive_lines or {}) do
        if not known[key] and not key:match("^curl%-") then
            local best, bestd = nil, 3
            for kk in pairs(known) do
                local d = edit_distance(key, kk)
                if d < bestd then
                    best, bestd = kk, d
                end
            end
            if best and bestd <= 2 then
                out[#out + 1] = diag(
                    buf,
                    lines[1],
                    vim.diagnostic.severity.INFO,
                    "directive.unknown.near",
                    ("unknown directive @%s — did you mean @%s?"):format(key, best)
                )
            end
        end
    end
end

-- ── directive value / format validation ─────────────────────────────────────────────────
--- The RAW value written after a `# @key ` (or `// @key `) directive on `lnum`, or nil. The parser
--- coerced the value (tonumber, split…), so the raw text is read back from the buffer to format-check
--- and to apply template-opacity to what the user actually typed.
---@param buf integer?
---@param lnum integer
---@param key string
---@return string?
local function raw_directive_value(buf, lnum, key)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return nil
    end
    local line = (vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false) or {})[1] or ""
    local k = vim.pesc(key)
    return line:match("^%s*#+%s*@" .. k .. "%s+(.*)$") or line:match("^%s*//%s*@" .. k .. "%s+(.*)$")
end

--- Format-check the plugin's OWN directives (known keys with a `format`), reading each raw value from
--- the buffer. A `{{template}}` value is opaque (skipped). Path-formatted directives also get a
--- file-existence WARN (decision #4), resolved relative to the `.http` file's directory.
---@param req LvimRestRequest
---@param ctx LvimRestSpecCtx?
---@param out vim.Diagnostic[]
local function validate_directives(req, ctx, out)
    local buf = ctx and ctx.buf
    local base_dir = ctx and ctx.path and ctx.path ~= "" and vim.fn.fnamemodify(ctx.path, ":h") or nil
    local known = M.schema().directives
    for key, lines in pairs(req.directive_lines or {}) do
        local d = known[key]
        if d and d.format then
            local checker = formats.get(d.format)
            for _, lnum in ipairs(lines) do
                local val = raw_directive_value(buf, lnum, key)
                if val then
                    val = vim.trim(val)
                    if val ~= "" and not is_template(val) then
                        local err = checker and checker(val)
                        if err then
                            out[#out + 1] = diag(
                                buf,
                                lnum,
                                vim.diagnostic.severity.ERROR,
                                "directive." .. key .. ".format",
                                ("@%s: %s"):format(key, err)
                            )
                        elseif d.format == "path" or d.format == "proto_path" then
                            local raw = (base_dir and not val:match("^/")) and (base_dir .. "/" .. val) or val
                            -- normalize (not expand): it collapses `./` and expands `~` without the
                            -- glob behaviour of vim.fn.expand (which returns "" for a `.`-containing
                            -- path). A directory counts as present (`@grpc-import` names an import root).
                            local pn = vim.fs.normalize(raw)
                            if vim.fn.filereadable(pn) == 0 and vim.fn.isdirectory(pn) == 0 then
                                out[#out + 1] = diag(
                                    buf,
                                    lnum,
                                    vim.diagnostic.severity.WARN,
                                    "directive." .. key .. ".missing",
                                    ("@%s: file not found: %s"):format(key, val)
                                )
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ── public: validate ──────────────────────────────────────────────────────────────────────
--- Structural diagnostics for ONE parsed request. PURE: no I/O beyond reading the buffer's own lines
--- for span text, no resolve, cache-reads only. Diagnostics are 0-based `lnum`, `source="lvim-rest"`,
--- each with a stable dotted `code`.
---@param req LvimRestRequest
---@param ctx LvimRestSpecCtx?
---@return vim.Diagnostic[]
function M.validate(req, ctx)
    local buf = ctx and ctx.buf
    ---@type vim.Diagnostic[]
    local out = {}
    validate_auth(req, ctx, out)
    validate_body(req, buf, out)
    validate_directives(req, ctx, out)
    validate_unknown(req, buf, out)
    return out
end

--- Structural diagnostics for a whole parsed document (concat over its requests).
---@param doc LvimRestDocument
---@param ctx LvimRestSpecCtx?
---@return vim.Diagnostic[]
function M.validate_document(doc, ctx)
    ---@type vim.Diagnostic[]
    local out = {}
    for _, req in ipairs(doc.requests or {}) do
        for _, d in ipairs(M.validate(req, ctx)) do
            out[#out + 1] = d
        end
    end
    return out
end

-- ── rows: the panel-builder contract ─────────────────────────────────────────────────────
---@class LvimRestSpecWrite
---@field kind  "directive"|"header"|"request_line"|"query"|"body"|"body_include"
---@field key?  string   directive key / header name
---@field group? string  a directive-line group (auth) — the panel reassembles the whole line on any edit

---@class LvimRestSpecRow
---@field row   table               the lvim-ui.tabs row (type/name/label/value/options)
---@field field LvimRestSpecField   the descriptor it came from
---@field write LvimRestSpecWrite   where this value lives in the document

--- Which variant of `group` is active for `req` — the written discriminator (explicit) or the
--- inferred one (`detect`).
---@param group LvimRestSpecGroup
---@param req LvimRestRequest
---@param group_name string
---@return string
local function active_variant(group, req, group_name)
    if group.detect then
        return group.detect(req) or next(group.variants) or "none"
    end
    if group_name == "auth" then
        return (req.directives and req.directives.auth and req.directives.auth.scheme) or "none"
    end
    return next(group.variants) or "none"
end

--- Current values of an AUTH variant's fields, read positionally from the parsed `# @auth` args.
---@param variant LvimRestSpecVariant
---@param req LvimRestRequest
---@return table<string, any>
local function auth_values(variant, req)
    local vals = {}
    local args = (req.directives and req.directives.auth and req.directives.auth.args) or {}
    for i, argkey in ipairs(variant.args or {}) do
        vals[argkey] = args[i]
    end
    return vals
end

--- Current values of a BODY variant's fields, read from the parsed request.
---@param vname string
---@param req LvimRestRequest
---@return table<string, any>
local function body_values(vname, req)
    if vname == "file" then
        return { path = req.body_file or "", substitute = req.body_file_var == true }
    end
    -- json / graphql / grpc_message / form / raw all edit the body block.
    return { content = req.body or "", message = req.body or "", query = req.body or "" }
end

--- A select field's options: a static list, a plain `options` function, or a `dynamic` resolver read
--- through the cache. Returns synchronously — a sync resolver (a local env-file read) fills it now; an
--- async one (gRPC reflection) yields whatever the cache holds (empty on a cold cache; the panel then
--- calls `M.resolve_options` to warm it and re-render).
---@param field LvimRestSpecField
---@param ctx LvimRestSpecCtx?
---@return string[]
local function select_options(field, ctx)
    local opts = field.options
    if type(opts) == "table" then
        return opts
    end
    if type(opts) == "function" then
        local ok, res = pcall(opts, ctx or {})
        return (ok and type(res) == "table") and res or {}
    end
    if field.dynamic then
        local cache = require("lvim-rest.spec.cache")
        local key = field.dynamic.key and field.dynamic.key(ctx or {})
        local cached = cache.get(key, field.dynamic.ttl)
        if type(cached) == "table" then
            return cached
        end
        -- A sync resolver (env read) calls back immediately; an async one leaves `got` nil.
        local got
        pcall(field.dynamic.resolve, ctx or {}, function(res)
            got = res
        end)
        if type(got) == "table" then
            cache.set(key, got)
            return got
        end
    end
    return {}
end

--- Turn a `select`/`string`/… descriptor into the lvim-ui row it renders as.
---@param field LvimRestSpecField
---@param value any
---@param ctx LvimRestSpecCtx?
---@return table
local function to_ui_row(field, value, ctx)
    local ui_type = field.type
    if ui_type == "json" then
        ui_type = "string" -- a body opens a scratch editor; the row itself is a string
    end
    local row = { type = ui_type, name = field.key, label = field.label or field.key, value = value or "" }
    if field.type == "select" then
        row.options = select_options(field, ctx)
    end
    return row
end

--- Warm the cache for a group's dynamic select fields, calling `cb` once any resolve lands (so the
--- panel can re-render with populated options). Sync resolvers return before `cb`; async ones drive it.
---@param group_name string
---@param req LvimRestRequest
---@param ctx LvimRestSpecCtx?
---@param cb fun()
---@return nil
function M.resolve_options(group_name, req, ctx, cb)
    local group = M.schema()[group_name]
    if type(group) ~= "table" or not group.variants then
        return
    end
    local vname = active_variant(group, req, group_name)
    local variant = group.variants[vname] or {}
    local cache = require("lvim-rest.spec.cache")
    for _, field in ipairs(variant.fields or {}) do
        if field.dynamic and field.type == "select" then
            local key = field.dynamic.key and field.dynamic.key(ctx or {})
            if not cache.get(key, field.dynamic.ttl) then
                field.dynamic.resolve(ctx or {}, function(res)
                    if type(res) == "table" then
                        cache.set(key, res)
                        vim.schedule(cb)
                    end
                end)
            end
        end
    end
end

--- Declarative rows for one group, seeded from the parsed request. The panel wraps each into a live
--- row whose `run` routes through the write-back engine using the `write` descriptor — this module
--- attaches NO callbacks and performs NO writes.
---@param group_name string
---@param req LvimRestRequest
---@param ctx LvimRestSpecCtx?
---@return LvimRestSpecRow[]
function M.rows(group_name, req, ctx)
    local group = M.schema()[group_name]
    if type(group) ~= "table" or not group.variants then
        return {}
    end
    local vname = active_variant(group, req, group_name)
    local variant = group.variants[vname] or {}
    local values = group_name == "auth" and auth_values(variant, req)
        or (group_name == "body" and body_values(vname, req))
        or {}

    ---@type LvimRestSpecRow[]
    local rows = {}

    -- The discriminator select (variant names, sorted for a stable menu).
    local names = vim.tbl_keys(group.variants)
    table.sort(names)
    rows[#rows + 1] = {
        row = {
            type = "select",
            name = group.discriminator.key,
            label = group.discriminator.label,
            value = vname,
            options = names,
        },
        field = { key = group.discriminator.key, type = "select", label = group.discriminator.label },
        write = { kind = "directive", key = group_name == "auth" and "auth" or nil, group = group_name },
    }

    -- The selected variant's fields.
    for _, field in ipairs(variant.fields or {}) do
        rows[#rows + 1] = {
            row = to_ui_row(field, values[field.key] ~= nil and values[field.key] or field.default, ctx),
            field = field,
            write = group_name == "auth" and { kind = "directive", key = "auth", group = "auth" }
                or { kind = "body", key = field.key },
        }
    end
    return rows
end

-- ── complete: the cmp-source contract ───────────────────────────────────────────────────
---@class LvimRestSpecCmpCtx
---@field buf?  integer
---@field line  string    the text on the cursor line up to the cursor
---@field req?  LvimRestRequest

---@class LvimRestSpecCompletion
---@field label  string
---@field insert? string
---@field kind   "directive"|"scheme"|"method"|"value"
---@field doc?   string

--- Completions valid at the cursor position, derived from the SAME schema (so cmp can never offer a
--- directive/scheme the validator would reject). Position kind is read off the cursor line, never a
--- second grammar. Async-shaped (`cb`) for the dynamic cases; the static ones answer synchronously.
---@param ctx LvimRestSpecCmpCtx
---@param cb fun(items: LvimRestSpecCompletion[])
---@return nil
function M.complete(ctx, cb)
    local line = ctx.line or ""
    local schema = M.schema()
    local items = {}
    local function add(label, kind, doc)
        items[#items + 1] = { label = label, insert = label, kind = kind, doc = doc }
    end

    -- `# @<partial>` → directive keys the plugin owns.
    if line:match("^%s*#+%s*@[%w%-]*$") then
        for key, d in pairs(schema.directives) do
            add(key, "directive", d.hint)
        end
        return cb(items)
    end
    -- `# @auth apikey <name> <value> <partial>` → the location enum (checked before the bare-scheme case).
    if line:match("^%s*#+%s*@auth%s+apikey%s+%S+%s+%S+%s+%S*$") then
        add("header", "value")
        add("query", "value")
        return cb(items)
    end
    -- `# @auth <partial>` → the auth schemes.
    if line:match("^%s*#+%s*@auth%s+[%w]*$") then
        local names = vim.tbl_keys(schema.auth.variants)
        table.sort(names)
        for _, name in ipairs(names) do
            add(name, "scheme", schema.auth.variants[name].label)
        end
        return cb(items)
    end
    -- An uppercase word at line start → an HTTP method / GRAPHQL / GRPC / WEBSOCKET.
    if line:match("^%u+$") then
        for _, m in ipairs(schema.methods) do
            add(m, "method")
        end
        return cb(items)
    end
    return cb({})
end

--- The current field values of a group's active variant, read from the parsed request — what the
--- panel edits and `assemble_auth` consumes.
---@param group_name string
---@param req LvimRestRequest
---@return table<string, any>
function M.values(group_name, req)
    local group = M.schema()[group_name]
    if type(group) ~= "table" or not group.variants then
        return {}
    end
    local vname = active_variant(group, req, group_name)
    local variant = group.variants[vname] or {}
    if group_name == "auth" then
        return auth_values(variant, req)
    elseif group_name == "body" then
        return body_values(vname, req)
    end
    return {}
end

--- The active variant name of a group for `req` (the panel's discriminator value).
---@param group_name string
---@param req LvimRestRequest
---@return string
function M.variant(group_name, req)
    local group = M.schema()[group_name]
    if type(group) ~= "table" or not group.variants then
        return "none"
    end
    return active_variant(group, req, group_name)
end

--- Reassemble the `# @auth` directive VALUE (`<scheme> <arg1> <arg2>…`) from a variant's positional
--- args, dropping trailing empties (so `apikey X-Key {{secret}}` omits the default `header`). This is
--- what the panel hands to `set_directive("auth", …)` after any auth-field edit.
---@param scheme string
---@param values table<string, any>
---@return string
function M.assemble_auth(scheme, values)
    local variant = M.schema().auth.variants[scheme]
    if not variant then
        return scheme
    end
    -- Field defaults, so a trailing arg left at its default is dropped (`apikey X-Key {{s}}` omits
    -- the default `header`), not just an empty one.
    local defaults = {}
    for _, f in ipairs(variant.fields or {}) do
        defaults[f.key] = f.default
    end
    local tail = {}
    for _, argkey in ipairs(variant.args or {}) do
        local v = values[argkey]
        tail[#tail + 1] = (v == nil) and "" or tostring(v)
    end
    -- Trim trailing args that are empty OR equal to their field default.
    while #tail > 0 do
        local i = #tail
        local argkey = variant.args[i]
        local def = defaults[argkey]
        if tail[i] == "" or (def ~= nil and tail[i] == tostring(def)) then
            tail[i] = nil
        else
            break
        end
    end
    local parts = { scheme }
    for _, v in ipairs(tail) do
        parts[#parts + 1] = v
    end
    return table.concat(parts, " ")
end

return M
