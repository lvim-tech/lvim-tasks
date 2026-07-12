-- lvim-tasks.panel: the task list — ONE `lvim-ui.tabs` menu tab over the live registry.
-- Each task is a menu row: a status BADGE (spinner frames while running, driven by a uv timer →
-- rows rebuilt + `recalc()`), the name painted in the status accent, the template group, and a
-- dim duration / exit-code / soft-ETA suffix. A filter bar (the shared lvim-ui.filters group
-- model) narrows by status with live counts; the border counter shows running/total. The focused
-- task's OUTPUT — its real terminal buffer — is swapped into the chassis preview panel (the
-- lvim-term buffer-swap pattern), so it is live scrollback, not a copy. Per-row action keys are
-- wired in `on_open`; footer chips add new / clear-done. The chassis owns every window, band,
-- sector and layout — this module renders rows and reacts to `User LvimTasksChanged`.
--
---@module "lvim-tasks.panel"

local api = vim.api
local uv = vim.uv or vim.loop
local config = require("lvim-tasks.config")
local registry = require("lvim-tasks.registry")
local runner = require("lvim-tasks.runner")
local history = require("lvim-tasks.history")
local ui = require("lvim-ui")
local ui_filters = require("lvim-ui.filters")
local uipreview = require("lvim-ui.preview")

local M = {}

-- The preview panel's "no output" placeholder extmark namespace.
local NS = api.nvim_create_namespace("lvim-tasks-preview-empty")

---@class LvimTasksPanelState
---@field handle table?        the live ui.tabs handle
---@field tabs table[]?        the tab specs (rows mutated in place, seen by recalc)
---@field registry table<string, LvimTask>  row name → task (the cursor-dispatch seam)
---@field filter string        active status filter id ("all"|"running"|"failed"|"success")
---@field layout string?       session-sticky per-command layout override
---@field active_layout string? the RESOLVED layout of the open panel
---@field preview_pan table?   the preview panel handle (captured in the provider keys hook)
---@field spin_i integer       current spinner frame index
---@field timer uv.uv_timer_t? the spinner timer (runs only while open AND anything runs)
local state = {
    registry = {},
    filter = "all",
    spin_i = 1,
}

---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-tasks: " .. msg, level or vim.log.levels.INFO)
end

--- Whether the panel is currently open.
---@return boolean
function M.is_open()
    return state.handle ~= nil and state.handle.valid ~= nil and state.handle.valid()
end

-- ── row building ─────────────────────────────────────────────────────────────

--- Whether `task` passes the status filter ("all" matches everything).
---@param task LvimTask
---@param filter string
---@return boolean
local function matches(task, filter)
    return filter == "all" or task.status == filter
end

--- Human duration: "480ms" under a second, "3.2s" under a minute, "2m05s" past it.
---@param ms integer
---@return string
local function fmt_duration(ms)
    if ms < 1000 then
        return ("%dms"):format(ms)
    elseif ms < 60000 then
        return ("%.1fs"):format(ms / 1000)
    end
    return ("%dm%02ds"):format(math.floor(ms / 60000), math.floor(ms % 60000 / 1000))
end

--- The status badge glyph: a spinner frame while running, the status icon otherwise.
---@param task LvimTask
---@return string
local function status_glyph(task)
    if task.status == "running" then
        return config.spinner[state.spin_i] or config.spinner[1]
    end
    return config.icons[task.status] or config.icons.pending
end

-- Status → highlight group suffix ("Pending"/"Running"/…), shared by the badge and name zones.
---@param status LvimTaskStatus
---@return string
local function hl_suffix(status)
    return status:sub(1, 1):upper() .. status:sub(2)
end

--- Truncate `s` to at most `n` characters, with a trailing ellipsis when clipped.
---@param s string
---@param n integer
---@return string
local function clip(s, n)
    if vim.fn.strchars(s) <= n then
        return s
    end
    return vim.fn.strcharpart(s, 0, n - 1) .. "…"
end

--- The dim trailing cell: run time, then "exit N" for a finished task or the soft ETA (the
--- template's average past duration, from the opt-in history) for a running one.
---@param task LvimTask
---@return string
local function suffix_of(task)
    local parts = {}
    if task.started_at then
        parts[#parts + 1] = fmt_duration(task:duration_ms())
    end
    if task.status == "running" then
        local avg = task.spec.template and history.avg_duration(task.spec.template) or nil
        if avg then
            parts[#parts + 1] = ("~%s"):format(fmt_duration(avg))
        end
    elseif task.exit_code then
        parts[#parts + 1] = ("exit %d"):format(task.exit_code)
    end
    return table.concat(parts, "  ")
end

--- One task row: badge + name (status accent) + group (cyan), the timing suffix, and `_item` =
--- the task (drives the preview via on_item_change). <CR> opens the OUTPUT (focuses the preview).
---@param task LvimTask
---@param namew integer  the aligned name column width
---@return table row
local function task_row(task, namew)
    local name = "task_" .. task.id
    state.registry[name] = task
    local sfx = hl_suffix(task.status)
    local label = (" %-" .. namew .. "s"):format(clip(task.spec.name or "?", namew))
    local spans = { { 1, 1 + #label, "LvimTasks" .. sfx .. "Name" } }
    local group = task.spec.group or task.spec.template
    if group then
        local cell = clip(group, 14)
        local start = #label + 3
        label = label .. "  " .. cell
        spans[#spans + 1] = { start, start + #cell, "LvimTasksGroup" }
    end
    return {
        type = "action",
        name = name,
        flat = true,
        tight = true,
        icon = " " .. status_glyph(task) .. " ",
        icon_hl = "LvimTasks" .. sfx .. "Badge",
        label = label,
        label_spans = spans,
        suffix = suffix_of(task),
        suffix_hl = task.status == "running" and "LvimTasksEta" or "LvimTasksDim",
        _item = task,
        run = function()
            M.show_output(task)
        end,
    }
end

--- The status filter bar — the shared lvim-ui filter-group model, one group with live counts.
--- (`u` for Running: `r` is the row RESTART key, and bar hotkeys are re-mapped over row keys on
--- every header rebuild, so the two must not share a letter.)
---@return table  a `type="bar"` row
local function filter_bar()
    local buttons = {
        { id = "running", label = "Running", key = "u" },
        { id = "failed", label = "Failed", key = "f" },
        { id = "success", label = "Success", key = "s" },
        { id = "all", label = "All", key = "a" },
    }
    local fb = ui_filters.bar({ { id = "status", active = state.filter, buttons = buttons } }, {
        count = function(_, b)
            local n = 0
            for _, t in ipairs(registry.all()) do
                if matches(t, b.id) then
                    n = n + 1
                end
            end
            return n
        end,
        on_select = function(_, id)
            state.filter = id
            M.refresh()
        end,
    })
    return { type = "bar", name = "filter", align = "center", items = fb.band.items }
end

--- Build the tab's rows from the live registry + the active filter.
---@return table[] rows
local function build_rows()
    state.registry = {}
    local tasks = {}
    local namew = 8
    for _, t in ipairs(registry.all()) do
        if matches(t, state.filter) then
            tasks[#tasks + 1] = t
            namew = math.max(namew, vim.fn.strdisplaywidth(t.spec.name or "?"))
        end
    end
    namew = math.min(namew, 32)
    local rows = { filter_bar() }
    for _, t in ipairs(tasks) do
        rows[#rows + 1] = task_row(t, namew)
    end
    if #tasks == 0 then
        rows[#rows + 1] = {
            type = "spacer",
            name = "empty",
            label = state.filter == "all" and "No tasks yet — [n] runs a command" or "No tasks match this filter",
            hl = { inactive = "LvimTasksEmpty" },
        }
    end
    return rows
end

-- ── the focused task / preview ───────────────────────────────────────────────

--- The task under the form cursor (resolved live through the row registry).
---@return LvimTask?
local function cur_task()
    local name = state.handle and state.handle.cursor_name and state.handle.cursor_name()
    return name and state.registry[name] or nil
end

--- Bind the chassis keys buffer-local on a task's OUTPUT buffer, once (the lvim-term pattern: the
--- preview window shows a REAL terminal buffer, which carries none of the frame's scratch-buffer
--- keymaps — without these, focusing the output strands the user there). Normal mode only; the
--- frame is resolved from the live panel handle at press time (the buffer may outlive this open).
---@param buf integer
local function bind_output_keys(buf)
    if vim.b[buf].lvim_tasks_nav then
        return
    end
    vim.b[buf].lvim_tasks_nav = true
    local function map(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
    local function frame()
        local pan = state.preview_pan
        return pan and pan.frame or nil
    end
    map("<C-h>", function()
        local f = frame()
        if f then
            f.panel(-1)
        end
    end, "lvim-tasks: back to the task list")
    map("<C-l>", function()
        local f = frame()
        if f then
            f.panel(1)
        end
    end, "lvim-tasks: next panel")
    map("<C-j>", function()
        local f = frame()
        if f then
            f.sector(1)
        end
    end, "lvim-tasks: next sector")
    map("<C-k>", function()
        local f = frame()
        if f then
            f.sector(-1)
        end
    end, "lvim-tasks: previous sector")
    for _, lhs in ipairs({ "q", "<Esc>" }) do
        map(lhs, function()
            M.close()
        end, "lvim-tasks: close the panel")
    end
end

--- Swap the focused task's terminal buffer into the preview window (live scrollback — it IS the
--- output buffer), or paint the shared empty placeholder when there is nothing to show. Never
--- touches the window while the user is INSIDE it (scrolling the output).
---@param pan table
local function render_preview(pan)
    if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
        return
    end
    if api.nvim_get_current_win() == pan.win then
        return
    end
    local task = cur_task()
    local buf = task and task.bufnr
    if buf and api.nvim_buf_is_valid(buf) then
        bind_output_keys(buf)
        if api.nvim_win_get_buf(pan.win) ~= buf then
            api.nvim_win_set_buf(pan.win, buf)
        end
        vim.wo[pan.win].winhighlight = "Normal:LvimUiPeekNormal,FloatBorder:LvimUiPeekBorder"
        vim.wo[pan.win].number = false
        vim.wo[pan.win].relativenumber = false
        vim.wo[pan.win].signcolumn = "no"
        -- follow the live output: keep the view pinned to the tail
        local last = api.nvim_buf_line_count(buf)
        pcall(api.nvim_win_set_cursor, pan.win, { last, 0 })
    else
        -- fall back to the panel's own scratch buffer for the placeholder (the task buffer may be gone)
        if pan.buf and api.nvim_buf_is_valid(pan.buf) then
            if api.nvim_win_get_buf(pan.win) ~= pan.buf then
                api.nvim_win_set_buf(pan.win, pan.buf)
            end
            uipreview.render_empty(pan.buf, NS, "No output")
        end
    end
end

--- The preview block provider handed to `ui.tabs` (nil when `config.preview` is off).
---@return table?
local function build_preview()
    if not config.preview then
        return nil
    end
    return {
        ---@return integer width, integer height
        size = function()
            return math.max(40, math.floor(vim.o.columns * 0.5)), 12
        end,
        update = render_preview,
        keys = function(_, pan)
            state.preview_pan = pan
        end,
        on_close = function()
            state.preview_pan = nil
        end,
    }
end

--- Open a task's OUTPUT: focus the preview panel on it (the panel is already showing it via the
--- cursor-follow), or — with the preview disabled — show a read-only snapshot in `ui.info`.
---@param task LvimTask
function M.show_output(task)
    local pan = state.preview_pan
    if pan and pan.win and api.nvim_win_is_valid(pan.win) then
        render_preview(pan)
        api.nvim_set_current_win(pan.win)
        return
    end
    local buf = task and task.bufnr
    if not (buf and api.nvim_buf_is_valid(buf)) then
        notify("no output for this task", vim.log.levels.WARN)
        return
    end
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    while #lines > 0 and lines[#lines] == "" do
        lines[#lines] = nil
    end
    ui.info(lines, { title = " " .. (task.spec.name or "task"), hide_cursor = true })
end

-- ── the spinner ──────────────────────────────────────────────────────────────

--- Stop + close the spinner timer.
local function stop_spinner()
    if state.timer then
        pcall(function()
            state.timer:stop()
            state.timer:close()
        end)
        state.timer = nil
    end
end

--- Keep the spinner running exactly while the panel is open AND anything runs: each tick advances
--- the frame and rebuilds the rows in place (`recalc` — the installer's row-spinner pattern).
local function sync_spinner()
    local want = M.is_open() and registry.running_count() > 0
    if want and not state.timer then
        local t = uv.new_timer()
        if t then
            state.timer = t
            t:start(
                120,
                120,
                vim.schedule_wrap(function()
                    if not (M.is_open() and registry.running_count() > 0) then
                        stop_spinner()
                        return
                    end
                    state.spin_i = state.spin_i % #config.spinner + 1
                    M.refresh()
                end)
            )
        end
    elseif not want then
        stop_spinner()
    end
end

-- ── refresh ──────────────────────────────────────────────────────────────────

--- Rebuild the rows from the live registry and re-fit the open panel, keeping the cursor line;
--- the preview follows the (possibly moved) focused row. The ONE repaint path — row actions, the
--- spinner ticks and the LvimTasksChanged events all land here.
function M.refresh()
    if not M.is_open() then
        return
    end
    state.tabs[1].rows = build_rows()
    local idx = state.handle.cursor_index()
    state.handle.recalc()
    state.handle.focus_index(idx)
    if state.preview_pan then
        render_preview(state.preview_pan)
    end
    sync_spinner()
end

-- ── per-row action keys ──────────────────────────────────────────────────────

--- Wire the row action keys on the panel buffer: r restart, x stop, d dispose, e edit-and-rerun.
--- Every key dispatches on the focused row's task; mutations repaint through M.refresh().
---@param buf integer
local function wire_keys(buf)
    local function key(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
    key("r", function()
        local task = cur_task()
        if task then
            runner.restart(task, require("lvim-tasks").on_task_exit)
            M.refresh()
        end
    end, "Restart task")
    key("x", function()
        local task = cur_task()
        if task and task:is_running() then
            runner.stop(task)
            M.refresh()
        end
    end, "Stop task (SIGTERM → SIGKILL)")
    key("d", function()
        local task = cur_task()
        if task then
            if task:is_running() then
                notify("stop the task first (x)", vim.log.levels.WARN)
                return
            end
            registry.dispose(task.id)
            M.refresh()
        end
    end, "Dispose task (drop row + output)")
    key("e", function()
        local task = cur_task()
        if not task then
            return
        end
        local cmd = task.spec.cmd
        ui.input({
            title = " Edit & rerun",
            default = type(cmd) == "table" and table.concat(cmd, " ") or tostring(cmd or ""),
            callback = function(confirmed, value)
                if confirmed ~= true or vim.trim(value or "") == "" then
                    return
                end
                -- inline require: init owns the run flow (registry add + exit glue); circular at load time
                require("lvim-tasks").run({
                    name = value,
                    cmd = value,
                    cwd = task.spec.cwd,
                    env = task.spec.env,
                    matcher = task.spec.matcher,
                    group = task.spec.group,
                })
            end,
        })
    end, "Edit the command and run it as a new task")
end

-- ── footer chips ─────────────────────────────────────────────────────────────

---@return table[]  footer button specs (the ui.tabs per-tab `footer` shape)
local function build_footer()
    return {
        {
            key = "n",
            label = "new",
            run = function()
                ui.input({
                    title = " Run command",
                    callback = function(confirmed, value)
                        if confirmed == true and vim.trim(value or "") ~= "" then
                            require("lvim-tasks").run({ name = value, cmd = value })
                        end
                    end,
                })
            end,
        },
        {
            key = "c",
            label = "clear done",
            run = function()
                registry.clear_done()
                M.refresh()
            end,
        },
        { type = "separator", text = "●", style = { padding = { 1, 1 }, hl = "LvimUiFooterSep" } },
        {
            key = "q/Esc",
            label = "close",
            no_hotkey = true, -- q/<Esc> are the chassis close keys; this chip is a clickable legend
            run = function(st)
                st.close()
            end,
        },
    }
end

-- ── open / close ─────────────────────────────────────────────────────────────

--- Open the task panel.
---@param layout string?  per-open layout override ("float" | "area" | "bottom"; session-sticky)
function M.open(layout)
    if M.is_open() then
        state.handle.close()
        state.handle = nil
    end
    if layout then
        state.layout = layout -- a per-command override is sticky for the session
    end
    state.active_layout = state.layout or config.layout
    state.tabs = {
        {
            label = config.title,
            icon = config.icons.tasks,
            menu = true,
            rows = build_rows(),
            footer = build_footer(),
        },
    }
    state.handle = ui.tabs({
        title = { icon = config.icons.tasks, text = config.title },
        title_pos = config.title_pos,
        title_count = function()
            return { current = registry.running_count(), total = #registry.all() }
        end,
        tabs = state.tabs,
        layout = state.active_layout,
        pad = 0, -- the badges carry their own gutter; the list sits flush
        cursorline_hl = "LvimUiCursorLine",
        preview = build_preview(),
        on_item_change = function()
            if state.preview_pan then
                render_preview(state.preview_pan)
            end
        end,
        on_open = function(buf)
            wire_keys(buf)
        end,
        callback = function()
            stop_spinner()
            state.handle = nil
            state.tabs = nil
            state.preview_pan = nil
            state.registry = {}
        end,
    })
    sync_spinner()
end

--- Close the panel (a no-op when it is not open).
function M.close()
    if M.is_open() then
        state.handle.close()
    end
    stop_spinner()
end

--- Toggle the panel.
---@param layout string?
function M.toggle(layout)
    if M.is_open() then
        M.close()
    else
        M.open(layout)
    end
end

return M
