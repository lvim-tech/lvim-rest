-- lvim-rest.spec.grpc: gRPC service/method DISCOVERY for the options panel. The daemon's `grpc.list`
-- resolves the vocabulary from either the `.proto` files the request names (`# @grpc-proto` /
-- `# @grpc-import`, compiled in-process — no server, no TLS) or, when none is named, SERVER reflection.
-- Results are cached per (endpoint + protos); reads are sync from the cache, a miss kicks the async
-- resolve and the caller repaints when it lands — the same dynamic contract the rest of the spec uses.
--
---@module "lvim-rest.spec.grpc"

local cache = require("lvim-rest.spec.cache")

local M = {}

--- The endpoint (host[:port]) of a `GRPC host/pkg.Service/Method` request line.
---@param req LvimRestRequest
---@return string
function M.endpoint(req)
    return (req.url or ""):match("^([^/]+)") or ""
end

--- Absolute proto / import paths (resolved relative to the `.http` file's directory when given).
---@param req LvimRestRequest
---@param ctx LvimRestSpecCtx?
---@return string[] protos, string[] imports
local function proto_paths(req, ctx)
    local grpc = req.directives and req.directives.grpc or { proto = {}, import = {} }
    local base = ctx and ctx.path and ctx.path ~= "" and vim.fn.fnamemodify(ctx.path, ":h") or nil
    local function abs(list)
        local out = {}
        for _, p in ipairs(list or {}) do
            out[#out + 1] = (base and not p:match("^/")) and vim.fs.normalize(base .. "/" .. p) or p
        end
        return out
    end
    return abs(grpc.proto), abs(grpc.import)
end

--- Cache key for a request's reflection (endpoint + the protos it names).
---@param req LvimRestRequest
---@param protos string[]
---@return string
local function key_of(req, protos)
    return "grpc:" .. M.endpoint(req) .. ":" .. table.concat(protos, ",")
end

--- The cached `{ services, methods }` for `req`, or nil on a cold cache.
---@param req LvimRestRequest
---@param ctx LvimRestSpecCtx?
---@return { services: string[], methods: table<string, string[]> }?
function M.cached(req, ctx)
    local protos = proto_paths(req, ctx)
    return cache.get(key_of(req, protos), 60000)
end

--- Resolve `req`'s services/methods via the daemon, caching the answer. `cb(result)` fires once it
--- lands (or immediately on a cache hit). Never blocks; a daemon/compile error just leaves the cache
--- cold (the panel shows plain text fields until then).
---@param req LvimRestRequest
---@param ctx LvimRestSpecCtx?
---@param cb fun(result: { services: string[], methods: table<string, string[]> })
---@return nil
function M.reflect(req, ctx, cb)
    local protos, imports = proto_paths(req, ctx)
    local key = key_of(req, protos)
    local hit = cache.get(key, 60000)
    if hit then
        return cb(hit)
    end
    local ok, rpc = pcall(require, "lvim-rest.backend.rpc")
    if not ok then
        return
    end
    rpc.request("grpc.list", {
        url = M.endpoint(req),
        proto = protos,
        import_paths = imports,
        methods = true,
    }, function(res)
        if type(res) == "table" and res.services then
            cache.set(key, res)
            cb(res)
        end
    end)
end

return M
