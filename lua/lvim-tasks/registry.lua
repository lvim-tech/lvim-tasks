-- lvim-tasks.registry: the live in-memory task list.
-- Holds every task created this session (newest first), applies the dispose policy (a succeeded
-- task is auto-disposed after `dispose_succeeded_after`; failed tasks are kept for inspection),
-- and caps the list at `max_history` by dropping the oldest DISPOSED rows. The panel renders from
-- here; history.lua is the separate DURABLE store.
--
---@module "lvim-tasks.registry"

local config = require("lvim-tasks.config")
local runner = require("lvim-tasks.runner")

local M = {}

---@type LvimTask[]  newest first
local tasks = {}
---@type table<integer, uv.uv_timer_t>  per-task auto-dispose timers
local dispose_timers = {}

--- Add a task to the front of the registry and trim to the cap.
---@param task LvimTask
function M.add(task)
    table.insert(tasks, 1, task)
    M._trim()
end

--- Every task, newest first.
---@return LvimTask[]
function M.all()
    return tasks
end

--- Tasks matching a status predicate, newest first.
---@param status LvimTaskStatus
---@return LvimTask[]
function M.by_status(status)
    local out = {}
    for _, t in ipairs(tasks) do
        if t.status == status then
            out[#out + 1] = t
        end
    end
    return out
end

--- A task by id, or nil.
---@param id integer
---@return LvimTask?
function M.get(id)
    for _, t in ipairs(tasks) do
        if t.id == id then
            return t
        end
    end
    return nil
end

--- The most recent task (newest), or nil.
---@return LvimTask?
function M.last()
    return tasks[1]
end

--- The most recent FAILED task (for "redo last failed"), or nil.
---@return LvimTask?
function M.last_failed()
    for _, t in ipairs(tasks) do
        if t.status == "failed" then
            return t
        end
    end
    return nil
end

--- How many tasks are currently running.
---@return integer
function M.running_count()
    return #M.by_status("running")
end

--- Dispose a task: free its output buffer and remove it from the registry. Fires the shared
--- `User LvimTasksChanged` seam (status "disposed") so the panel / chip repaint — an AUTO-dispose
--- (the succeeded-task timer) must update the open panel exactly like a manual one.
---@param id integer
---@return boolean
function M.dispose(id)
    for i, t in ipairs(tasks) do
        if t.id == id then
            -- NEVER dispose a running task: the succeeded-task auto-dispose timer can fire after the user
            -- RESTARTED the task (panel `r`), and disposing it deletes the live terminal buffer out from under
            -- the job. The panel's `d` and clear_done already guard this; the timer path did not.
            if t:is_running() then
                return false
            end
            if dispose_timers[id] then
                pcall(function()
                    dispose_timers[id]:stop()
                    dispose_timers[id]:close()
                end)
                dispose_timers[id] = nil
            end
            runner.dispose(t)
            table.remove(tasks, i)
            pcall(vim.api.nvim_exec_autocmds, "User", {
                pattern = "LvimTasksChanged",
                data = { id = id, status = "disposed" },
            })
            return true
        end
    end
    return false
end

--- Dispose every task that is not running (the panel's "clear done").
---@return integer  count disposed
function M.clear_done()
    local n = 0
    -- Snapshot the IDS first — M.dispose mutates `tasks`, so iterating it directly would skip rows.
    local ids = {}
    for _, t in ipairs(tasks) do
        if t.status ~= "running" then
            ids[#ids + 1] = t.id
        end
    end
    for _, id in ipairs(ids) do
        if M.dispose(id) then
            n = n + 1
        end
    end
    return n
end

--- Cancel a pending succeeded-task auto-dispose timer (e.g. the task was RESTARTED before it fired), so the
--- timer never runs against the now-running task and its handle is released.
---@param id integer
function M.cancel_dispose(id)
    if dispose_timers[id] then
        pcall(function()
            dispose_timers[id]:stop()
            dispose_timers[id]:close()
        end)
        dispose_timers[id] = nil
    end
end

--- Apply the dispose policy for a task that just ended: schedule a succeeded task's auto-dispose.
--- Called by init's LvimTasksChanged handler. Failed/canceled tasks are kept.
---@param task LvimTask
function M.on_ended(task)
    local after = config.dispose_succeeded_after
    local transient = task.spec.transient == true
    -- A transient task auto-disposes on ANY terminal status (a watch re-run should not linger);
    -- a normal task only when it SUCCEEDED and a dispose delay is configured.
    local delay = after
    if transient and (type(delay) ~= "number" or delay <= 0) then
        delay = 10 -- a sensible default when the user disabled success-dispose
    end
    local should = transient or (task.status == "success" and type(after) == "number" and after > 0)
    if not should or type(delay) ~= "number" or delay <= 0 then
        return
    end
    local timer = (vim.uv or vim.loop).new_timer()
    if timer then
        dispose_timers[task.id] = timer
        timer:start(
            delay * 1000,
            0,
            vim.schedule_wrap(function()
                M.dispose(task.id)
            end)
        )
    end
end

--- Drop the oldest DISPOSED-eligible rows past the cap (never drops a running task).
function M._trim()
    if #tasks <= config.max_history then
        return
    end
    for i = #tasks, 1, -1 do
        if #tasks <= config.max_history then
            break
        end
        local t = tasks[i]
        if t.status ~= "running" then
            M.dispose(t.id)
        end
    end
end

return M
