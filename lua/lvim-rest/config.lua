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
---@field autostart     boolean   Spawn the daemon lazily on the first daemon-backed request
---@field idle_timeout  integer   Milliseconds of inactivity before the idle daemon is stopped

---@class LvimRestWorkbenchDock
---@field position "right"|"bottom"  The response dock side inside the workbench tab
---@field size     number            Fraction of the workbench reserved for the dock

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
---@field scope    "project"|"buffer"  Active-env scope: sticky per project, or per file
---@field default  string              Default env profile name
---@field hud_chip boolean             Show the lvim-hud env chip while a non-default env is active

---@class LvimRestChainConfig
---@field auto_run boolean  Auto-run a request's chain dependencies before it (else error on unresolved refs)

---@class LvimRestRequestConfig
---@field timeout          integer               Per-request timeout (ms)
---@field follow_redirects boolean               Follow 3xx redirects
---@field insecure         boolean               Skip TLS verification (per-request `@curl-insecure` overrides)
---@field http_version     "auto"|"1.1"|"2"|"3"  Preferred HTTP version
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
---@field parallel        integer  Max requests in flight during a run (1 = serial)

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

---@class LvimRestKeys
---@field send           string  Send the request under the cursor
---@field send_all       string  Send every request in the buffer
---@field replay         string  Replay the last request
---@field cancel         string  Cancel in-flight request(s)
---@field inspect        string  Show the fully resolved request
---@field jump_next      string  Jump to the next request
---@field jump_prev      string  Jump to the previous request
---@field explorer       string  Focus/open the collection explorer
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
---@field running    string
---@field ok         string
---@field fail       string
---@field env        string
---@field sent       string
---@field recv       string
---@field workspace  string
---@field collection string
---@field folder     string
---@field request    string
---@field jq         string
---@field history    string
---@field stats      string
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
---@field scripts       { enabled: boolean }
---@field history       LvimRestHistoryConfig
---@field scrub_secrets boolean                 Mask Authorization/Cookie/vault values everywhere they surface
---@field prompt        { cache: boolean }       Cache prompt-var values for the session (never persisted)
---@field inline_status boolean                 Show the per-request extmark status lane
---@field keys          LvimRestKeys             Buffer-local maps for http/rest filetypes (all configurable)
---@field icons         LvimRestIcons

---@type LvimRestConfig
return {
    -- Execution engine: "auto" = the daemon when built, else curl for HTTP with a one-time notice;
    -- "daemon" = require lvim-rest-core; "curl" = the pure-curl HTTP/GraphQL fallback only.
    backend = "auto",
    daemon = {
        bin = nil, -- nil = probe the repo/installer-managed path
        autostart = true,
        idle_timeout = 300000,
    },
    -- The dedicated full-tab IDE face (`:LvimRest`): LEFT explorer / CENTER .http editor / dock.
    workbench = {
        explorer_width = 34,
        dock = {
            position = "right", -- "right" | "bottom"
            size = 0.42, -- fraction of the workbench for the dock
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
        runner = { delay = 0, stop_on_failure = false, parallel = 1 },
    },
    vault = { enabled = true, auto = false },
    cookies = { enabled = true },
    scripts = { enabled = true },
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
}
