-- lvim-rest.spec.formats: the named structural format checkers the SPEC schema refers to by NAME.
-- A `LvimRestSpecField.format = "url"` resolves here, so panel hints, validator messages and cmp docs
-- all name the SAME check — never an inline pattern in a descriptor. Each checker is a pure
-- `fun(value: string): string?` returning an error message (structural only) or nil when acceptable.
--
-- These are STRUCTURAL, not semantic (spec invariant §7.1): they catch shape typos, never "will the
-- server accept this". They are deliberately LENIENT — a false positive on a valid document is worse
-- than a missed exotic case, and the template-opacity rule (a value containing `{{` is skipped before
-- a checker ever runs) means a checker only ever sees a literal value.
--
---@module "lvim-rest.spec.formats"

local M = {}

---@alias LvimRestFormatChecker fun(value: string): string?

--- A URL as written on a request line. Structural: a real URL carries no raw whitespace, and is
--- either scheme-qualified, root-relative, or an authority (host[:port][/…], as gRPC targets are).
---@type LvimRestFormatChecker
function M.url(value)
    if value:find("%s") then
        return "a URL cannot contain spaces"
    end
    if value:match("^%a[%w+.%-]*://") or value:sub(1, 1) == "/" or value:match("^[%w.%-]+[:/]") then
        return nil
    end
    return "does not look like a URL (expected scheme://…, /path, or host[:port]/…)"
end

--- An HTTP header field name — an RFC 7230 token.
---@type LvimRestFormatChecker
function M.header_name(value)
    if value:match("^[%w!#$%%&'*+%-.^_`|~]+$") then
        return nil
    end
    return "invalid header name (only token characters are allowed)"
end

--- A filesystem path. Structural only — existence is a SEPARATE, opt-in WARN (not this checker),
--- so a path to a not-yet-created fixture is not flagged as malformed.
---@type LvimRestFormatChecker
function M.path(value)
    if value == "" then
        return "a path is required"
    end
    if value:find("%z") then
        return "a path cannot contain a NUL byte"
    end
    return nil
end

--- A `.proto` file path (for `# @grpc-proto`). A proto import is a path that ends in `.proto`.
---@type LvimRestFormatChecker
function M.proto_path(value)
    local perr = M.path(value)
    if perr then
        return perr
    end
    if not value:lower():match("%.proto$") then
        return "expected a .proto file path"
    end
    return nil
end

--- A duration in milliseconds — a non-negative integer.
---@type LvimRestFormatChecker
function M.duration_ms(value)
    local n = tonumber(value)
    if not n or n ~= math.floor(n) or n < 0 then
        return "expected a non-negative whole number of milliseconds"
    end
    return nil
end

--- A TCP port — an integer in 1..65535.
---@type LvimRestFormatChecker
function M.port(value)
    local n = tonumber(value)
    if not n or n ~= math.floor(n) or n < 1 or n > 65535 then
        return "expected a port number in 1..65535"
    end
    return nil
end

--- A jq program. Its grammar is not cheaply verifiable, so this is a presence check only — a real
--- syntax verdict comes from jq at run time (structural-only rule).
---@type LvimRestFormatChecker
function M.jq(value)
    if vim.trim(value) == "" then
        return "an empty jq filter does nothing"
    end
    return nil
end

--- An OAuth2 scope list — whitespace-separated tokens. Effectively always valid; kept as a NAME so
--- the panel/cmp can document the space-separated shape.
---@type LvimRestFormatChecker
function M.scope_list(_)
    return nil
end

--- A gRPC method reference on a request line: `pkg.Service/Method`. Structural shape only; whether
--- the method EXISTS is a dynamic (reflection) check that lives in the validator's cache path, not
--- here — a cold cache never makes this fail.
---@type LvimRestFormatChecker
function M.grpc_method(value)
    if value:match("^[%w.%-]+/[%w_]+$") then
        return nil
    end
    return "expected pkg.Service/Method"
end

--- Look a checker up by name. An unknown format name is a SCHEMA bug (a descriptor named a format
--- that does not exist) — surface it once at setup, never crash a validate pass; here it resolves to
--- a no-op so a typo in the schema cannot block a document.
---@param name string?
---@return LvimRestFormatChecker?
function M.get(name)
    if not name then
        return nil
    end
    return M[name]
end

return M
