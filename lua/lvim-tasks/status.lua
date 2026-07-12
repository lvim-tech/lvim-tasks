-- lvim-tasks.status: a statusline provider + the lvim-hud "running tasks" chip.
-- `get()` is the stable data seam for a statusline component (the planned lvim-utils/hud
-- statusline components will consume it); until those land, `refresh_chip()` shows a compact
-- count in the statusline via the lvim-hud overlay while any task runs, and clears it when idle.
--
---@module "lvim-tasks.status"

local config = require("lvim-tasks.config")
local registry = require("lvim-tasks.registry")

local M = {}

--- A snapshot of task counts for a statusline component.
---@return { running: integer, failed: integer, success: integer }
function M.get()
    return {
        running = #registry.by_status("running"),
        failed = #registry.by_status("failed"),
        success = #registry.by_status("success"),
    }
end

--- Update the lvim-hud statusline chip: show "N task(s)" with the running spinner accent while
--- anything runs; clear it when nothing does. No-op when hud_chip is off or lvim-hud is absent.
---@return nil
function M.refresh_chip()
    if not config.hud_chip then
        return
    end
    local ok, overlay = pcall(require, "lvim-hud.overlay")
    if not ok then
        return
    end
    local running = #registry.by_status("running")
    if running > 0 then
        pcall(overlay.set, {
            icon = config.icons.tasks,
            title = ("%d task%s"):format(running, running == 1 and "" or "s"),
        })
    else
        pcall(overlay.clear)
    end
end

return M
