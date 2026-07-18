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
local surface = require("lvim-ui.surface")

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
---@field dock_key string?     the dock ENTRY KEY returned by `dock.open` (passed back to dock.closed)
---@field parking boolean      true while the DOCK is parking us — suppresses the self-close notification
local state = {
    registry = {},
    filter = "all",
    spin_i = 1,
    parking = false,
}

-- The shared dock-stack manager. Optional: without it (an older lvim-utils) the panel still opens — it
-- just does so standalone, outside the stack.
local ok_dock, dock = pcall(require, "lvim-utils.dock")

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
    local k = config.keys
    local buttons = {
        { id = "running", label = "Running" },
        { id = "failed", label = "Failed" },
        { id = "success", label = "Success" },
        { id = "all", label = "All" },
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
    --- Bind one chassis key (a single lhs or a list) on the output buffer.
    ---@param lhs string|string[]|nil
    ---@param fn fun()
    ---@param desc string
    local function map(lhs, fn, desc)
        for _, k in ipairs(type(lhs) == "table" and lhs or { lhs }) do
            if type(k) == "string" and k ~= "" then
                vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
            end
        end
    end
    local function frame()
        local pan = state.preview_pan
        return pan and pan.frame or nil
    end
    --- The chassis nav key `id` as the user has it configured (never a hardcoded copy: a remap in
    --- lvim-ui must reach the output buffer too, or the key that walked IN would not walk back OUT).
    ---@param id string
    ---@return string|string[]|nil
    local function key(id)
        return surface.key(id)
    end

    -- panel_toggle (<Tab>) is the key that FOCUSED this buffer — so it is the one the user reaches
    -- for to leave it. It was missing here, which stranded them in the output: the toggle is bound by
    -- the chassis on its OWN scratch buffers, and a terminal buffer carries none of them.
    map(key("panel_toggle"), function()
        local f = frame()
        if f and f.panel_toggle then
            f.panel_toggle()
        end
    end, "lvim-tasks: back to the task list")
    map(key("panel_prev"), function()
        local f = frame()
        if f then
            f.panel(-1)
        end
    end, "lvim-tasks: back to the task list")
    map(key("panel_next"), function()
        local f = frame()
        if f then
            f.panel(1)
        end
    end, "lvim-tasks: next panel")
    map(key("sector_next"), function()
        local f = frame()
        if f then
            f.sector(1)
        end
    end, "lvim-tasks: next sector")
    map(key("sector_prev"), function()
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
    ui.info(lines, { title = task.spec.name or "task", hide_cursor = true })
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

--- Hand the focused task's OUTPUT to lvim-term as an adopted terminal tab. The preview beside the list is
--- a viewer — you read it; a terminal TAB is a real terminal — you TYPE into it, which is the only way to
--- drive a program that wants input (a watch-mode test runner waiting for a keypress, a REPL, a prompt).
--- lvim-term only views the buffer: the task keeps its job, and closing the tab detaches it.
---@param task LvimTask?
local function open_in_term(task)
    if not (task and task.bufnr and api.nvim_buf_is_valid(task.bufnr)) then
        notify("no output to open (the task has produced none yet)", vim.log.levels.WARN)
        return
    end
    local ok, term = pcall(require, "lvim-term")
    if not ok or type(term.adopt) ~= "function" then
        notify("lvim-term is not installed (it provides the interactive terminal)", vim.log.levels.WARN)
        return
    end
    term.adopt({
        bufnr = task.bufnr,
        job_id = task.job_id,
        name = task.spec.name,
        cwd = task.spec.cwd,
    })
end

--- Wire the row action keys on the panel buffer: r restart, x stop, d dispose, e edit-and-rerun,
--- t open-the-output-as-a-terminal. Every key dispatches on the focused row's task; mutations repaint
--- through M.refresh().
---@param buf integer
local function wire_keys(buf)
    local k = config.keys
    local function key(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
    key(k.terminal, function()
        open_in_term(cur_task())
    end, "Open the output as an interactive terminal (lvim-term)")
    key(k.restart, function()
        local task = cur_task()
        if task then
            runner.restart(task, require("lvim-tasks").on_task_exit)
            M.refresh()
        end
    end, "Restart task")
    key(k.stop, function()
        local task = cur_task()
        if task and task:is_running() then
            runner.stop(task)
            M.refresh()
        end
    end, "Stop task (SIGTERM → SIGKILL)")
    key(k.dispose, function()
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
    key(k.edit, function()
        local task = cur_task()
        if not task then
            return
        end
        local cmd = task.spec.cmd
        ui.input({
            title = "Edit & rerun",
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

-- ── the help window (the canonical cheatsheet) ───────────────────────────────

-- Key id → description, in display order. The keys come from the LIVE `config.keys` (an unset key drops
-- its row), so a rebind is reflected in the cheatsheet.
---@type { [1]: string, [2]: string }[]
local HELP = {
    { "restart", "restart the task" },
    { "stop", "stop the task (SIGTERM → SIGKILL)" },
    { "dispose", "dispose the task (drop row + output)" },
    { "edit", "edit the command and rerun it" },
    { "terminal", "open the output as an interactive terminal" },
    { "new", "run a new command" },
    { "clear_done", "drop every finished task" },
    -- The status filter bar claims no keys: a filter is fired with <CR> on its button (or a click).
    { "help", "this help" },
}

--- The keymap cheatsheet — the shared `lvim-ui.help` component owns the rows, the striping, the colours and
--- the window; this only supplies the plugin's LIVE keys.
local function show_help()
    local items = {}
    for _, e in ipairs(HELP) do
        local lhs = config.keys[e[1]]
        if lhs and lhs ~= "" then
            items[#items + 1] = { lhs, e[2] }
        end
    end
    ui.help({
        title = config.title .. " keymaps",
        items = items,
        close_keys = { "q", "<Esc>", config.keys.help },
    })
end

-- ── footer chips ─────────────────────────────────────────────────────────────

---@return table[]  footer button specs (the ui.tabs per-tab `footer` shape)
local function build_footer()
    local k = config.keys
    return {
        {
            key = k.terminal,
            label = "terminal",
            run = function()
                open_in_term(cur_task())
            end,
        },
        {
            key = k.new,
            label = "new",
            run = function()
                ui.input({
                    title = "Run command",
                    callback = function(confirmed, value)
                        if confirmed == true and vim.trim(value or "") ~= "" then
                            require("lvim-tasks").run({ name = value, cmd = value })
                        end
                    end,
                })
            end,
        },
        {
            key = k.clear_done,
            label = "clear done",
            run = function()
                registry.clear_done()
                M.refresh()
            end,
        },
        { type = "separator", text = "●", style = { padding = { 1, 1 }, hl = "LvimUiFooterSep" } },
        {
            -- The row keys are not discoverable from the list, so the bar has to say where they are written
            -- down. A DISPLAY chip: the real `g?` is a frame-wide keymap (see open_frame), which is what makes
            -- the chassis own the `g` prefix.
            key = k.help,
            label = "help",
            no_hotkey = true,
            run = function()
                show_help()
            end,
        },
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

--- Build + show the frame. The panel's STATE lives in the task registry, never in the frame, so the
--- frame is fully reconstructible — which is what makes the dock's park/restore trivial and lossless:
--- `hide` just tears the window down, `show` rebuilds it from the registry.
---@param layout string?  per-open layout override ("float" | "area" | "bottom"; session-sticky)
local function open_frame(layout)
    if M.is_open() then
        state.parking = true -- a rebuild, not a user close: do not notify the dock
        state.handle.close()
        state.handle = nil
        state.parking = false
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
        -- The cheatsheet is a FRAME-WIDE keymap, not an `on_open` buffer map: only keys the chassis binds
        -- itself land in its `used` set, which is what makes it OWN the `g` chord prefix (so a `g?` typed at
        -- human speed cannot fall through to the builtin `g` once `timeoutlen` expires).
        keymaps = { { key = config.keys.help, run = show_help } },
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
            -- A close the USER drove (q / Esc) must tell the dock, so it can reveal the LIFO-next parked
            -- consumer. A PARK (dock-driven hide) or an internal rebuild must not — hence the guard.
            if ok_dock and state.dock_key and not state.parking then
                local key = state.dock_key
                state.dock_key = nil
                pcall(dock.closed, key)
            end
        end,
    })
    sync_spinner()
end

--- This panel as a dock CONSUMER for `layout` — the contract the shared stack manager drives
--- (lvim-utils.dock). Registering is what lets the global descend key (`<C-j>`) reach the panel from an
--- editor window at all: `dock.descend()` only walks REGISTERED consumers. It also makes the panel share
--- the one-visible-per-layout invariant with the terminal / shell / pickers, instead of overlapping them.
---@param layout string
---@return table
local function consumer(layout)
    return {
        id = "lvim-tasks",
        name = config.title,
        icon = config.icons.tasks,
        layout = layout,
        show = function()
            open_frame(layout)
        end,
        -- PARK: drop the window, keep the state. Nothing is lost — the rows come from the task registry
        -- and each task's output lives in its own terminal buffer, both of which outlive the frame.
        hide = function()
            if M.is_open() then
                state.parking = true
                state.handle.close()
                state.handle = nil
                state.parking = false
            end
            stop_spinner()
        end,
        is_alive = function()
            return true -- the registry IS the state; a parked panel can always be rebuilt
        end,
        close = function()
            if M.is_open() then
                state.parking = true
                state.handle.close()
                state.handle = nil
                state.parking = false
            end
            stop_spinner()
        end,
        focus = function()
            local win = state.handle and state.handle.win and state.handle.win()
            if win and api.nvim_win_is_valid(win) then
                api.nvim_set_current_win(win)
            end
        end,
        -- The global descend lands on the frame's HEADER (its first sector), mirroring the <C-k> escape-up.
        descend = function()
            if state.handle and state.handle.enter then
                state.handle.enter()
            end
        end,
        is_current = function()
            local win = state.handle and state.handle.win and state.handle.win()
            return win ~= nil and win == api.nvim_get_current_win()
        end,
    }
end

--- Open the task panel.
---@param layout string?  per-open layout override ("float" | "area" | "bottom"; session-sticky)
function M.open(layout)
    local target = layout or state.layout or config.layout
    if not ok_dock then
        open_frame(layout) -- no dock manager: standalone, geometry still central
        return
    end
    -- Through the dock: opening in a layout that already holds a terminal / shell / picker PARKS that
    -- occupant rather than overlapping it, and our `show` builds the frame.
    state.dock_key = dock.open(consumer(target))
end

--- Close the panel (a no-op when it is not open).
function M.close()
    if ok_dock and state.dock_key then
        local key = state.dock_key
        state.dock_key = nil
        pcall(dock.close, key)
        stop_spinner()
        return
    end
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
