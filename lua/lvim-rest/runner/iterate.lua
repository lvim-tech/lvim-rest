-- lvim-rest.runner.iterate: the COLLECTION RUNNER — execute a whole collection (or one folder) in
-- order, optionally once per row of a data file, and persist the run.
--
-- Sequential ON PURPOSE. Requests in a collection routinely depend on the ones before them (log in,
-- capture a token, use it), so firing them concurrently would break the common case for a speed-up
-- nobody asked for. Each request completes before the next starts; the chain cache the ordinary
-- `send` maintains therefore works exactly as it does when you run them by hand.
--
-- Every request goes through the SAME `runner.send` an interactive send uses — via its bound `.http`
-- buffer — so scripts, variables, auth, cookies and history behave identically in a run and in a
-- single send. A collection runner that re-implemented execution would drift from it immediately.
--
-- A data file (json array, or csv with a header row) turns one pass into N: each row lands in the
-- top-priority `data` variable scope, so `{{id}}` in a stored request resolves to that row's value.
--
---@module "lvim-rest.runner.iterate"

local config = require("lvim-rest.config")
local library = require("lvim-rest.store.library")
local bind = require("lvim-rest.store.bind")
local runner = require("lvim-rest.runner")

local M = {}

---@type table? the run in flight (only one at a time — see `cancel`)
local active

--- Notify through the plugin's prefix.
---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-rest: " .. msg, level or vim.log.levels.INFO)
end

-- ── data files ───────────────────────────────────────────────────────────────

--- Split one CSV line, honouring double quotes (`a,"b,c",d` → 3 fields).
---@param line string
---@return string[]
local function csv_split(line)
    local out, field, quoted = {}, {}, false
    local i = 1
    while i <= #line do
        local ch = line:sub(i, i)
        if quoted then
            if ch == '"' then
                if line:sub(i + 1, i + 1) == '"' then -- an escaped quote inside a quoted field
                    field[#field + 1] = '"'
                    i = i + 1
                else
                    quoted = false
                end
            else
                field[#field + 1] = ch
            end
        elseif ch == '"' then
            quoted = true
        elseif ch == "," then
            out[#out + 1] = table.concat(field)
            field = {}
        else
            field[#field + 1] = ch
        end
        i = i + 1
    end
    out[#out + 1] = table.concat(field)
    return out
end

--- Load a data file into iteration rows: a json ARRAY of objects, or a csv whose FIRST line is the
--- header. Returns `{}` (and says why) when the file cannot be used — a run with no rows is just a
--- single pass, never a crash.
---@param path string
---@return table[] rows
function M.load_data(path)
    if not path or path == "" or vim.fn.filereadable(path) == 0 then
        notify(("data file not found: %s"):format(tostring(path)), vim.log.levels.ERROR)
        return {}
    end
    local text = table.concat(vim.fn.readfile(path), "\n")
    if path:lower():match("%.json$") then
        local ok, decoded = pcall(vim.json.decode, text)
        if not ok or type(decoded) ~= "table" then
            notify("data file is not valid json", vim.log.levels.ERROR)
            return {}
        end
        -- An object (not an array) is a single iteration.
        if decoded[1] == nil and next(decoded) ~= nil then
            return { decoded }
        end
        return decoded
    end
    -- csv
    local lines = vim.split(text, "\n", { plain = true })
    local header
    local rows = {}
    for _, line in ipairs(lines) do
        if vim.trim(line) ~= "" then
            local cells = csv_split(line)
            if not header then
                header = cells
            else
                local row = {}
                for i, name in ipairs(header) do
                    row[vim.trim(name)] = cells[i]
                end
                rows[#rows + 1] = row
            end
        end
    end
    return rows
end

-- ── traversal ────────────────────────────────────────────────────────────────

--- Flatten a collection (or one folder) into the execution order: a folder's own requests first,
--- then its sub-folders, each in `ord` — the order the explorer shows, so a run matches what you see.
---@param collection_id integer
---@param folder_id integer?
---@return table[] requests
function M.plan(collection_id, folder_id)
    local out = {}
    local function walk(fid)
        for _, r in ipairs(library.requests(collection_id, fid)) do
            out[#out + 1] = r
        end
        for _, f in ipairs(library.folders(collection_id, fid)) do
            walk(f.id)
        end
    end
    walk(folder_id)
    return out
end

-- ── the run ──────────────────────────────────────────────────────────────────

--- Whether a collection run is in flight.
---@return boolean
function M.is_running()
    return active ~= nil
end

--- Ask the in-flight run to stop after the current request.
---@return nil
function M.cancel()
    if active then
        active.cancelled = true
        notify("run cancelled — finishing the current request")
    end
end

--- Run a collection (or folder), optionally once per data row.
---@param opts { collection_id: integer, folder_id?: integer, data?: table[], data_file?: string, env_id?: integer, stop_on_failure?: boolean, delay?: integer, on_progress?: fun(info: table), on_result?: fun(info: table, result: table?), on_done?: fun(summary: table) }
---@return boolean started
function M.run(opts)
    opts = opts or {}
    if active then
        notify("a run is already in flight", vim.log.levels.WARN)
        return false
    end
    if not opts.collection_id then
        notify("no collection to run", vim.log.levels.ERROR)
        return false
    end
    local requests = M.plan(opts.collection_id, opts.folder_id)
    if #requests == 0 then
        notify("nothing to run — the collection has no requests", vim.log.levels.WARN)
        return false
    end
    local rows = opts.data or (opts.data_file and M.load_data(opts.data_file)) or {}
    local iterations = math.max(1, #rows)

    -- `library.runner` holds the defaults; an explicit `opts` field wins for this one run.
    local cfg = (config.library or {}).runner or {}
    local stop_on_failure = opts.stop_on_failure
    if stop_on_failure == nil then
        stop_on_failure = cfg.stop_on_failure
    end
    local delay = opts.delay or cfg.delay or 0

    local run_id = library.start_run({
        collection_id = opts.collection_id,
        folder_id = opts.folder_id,
        env_id = opts.env_id,
        iterations = iterations,
    })

    active = {
        run_id = run_id,
        cancelled = false,
        passed = 0,
        failed = 0,
        total = iterations * #requests,
        done = 0,
    }

    --- Finish: stamp the run, report, release.
    local function finish()
        local summary = {
            run_id = run_id,
            passed = active.passed,
            failed = active.failed,
            total = active.total,
            cancelled = active.cancelled,
        }
        if run_id then
            library.finish_run(run_id, { passed = summary.passed, failed = summary.failed })
        end
        active = nil
        notify(
            ("run finished — %d/%d ok, %d failed%s"):format(
                summary.passed,
                summary.total,
                summary.failed,
                summary.cancelled and " (cancelled)" or ""
            ),
            summary.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO
        )
        if opts.on_done then
            opts.on_done(summary)
        end
    end

    -- One step per (iteration, request). Recursion via the send callback keeps it strictly
    -- sequential without a busy wait.
    local function step(iter, idx)
        if not active or active.cancelled then
            return finish()
        end
        if idx > #requests then
            iter, idx = iter + 1, 1
            if iter > iterations then
                return finish()
            end
        end
        local req = requests[idx]
        local buf = bind.open(req.id)
        if not buf then
            active.failed = active.failed + 1
            active.done = active.done + 1
            return step(iter, idx + 1)
        end
        if opts.on_progress then
            opts.on_progress({
                iteration = iter,
                index = idx,
                total = active.total,
                done = active.done,
                request = req,
            })
        end
        runner.send(buf, 1, {
            silent = true, -- a run must not flash the dock once per request
            vars = rows[iter], -- nil for a non-data run
            on_done = function(result)
                local status = result and result.status
                -- A request "passes" only if the transport succeeded AND every assertion its script
                -- made held: a 200 whose test failed is a failed step, not a green one.
                local ok = type(status) == "number" and status >= 200 and status < 400
                if ok and (result.tests_failed or 0) > 0 then
                    ok = false
                end
                if ok then
                    active.passed = active.passed + 1
                else
                    active.failed = active.failed + 1
                end
                active.done = active.done + 1
                local asserts = (result and result.assertions) or {}
                local tests_failed = result and result.tests_failed or 0
                local tests_passed = #asserts - tests_failed
                if #asserts == 0 then
                    tests_passed, tests_failed = ok and 1 or 0, ok and 0 or 1
                end
                local assert_msg
                for _, t in ipairs(asserts) do
                    if not t.ok then
                        assert_msg = ("test %q: %s"):format(t.name, t.message or "failed")
                        break
                    end
                end
                if run_id then
                    library.add_run_result(run_id, {
                        request_id = req.id,
                        iteration = iter,
                        status = status,
                        ms = result and result.timing and result.timing.total,
                        -- Count the ASSERTIONS when a script made any, so a run's totals are test
                        -- counts (like Newman's) rather than a per-request 1/0 that hides which of
                        -- five tests failed.
                        passed = tests_passed,
                        failed = tests_failed,
                        error = (not ok) and (result and (result.error or assert_msg)) or nil,
                    })
                end
                -- Per-request RESULT hook (the batch run sheet uses it to paint each block's inline status
                -- and to feed the response into the dock's log). Runs for EVERY request, pass or fail.
                if opts.on_result then
                    opts.on_result({ iteration = iter, index = idx, request = req, ok = ok }, result)
                end
                if not ok and stop_on_failure then
                    active.cancelled = true
                end
                -- A deliberate abort (an escaped `# @prompt`, `:LvimRest cancel`) ends the RUN, not
                -- just this request: the user said stop, and the next request would only ask again.
                if result and result.cancelled then
                    active.cancelled = true
                end
                -- `delay` throttles a run against a rate-limited API; 0 goes straight on.
                if delay > 0 then
                    vim.defer_fn(function()
                        step(iter, idx + 1)
                    end, delay)
                else
                    vim.schedule(function()
                        step(iter, idx + 1)
                    end)
                end
            end,
        })
    end

    notify(("running %d request(s) × %d iteration(s)"):format(#requests, iterations))
    -- Unlock the wallet ONCE up front when any request in the run references a `{{ vault … }}` secret. A run
    -- resolves each request with `get_sync` (never prompts), and the per-request send gate only fires for the
    -- request that OWNS the reference — so a request that relies on it via a chain (e.g. `authorization:
    -- {{signin.…}}`) would fire before the user typed the password and fail on missing auth. Unlocking here,
    -- before the first step, means the whole run has the secret. Best-effort: no keyring ⇒ just start.
    local function needs_vault()
        if not (config.vault or {}).enabled then
            return false
        end
        for _, r in ipairs(requests) do
            for _, s in ipairs({ r.url, r.body }) do
                if type(s) == "string" and s:match("{{%s*vault") then
                    return true
                end
            end
            for _, h in ipairs(r.headers or {}) do
                if type(h) == "table" and type(h.value) == "string" and h.value:match("{{%s*vault") then
                    return true
                end
            end
        end
        return false
    end
    if needs_vault() then
        local ok_kr, kr = pcall(require, "lvim-keyring")
        if ok_kr and type(kr.ensure_unlocked) == "function" then
            kr.ensure_unlocked(function()
                step(1, 1)
            end)
            return true
        end
    end
    step(1, 1)
    return true
end

return M
