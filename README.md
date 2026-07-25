# lvim-rest

A REST / HTTP client for Neovim — send requests straight from `.http` / `.rest` documents, with a
rich variable system, environments, request chaining, response formatting, and its own native Rust
execution daemon (`lvim-rest-core`). A pure-`curl` fallback keeps HTTP and GraphQL working when the
daemon is not built.

`lvim-rest` is part of the [lvim-tech](https://github.com/lvim-tech) set and self-themes from the
shared palette; every popup, picker and dock goes through the canonical lvim-ui components.

## Features

- **`.http` / `.rest` documents** — requests separated by `###` (text after `###` is the display
  name); request line `METHOD url [HTTP/x.y]`; ordered headers; a body after one blank line; body
  from a file (`< ./payload.json`, or `<@ ./file` with variable substitution); save the response to
  a file (`>> ./out.json`, `>>!` overwrites).
- **Two execution engines** — the native Rust daemon `lvim-rest-core` (reqwest, HTTP/1.1 · HTTP/2,
  rustls) when built, else a pure-`curl` fallback for HTTP/GraphQL. Selection is automatic
  (`backend = "auto"`).
- **A rich variable system** — document (`@var = value`), request-local, environment files, dynamic
  (`{{$uuid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}`, `{{$date}}`, `{{$randomInt}}` — extensible),
  `{{$processEnv VAR}}` / `{{$dotenv VAR}}`, and vaulted secrets (`{{vault "key"}}` via lvim-keyring).
- **Request chaining** — `{{name.response.body.$.path}}`, `{{name.response.headers.X}}`,
  `{{name.request.body.$.x}}`; a request that references another auto-runs its dependencies first.
- **Environments** — `http-client.env.json` (+ `http-client.private.env.json`) discovered upward
  from the file; the active profile is sticky per project; `:LvimRest env` switches it.
- **Interactive prompts** — `# @prompt var [description]`; asked once, cached per session.
- **Metadata directives** — `# @name`, `# @timeout ms`, `# @no-log`, `# @no-cookie-jar`,
  `# @accept chunked`, `# @jq expr`, `# @curl-<flag>[=value]`, `# @prompt`, `# @stdin-cmd`.
- **A themed response dock** — body / headers / both / stats / verbose / script / report views (the
  body highlighted by treesitter for its Content-Type), a live `jq` filter, and footer actions
  (yank / save / copy-as-curl / replay). Oversized bodies divert to a scratch file.
- **Inline status** — a per-request end-of-line lane: a spinner while running, then
  `➤ 200 OK · 132 ms` in the status accent.
- **History** — every executed request is logged (sqlite); `:LvimRest history` reopens or lists past
  runs. `@no-log` skips a request.
- **The request library (sqlite)** — workspaces ▸ collections ▸ nested folders ▸ requests, with
  examples, environments and run history, stored in the same sqlite database as the history.
  Reorderable (`ord` is persisted), and each request opens as an ordinary `.http` buffer bound to its
  row: `:w` re-parses it and updates the record, so the request *builder* is just the editor.
- **The workbench** — `:LvimRest workbench` opens a tab of its own with the library tree beside the
  request editor (the response dock keeps its configured layout). `:LvimRest library` docks the same
  tree as a sidebar next to whatever you are already doing.
- **Lua scripting + tests** — `< {% … %}` before a request and `> {% … %}` after the response (or a
  `< ./setup.lua` / `> ./check.lua` file). They are **Lua**, not JavaScript: the host language is
  already Lua, so there is no JS engine to ship. A pre-script may rewrite `request.method` / `url` /
  `headers` / `body`; a post-script gets `response` (`status`, `headers`, `body`, lazily-decoded
  `json`) and the `client` API — `client.test(name, fn)`, `client.assert(cond, msg)`,
  `client.log(...)`, and `client.global.set/get` for values that carry into later requests. Results
  land in the dock's **report** and **script** views.
- **The collection runner** — run a whole collection (or one folder) in order, sequentially, through
  the same send path an interactive request uses. A data file (json array, or csv with a header row)
  turns one pass into one per row: its values enter the top-priority `data` variable scope, so
  `{{id}}` resolves per iteration. Every run is persisted (status, duration, pass/fail per request).
- **Authentication** — `# @auth basic|bearer|apikey|oauth2|none`. OAuth2 profiles live in the env
  file under `Security.Auth.<id>` (the JetBrains shape, so an existing project needs no second
  file), with the `client_credentials`, `password`, `refresh_token` and `authorization_code` grants
  — the last with PKCE and a one-shot loopback listener for the redirect. Tokens are cached,
  refreshed just before they expire, and kept in lvim-keyring rather than the database.
- **gRPC** — `GRPC host:port/package.Service/Method` with a JSON body. Message types are discovered
  at call time, either from the server's **reflection** service (v1 or v1alpha) or from a
  `# @grpc-proto ./api.proto` compiled in-process — no `protoc` on the machine, no generated code.
  `:LvimRest grpc` lists a server's methods and writes the chosen one at the cursor.
- **WebSocket** — `WEBSOCKET ws://…` opens a session; frames stream into the dock as they arrive,
  `:LvimRest ws <text>` sends one and `:LvimRest ws close` ends it.
- **A persistent cookie jar** — one jar in Lua for BOTH engines (so a request behaves the same
  whether the daemon is built), stored in sqlite and inspectable with `:LvimRest cookies`. RFC 6265
  matching (domain / path / `Secure` / expiry), a hand-written `Cookie:` header always wins, and
  `# @no-cookie-jar` opts a request out. Session cookies are dropped when Neovim starts.
- **Import / export** — `:LvimRest import` takes a **Postman v2.1** collection or environment, an
  **OpenAPI 3.x / Swagger 2.0** description, a **HAR** recording, or a pasted `curl` command;
  `:LvimRest export` writes a stored collection back out as Postman v2.1 (a round-trip keeps the
  folders, headers, bodies, auth, examples and scripts). A HAR's recorded responses come in as
  examples — a recording's whole value is that it says what came back. Copy any request out as curl
  from the dock.
- **Save into a collection** — `:LvimRest save` (or `<leader>rs`) puts the request under the cursor
  into the library, carrying the document's variables so the stored request runs on its own.
- **Secrets are always vaulted** — secret-shaped fields go to lvim-keyring, never plaintext; masked
  in `:LvimRest inspect`, notifications, verbose view and copy-as-curl.

## Requirements

- Neovim ≥ 0.10
- [lvim-utils](https://github.com/lvim-tech/lvim-utils), [lvim-ui](https://github.com/lvim-tech/lvim-ui)
- `curl` on `PATH` (the fallback engine) — or build the Rust daemon (below)
- Optional: a Rust toolchain (build the daemon), `jq` (JSON `jq` filter), `xmllint` (XML format),
  [lvim-keyring](https://github.com/lvim-tech/lvim-keyring) (secret vaulting), `sqlite.lua` (history),
  the treesitter `http` / `graphql` grammars via [lvim-ts](https://github.com/lvim-tech/lvim-ts)
  `ensure_installed` (syntax highlight).

## Installation

Install with the lvim-tech installer, or with Neovim's native `vim.pack`:

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-rest" },
})

require("lvim-rest").setup()
```

### Building the native daemon (optional)

The daemon gives native HTTP/1.1 · HTTP/2 (and, over time, gRPC / WebSocket / HTTP-3). Without it the
plugin falls back to `curl` for HTTP/GraphQL. Build it with a Rust toolchain:

```sh
sh core/build.sh
```

`:checkhealth lvim-rest` reports which engine is active.

## Usage

Open a `.http` file, put the cursor on a request, and press `<CR>` to send it — the response opens in
the dock. `:LvimRest` with no argument prints status; the subcommands are:

| Command | Action |
| --- | --- |
| `:LvimRest workbench` | toggle the full-tab workbench (library + editor) |
| `:LvimRest library` | dock the library tree as a sidebar |
| `:LvimRest run [datafile]` | run the collection, once per data-file row |
| `:LvimRest send` | send the request under the cursor |
| `:LvimRest all` | send every request in the buffer |
| `:LvimRest replay` | replay the last request |
| `:LvimRest cancel` | cancel in-flight requests |
| `:LvimRest inspect` | show the fully resolved request (secrets masked) |
| `:LvimRest options [layout]` | the request OPTIONS form (params / headers / directives) |
| `:LvimRest env [name]` | switch the active environment |
| `:LvimRest history` | the request-history picker |
| `:LvimRest cookies [clear]` | list the cookie jar (or empty it) |
| `:LvimRest auth [clear]` | show the OAuth2 profiles / forget cached tokens |
| `:LvimRest grpc [host:port]` | list a gRPC server's methods, insert one |
| `:LvimRest ws [text\|close]` | list sessions / send a frame / close |
| `:LvimRest import [fmt]` | import postman / openapi / har / curl |
| `:LvimRest export` | export a collection as Postman v2.1 |
| `:LvimRest save` | save the request under the cursor into the library |
| `:LvimRest scratch` | open a persistent scratch `.http` buffer |
| `:LvimRest next` / `prev` | jump between requests |
| `:LvimRest close` | close the response dock |

### Example document

```http
@host = https://api.example.com

### Login
# @name login
POST {{host}}/auth/login
Content-Type: application/json

{ "user": "me", "password": "{{vault \"example/password\"}}" }

### Get the current user
GET {{host}}/me
Authorization: Bearer {{login.response.body.$.token}}
Accept: application/json
```

Sending "Get the current user" auto-runs "Login" first (it references `login.response.…`), then uses
the token from its response.

## The library, the workbench and the runner

Requests do not have to live in a file. `:LvimRest workbench` opens the library in a tab of its own:

```
┌───────────────┬──────────────────────────────────────────┐
│  explorer     │  request editor (the bound `.http` buf)  │
│  (library)    │                                          │
└───────────────┴──────────────────────────────────────────┘
```

In the tree: `<CR>` opens a request in the editor, `S` sends it, `X` runs the whole collection the
cursor is inside (on a folder, just that subtree), `a` / `A` / `n` add a request / folder /
collection, `r` renames, `d` deletes, `]e` / `[e` move an item among its siblings, `w` switches
workspace, `R` refreshes — and `?` opens a window listing all of them. The panel's footer carries
the everyday actions as clickable chips.

The library panel is a singleton: `:LvimRest library` while the workbench is open focuses the
library pane there instead of opening a second copy. Fold state survives closing and reopening it.

A run walks the collection in the order the tree shows it — a folder's own requests first, then its
sub-folders — and it is sequential on purpose: requests routinely depend on the ones before them
(log in, capture a token, use it), and each one goes through the same send path as `<CR>`, so
chaining, scripts, variables and history behave identically.

To run the same requests against many inputs, pass a data file:

```vim
:LvimRest run ./users.csv
```

A csv's first line is the header; a json file is an array of objects. Each row becomes one iteration
and its keys enter the top-priority `data` scope, so a stored request with `POST /users/{{id}}`
sends one request per row.

## The request options form

`:LvimRest options` (or `<leader>ro`) opens a Postman-style form over the request under the cursor —
in a loose `.http` file and in a request opened from the library alike.

| Tab | Rows |
| --- | --- |
| Params | one row per query parameter of the request line |
| Headers | one row per header LINE, including the ones commented out |
| Settings | `@timeout` · `@no-log` · `@no-cookie-jar` · `@accept` · `@jq`, plus a fold per repeatable directive (`@prompt`, `@stdin-cmd`, `@env-stdin-cmd`, `@curl-*`) and a read-only fold of the directives lvim-rest does not know |

| Key | Action |
| --- | --- |
| `<CR>` | edit the focused row's value |
| `a` | add a parameter / header / directive entry (in the section under the cursor) |
| `d` | delete the row under the cursor |
| `t` | switch a header line off / on |
| `r` | rename a parameter / header |
| `s` | send this request and close |
| `?` | the key help |

**The document stays the single source of truth.** The form is a view over the parsed request: every
row is built from a fresh parse of the buffer and every change is written back as buffer TEXT, one
line at a time. So a line the form did not touch is byte-identical afterwards — your comments, your
blank lines and any `# @directive` this plugin does not understand are never rewritten or reordered.
A request opened from the library is edited the same way, through its bound buffer, and `:w` persists
it exactly as a hand edit does; the form never writes to the database itself.

Two consequences worth knowing:

- Switching a HEADER off comments its line out (`# X-Trace: 1`) — the text survives and `t` brings it
  back. A disabled header renders dimmed and struck through.
- A query PARAMETER has no "off": a url cannot express it, so the form does not pretend. Edit, add
  and delete are the honest operations.

## Authentication

```http
### the four instant schemes
# @auth basic {{user}} {{password}}
# @auth bearer {{token}}
# @auth apikey X-Api-Key {{key}}          # or: … {{key}} query
# @auth none                              # opt out

### oauth2 — the profile id comes from the environment file
# @auth oauth2 myapi
GET https://api.example.com/me
```

```json
{
  "dev": {
    "Security": {
      "Auth": {
        "myapi": {
          "Grant Type": "authorization_code",
          "Auth URL": "https://id.example.com/authorize",
          "Token URL": "https://id.example.com/token",
          "Client ID": "abc",
          "Client Secret": "{{vault \"example/client-secret\"}}",
          "Scope": "openid profile",
          "PKCE": true
        }
      }
    }
  }
}
```

Field names are matched loosely, so `"Token URL"`, `"token_url"` and `"tokenUrl"` are the same key.
The grants are `client_credentials`, `password`, `refresh_token` and `authorization_code` (PKCE on
by default; the redirect comes back to a loopback listener that answers one request and closes).

A token is reused until `auth.oauth2.leeway` seconds before it expires, then refreshed, and only
re-authorised if the refresh fails. Tokens go to lvim-keyring — the database holds only the expiry.
An `Authorization` header you wrote yourself always wins.

## gRPC and WebSocket

```http
### gRPC — types come from the server's reflection service…
GRPC 127.0.0.1:50051/demo.Greeter/SayHello
X-Token: {{token}}

{ "name": "ana", "times": 2 }

### …or from a .proto compiled in-process (no protoc needed)
# @grpc-proto greet.proto
# @grpc-import ./protos
GRPC 127.0.0.1:50051/demo.Greeter.Add

{ "a": 40, "b": 2 }

### WebSocket — this opens a session, it does not "reply"
WEBSOCKET ws://127.0.0.1:8080/chat
Sec-WebSocket-Protocol: chat
```

Headers are gRPC metadata; the body is the request message as JSON and the reply comes back as JSON.
Unary calls only — a streaming method has no single response, which is what the WebSocket session
model is for. Both are **daemon-only**: curl can neither speak gRPC nor hold a duplex connection.

## Scripting

```http
### login
< {%
  request.headers["X-Trace"] = "abc"
%}
POST https://api.example.com/login
Content-Type: application/json

{"user":"ana"}

> {%
  client.test("logged in", function()
      client.assert(response.status == 200, "got " .. tostring(response.status))
  end)
  client.global.set("token", response.json.token)
%}

### uses the captured token
GET https://api.example.com/me
Authorization: Bearer {{token}}
```

Scripts run in a sandbox: the standard-library subset (`string`, `table`, `math`, `pcall`, …) plus
`client`, and `request` (pre) or `response` (post). There is no `require`, `io` or `os.execute` — a
request script has no reason to reach for them, and their absence keeps the surface small.

A value set with `client.global.set` lives for the session and resolves as `{{name}}` in any later
request — below what the document says literally, above the environment file (see the table below).

Assertions become the dock's report view; `scripts.show_report` decides when it opens
(`on_failure` by default, or `always` / `never`).

## Import and export

| Format | Direction | Notes |
| --- | --- | --- |
| Postman collection v2.1 | in / out | folders, headers, bodies, auth, examples, variables |
| Postman environment | in | becomes a stored environment |
| OpenAPI 3.x / Swagger 2.0 | in | one request per operation, a folder per tag |
| HAR | in | recorded responses become examples |
| curl | in / out | paste a command; copy any request back out |

A Postman request's `event` scripts are **JavaScript** and this plugin's are **Lua**, so they are
never translated: an imported script is preserved verbatim in the request's docs, clearly labelled
and not executed. Exported Lua scripts go out as events typed `text/lua`, so a round-trip through
lvim-rest keeps them.

A collection-level auth scheme is inherited by requests that declare none — it is rendered into the
request's document form, so you can see what will be sent and override it by editing the line.

OpenAPI: the server url becomes a `{{baseUrl}}` collection variable, path parameters become
request-local variables (`/pets/{{petId}}`), required query parameters are appended empty, and a
JSON request body is generated from the schema. A YAML spec is converted with `yq` when it is
installed — a subtly wrong hand-rolled YAML parser would silently import a wrong API, so it is not
guessed at.

HAR: requests are grouped into a folder per host, and the headers a recording carries but a client
must not resend (`Host`, `Content-Length`, HTTP/2 pseudo-headers) are dropped.

## Variable resolution order

First hit wins:

| Precedence | Source | Syntax |
| --- | --- | --- |
| 1 | Data | the collection runner's iteration row (a run given a data file) |
| 2 | Prompt | `# @prompt var` → `{{var}}` |
| 3 | Request-local | `@var = value` inside a request block |
| 4 | Document | `@var = value` before the first request |
| 5 | Environment file | `http-client.env.json` active profile |
| 6 | Process env | `{{$processEnv VAR}}` |
| 7 | Dotenv | `{{$dotenv VAR}}` |
| 8 | Dynamic | `{{$uuid}}`, `{{$timestamp}}`, `{{$date}}`, `{{$randomInt}}`, … |
| 9 | Vault | `{{vault "key"}}` (lvim-keyring) |
| — | Chained | `{{name.response.body.$.path}}`, `{{name.response.headers.X}}` |

An unresolved `{{…}}` token is left verbatim so a missing variable is visible in the request and
`:LvimRest inspect`, never silently blanked.

## Default configuration

The full default `setup()` options (kept in sync with `lua/lvim-rest/config.lua`):

```lua
require("lvim-rest").setup({
    backend = "auto", -- "auto" | "daemon" | "curl"  (daemon = lvim-rest-core)
    daemon = {
        bin = nil, -- nil = repo/installer-managed path; else an explicit binary path
        autostart = true, -- false = never spawn it (HTTP/GraphQL fall back to curl)
        idle_timeout = 300000, -- stop an idle daemon after this long (0 = keep it); a live WebSocket holds it open
    },
    workbench = { -- the dedicated full-tab IDE face
        explorer_width = 34,
        dock = { position = "right", size = 0.42 }, -- "right" | "bottom"
    },
    dock = { -- the inline dock when sending from a loose .http file
        layout = "bottom", -- "float" | "area" | "bottom"
        size = { height = 15, float = { width = 0.85, height = 0.8 } },
    },
    default_view = "body", -- body|headers|both|verbose|stats|script|report
    env = { scope = "project", default = "dev", hud_chip = true }, -- scope: "project" | "buffer"
    request = {
        timeout = 30000,
        follow_redirects = true,
        insecure = false,
        http_version = "auto", -- "auto" | "1.1" | "2" | "3"
        send_all_delay = 0, -- pause between requests in `:LvimRest all` (ms)
        chain = { auto_run = true },
    },
    format = {
        indent = 2,
        sort_keys = false,
        max_size = 2 * 1024 * 1024,
        jq_bin = "jq",
        xmllint_bin = "xmllint",
    },
    library = { -- the sqlite Postman-style request library
        confirm_delete = true,
        runner = { delay = 0, stop_on_failure = false }, -- the collection runner (sequential by design)
    },
    vault = { enabled = true, auto = false }, -- auto = vault detected secrets without asking on save
    cookies = { enabled = true },
    auth = {
        enabled = true,
        oauth2 = {
            redirect_port = 8765, -- the loopback port the authorization_code redirect comes back to
            timeout = 180000, -- how long to wait for that redirect
            leeway = 60, -- refresh this many seconds before a token actually expires
            browser_cmd = nil, -- nil = vim.ui.open (the desktop's own handler)
        },
    },
    ws = {
        max_messages = 500, -- per session; a stream must not become the only thing in memory
    },
    -- The interactive panels (every label, icon, key and layout an option).
    ui = {
        options = {
            layout = "float", -- "float" | "area" | "bottom"
            keys = { add = "a", delete = "d", toggle = "t", rename = "r", send = "s", help = "?" },
            tabs = {
                params = { label = "Params", icon = "󰘲" },
                headers = { label = "Headers", icon = "󰈻" },
                settings = { label = "Settings", icon = "󰒓" },
            },
        },
    },
    scripts = { enabled = true, show_report = "on_failure" }, -- always | on_failure | never
    history = { enabled = true, bodies = false, max_entries = 500 },
    scrub_secrets = true,
    prompt = { cache = true },
    inline_status = true,
    keys = { -- buffer-local maps on http/rest buffers (all configurable)
        send = "<CR>",
        send_all = "<leader>ra",
        replay = "<leader>rr",
        cancel = "<leader>rx",
        inspect = "<leader>ri",
        jump_next = "]r",
        jump_prev = "[r",
        explorer = "<leader>rc",
        run_collection = "<leader>rR",
        save_into = "<leader>rs",
        options = "<leader>ro",
    },
    icons = { -- real Nerd Font single-width glyphs; ➤ for pointers
        get = "󰇚",
        post = "󰆐",
        put = "󰏫",
        patch = "󰆕",
        delete = "󰆴",
        graphql = "󰡷",
        grpc = "󰢹",
        ws = "󰖟",
        expand_open = "", -- the options form's fold carets
        expand_closed = "",
        ws_in = "󰁅", -- an inbound websocket frame
        ws_out = "󰁝", -- an outbound one
        ok = "󰄬",
        fail = "󰅚",
        env = "󰙅",
        workspace = "󰆧",
        collection = "󰉓",
        folder = "󰉋",
        request = "󰋼",
        pointer = "➤",
        spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    },
})
```

## Health

Run `:checkhealth lvim-rest` for the active engine (daemon / curl), the optional tools (jq, xmllint),
the sqlite history DB, lvim-keyring, the treesitter `http` grammar, and the lvim-cmp source.

## Roadmap

The following are planned and partially scaffolded (the config keys above already reserve their
options): **Lua scripting** with tests / assertions, **OAuth2** (incl. `authorization_code` / PKCE),
native **gRPC** (reflection, streaming) and **WebSocket** through the daemon, and
**Postman v2.1 / OpenAPI / HAR** import-export.

## License

BSD-3-Clause. See [LICENSE](LICENSE).
