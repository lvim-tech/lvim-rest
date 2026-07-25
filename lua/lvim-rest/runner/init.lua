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
local script = require("lvim-rest.runner.script")
local cookies = require("lvim-rest.cookies")
local fs = require("lvim-rest.fs")
local auth = require("lvim-rest.auth")
local inline = require("lvim-rest.ui.inline")

local M = {}

---@type table<integer, { handle: table, complete: fun(result: table) }> id → in-flight request
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
    -- Raw BYTES (see `lvim-rest.fs`): a redirect must save exactly what arrived, image or not.
    local ok, err = fs.write(path, body)
    if not ok then
        vim.notify(("lvim-rest: could not write %s: %s"):format(path, tostring(err)), vim.log.levels.ERROR)
    end
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
--- `prompt.cache`). Calls `cont(prompts)` with the collected map, or `cont(nil)` when the user
--- cancelled an input.
---
--- CANCELLING MUST STILL CONTINUE. Returning without calling `cont` would strand every caller that
--- sequences through it — the collection runner recurses through the send callback, so an abandoned
--- prompt would leave its in-flight flag set and refuse every later run for the rest of the session.
---@param req LvimRestRequest
---@param cont fun(prompts: table<string, string>?)
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
                    cont(nil) -- cancelled: abort the whole send, but tell the caller so
                    return
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
---@param opts { show?: boolean, on_done?: fun(result: table), silent?: boolean, vars?: table<string, string> }
execute = function(bufnr, doc, req, prompts, opts)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local base_dir = vim.fn.fnamemodify(bufname, ":h")

    -- PRE scripts run before the context is built: they may rewrite the method / url / headers /
    -- body and set globals, and all of that must be visible to variable resolution below.
    local pre = config.scripts.enabled and script.run_pre(req, base_dir) or nil
    if pre and #pre.errors > 0 and not opts.silent then
        vim.notify("lvim-rest: pre-request script: " .. table.concat(pre.errors, "; "), vim.log.levels.ERROR)
    end

    -- `opts.vars` is the collection runner's iteration row; it enters the context as the top-priority
    -- `data` scope, so a data file can drive the same stored request through many passes.
    local ctx = vars.build_context(doc, req, { path = bufname, prompts = prompts, chain = chain, data = opts.vars })
    local resolved = vars.resolve_request(req, ctx)

    id_seq = id_seq + 1
    local id = id_seq
    -- The spinner starts BEFORE auth: an oauth2 browser round-trip is exactly the moment you want to
    -- see that the request is alive rather than ignored.
    if config.inline_status then
        inline.start(bufnr, req.line, req.method)
    end
    local title = req.name or (resolved.method .. " " .. resolved.url)

    -- AUTH is async (an oauth2 profile may have to fetch a token, or open a browser), so everything
    -- from here on runs in its callback. It comes after resolution so it can see the resolved url
    -- and headers, and before the cookie jar so an `Authorization` it adds is already in place.
    -- Guarded: `send` promises `on_done` fires exactly once. An error thrown inside the auth layer
    -- would otherwise strand the caller forever — a collection run would simply stop.
    local function with_auth(ok_auth, auth_err)
        if not ok_auth then
            if config.inline_status then
                inline.clear(bufnr, req.line)
            end
            local failed = { error = "auth: " .. tostring(auth_err) }
            if not opts.silent then
                vim.notify("lvim-rest: " .. failed.error, vim.log.levels.ERROR)
            end
            if opts.on_done then
                opts.on_done(failed)
            end
            return
        end

        -- The cookie jar is applied HERE, on the resolved request, so both engines send the same thing
        -- (see `lvim-rest.cookies`). A `Cookie:` header written by hand always wins — the document is
        -- more specific than the jar — and `# @no-cookie-jar` opts the request out entirely.
        if config.cookies.enabled and not (req.directives and req.directives.no_cookie_jar) then
            local has_own = false
            for _, h in ipairs(resolved.headers or {}) do
                if h.name:lower() == "cookie" then
                    has_own = true
                    break
                end
            end
            if not has_own then
                local jar = cookies.header_for(resolved.url)
                if jar then
                    resolved.headers[#resolved.headers + 1] = { name = "Cookie", value = jar }
                end
            end
        end

        -- A WEBSOCKET request OPENS something rather than sending: it has no single response, so it
        -- goes to the session layer and the dock shows the stream instead of a body.
        if resolved.method == "WEBSOCKET" then
            require("lvim-rest.ws").open(resolved, function(result)
                if config.inline_status then
                    inline.finish(bufnr, req.line, result)
                end
                if result.error and not opts.silent then
                    vim.notify("lvim-rest: " .. result.error, vim.log.levels.ERROR)
                elseif opts.show ~= false then
                    require("lvim-rest.ui.dock").show(result, { title = title, name = req.name })
                end
                if opts.on_done then
                    opts.on_done(result)
                end
            end)
            return
        end

        -- ONE completion path, taken at most once: the engine's callback, or `M.cancel`. Killing a
        -- transport drops its pending callback by design, so without this a cancel would break the
        -- promise that `on_done` fires exactly once — and a collection run, which sequences through
        -- that callback, would hang for the rest of the session.
        local completed = false
        ---@param result table
        local function complete(result)
            if completed then
                return
            end
            completed = true
            inflight[id] = nil
            if result.cancelled then
                -- Nothing arrived and nothing will: clear the lane, skip the dock/history/scripts.
                if config.inline_status then
                    inline.clear(bufnr, req.line)
                end
                if opts.on_done then
                    opts.on_done(result)
                end
                return
            end
            if config.inline_status then
                inline.finish(bufnr, req.line, result)
            end
            -- Absorb `Set-Cookie` BEFORE the scripts run, so a post-script that fires a follow-up (or
            -- reads the jar) sees what this response established.
            if
                config.cookies.enabled
                and not result.error
                and not (req.directives and req.directives.no_cookie_jar)
            then
                cookies.absorb(resolved.url, result.headers)
            end
            -- POST scripts see the response; their assertions and log land ON the result, so the dock's
            -- `report` / `script` views and the collection runner read the same one object.
            if config.scripts.enabled and not result.error then
                local post = script.run_post(req, result, base_dir)
                local log, tests, errors = {}, {}, {}
                for _, src in ipairs({ pre, post }) do
                    for _, l in ipairs(src and src.log or {}) do
                        log[#log + 1] = l
                    end
                    for _, t in ipairs(src and src.tests or {}) do
                        tests[#tests + 1] = t
                    end
                    for _, e in ipairs(src and src.errors or {}) do
                        errors[#errors + 1] = e
                    end
                end
                result.script_output = #log > 0 and log or nil
                result.assertions = #tests > 0 and tests or nil
                result.script_errors = #errors > 0 and errors or nil
                for _, t in ipairs(tests) do
                    if not t.ok then
                        result.tests_failed = (result.tests_failed or 0) + 1
                    end
                end
                if #errors > 0 and not opts.silent then
                    vim.notify("lvim-rest: post-response script: " .. table.concat(errors, "; "), vim.log.levels.ERROR)
                end
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
        end

        local handle = backend.run(resolved, complete)
        inflight[id] = { handle = handle, complete = complete }
    end
    local ok_apply, apply_err =
        pcall(auth.apply, resolved, req.directives and req.directives.auth, bufname, ctx, with_auth)
    if not ok_apply then
        with_auth(false, tostring(apply_err))
    end
end

--- Run a request's chain dependencies (that are not yet cached) sequentially, then `cont(true)`.
--- `cont(false)` means a dependency's prompt was cancelled, so the whole send is off.
---@param bufnr integer
---@param doc LvimRestDocument
---@param req LvimRestRequest
---@param cont fun(ok: boolean)
local function run_deps(bufnr, doc, req, cont)
    if not config.request.chain.auto_run then
        cont(true)
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
            cont(true)
            return
        end
        collect_prompts(dep, function(prompts)
            if not prompts then
                cont(false)
                return
            end
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

--- Send one request under the cursor (prompts + chain deps first). `opts.on_done` fires after —
--- ALWAYS, exactly once, including on every give-up path: callers sequence through it.
---@param bufnr integer
---@param lnum integer
---@param opts { on_done?: fun(result: table), silent?: boolean, vars?: table<string, string> }?
function M.send(bufnr, lnum, opts)
    opts = opts or {}
    --- Give up before anything was sent, telling the caller. `cancelled` marks a deliberate abort
    --- (an escaped prompt) so a run stops rather than grinding through the rest of its requests.
    ---@param message string
    ---@param cancelled boolean?
    local function give_up(message, cancelled)
        if not opts.silent then
            vim.notify("lvim-rest: " .. message, cancelled and vim.log.levels.INFO or vim.log.levels.WARN)
        end
        if opts.on_done then
            opts.on_done({ error = message, cancelled = cancelled or nil })
        end
    end
    local doc = parse_buffer(bufnr)
    local req = parser.request_at(doc, lnum)
    if not req or req.method == "" then
        return give_up("no request under the cursor")
    end
    last = { bufnr = bufnr, lnum = req.line }
    collect_prompts(req, function(prompts)
        if not prompts then
            return give_up("cancelled at the prompt", true)
        end
        run_deps(bufnr, doc, req, function(ok_deps)
            if not ok_deps then
                return give_up("cancelled at the prompt", true)
            end
            execute(bufnr, doc, req, prompts, {
                show = true,
                silent = opts.silent,
                on_done = opts.on_done,
                vars = opts.vars,
            })
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
            vim.notify(("lvim-rest: sent %d request(s)"):format(i - 1), vim.log.levels.INFO)
            return
        end
        M.send(bufnr, req.line, {
            on_done = function(result)
                -- An escaped prompt is a deliberate abort of the whole sweep, not of one request.
                if result and result.cancelled then
                    vim.notify(("lvim-rest: stopped after %d request(s)"):format(i - 1), vim.log.levels.INFO)
                    return
                end
                -- Its OWN pause: `library.runner.delay` documents itself as the collection-run
                -- throttle, and a buffer sweep is not a collection run.
                if config.request.send_all_delay > 0 then
                    vim.defer_fn(step, config.request.send_all_delay)
                else
                    vim.schedule(step)
                end
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

--- Cancel every in-flight request. Each one is COMPLETED as cancelled (see `execute`), so its
--- `on_done` still fires and whatever was sequencing through it moves on instead of hanging.
function M.cancel()
    local n = 0
    for id, entry in pairs(inflight) do
        inflight[id] = nil
        pcall(function()
            entry.handle.kill()
        end)
        entry.complete({ error = "cancelled", cancelled = true })
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
