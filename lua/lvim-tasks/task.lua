-- lvim-tasks.task: the Task class — one runnable unit of work and its lifecycle.
-- A task holds its spec (name / cmd / cwd / env / matcher / template), a monotonically rising id,
-- its live status, exit code and timing, the terminal buffer its output streams into, and the
-- caller hooks. State transitions go through :set_status so the registry/panel/history observe a
-- single seam (and User autocmds fire), never by poking `.status` directly.
--
-- The task does NOT start itself — lvim-tasks.runner drives jobstart into `bufnr` and calls the
-- status transitions. This keeps the model (what a task IS) separate from the runner (how it runs).
--
---@module "lvim-tasks.task"

local uv = vim.uv or vim.loop

local M = {}

-- Monotonic id source (never reused within a session, so panel/history rows stay stable).
local _next_id = 0

---@alias LvimTaskStatus "pending"|"running"|"success"|"failed"|"canceled"

---@class LvimTaskSpec
---@field name     string        Human label (unique-ish; the panel/history key)
---@field cmd      string|string[]  Command (argv list preferred; a string runs via the shell)
---@field cwd      string?       Working directory (default: the current cwd)
---@field env      table<string,string>?  Extra environment
---@field template string?       The template that produced it (for history grouping)
---@field matcher  string?       Problem-matcher name / errorformat key (see matchers.lua)
---@field group    string?       Display group (Build/Run/Test/…)
---@field transient boolean?     A throwaway run (e.g. a watch re-run): kept OUT of the durable
---                              history and auto-disposed on ANY terminal status (not only success),
---                              so a frequently re-triggered task does not pollute the panel/history.
---@field hooks    LvimTaskHooks?  Caller lifecycle callbacks (fired by the runner)

---@class LvimTaskHooks
---@field on_start  fun(task: LvimTask)?
---@field on_output fun(task: LvimTask, data: string[])?  raw stdout line chunks while running
---@field on_exit   fun(task: LvimTask)?                  after the terminal status transition

---@class LvimTask
---@field id         integer
---@field spec       LvimTaskSpec
---@field status     LvimTaskStatus
---@field exit_code  integer?
---@field bufnr      integer?     Terminal buffer the output streams into
---@field job_id     integer?     jobstart id while running
---@field started_at number?      uv.now() at start (ms, MONOTONIC — durations only)
---@field started_epoch integer?  os.time() at start (wall clock — the history timestamp)
---@field ended_at   number?      uv.now() at exit (ms, monotonic)
local Task = {}
Task.__index = Task

--- Create a task from a spec (does NOT start it).
---@param spec LvimTaskSpec
---@return LvimTask
function M.new(spec)
    _next_id = _next_id + 1
    return setmetatable({
        id = _next_id,
        spec = spec,
        status = "pending",
        exit_code = nil,
        bufnr = nil,
        job_id = nil,
        started_at = nil,
        ended_at = nil,
    }, Task)
end

--- Transition the status and fire the `User LvimTasksChanged` autocmd (the single observation
--- seam for the registry / panel / history). Stamps timing on the running/terminal transitions.
---@param status LvimTaskStatus
---@param exit_code integer?
function Task:set_status(status, exit_code)
    self.status = status
    if status == "running" then
        -- two clocks on purpose: uv.now() is monotonic (safe for durations), os.time() is the
        -- wall-clock stamp the durable history shows as "when"
        self.started_at = uv.now()
        self.started_epoch = os.time()
    elseif status == "success" or status == "failed" or status == "canceled" then
        self.ended_at = uv.now()
        self.exit_code = exit_code
    end
    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "LvimTasksChanged",
        data = { id = self.id, status = status },
    })
end

--- Whether the task is currently running.
---@return boolean
function Task:is_running()
    return self.status == "running"
end

--- Elapsed run time in milliseconds (live while running, final once ended). 0 before start.
---@return integer
function Task:duration_ms()
    if not self.started_at then
        return 0
    end
    return math.floor((self.ended_at or uv.now()) - self.started_at)
end

return M
