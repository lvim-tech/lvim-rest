-- lvim-rest.config: the LIVE configuration table.
--
-- Holds the defaults; setup() merges user overrides into it IN PLACE (via lvim-utils.utils.merge),
-- so every require("lvim-rest.config") reader sees the effective values. This is the single source
-- of truth for the plugin's behaviour — the README's default-config block is kept in sync with it.
--
-- Two faces over one runner: the loose `.http`/`.rest` document (kulala parity) and the persistent
-- sqlite request library (Postman parity). The `backend` picks the execution engine — the native
-- Rust daemon `lvim-rest-core` (all four protocols) or the pure-curl HTTP/GraphQL fallback.
--
---@module "lvim-rest.config"

---@class LvimRestDaemonConfig
---@field bin           string?   Explicit daemon binary path (nil = installer/repo-managed path)
---@field autostart     boolean   Spawn the daemon lazily on the first daemon-backed request; `false` keeps the editor process-free (HTTP/GraphQL run on curl, the daemon-only protocols report it is off)
---@field idle_timeout  integer   Milliseconds of inactivity before the idle daemon is stopped (0 = keep it running); a live WebSocket session holds it open

---@class LvimRestWorkbenchDockSize
---@field stacked number  span="stacked" (state 1): fraction of the RIGHT COLUMN the response takes (editor gets the rest) — 2/3 by default
---@field full    number  span="full" (state 2): fraction of the WHOLE TAB the full-width result takes — 1/3 by default, so tree+editor keep the top 2/3

---@class LvimRestWorkbenchDock
---@field position "right"|"bottom"   Side for the state-1 dock (bottom = under the editor; right = beside it)
---@field span     "stacked"|"full"   The layout STATE. state 1 "stacked": tree full-height, right column editor(top)/response(bottom). state 2 "full": tree+editor on top, result full-width below. `:LvimRest dock` toggles them.
---@field size     LvimRestWorkbenchDockSize  Per-state height fractions

---@class LvimRestWorkbenchConfig
---@field explorer_width integer                LEFT collection-tree width (columns)
---@field dock           LvimRestWorkbenchDock   Response dock placement in the workbench tab

---@class LvimRestDockSize
---@field height integer                         Bottom-dock height (rows)
---@field float  { width: number, height: number } Float-dock size (fractions of the editor)

---@class LvimRestDockConfig
---@field layout "float"|"area"|"bottom"  Inline dock layout when sending from a loose .http file
---@field size   LvimRestDockSize          Dock geometry per layout

---@class LvimRestEnvConfig
---@field scope    "project"|"buffer"  Active-env scope: sticky per project root, or per file
---@field default  string              Default env profile name
---@field hud_chip boolean             Show the lvim-hud env chip while a non-default env is active

---@class LvimRestChainConfig
---@field auto_run boolean  Auto-run a request's chain dependencies before it (else error on unresolved refs)

---@class LvimRestRequestConfig
---@field timeout          integer               Per-request timeout (ms)
---@field follow_redirects boolean               Follow 3xx redirects
---@field insecure         boolean               Skip TLS verification (per-request `@curl-insecure` overrides)
---@field http_version     "auto"|"1.1"|"2"|"3"  Preferred HTTP version
---@field send_all_delay   integer               Pause between requests in a buffer-wide send-all (ms)
---@field chain            LvimRestChainConfig    Request-chaining behaviour

---@class LvimRestFormatConfig
---@field indent      integer  JSON/XML pretty-print indent
---@field sort_keys   boolean  Sort JSON object keys when formatting
---@field max_size    integer  Bodies larger than this (bytes) open raw in a scratch file, not the dock
---@field jq_bin      string   jq binary (JSON formatting + `@jq` filtering)
---@field xmllint_bin string   xmllint binary (XML formatting; optional, health-gated)

---@class LvimRestRunnerConfig
---@field delay           integer  Delay between requests in a collection run (ms)
---@field stop_on_failure boolean  Stop the run on the first failed request

---@class LvimRestLibraryConfig
---@field confirm_delete boolean               Confirm before deleting a library item
---@field runner         LvimRestRunnerConfig   Collection-runner behaviour

---@class LvimRestVaultConfig
---@field enabled boolean  Resolve `{{vault "…"}}` and vault secrets on save (needs lvim-keyring)
---@field auto    boolean  Move detected secrets into lvim-keyring without asking on save

---@class LvimRestHistoryConfig
---@field enabled     boolean  Record executed requests in the sqlite history
---@field bodies      boolean  Store response bodies/headers (off by default — size + secrets)
---@field max_entries integer  Retention cap (older rows pruned)

---@class LvimRestOptionsKeys
---@field add    string  add a row (a query param / a header / a directive entry)
---@field delete string  delete the row under the cursor
---@field toggle string  comment a header line out / back in
---@field rename string  edit the row's NAME (a param name, a header name)
---@field send      string  send the request and close the panel
---@field keyring   string  store the focused Auth secret in the keyring (→ a `{{vault "…"}}` reference)
---@field edit_body string  open the request's body in a multi-line scratch editor
---@field help      string  the panel's key help

---@class LvimRestOptionsTab
---@field label string
---@field icon  string

---@class LvimRestOptionsConfig
---@field layout "float"|"area"|"bottom"  Panel layout (a per-command token overrides it)
---@field keys   LvimRestOptionsKeys
---@field tabs   { params: LvimRestOptionsTab, headers: LvimRestOptionsTab, auth: LvimRestOptionsTab, body: LvimRestOptionsTab, settings: LvimRestOptionsTab }

---@class LvimRestUiConfig
---@field options LvimRestOptionsConfig  The request-options form (`:LvimRest options`)

---@class LvimRestKeys
---@field send           string  Send the request under the cursor
---@field send_all       string  Send every request in the buffer
---@field replay         string  Replay the last request
---@field cancel         string  Cancel in-flight request(s)
---@field inspect        string  Show the fully resolved request
---@field jump_next      string  Jump to the next request
---@field jump_prev      string  Jump to the previous request
---@field explorer       string  Focus/open the collection explorer
---@field options        string  Open the request options form
---@field run_collection string  Run the current collection/folder
---@field save_into      string  Save the request into a collection

---@class LvimRestIcons
---@field get        string
---@field post       string
---@field put        string
---@field patch      string
---@field delete     string
---@field graphql    string
---@field grpc       string
---@field ws         string
---@field ok         string
---@field fail       string
---@field env        string
---@field workspace  string
---@field collection string
---@field folder     string
---@field request    string
---@field expand_open   string  Caret of an OPEN fold header (the options form's sections)
---@field expand_closed string  Caret of a CLOSED fold header
---@field ws_in      string  Inbound websocket frame marker
---@field ws_out     string  Outbound websocket frame marker
---@field pointer    string  Active/selected marker + sequence separator (canon `➤`)
---@field spinner    string[] Braille spinner frames for the inline running lane

---@class LvimRestConfig
---@field backend       "auto"|"daemon"|"curl"  Execution engine selection
---@field daemon        LvimRestDaemonConfig
---@field workbench     LvimRestWorkbenchConfig
---@field dock          LvimRestDockConfig
---@field default_view  string                  body|headers|both|verbose|stats|script|report
---@field env           LvimRestEnvConfig
---@field request       LvimRestRequestConfig
---@field format        LvimRestFormatConfig
---@field library       LvimRestLibraryConfig
---@field vault         LvimRestVaultConfig
---@field cookies       { enabled: boolean }
---@field auth          { enabled: boolean, oauth2: { redirect_port: integer, timeout: integer, leeway: integer, browser_cmd: string? } }
---@field ws            { max_messages: integer }
---@field scripts       { enabled: boolean, show_report: string }  show_report: always|on_failure|never
---@field history       LvimRestHistoryConfig
---@field scrub_secrets boolean                 Mask Authorization/Cookie/vault values everywhere they surface
---@field prompt        { cache: boolean }       Cache prompt-var values for the session (never persisted)
---@field inline_status boolean                 Show the per-request extmark status lane
---@field ui            LvimRestUiConfig         The interactive panels
---@field keys          LvimRestKeys             Buffer-local maps for http/rest filetypes (all configurable)
---@field icons         LvimRestIcons
---@field spec?         table                    Overrides merged over the shipped `.http` schema (spec/schema.lua):
---                                              adds/replaces auth variants, body types, directives — appears in the
---                                              panel, the validator AND cmp at once (see lvim-rest.spec).
---@field diagnostics   { enabled: boolean, debounce: integer }  Live structural validation of hand-written `.http`.

---@type LvimRestConfig
return {
    -- Live STRUCTURAL validation of hand-written `.http` (unknown method fields, missing required auth
    -- args, malformed JSON body, near-miss directives) via vim.diagnostic — the same spec/schema that
    -- drives the options panel. Debounced while typing; semantic checks stay with send. `enabled=false`
    -- turns the squiggles off entirely.
    diagnostics = { enabled = true, debounce = 300 },
    -- Execution engine: "auto" = the daemon when built, else curl for HTTP with a one-time notice;
    -- "daemon" = require lvim-rest-core; "curl" = the pure-curl HTTP/GraphQL fallback only.
    backend = "auto",
    daemon = {
        bin = nil, -- nil = probe the repo/installer-managed path
        autostart = true,
        idle_timeout = 300000,
    },
    -- The dedicated full-tab IDE face (`:LvimRest`): LEFT explorer (full height) / editor + response
    -- dock stacked in the RIGHT column — the editor on top, the response below it.
    workbench = {
        explorer_width = 34,
        dock = {
            position = "bottom", -- state-1 side: "bottom" (below the editor) | "right" (beside it)
            span = "stacked", -- start in state 1: "stacked" (tree full-height) — toggle to "full" with :LvimRest dock
            size = {
                stacked = 0.66, -- state 1: response = 2/3 of the right column (editor keeps 1/3 on top)
                full = 0.34, -- state 2: full-width result = 1/3 of the whole tab (tree+editor keep the top 2/3)
            },
        },
    },
    -- The inline dock shown when sending from a loose .http file (not the workbench).
    dock = {
        layout = "bottom", -- "float" | "area" | "bottom"
        size = { height = 15, float = { width = 0.85, height = 0.8 } },
    },
    default_view = "body", -- body|headers|both|verbose|stats|script|report
    env = { scope = "project", default = "dev", hud_chip = true },
    request = {
        timeout = 30000,
        follow_redirects = true,
        insecure = false,
        http_version = "auto",
        send_all_delay = 0, -- `:LvimRest all` is a sweep of one buffer, not a throttled run
        chain = { auto_run = true },
    },
    format = {
        indent = 2,
        sort_keys = false,
        max_size = 2 * 1024 * 1024,
        jq_bin = "jq",
        xmllint_bin = "xmllint",
    },
    library = {
        confirm_delete = true,
        runner = { delay = 0, stop_on_failure = false },
    },
    vault = { enabled = true, auto = false },
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
            keys = {
                add = "a",
                delete = "d",
                toggle = "t",
                rename = "r",
                send = "s",
                keyring = "v",
                edit_body = "e",
                help = "?",
            },
            tabs = {
                params = { label = "Params", icon = "󰘲" },
                headers = { label = "Headers", icon = "󰈻" },
                auth = { label = "Auth", icon = "󰌆" },
                body = { label = "Body", icon = "󰈔" },
                grpc = { label = "gRPC", icon = "󰢌" },
                settings = { label = "Settings", icon = "󰒓" },
            },
        },
    },
    scripts = { enabled = true, show_report = "on_failure" }, -- always | on_failure | never
    history = { enabled = true, bodies = false, max_entries = 500 },
    scrub_secrets = true,
    prompt = { cache = true },
    inline_status = true,
    keys = {
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
    -- Real Nerd Font single-width glyphs (verified via strdisplaywidth); `➤` for pointers/separators.
    icons = {
        get = "󰇚",
        post = "󰆐",
        put = "󰏫",
        patch = "󰆕",
        delete = "󰆴",
        graphql = "󰡷",
        grpc = "󰢹",
        ws = "󰖟",
        expand_open = "",
        expand_closed = "",
        ws_in = "󰁅", -- a frame the server sent — the two directions must not look the same
        ws_out = "󰁝", -- a frame this editor sent
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
}
