-- lvim-rest.highlights: every highlight group, self-themed from the lvim-utils palette.
--
-- A `build()` factory (bound via lvim-utils.highlight.bind, re-run on ColorScheme / palette sync):
-- method accents (GET green, POST blue, PUT/PATCH yellow, DELETE red, GraphQL/gRPC/WS magenta/cyan),
-- status accents (2xx green · 3xx yellow · 4xx orange · 5xx red) shared by the inline lane + history
-- rows + dock title, header name/value dim pair, stats key/value pair, verbose request/response
-- tints, report pass/fail tints, WS sent/recv direction tints, and the dock cursor line. Every colour
-- is an mtint of a live-palette accent — nothing hardcoded, so it tracks the theme.
--
---@module "lvim-rest.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")

local M = {}

--- Blend an accent toward the editor bg (the shared "mtint" convention).
---@param accent string
---@param t number
---@return string
local function mtint(accent, t)
    return hl.blend(accent, c.bg, t)
end

--- The lvim-rest highlight groups from the live palette.
---@return table<string, table>
function M.build()
    return {
        -- Method accents (fg = the method's colour).
        LvimRestGet = { fg = c.green, bold = true },
        LvimRestPost = { fg = c.blue, bold = true },
        LvimRestPut = { fg = c.yellow, bold = true },
        LvimRestPatch = { fg = c.yellow, bold = true },
        LvimRestDelete = { fg = c.red, bold = true },
        LvimRestHead = { fg = c.cyan, bold = true },
        LvimRestOptions = { fg = c.cyan, bold = true },
        LvimRestGraphql = { fg = c.magenta, bold = true },
        LvimRestGrpc = { fg = c.magenta, bold = true },
        LvimRestWebsocket = { fg = c.cyan, bold = true },

        -- Status accents (shared by the inline lane, history rows, dock title).
        LvimRestStatus2xx = { fg = c.green, bold = true },
        LvimRestStatus3xx = { fg = c.yellow, bold = true },
        LvimRestStatus4xx = { fg = c.orange, bold = true },
        LvimRestStatus5xx = { fg = c.red, bold = true },

        -- Response dock view-tab bar (body / headers / … / jq) — the lvim-installer TOOLBAR canon: a YELLOW
        -- family, fg-ONLY (no background). The open view reads light-yellow-bold, the rest a dimmer yellow, and
        -- the keyboard cursor braces the hovered tab in `[ ]` (drawn by ui.button — these groups carry no bg, so
        -- the brackets ARE the hover affordance, not doubled by a tint).
        LvimRestTabInactive = { fg = mtint(c.yellow, 0.6) }, -- not selected: dim yellow
        LvimRestTabActive = { fg = c.yellow, bold = true }, -- the open view: light yellow bold
        LvimRestTabHover = { fg = c.yellow, bold = true }, -- the cursor (+ `[ ]` brackets), fg-only

        -- Header view: dim name, normal value.
        LvimRestHeaderName = { fg = mtint(c.fg, 0.6) },
        LvimRestHeaderValue = { fg = c.fg },

        -- Stats view: dim key, bright value.
        LvimRestStatsKey = { fg = mtint(c.fg, 0.6) },
        LvimRestStatsVal = { fg = c.fg, bold = true },

        -- Verbose transcript: request lines blue-tinted, response lines green-tinted.
        LvimRestVerboseReq = { fg = mtint(c.blue, 0.85) },
        LvimRestVerboseResp = { fg = mtint(c.green, 0.85) },

        -- Report (assertions).
        LvimRestPass = { fg = c.green },
        LvimRestFail = { fg = c.red },

        -- WebSocket transcript direction tints (phase 7).
        LvimRestSent = { fg = c.blue },
        LvimRestRecv = { fg = c.green },

        -- The dock cursor line (a faint blue wash so it reads over the content).
        LvimRestCursorLine = { bg = mtint(c.blue, 0.12) },

        -- The env / hud chip (phase 4).
        LvimRestEnv = { fg = c.cyan, bg = mtint(c.cyan, 0.2), bold = true },
    }
end

return M
