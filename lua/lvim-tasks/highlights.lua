-- lvim-tasks.highlights: the panel's status badges / text zones, self-themed from the lvim-utils
-- palette. One accent per task status (from config.colors), each lead badge a tint of its accent
-- toward the editor bg (the shared "mtint" convention), so the rows track the live theme. build()
-- is bound via lvim-utils.highlight.bind in setup(), re-derived on ColorScheme / palette sync.
--
---@module "lvim-tasks.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")
local config = require("lvim-tasks.config")

local M = {}

--- Blend an accent toward the editor bg (the shared "mtint" convention).
---@param accent string
---@param t number
---@return string
local function mtint(accent, t)
    return hl.blend(accent, c.bg, t)
end

--- Resolve a `config.colors` value to a real colour: a palette KEY (`c[key]`, tracks the live
--- theme) or, when it is not a palette field, the value itself (a literal "#rrggbb").
---@param key string
---@return string
local function accent(key)
    local v = c[key]
    return type(v) == "string" and v or key
end

--- The lvim-tasks highlight groups from the live palette + `config.colors`.
---@return table<string, table>
function M.build()
    local col = config.colors
    local pending = accent(col.pending)
    local running = accent(col.running)
    local success = accent(col.success)
    local failed = accent(col.failed)
    local canceled = accent(col.canceled)
    return {
        -- lead badges (the row's status icon box) — fg = the status accent on its own soft tint
        LvimTasksPendingBadge = { fg = pending, bg = mtint(pending, 0.2) },
        LvimTasksRunningBadge = { fg = running, bg = mtint(running, 0.3), bold = true },
        LvimTasksSuccessBadge = { fg = success, bg = mtint(success, 0.3), bold = true },
        LvimTasksFailedBadge = { fg = failed, bg = mtint(failed, 0.3), bold = true },
        LvimTasksCanceledBadge = { fg = canceled, bg = mtint(canceled, 0.2) },
        -- the task NAME cell, painted per status (the primary text reads in the row's accent)
        LvimTasksPendingName = { fg = pending },
        LvimTasksRunningName = { fg = running },
        LvimTasksSuccessName = { fg = success },
        LvimTasksFailedName = { fg = failed },
        LvimTasksCanceledName = { fg = canceled },
        -- row text zones
        LvimTasksText = { fg = c.fg },
        LvimTasksDim = { fg = mtint(c.fg, 0.6) },
        LvimTasksGroup = { fg = c.cyan },
        LvimTasksEta = { fg = mtint(running, 0.7), italic = true },
        -- empty-state text
        LvimTasksEmpty = { fg = mtint(c.fg, 0.5), italic = true },
    }
end

return M
