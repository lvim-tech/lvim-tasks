-- lvim-tasks.runner: how a task RUNS (kept apart from what a task IS, in task.lua).
-- Each task streams into its OWN terminal buffer via `jobstart(cmd, { term = true })`, so it gets
-- full ANSI colour and a scrollback for free and the panel/preview can just show that buffer. The
-- output buffer lives past a `hide` (bufhidden = "hide") until the task is disposed. On exit we
-- flip the task status (which the registry/panel/history observe) and, when the task has a
-- matcher, hand the captured output to matchers.lua.
--
-- Stop escalates SIGTERM → SIGKILL. Restart re-runs the same spec into a fresh buffer.
--
---@module "lvim-tasks.runner"

local api = vim.api
local fn = vim.fn

local M = {}

--- Start `task`: open a scratch terminal buffer, jobstart the command into it, wire the exit
--- callback. No-op when the task is already running.
---@param task LvimTask
---@param on_exit fun(task: LvimTask)?  extra callback after the status transition (registry/history)
---@return boolean started
function M.start(task, on_exit)
    if task:is_running() then
        return false
    end

    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    task.bufnr = buf
    local hooks = task.spec.hooks or {}

    -- jobstart with term=true must run in a window OWNING the buffer OR via nvim_buf_call so the
    -- terminal is attached to `buf` regardless of the current window.
    local ok, job = pcall(function()
        return api.nvim_buf_call(buf, function()
            return fn.jobstart(task.spec.cmd, {
                cwd = task.spec.cwd,
                env = task.spec.env,
                term = true,
                -- The output already streams into the terminal buffer; the stdout tap exists only
                -- for the caller's on_output hook (line chunks, unfiltered).
                on_stdout = hooks.on_output and function(_, data)
                    pcall(hooks.on_output, task, data)
                end or nil,
                on_exit = function(j, code)
                    -- Ownership guard: a restart may have superseded this run (stop → start put a NEW
                    -- job id on the task before the killed job's exit arrives). A stale exit must not
                    -- touch the task — clearing job_id / flipping status here would corrupt the new run.
                    if task.job_id ~= j then
                        return
                    end
                    task.job_id = nil
                    -- A stop() marked the task "canceled" BEFORE the job died — the exit of the
                    -- killed process must not overwrite that intent with "failed" (and a canceled
                    -- run's partial output is not worth a matcher parse).
                    if task.status ~= "canceled" then
                        task:set_status(code == 0 and "success" or "failed", code)
                        if task.spec.matcher then
                            pcall(function()
                                require("lvim-tasks.matchers").apply(task)
                            end)
                        end
                    end
                    if hooks.on_exit then
                        pcall(hooks.on_exit, task)
                    end
                    if on_exit then
                        pcall(on_exit, task)
                    end
                end,
            })
        end)
    end)

    if not ok or type(job) ~= "number" or job <= 0 then
        task:set_status("failed", -1)
        return false
    end

    task.job_id = job
    task:set_status("running")
    if hooks.on_start then
        pcall(hooks.on_start, task)
    end
    return true
end

--- Stop a running task (SIGTERM, then SIGKILL after a grace period). Marks it canceled — the
--- runner's exit callback sees that status and keeps it (a kill exits non-zero, not "failed").
---@param task LvimTask
---@return boolean stopped
function M.stop(task)
    if not task:is_running() or not task.job_id then
        return false
    end
    local job = task.job_id
    task:set_status("canceled", nil)
    pcall(fn.jobstop, job)
    -- Escalate to SIGKILL if it is still alive shortly after (jobstop on an already-dead id is a
    -- harmless no-op, so no liveness check is needed).
    vim.defer_fn(function()
        pcall(fn.jobstop, job) -- jobstop sends SIGKILL on a second call to a stuck job
    end, 1500)
    return true
end

--- Detach `buf` from every window still displaying it (swap a bare scratch in) BEFORE it is
--- deleted: deleting a buffer shown in a float closes that window, and closing a frame panel
--- window tears the whole frame down (the panel preview displays task buffers). The scratch is
--- `bufhidden = wipe`, so it vanishes as soon as the real owner (the panel's own render) swaps
--- its content back in.
---@param buf integer
local function detach_windows(buf)
    for _, win in ipairs(fn.win_findbuf(buf)) do
        local scratch = api.nvim_create_buf(false, true)
        vim.bo[scratch].bufhidden = "wipe"
        pcall(api.nvim_win_set_buf, win, scratch)
    end
end

--- Restart a task: dispose its old output buffer and run the same spec again.
---@param task LvimTask
---@param on_exit fun(task: LvimTask)?
---@return boolean
function M.restart(task, on_exit)
    if task:is_running() then
        M.stop(task)
    end
    if task.bufnr and api.nvim_buf_is_valid(task.bufnr) then
        detach_windows(task.bufnr)
        pcall(api.nvim_buf_delete, task.bufnr, { force = true })
    end
    task.bufnr = nil
    task.exit_code = nil
    task.started_at = nil
    task.started_epoch = nil
    task.ended_at = nil
    task.status = "pending" -- a canceled/failed task re-enters the lifecycle from the start
    return M.start(task, on_exit)
end

--- Free a task's terminal buffer (after it is disposed from the registry).
---@param task LvimTask
function M.dispose(task)
    if task.bufnr and api.nvim_buf_is_valid(task.bufnr) then
        detach_windows(task.bufnr)
        pcall(api.nvim_buf_delete, task.bufnr, { force = true })
    end
    task.bufnr = nil
end

return M
