-- A `.http` document, parsed.
--
-- The format is line-oriented and full of traps: `###` separates requests but may also appear
-- inside a `{% … %}` script block, a `#` can be a comment or part of a URL fragment, `@var` lines
-- are document-scoped before the first request and request-scoped after it, and a blank line ends
-- the headers and starts the body — except inside a script. Each of those is a case here.

local parser = require("lvim-rest.parser")

---@param lines string[]
---@return table
local function parse(lines)
    return parser.parse(lines)
end

describe("lvim-rest.parser.parse: requests")

it("reads a bare method and URL", function()
    local doc = parse({ "GET https://example.test/api" })
    eq(1, #doc.requests)
    eq("GET", doc.requests[1].method)
    eq("https://example.test/api", doc.requests[1].url)
    eq(true, doc.has_requests)
end)

it("splits a document on ###", function()
    local doc = parse({
        "GET https://example.test/one",
        "###",
        "POST https://example.test/two",
    })
    eq(2, #doc.requests)
    eq("GET", doc.requests[1].method)
    eq("POST", doc.requests[2].method)
end)

it("takes the name from a ### title or an @name", function()
    local doc = parse({
        "### first one",
        "GET https://example.test/a",
        "###",
        "# @name second",
        "GET https://example.test/b",
    })
    eq(2, #doc.requests)
    truthy(doc.requests[1].name and doc.requests[1].name ~= "", "no name on the titled request")
    eq("second", doc.requests[2].name)
end)

--- A request's headers as a name→value map (the parser keeps them as an ORDERED list, because
--- order and the source line matter to the options form).
---@param req table
---@return table<string, string>
local function header_map(req)
    local m = {}
    for _, h in ipairs(req.headers or {}) do
        m[h.name] = h.value
    end
    return m
end

it("collects the headers until the blank line", function()
    local doc = parse({
        "POST https://example.test/api",
        "Content-Type: application/json",
        "X-Token: abc",
        "",
        '{"a":1}',
    })
    local req = doc.requests[1]
    local headers = header_map(req)
    eq("application/json", headers["Content-Type"])
    eq("abc", headers["X-Token"])
    eq(2, #req.headers, "two headers, in order")
    eq("Content-Type", req.headers[1].name, "the order is kept")
    truthy(req.body and req.body:find('"a":1', 1, true) ~= nil, "body: " .. tostring(req.body))
end)

it("reads one header line, which the options form shares", function()
    -- Exposed so the form recognises exactly the lines the parser does; two definitions of "a
    -- header line" would drift the moment either was touched.
    local name, value = parser.match_header("Content-Type:   application/json  ")
    eq("Content-Type", name)
    eq("application/json", value, "the value is trimmed")
    eq(nil, (parser.match_header("not a header")))
    eq(nil, (parser.match_header("GET https://example.test/api")), "a request line is not a header")
end)

it("keeps a body that contains a blank line", function()
    local doc = parse({
        "POST https://example.test/api",
        "Content-Type: text/plain",
        "",
        "first",
        "",
        "second",
    })
    local body = doc.requests[1].body or ""
    truthy(body:find("first", 1, true) and body:find("second", 1, true), "body: " .. body)
end)

it("takes a request with no body at all", function()
    local doc = parse({ "GET https://example.test/api", "Accept: */*" })
    eq(1, #doc.requests)
    truthy(doc.requests[1].body == nil or doc.requests[1].body == "", "body: " .. tostring(doc.requests[1].body))
end)

describe("lvim-rest.parser.parse: variables")

it("scopes an @var before the first request to the document", function()
    -- doc.vars is an ordered LIST of { name, value }, not a map: a later definition must be able
    -- to shadow an earlier one in source order.
    local doc = parse({
        "@host = https://example.test",
        "",
        "GET {{host}}/api",
    })
    local found
    for _, v in ipairs(doc.vars or {}) do
        if v.name == "host" then
            found = v.value
        end
    end
    eq("https://example.test", found, "doc.vars: " .. vim.inspect(doc.vars))
end)

it("scopes an @var after a request line to that request", function()
    local doc = parse({
        "GET https://example.test/a",
        "###",
        "@token = abc",
        "GET https://example.test/b",
    })
    local names = {}
    for _, v in ipairs(doc.requests[2].vars or {}) do
        names[v.name] = v.value
    end
    eq("abc", names.token, "request-local vars: " .. vim.inspect(doc.requests[2].vars))
end)

it("keeps a comment out of the way", function()
    local doc = parse({
        "# just a comment",
        "// another one",
        "GET https://example.test/api",
    })
    eq(1, #doc.requests)
    eq("GET", doc.requests[1].method)
end)

describe("lvim-rest.parser.parse: script blocks")

it("does not reinterpret ### inside a script block", function()
    local doc = parse({
        "GET https://example.test/api",
        "",
        "{%",
        "-- ### this is not a separator",
        "local x = 1",
        "%}",
    })
    eq(1, #doc.requests, "the ### inside the script split the document")
end)

describe("lvim-rest.parser.request_at")

it("finds the request a line belongs to", function()
    local lines = {
        "GET https://example.test/one",
        "###",
        "POST https://example.test/two",
        "Accept: */*",
    }
    local doc = parse(lines)
    eq("GET", (parser.request_at(doc, 1) or {}).method)
    eq("POST", (parser.request_at(doc, 3) or {}).method)
    eq("POST", (parser.request_at(doc, 4) or {}).method, "a header line belongs to its request")
end)

it("finds a request by name", function()
    local doc = parse({
        "# @name wanted",
        "GET https://example.test/a",
    })
    eq("GET", (parser.request_by_name(doc, "wanted") or {}).method)
    eq(nil, parser.request_by_name(doc, "no-such-name"))
end)

describe("lvim-rest.parser.parse: nothing to parse")

it("answers for an empty document", function()
    local doc = parse({})
    eq(0, #doc.requests)
    eq(false, doc.has_requests)
end)

it("answers for a document of nothing but comments", function()
    local doc = parse({ "# nothing here", "" })
    eq(false, doc.has_requests)
end)

describe("lvim-rest.vars.substitute")

local vars = require("lvim-rest.vars")

--- A resolution context with `map` as the document variables, the way build_context builds one.
---@param map table<string, string>
---@return table
local function ctx(map)
    return {
        data = {},
        prompts = {},
        request_local = {},
        document = map,
        globals = {},
        env = {},
        dotenv = {},
    }
end

it("replaces a token it can resolve", function()
    eq("https://example.test/api", vars.substitute("{{host}}/api", ctx({ host = "https://example.test" })))
end)

it("lets a request-local variable shadow the document's", function()
    local c = ctx({ host = "document" })
    c.request_local = { host = "request" }
    eq("request", vars.substitute("{{host}}", c))
end)

it("leaves an unresolved token verbatim, rather than emptying it", function()
    -- An emptied token turns `{{token}}` into a request to the wrong URL silently; left as it is,
    -- the request fails in a way the user can read.
    eq("{{nope}}/api", vars.substitute("{{nope}}/api", ctx({})))
end)

it("replaces every occurrence", function()
    eq("a-a", vars.substitute("{{x}}-{{x}}", ctx({ x = "a" })))
end)

it("leaves a string with no tokens untouched, and takes a non-string", function()
    eq("plain", vars.substitute("plain", ctx({})))
    eq(42, vars.substitute(42, ctx({})))
end)
