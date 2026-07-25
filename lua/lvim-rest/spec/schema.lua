-- lvim-rest.spec.schema: the STATIC, plugin-owned `.http` vocabulary as declarative data — the single
-- source of truth read by the panel, the validator and the cmp source (via `lvim-rest.spec`). Nothing
-- here does I/O or writes a buffer; it is pure description. User overrides are merged over this in
-- `setup()` under `config.spec` (max-configurability), and DYNAMIC vocabulary (gRPC reflection, env
-- profile ids, imported OpenAPI) is layered on at read time — see `lvim-rest.spec`.
--
-- Shapes (defined on `lvim-rest.spec`): LvimRestSpecField (atomic row/value), LvimRestSpecGroup
-- (a discriminated one-of: a `discriminator` select + `variants`), LvimRestSpecVariant (`args` for
-- positional directive order + `fields`, optionally a nested `group`), LvimRestSpecDynamic (async
-- `resolve`/`key`/`ttl` for per-server/-file vocabulary).
--
---@module "lvim-rest.spec.schema"

local M = {}

-- ── Methods (static enum, from the parser's METHODS) ───────────────────────────────────
---@type string[]
M.methods = {
    "GET",
    "POST",
    "PUT",
    "PATCH",
    "DELETE",
    "HEAD",
    "OPTIONS",
    "TRACE",
    "CONNECT",
    "GRAPHQL",
    "GRPC",
    "WEBSOCKET",
}

-- ── Directive registry (the `# @x` keys the plugin OWNS) ───────────────────────────────
-- Each entry: type/format for the value, `bool` (flag, no value), `repeatable` (many lines),
-- `args` (positional value fields for a structured directive). A `# @x` whose key is NOT here is
-- TOLERATED (never an error; at most a near-miss INFO) — this table is only what the plugin owns.
---@class LvimRestSpecDirective
---@field key         string
---@field type        "string"|"int"|"bool"|"select"
---@field format?     string
---@field bool?       boolean      a bare flag (`# @no-log`), carries no value
---@field repeatable? boolean      may appear on many lines (`# @prompt`, `# @grpc-proto`)
---@field options?    string[]     enum for a select directive
---@field hint        string

---@type table<string, LvimRestSpecDirective>
M.directives = {
    name = { key = "name", type = "string", hint = "display name for the request" },
    timeout = { key = "timeout", type = "int", format = "duration_ms", hint = "per-request timeout in ms" },
    accept = { key = "accept", type = "string", hint = "override the Accept header for this request" },
    jq = { key = "jq", type = "string", format = "jq", hint = "post-process the JSON response with jq" },
    ["no-log"] = { key = "no-log", type = "bool", bool = true, hint = "do not record this request in history" },
    ["no-cookie-jar"] = {
        key = "no-cookie-jar",
        type = "bool",
        bool = true,
        hint = "do not send or store cookies for this request",
    },
    prompt = { key = "prompt", type = "string", repeatable = true, hint = "prompt for a variable before sending" },
    ["stdin-cmd"] = {
        key = "stdin-cmd",
        type = "string",
        repeatable = true,
        hint = "fill a variable from a shell command's output",
    },
    ["env-stdin-cmd"] = {
        key = "env-stdin-cmd",
        type = "string",
        repeatable = true,
        hint = "fill a variable from a command, with the request env exported",
    },
    ["grpc-proto"] = {
        key = "grpc-proto",
        type = "string",
        format = "proto_path",
        repeatable = true,
        hint = "a .proto file describing the gRPC service",
    },
    ["grpc-import"] = {
        key = "grpc-import",
        type = "string",
        format = "path",
        repeatable = true,
        hint = "a proto import root directory",
    },
    -- `# @curl-<flag>` is an open passthrough to curl; the key is dynamic, so it is matched by prefix
    -- (see `lvim-rest.spec`), not listed here.
}

-- ── Auth (EXPLICIT discriminator: the scheme token is written) ─────────────────────────
---@type LvimRestSpecGroup
M.auth = {
    discriminator = { key = "scheme", label = "Method" },
    variants = {
        none = { label = "None", fields = {} },
        basic = {
            label = "Basic",
            args = { "user", "password" },
            fields = {
                { key = "user", type = "string", label = "User", required = true },
                { key = "password", type = "string", label = "Password", required = true, secret = true },
            },
        },
        bearer = {
            label = "Bearer",
            args = { "token" },
            fields = {
                { key = "token", type = "string", label = "Token", required = true, secret = true },
            },
        },
        apikey = {
            label = "API key",
            args = { "name", "value", "location" },
            fields = {
                { key = "name", type = "string", label = "Key name", required = true, format = "header_name" },
                { key = "value", type = "string", label = "Key value", required = true, secret = true },
                {
                    key = "location",
                    type = "select",
                    label = "Send in",
                    options = { "header", "query" },
                    default = "header",
                },
            },
        },
        oauth2 = {
            label = "OAuth 2.0",
            args = { "profile" },
            fields = {
                {
                    key = "profile",
                    type = "select",
                    label = "Auth profile (env Security.Auth)",
                    required = true,
                    -- DYNAMIC options: the profile ids in the active env file (a local read).
                    dynamic = {
                        key = function(ctx)
                            return ctx.path
                        end,
                        resolve = function(ctx, cb)
                            local ok, auth = pcall(require, "lvim-rest.auth")
                            local profiles = (ok and auth.profiles and auth.profiles(ctx.path)) or {}
                            cb(vim.tbl_keys(profiles))
                        end,
                    },
                    hint = "profile id under Security.Auth in the active environment file",
                },
            },
            -- The referenced profile's own schema — validated against the ENV file's table, its
            -- diagnostics aggregated onto the `# @auth oauth2 <id>` line (the env file is a separate
            -- JSON document, not the buffer being validated). Read-only in the panel for v1.
            profile = {
                discriminator = { key = "grant_type", label = "Grant" },
                variants = {
                    client_credentials = {
                        label = "Client credentials",
                        fields = {
                            {
                                key = "token_url",
                                type = "string",
                                label = "Token URL",
                                required = true,
                                format = "url",
                            },
                            { key = "client_id", type = "string", label = "Client ID", required = true },
                            { key = "client_secret", type = "string", label = "Client secret", secret = true },
                            { key = "scope", type = "string", label = "Scopes", format = "scope_list" },
                            { key = "audience", type = "string", label = "Audience" },
                            {
                                key = "client_auth",
                                type = "select",
                                label = "Client auth",
                                options = { "body", "basic" },
                                default = "body",
                                hint = "where client_id/secret go on the token request",
                            },
                        },
                    },
                    password = {
                        label = "Password",
                        fields = {
                            {
                                key = "token_url",
                                type = "string",
                                label = "Token URL",
                                required = true,
                                format = "url",
                            },
                            { key = "client_id", type = "string", label = "Client ID", required = true },
                            { key = "client_secret", type = "string", label = "Client secret", secret = true },
                            { key = "username", type = "string", label = "Username", required = true },
                            { key = "password", type = "string", label = "Password", required = true, secret = true },
                            { key = "scope", type = "string", label = "Scopes", format = "scope_list" },
                        },
                    },
                    authorization_code = {
                        label = "Authorization code (PKCE)",
                        fields = {
                            {
                                key = "token_url",
                                type = "string",
                                label = "Token URL",
                                required = true,
                                format = "url",
                            },
                            { key = "auth_url", type = "string", label = "Auth URL", required = true, format = "url" },
                            { key = "client_id", type = "string", label = "Client ID", required = true },
                            { key = "client_secret", type = "string", label = "Client secret", secret = true },
                            {
                                key = "redirect_port",
                                type = "int",
                                label = "Redirect port",
                                format = "port",
                                hint = "loopback port for the redirect",
                            },
                            { key = "redirect_uri", type = "string", label = "Redirect URI", format = "url" },
                            { key = "pkce", type = "bool", label = "PKCE (S256)", default = true },
                            { key = "scope", type = "string", label = "Scopes", format = "scope_list" },
                            { key = "audience", type = "string", label = "Audience" },
                        },
                    },
                    refresh_token = {
                        label = "Refresh token",
                        fields = {
                            {
                                key = "token_url",
                                type = "string",
                                label = "Token URL",
                                required = true,
                                format = "url",
                            },
                            { key = "client_id", type = "string", label = "Client ID", required = true },
                            { key = "client_secret", type = "string", label = "Client secret", secret = true },
                            {
                                key = "refresh_token",
                                type = "string",
                                label = "Refresh token",
                                required = true,
                                secret = true,
                            },
                            { key = "scope", type = "string", label = "Scopes", format = "scope_list" },
                        },
                    },
                },
            },
        },
    },
}

-- ── Body (INFERRED discriminator: the type follows from the request, never a written token) ──
---@type LvimRestSpecGroup
M.body = {
    discriminator = { key = "kind", label = "Body type" },
    --- Infer the body type from the request — the `.http` surface never writes a type token.
    ---@param req LvimRestRequest
    ---@return string
    detect = function(req)
        if req.method == "GRAPHQL" then
            return "graphql"
        end
        if req.method == "GRPC" then
            return "grpc_message"
        end
        if req.body_file then
            return "file"
        end
        local ct = ""
        for _, h in ipairs(req.headers or {}) do
            if h.name:lower() == "content-type" then
                ct = h.value:lower()
                break
            end
        end
        if ct:find("json", 1, true) then
            return "json"
        end
        if ct:find("x-www-form-urlencoded", 1, true) then
            return "form"
        end
        if not req.body or req.body == "" then
            return "none"
        end
        local first = req.body:match("^%s*(.)")
        return (first == "{" or first == "[") and "json" or "raw"
    end,
    variants = {
        none = { label = "None", fields = {} },
        json = {
            label = "JSON",
            fields = {
                {
                    key = "content",
                    type = "json",
                    label = "Body (JSON)",
                    hint = "validated with vim.json.decode; {{vars}} make it opaque",
                },
            },
            -- The panel ensures this header when the user picks JSON; the parser never invents it.
            headers = { ["Content-Type"] = "application/json" },
        },
        graphql = {
            label = "GraphQL",
            fields = {
                { key = "query", type = "string", label = "Query", hint = "the GraphQL query/mutation" },
                { key = "variables", type = "json", label = "Variables (JSON)" },
            },
        },
        grpc_message = {
            label = "gRPC message",
            fields = {
                { key = "message", type = "json", label = "Message (JSON)", hint = "the request message as JSON" },
            },
        },
        form = {
            label = "Form (urlencoded)",
            fields = {
                { key = "content", type = "string", label = "Body (a=1&b=2)" },
            },
            headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        },
        file = {
            label = "From file",
            fields = {
                { key = "path", type = "string", label = "File", required = true, format = "path" },
                { key = "substitute", type = "bool", label = "Substitute {{vars}} (<@)", default = false },
            },
        },
        raw = {
            label = "Raw",
            fields = {
                { key = "content", type = "string", label = "Body" },
            },
        },
    },
}

return M
