-- lvim-tasks: the task-runner framework of the lvim-tech set — define tasks (command + cwd +
-- env), run them as jobs with live terminal output, watch them in the list panel, restart / stop
-- / dispose, register reusable templates (yours, lvim-build's detected actions, a project's
-- .vscode/tasks.json), and optionally persist a durable run history. This module is the PUBLIC
-- seam: `setup()`, the `:LvimTasks` command, and the API other plugins call (`run` / `run_template`
-- / `register` / `list`). The lifecycle GLUE also lives here: one `User LvimTasksChanged` handler
-- routes every status transition to the registry's dispose policy, the durable history, the hud
-- chip and the open panel — so task/runner stay observers-free and the panel stays a renderer.
--
---@module "lvim-tasks"

local api = vim.api
local config = require("lvim-tasks.config")
local task_mod = require("lvim-tasks.task")
local runner = require("lvim-tasks.runner")
local registry = require("lvim-tasks.registry")
local templates = require("lvim-tasks.templates")
local history = require("lvim-tasks.history")
local status = require("lvim-tasks.status")
local panel = require("lvim-tasks.panel")
local merge = require("lvim-utils.utils").merge
local hl = require("lvim-utils.highlight")
local highlights = require("lvim-tasks.highlights")

local M = {}

---@type boolean  setup() ran (command + autocmd registered)
local registered = false

--- The last spec run per project root — powers `:LvimTasks redo` (session memory; the durable
--- cross-restart history is history.lua's).
---@type table<string, LvimTaskSpec>
local last_spec = {}

---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-tasks: " .. msg, level or vim.log.levels.INFO)
end

--- The current project root: the nearest `.git` ancestor of the cwd, else the cwd (the redo key).
---@return string
local function project_root()
    return vim.fs.normalize(vim.fs.root(0, ".git") or vim.fn.getcwd())
end

-- ── the lifecycle glue ───────────────────────────────────────────────────────

--- After a task ENDS (runner on_exit): apply the registry dispose policy and record the durable
--- history row. Passed to every runner.start/restart (public so the panel's restart key shares it).
---@param task LvimTask
function M.on_task_exit(task)
    registry.on_ended(task)
    history.record(task)
end

--- The single LvimTasksChanged observer: hud chip + panel repaint on EVERY transition.
local function on_changed()
    status.refresh_chip()
    panel.refresh()
end

-- ── public API ───────────────────────────────────────────────────────────────

--- Run a task spec: create the task, add it to the registry, start it. The spec this run per
--- project is remembered for `:LvimTasks redo`.
---@param spec LvimTaskSpec
---@return LvimTask? task  nil when the spec is unusable
function M.run(spec)
    if type(spec) ~= "table" or spec.cmd == nil then
        notify("run() needs a spec with a cmd", vim.log.levels.WARN)
        return nil
    end
    if spec.name == nil then
        local cmd = spec.cmd
        spec.name = type(cmd) == "table" and table.concat(cmd, " ") or tostring(cmd)
    end
    local task = task_mod.new(spec)
    registry.add(task)
    if runner.start(task, M.on_task_exit) then
        last_spec[project_root()] = spec
    end
    return task
end

--- Build + run a registered template by name (nil when it does not apply / build).
---@param name string
---@param ctx table?  detection context (default: the current buffer's)
---@return LvimTask?
function M.run_template(name, ctx)
    local spec = templates.build(name, ctx)
    if not spec then
        notify(("template '%s' produced no task here"):format(name), vim.log.levels.WARN)
        return nil
    end
    return M.run(spec)
end

--- Register (or replace) a task template — the seam lvim-build and user configs feed.
---@param template LvimTaskTemplate
function M.register(template)
    templates.register(template)
end

--- Every live task, newest first.
---@return LvimTask[]
function M.list()
    return registry.all()
end

--- A live task by id.
---@param id integer
---@return LvimTask?
function M.get(id)
    return registry.get(id)
end

--- Stop a running task by id (default: the most recent running one).
---@param id integer?
---@return boolean
function M.stop(id)
    local task = id and registry.get(id) or registry.by_status("running")[1]
    if not task then
        notify("nothing is running", vim.log.levels.WARN)
        return false
    end
    return runner.stop(task)
end

--- Re-run the last spec run in this project (`:LvimTasks redo`).
---@return LvimTask?
function M.redo()
    local spec = last_spec[project_root()]
    if not spec then
        notify("nothing to redo in this project yet", vim.log.levels.WARN)
        return nil
    end
    return M.run(vim.deepcopy(spec))
end

--- Re-run the most recent FAILED task (live registry first, then the durable history).
---@return LvimTask?
function M.redo_failed()
    local t = registry.last_failed()
    if t then
        return M.run(vim.deepcopy(t.spec))
    end
    for _, row in ipairs(history.list(50)) do
        if row.status == "failed" and row.cmd then
            return M.run({ name = row.name or row.cmd, cmd = row.cmd, cwd = row.cwd, template = row.template })
        end
    end
    notify("no failed run to redo", vim.log.levels.WARN)
    return nil
end

-- ── choosers ─────────────────────────────────────────────────────────────────

--- Refresh the project's .vscode/tasks.json templates (no-op when disabled / absent).
local function ensure_vscode()
    if config.vscode_tasks then
        require("lvim-tasks.parsers.vscode").ensure()
    end
end

--- The template chooser (`:LvimTasks run` with no name): applicable templates in `ui.select`,
--- labelled "group ➤ name — desc".
local function choose_template()
    ensure_vscode()
    local ctx = templates.context()
    local list = templates.applicable(ctx)
    if #list == 0 then
        notify("no applicable templates (register some, or add .vscode/tasks.json)", vim.log.levels.WARN)
        return
    end
    local items = {}
    for _, t in ipairs(list) do
        local label = t.name
        if t.group then
            label = t.group .. " ➤ " .. label
        end
        if t.desc then
            label = label .. " — " .. t.desc
        end
        items[#items + 1] = { label = label, icon = config.icons.tasks, _name = t.name }
    end
    require("lvim-ui").select({
        title = " Run template",
        items = items,
        callback = function(confirmed, index)
            if confirmed == true and items[index] then
                M.run_template(items[index]._name, ctx)
            end
        end,
    })
end

--- The durable-history chooser (`:LvimTasks history`): past runs newest-first, <CR> re-runs one.
local function choose_history()
    if not history.active() then
        notify("history is off — enable persist_history (needs sqlite.lua)", vim.log.levels.WARN)
        return
    end
    local rows = history.list(100)
    if #rows == 0 then
        notify("no recorded runs yet")
        return
    end
    local items = {}
    for _, r in ipairs(rows) do
        local icon = config.icons[r.status] or config.icons.pending
        local when = r.started_at and os.date("%d %b %H:%M", r.started_at) or ""
        items[#items + 1] = {
            label = ("%s  %s  %s"):format(r.name or r.cmd or "?", when, r.status or ""),
            icon = icon,
            _row = r,
        }
    end
    require("lvim-ui").select({
        title = " Task history",
        items = items,
        callback = function(confirmed, index)
            local r = confirmed == true and items[index] and items[index]._row or nil
            if r and r.cmd then
                M.run({ name = r.name or r.cmd, cmd = r.cmd, cwd = r.cwd, template = r.template })
            end
        end,
    })
end

-- ── panel passthrough ────────────────────────────────────────────────────────

--- Open the task panel.
---@param layout string?  "float" | "area" | "bottom" (session-sticky override)
function M.open(layout)
    panel.open(layout)
end

--- Toggle the task panel.
---@param layout string?
function M.toggle(layout)
    panel.toggle(layout)
end

-- ── the command ──────────────────────────────────────────────────────────────

---@type table<string, boolean>
local LAYOUTS = { float = true, area = true, bottom = true }
local SUBS = { "run", "redo", "redo-failed", "stop", "history", "clear", "toggle" }

--- Parse `:LvimTasks` args: a layout token anywhere + a subcommand; `run` consumes the REST as
--- the template name (template names may contain spaces).
---@param args string
---@return string sub, string? layout, string? rest
local function parse(args)
    local sub, layout = "", nil
    local rest = {}
    for tok in args:gmatch("%S+") do
        if sub == "run" then
            rest[#rest + 1] = tok
        elseif LAYOUTS[tok] then
            layout = tok
        elseif sub == "" then
            sub = tok
        else
            rest[#rest + 1] = tok
        end
    end
    return sub, layout, table.concat(rest, " ")
end

--- Configure lvim-tasks: merge `opts` into the live config, bind the theme factory, register the
--- `:LvimTasks` command and the one LvimTasksChanged observer. Idempotent past the first call.
---@param opts LvimTasksConfig?
function M.setup(opts)
    if opts then
        merge(config, opts)
    end
    if registered then
        return
    end
    registered = true
    hl.setup()
    hl.bind(highlights.build)

    api.nvim_create_user_command("LvimTasks", function(cmd)
        local sub, layout, rest = parse(cmd.args)
        if sub == "" or sub == "toggle" then
            if sub == "toggle" then
                M.toggle(layout)
            else
                M.open(layout)
            end
        elseif sub == "run" then
            if rest ~= "" then
                ensure_vscode()
                M.run_template(rest)
            else
                choose_template()
            end
        elseif sub == "redo" then
            M.redo()
        elseif sub == "redo-failed" then
            M.redo_failed()
        elseif sub == "stop" then
            M.stop(tonumber(rest))
        elseif sub == "history" then
            choose_history()
        elseif sub == "clear" then
            local n = registry.clear_done()
            notify(("%d task(s) cleared"):format(n))
        else
            notify(("unknown subcommand '%s'"):format(sub), vim.log.levels.WARN)
        end
    end, {
        nargs = "*",
        desc = "lvim-tasks: [toggle] / run [template] / redo / redo-failed / stop [id] / history / clear [float|area|bottom]",
        complete = function(_, line)
            if line:match("%f[%w]run%s+%S*$") then
                ensure_vscode()
                local names = {}
                for _, t in ipairs(templates.applicable(templates.context())) do
                    names[#names + 1] = t.name
                end
                return names
            end
            local out = vim.list_extend({}, SUBS)
            return vim.list_extend(out, { "float", "area", "bottom" })
        end,
    })

    -- The ONE observer of every status transition (task.set_status fires it): dispose policy +
    -- history are wired per-run via on_task_exit; this handles the cross-cutting repaints.
    api.nvim_create_autocmd("User", {
        pattern = "LvimTasksChanged",
        group = api.nvim_create_augroup("LvimTasksGlue", { clear = true }),
        callback = function()
            on_changed()
        end,
    })
end

return M
