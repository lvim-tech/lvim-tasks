-- lvim-tasks.history: the OPT-IN durable task history (config.persist_history).
-- A per-plugin sqlite store (via lvim-utils.store, its OWN db) recording one row per finished
-- run: template, cmd, cwd, exit_code, duration_ms, started_at. It survives restarts and powers
-- `:LvimTasks history`, "redo last failed" across sessions, and per-template average duration
-- (a soft ETA next to the spinner). Nothing touches the DB on the hot path — one insert on exit.
--
-- When persist_history is off, or sqlite.lua is missing, every call is a no-op (the live registry
-- is the only source), so callers never guard.
--
---@module "lvim-tasks.history"

local config = require("lvim-tasks.config")

local M = {}

---@type table?  the lvim-utils.store handle (nil until opened / when disabled)
local db = nil
local opened = false

---@type table<string, integer|false>  memoized avg_duration per template (`false` = computed, no data). The
--- panel rebuilds every 120ms spinner tick and each RUNNING templated row would otherwise run a SELECT over
--- all that template's success rows — a value that only changes when a run FINISHES. Invalidated in M.record.
local avg_cache = {}

local SCHEMA = {
    id = { "integer", primary = true, autoincrement = true },
    template = { "text" },
    name = { "text" },
    cmd = { "text" },
    cwd = { "text" },
    exit_code = { "integer" },
    status = { "text" },
    duration_ms = { "integer" },
    started_at = { "integer" },
}

--- Open the history store lazily (once). No-op when disabled or sqlite is unavailable.
---@return table?  the store handle or nil
local function ensure()
    if opened then
        return db
    end
    opened = true
    if not config.persist_history then
        return nil
    end
    local ok, store = pcall(require, "lvim-utils.store")
    if not ok or not store.available() then
        return nil
    end
    db = store.new({
        backend = "sqlite",
        name = "lvim-tasks",
        version = 1,
        tables = { task_history = SCHEMA },
    })
    -- The constructor never fails, but the db may not have OPENED (unwritable dir, sqlite error) —
    -- treat that as unavailable so every caller stays a clean no-op.
    if not (db and db:is_open()) then
        db = nil
    end
    return db
end

--- Record a finished task (one insert). No-op while disabled / unavailable.
---@param task LvimTask
function M.record(task)
    local store = ensure()
    if not store then
        return
    end
    local cmd = task.spec.cmd
    store:insert("task_history", {
        template = task.spec.template,
        name = task.spec.name,
        cmd = (type(cmd) == "table") and table.concat(cmd, " ") or tostring(cmd),
        cwd = task.spec.cwd,
        exit_code = task.exit_code,
        status = task.status,
        duration_ms = task:duration_ms(),
        started_at = task.started_epoch, -- wall-clock seconds (uv.now() is monotonic, not a date)
    })
    -- a new finished run changes this template's average → drop the memoized value
    if task.spec.template then
        avg_cache[task.spec.template] = nil
    end
end

--- Past runs, newest first (capped). Empty when disabled / unavailable.
---@param limit integer?
---@return table[]
function M.list(limit)
    local store = ensure()
    if not store then
        return {}
    end
    local rows = store:find("task_history", nil, { order_by = { desc = "id" }, limit = limit or 100 })
    return (type(rows) == "table") and rows or {}
end

--- The average duration (ms) of a template's SUCCESSFUL past runs, or nil (a soft ETA).
---@param template string
---@return integer?
function M.avg_duration(template)
    local store = ensure()
    if not store or not template then
        return nil
    end
    local cached = avg_cache[template]
    if cached ~= nil then
        return cached or nil -- `false` → computed, no data
    end
    local rows = store:find("task_history", { template = template, status = "success" })
    local sum, n = 0, 0
    if type(rows) == "table" then
        for _, r in ipairs(rows) do
            if r.duration_ms then
                sum = sum + r.duration_ms
                n = n + 1
            end
        end
    end
    local avg = (n > 0) and math.floor(sum / n) or nil
    avg_cache[template] = avg or false
    return avg
end

--- Whether durable history is active (enabled + backend available).
---@return boolean
function M.active()
    return ensure() ~= nil
end

return M
