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
- **Import** — paste a `curl` command and it becomes an `.http` request at the cursor
  (`:LvimRest import`); copy any request back out as curl from the dock.
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
| `:LvimRest send` | send the request under the cursor |
| `:LvimRest all` | send every request in the buffer |
| `:LvimRest replay` | replay the last request |
| `:LvimRest cancel` | cancel in-flight requests |
| `:LvimRest inspect` | show the fully resolved request (secrets masked) |
| `:LvimRest env [name]` | switch the active environment |
| `:LvimRest history` | the request-history picker |
| `:LvimRest import [curl]` | import a pasted curl command |
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

## Variable resolution order

First hit wins:

| Precedence | Source | Syntax |
| --- | --- | --- |
| 1 | Prompt | `# @prompt var` → `{{var}}` |
| 2 | Request-local | `@var = value` inside a request block |
| 3 | Document | `@var = value` before the first request |
| 4 | Environment file | `http-client.env.json` active profile |
| 5 | Process env | `{{$processEnv VAR}}` |
| 6 | Dotenv | `{{$dotenv VAR}}` |
| 7 | Dynamic | `{{$uuid}}`, `{{$timestamp}}`, `{{$date}}`, `{{$randomInt}}`, … |
| 8 | Vault | `{{vault "key"}}` (lvim-keyring) |
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
        autostart = true,
        idle_timeout = 300000,
    },
    workbench = { -- the dedicated full-tab IDE face (roadmap)
        explorer_width = 34,
        dock = { position = "right", size = 0.42 }, -- "right" | "bottom"
    },
    dock = { -- the inline dock when sending from a loose .http file
        layout = "bottom", -- "float" | "area" | "bottom"
        size = { height = 15, float = { width = 0.85, height = 0.8 } },
    },
    default_view = "body", -- body|headers|both|verbose|stats|script|report
    env = { scope = "project", default = "dev", hud_chip = true },
    request = {
        timeout = 30000,
        follow_redirects = true,
        insecure = false,
        http_version = "auto", -- "auto" | "1.1" | "2" | "3"
        chain = { auto_run = true },
    },
    format = {
        indent = 2,
        sort_keys = false,
        max_size = 2 * 1024 * 1024,
        jq_bin = "jq",
        xmllint_bin = "xmllint",
    },
    library = { -- the sqlite Postman-style request library (roadmap)
        confirm_delete = true,
        runner = { delay = 0, stop_on_failure = false, parallel = 1 },
    },
    vault = { enabled = true, auto = false }, -- auto = vault detected secrets without asking on save
    cookies = { enabled = true },
    scripts = { enabled = true },
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
        running = "󰦖",
        ok = "󰄬",
        fail = "󰅚",
        env = "󰙅",
        sent = "󰁝",
        recv = "󰁅",
        workspace = "󰆧",
        collection = "󰉓",
        folder = "󰉋",
        request = "󰋼",
        jq = "󰈲",
        history = "󰋚",
        stats = "󰓅",
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
options): the dedicated full-tab **workbench** + sqlite **request library** (workspaces / collections
/ folders / requests / examples / environments / runs) with a docked explorer and request↔buffer
binding, the **collection runner** with data-file iterations, **Lua scripting** with tests /
assertions, **OAuth2** (incl. `authorization_code` / PKCE), native **gRPC** (reflection, streaming)
and **WebSocket** through the daemon, and **Postman v2.1 / OpenAPI / HAR** import-export.

## License

BSD-3-Clause. See [LICENSE](LICENSE).
