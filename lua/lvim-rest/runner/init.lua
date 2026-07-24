-- lvim-rest.runner: the send / send-all / replay / cancel lifecycle + prompts + chaining.
--
-- A send parses the buffer, gathers any `# @prompt` values (asked once, cached per session), runs
-- the request's chain DEPENDENCIES first when it references `{{name.response.…}}` (config
-- `chain.auto_run`), resolves its variables, starts the inline spinner, runs it on the selected
-- engine, and on completion stops the spinner, shows the response, records history, stores the run
-- in the in-memory chain cache (for later `{{name.response.…}}` refs), and honours a `>>` redirect.
-- Every in-flight request is tracked by id so `cancel` can kill it.
--
---@module "lvim-rest.runner"

local config = require("lvim-rest.config")
local parser = require("lvim-rest.parser")
local vars = require("lvim-rest.vars")
local backend = require("lvim-rest.backend")
local inline = require("lvim-rest.ui.inline")

local M = {}

---@type table<integer, { handle: table, bufnr: integer, line: integer }> id → in-flight request
local inflight = {}
---@type integer monotonically increasing request id
local id_seq = 0
---@type { bufnr: integer, lnum: integer }? the last send, for replay
local last
---@type table<string, table> name → { response = { body, headers, json }, request = {...} } chain cache
local chain = {}
---@type table<string, string> session-scoped prompt cache (never persisted)
local prompt_cache = {}

--- Parse a buffer into a document.
---@param bufnr integer
---@return LvimRestDocument
local function parse_buffer(bufnr)
    return parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
end

--- Write a response body to a `>>` redirect target, relative to the buffer's directory.
---@param resolved LvimRestResolvedRequest
---@param body string
---@param bufname string
local function save_response(resolved, body, bufname)
    local path = resolved.save_to
    if not path then
        return
    end
    if not path:match("^/") then
        local dir = vim.fs.dirname(bufname)
        if dir and dir ~= "" then
            path = dir .. "/" .. path
        end
    end
    if not resolved.save_overwrite and vim.fn.filereadable(path) == 1 then
        vim.notify("lvim-rest: " .. path .. " exists (use >>! to overwrite)", vim.log.levels.WARN)
        return
    end
    pcall(vim.fn.writefile, vim.split(body, "\n", { plain = true }), path)
end

--- Store a completed run in the chain cache under the request's name.
---@param req LvimRestRequest
---@param result table
local function store_chain(req, result)
    local name = req.name or (req.directives and req.directives.name)
    if not name or result.error then
        return
    end
    local headers = {}
    for _, h in ipairs(result.headers or {}) do
        headers[h.name] = h.value
    end
    local json
    local ok, decoded = pcall(vim.json.decode, result.body or "")
    if ok then
        json = decoded
    end
    chain[name] = {
        response = { body = result.body, headers = headers, json = json },
        request = {
            body = result.request and result.request.body,
            headers = result.request and result.request.headers,
        },
    }
end

--- The chain dependency names referenced in a request's raw text (`{{name.response.…}}`).
---@param req LvimRestRequest
---@return string[]
local function chain_deps(req)
    local seen, deps = {}, {}
    local function scan(s)
        if type(s) ~= "string" then
            return
        end
        for name in s:gmatch("{{%s*([%w_%-%.]+)%.[rR]e") do
            if not seen[name] then
                seen[name] = true
                deps[#deps + 1] = name
            end
        end
    end
    scan(req.url)
    for _, h in ipairs(req.headers or {}) do
        scan(h.value)
    end
    scan(req.body)
    for _, v in ipairs(req.vars or {}) do
        scan(v.value)
    end
    return deps
end

-- Forward declaration for recursion (run_deps calls execute).
local execute

--- Gather `# @prompt` values for a request, asking sequentially (cached per session when
--- `prompt.cache`). Calls `cont(prompts)` with the collected map.
---@param req LvimRestRequest
---@param cont fun(prompts: table<string, string>)
local function collect_prompts(req, cont)
    local prompts = req.directives and req.directives.prompt or {}
    local values = {}
    local i = 0
    local function step()
        i = i + 1
        local p = prompts[i]
        if not p then
            cont(values)
            return
        end
        if config.prompt.cache and prompt_cache[p.var] ~= nil then
            values[p.var] = prompt_cache[p.var]
            step()
            return
        end
        require("lvim-ui").input({
            title = p.desc and (p.desc .. " (" .. p.var .. ")") or ("Prompt: " .. p.var),
            callback = function(ok, value)
                if not ok then
                    return -- cancelled: abort the whole send
                end
                values[p.var] = value or ""
                if config.prompt.cache then
                    prompt_cache[p.var] = value or ""
                end
                step()
            end,
        })
    end
    step()
end

--- Execute one request (resolve → run → inline → dock/history/chain). `opts.show ~= false` displays
--- the dock; deps run with show=false. `opts.on_done(result)` fires after handling.
---@param bufnr integer
---@param doc LvimRestDocument
---@param req LvimRestRequest
---@param prompts table<string, string>
---@param opts { show?: boolean, on_done?: fun(result: table), silent?: boolean }
execute = function(bufnr, doc, req, prompts, opts)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local ctx = vars.build_context(doc, req, { path = bufname, prompts = prompts, chain = chain })
    local resolved = vars.resolve_request(req, ctx)

    id_seq = id_seq + 1
    local id = id_seq
    if config.inline_status then
        inline.start(bufnr, req.line, req.method)
    end
    local title = req.name or (resolved.method .. " " .. resolved.url)

    local handle = backend.run(resolved, function(result)
        inflight[id] = nil
        if config.inline_status then
            inline.finish(bufnr, req.line, result)
        end
        if result.error then
            if not opts.silent then
                vim.notify("lvim-rest: " .. result.error, vim.log.levels.ERROR)
            end
        else
            store_chain(req, result)
            if resolved.save_to then
                save_response(resolved, result.body or "", bufname)
            end
            if config.history.enabled and not (req.directives and req.directives.no_log) then
                local ok, history = pcall(require, "lvim-rest.history")
                if ok and history.record then
                    history.record(result, {
                        name = req.name,
                        file = bufname,
                        env = require("lvim-rest.vars.env").active_name(bufname),
                    })
                end
            end
            if opts.show ~= false then
                require("lvim-rest.ui.dock").show(result, { title = title, name = req.name })
            end
        end
        if opts.on_done then
            opts.on_done(result)
        end
    end)
    inflight[id] = { handle = handle, bufnr = bufnr, line = req.line }
end

--- Run a request's chain dependencies (that are not yet cached) sequentially, then `cont()`.
---@param bufnr integer
---@param doc LvimRestDocument
---@param req LvimRestRequest
---@param cont fun()
local function run_deps(bufnr, doc, req, cont)
    if not config.request.chain.auto_run then
        cont()
        return
    end
    local pending = {}
    for _, name in ipairs(chain_deps(req)) do
        if not chain[name] then
            local dep = parser.request_by_name(doc, name)
            if dep and dep ~= req then
                pending[#pending + 1] = dep
            end
        end
    end
    local i = 0
    local function step()
        i = i + 1
        local dep = pending[i]
        if not dep then
            cont()
            return
        end
        collect_prompts(dep, function(prompts)
            execute(bufnr, doc, dep, prompts, {
                show = false,
                silent = true,
                on_done = function()
                    step()
                end,
            })
        end)
    end
    step()
end

--- Send one request under the cursor (prompts + chain deps first). `opts.on_done` fires after.
---@param bufnr integer
---@param lnum integer
---@param opts { on_done?: fun(result: table), silent?: boolean }?
function M.send(bufnr, lnum, opts)
    opts = opts or {}
    local doc = parse_buffer(bufnr)
    local req = parser.request_at(doc, lnum)
    if not req or req.method == "" then
        vim.notify("lvim-rest: no request under the cursor", vim.log.levels.WARN)
        return
    end
    last = { bufnr = bufnr, lnum = req.line }
    collect_prompts(req, function(prompts)
        run_deps(bufnr, doc, req, function()
            execute(bufnr, doc, req, prompts, { show = true, silent = opts.silent, on_done = opts.on_done })
        end)
    end)
end

--- Send every request in the buffer, in document order, sequentially.
---@param bufnr integer
function M.send_all(bufnr)
    local doc = parse_buffer(bufnr)
    if #doc.requests == 0 then
        vim.notify("lvim-rest: no requests in this buffer", vim.log.levels.WARN)
        return
    end
    local i = 0
    local function step()
        i = i + 1
        local req = doc.requests[i]
        if not req then
            vim.notify(("lvim-rest: sent %d request(s)"):format(#doc.requests), vim.log.levels.INFO)
            return
        end
        M.send(bufnr, req.line, {
            on_done = function()
                vim.defer_fn(step, config.library.runner.delay)
            end,
        })
    end
    step()
end

--- Replay the last sent request.
function M.replay()
    if not last or not vim.api.nvim_buf_is_valid(last.bufnr) then
        vim.notify("lvim-rest: nothing to replay", vim.log.levels.WARN)
        return
    end
    M.send(last.bufnr, last.lnum)
end

--- Cancel every in-flight request.
function M.cancel()
    local n = 0
    for id, entry in pairs(inflight) do
        pcall(function()
            entry.handle.kill()
        end)
        if config.inline_status and vim.api.nvim_buf_is_valid(entry.bufnr) then
            inline.clear(entry.bufnr, entry.line)
        end
        inflight[id] = nil
        n = n + 1
    end
    if n > 0 then
        vim.notify(("lvim-rest: cancelled %d request(s)"):format(n), vim.log.levels.INFO)
    end
end

--- Whether any request is currently in flight (for the hud chip / health).
---@return integer
function M.inflight_count()
    return vim.tbl_count(inflight)
end

--- Clear the session chain + prompt caches.
function M.clear_caches()
    chain = {}
    prompt_cache = {}
end

return M
