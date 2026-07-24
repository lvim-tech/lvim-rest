-- lvim-rest.vars: the variable-resolution pipeline + `{{…}}` substitution.
--
-- Resolution order (first hit wins), per the plan's `.http` face:
--   prompt > request-local > document > env file > {{$processEnv}} / {{$dotenv}} > dynamic > vault
-- A plain `{{name}}` is looked up through the scope chain; a prefixed token (`{{$uuid}}`,
-- `{{$processEnv X}}`, `{{$dotenv X}}`, `{{vault "k"}}`, `{{name.response.…}}`) is dispatched to
-- its resolver. An UNRESOLVED token is left verbatim (never silently blanked) so a missing
-- variable is visible in `:LvimRest inspect` and the request, not a mysterious empty string.
--
-- Values may themselves contain `{{…}}`; substitution recurses with a per-name cycle guard.
--
---@module "lvim-rest.vars"

local dynamic = require("lvim-rest.vars.dynamic")
local env = require("lvim-rest.vars.env")

local M = {}

---@class LvimRestVarContext
---@field prompts       table<string, string>  interactive `# @prompt` values (phase 4)
---@field request_local table<string, string>
---@field document      table<string, string>
---@field env           table<string, string>
---@field dotenv        table<string, string>
---@field chain         table<string, table>?  name → { response, request } (phase 4)
---@field path          string                 the source .http file (for body-file includes)

--- Convert a parsed `{ name, value }` var list into a map (later entries override earlier).
---@param list LvimRestVar[]?
---@return table<string, string>
local function to_map(list)
    local m = {}
    for _, v in ipairs(list or {}) do
        m[v.name] = v.value
    end
    return m
end

--- Build the resolution context for one request in a document.
---@param doc LvimRestDocument
---@param req LvimRestRequest?
---@param opts { path?: string, prompts?: table<string,string>, chain?: table }?
---@return LvimRestVarContext
function M.build_context(doc, req, opts)
    opts = opts or {}
    local path = opts.path or vim.api.nvim_buf_get_name(0)
    return {
        prompts = opts.prompts or {},
        request_local = req and to_map(req.vars) or {},
        document = to_map(doc and doc.vars),
        env = env.active_vars(path),
        dotenv = env.dotenv(path),
        chain = opts.chain,
        path = path,
    }
end

--- Resolve a `{{vault "key"}}` reference (delegated to vars.vault). Returns nil (token kept) when
--- vaulting is disabled, keyring is absent, or the wallet is locked.
---@param key string
---@return string?
function M.resolve_vault(key)
    return require("lvim-rest.vars.vault").resolve(key)
end

--- Read a chained value out of `ctx.chain` — `name.response.body.$.a.b`, `name.response.headers.X`,
--- `name.request.body.$.x`. Only a stored run of `name` resolves; nil otherwise (phase 4 populates
--- the chain; the resolver is here so the token syntax is honoured from the start).
---@param ctx LvimRestVarContext
---@param name string
---@param kind string  "response" | "request"
---@param sel string   "body.$.path…" | "headers.Name"
---@return string?
local function resolve_chain(ctx, name, kind, sel)
    local store = ctx.chain and ctx.chain[name]
    if not store or not store[kind] then
        return nil
    end
    local part = store[kind]
    local head, rest = sel:match("^(%w+)%.?(.*)$")
    if head == "headers" then
        local hv = part.headers and part.headers[rest]
        return hv and tostring(hv) or nil
    elseif head == "body" then
        -- `$.a.b` JSONPath-lite: dotted keys / [i] indices into the decoded body.
        local jsonpath = rest:gsub("^%$%.?", "")
        local cursor = part.json
        if cursor == nil and type(part.body) == "string" then
            local ok, decoded = pcall(vim.json.decode, part.body)
            cursor = ok and decoded or nil
        end
        if cursor == nil then
            return nil
        end
        for token in jsonpath:gmatch("[^%.%[%]]+") do
            if type(cursor) ~= "table" then
                return nil
            end
            cursor = cursor[tonumber(token) or token]
        end
        if cursor == nil then
            return nil
        end
        return type(cursor) == "table" and vim.json.encode(cursor) or tostring(cursor)
    end
    return nil
end

--- Resolve one `{{expr}}` inner expression. Returns nil when it cannot be resolved (the token is
--- then kept verbatim by `substitute`).
---@param expr string
---@param ctx LvimRestVarContext
---@param seen table<string, boolean>
---@return string?
local function resolve_token(expr, ctx, seen)
    expr = vim.trim(expr)
    local pe = expr:match("^%$processEnv%s+(%S+)$")
    if pe then
        return os.getenv(pe) or ""
    end
    local de = expr:match("^%$dotenv%s+(%S+)$")
    if de then
        return ctx.dotenv[de] or ""
    end
    local vaultkey = expr:match('^vault%s+"(.-)"$') or expr:match("^vault%s+'(.-)'$") or expr:match("^vault%s+(%S+)$")
    if vaultkey then
        return M.resolve_vault(vaultkey)
    end
    if expr:sub(1, 1) == "$" then
        local name, argstr = expr:match("^(%$[%w_]+)%s*(.*)$")
        if name and dynamic.has(name) then
            local args = argstr ~= "" and vim.split(vim.trim(argstr), "%s+") or {}
            return dynamic.resolve(name, args)
        end
        return nil
    end
    local cname, ckind, csel = expr:match("^([%w_%-%.]+)%.(response)%.(.+)$")
    if not cname then
        cname, ckind, csel = expr:match("^([%w_%-%.]+)%.(request)%.(.+)$")
    end
    if cname then
        return resolve_chain(ctx, cname, ckind, csel)
    end
    for _, scope in ipairs({ "prompts", "request_local", "document", "env" }) do
        local v = ctx[scope] and ctx[scope][expr]
        if v ~= nil then
            if seen[expr] then
                return "" -- cycle: break by emptying
            end
            seen[expr] = true
            local out = M.substitute(v, ctx, seen)
            seen[expr] = nil
            return out
        end
    end
    return nil
end

--- Substitute every `{{…}}` in `str`. Unresolved tokens are left verbatim.
---@param str string
---@param ctx LvimRestVarContext
---@param seen table<string, boolean>?
---@return string
function M.substitute(str, ctx, seen)
    if type(str) ~= "string" or not str:find("{{", 1, true) then
        return str
    end
    seen = seen or {}
    return (
        str:gsub("{{(.-)}}", function(expr)
            local v = resolve_token(expr, ctx, seen)
            if v == nil then
                return nil -- keep the original {{…}} token
            end
            return v
        end)
    )
end

--- Load a body-file include (`< ./file` / `<@ ./file`), resolving `{{vars}}` when `<@`.
---@param req LvimRestRequest
---@param ctx LvimRestVarContext
---@return string?
local function load_body_file(req, ctx)
    local base = vim.fs.dirname(ctx.path or "")
    local fpath = req.body_file
    if not fpath then
        return nil
    end
    if not fpath:match("^/") and base ~= "" then
        fpath = base .. "/" .. fpath
    end
    if vim.fn.filereadable(fpath) == 0 then
        return nil
    end
    local ok, lines = pcall(vim.fn.readfile, fpath)
    if not ok then
        return nil
    end
    local content = table.concat(lines, "\n")
    if req.body_file_var then
        content = M.substitute(content, ctx)
    end
    return content
end

---@class LvimRestResolvedRequest
---@field method       string
---@field url          string
---@field http_version string?
---@field headers      LvimRestHeader[]
---@field body         string?
---@field directives   LvimRestDirectives
---@field name         string?
---@field save_to      string?
---@field save_overwrite boolean

--- Fully resolve a request against a context: variables substituted, body-file loaded, an implied
--- `Content-Type: application/json` added for a JSON body with no explicit type.
---@param req LvimRestRequest
---@param ctx LvimRestVarContext
---@return LvimRestResolvedRequest
function M.resolve_request(req, ctx)
    local headers = {}
    local has_ct = false
    for _, h in ipairs(req.headers) do
        headers[#headers + 1] = { name = h.name, value = M.substitute(h.value, ctx) }
        if h.name:lower() == "content-type" then
            has_ct = true
        end
    end

    local body
    if req.body_file then
        body = load_body_file(req, ctx)
    elseif req.body then
        body = M.substitute(req.body, ctx)
    end

    -- Imply application/json for an obvious JSON body when the user did not set a Content-Type.
    if body and not has_ct then
        local trimmed = vim.trim(body)
        if trimmed:match("^[{%[]") then
            headers[#headers + 1] = { name = "Content-Type", value = "application/json" }
        end
    end

    return {
        method = req.method,
        url = M.substitute(req.url, ctx),
        http_version = req.http_version,
        headers = headers,
        body = body,
        directives = req.directives,
        name = req.name,
        save_to = req.save_to,
        save_overwrite = req.save_overwrite,
    }
end

return M
