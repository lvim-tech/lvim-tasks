-- lvim-tasks: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it IN PLACE (via
-- lvim-utils.utils.merge), so every require("lvim-tasks.config") reader sees the effective
-- values.
--
---@module "lvim-tasks.config"

---@class LvimTasksConfig
---@field layout          "float"|"area"|"bottom"  Default panel layout
---@field title           string   Panel title
---@field title_pos       "left"|"center"|"right"  Panel title alignment
---@field preview         boolean  Show the focused task's output (its terminal buffer) beside the list
---@field max_history     integer  Live registry cap (oldest disposed task rows drop past this)
---@field dispose_succeeded_after integer?  Seconds after which a SUCCEEDED task is auto-disposed (nil = keep)
---@field persist_history boolean  Persist a task history to disk (sqlite via lvim-utils.store)
---@field qf              boolean  Route problem-matcher results to the quickfix list (styled by lvim-qf-loc)
---@field hud_chip        boolean  Show a "running tasks" chip in the statusline via lvim-hud while any run
---@field vscode_tasks    boolean  Register templates from a project's .vscode/tasks.json
---@field spinner         string[]  Spinner frames for a running task's status icon
---@field icons           table    Status glyphs (Nerd Font single-width)
---@field keys            LvimTasksKeys  The panel's keymaps (row actions, footer chips, the cheatsheet)
---@field colors          table<string, string>  Status accents (lvim-utils palette keys or "#rrggbb")

---@class LvimTasksKeys
---@field help       string  Open the keymap cheatsheet (the set-wide `g?` chord)
---@field terminal   string  Open the focused task's output as an interactive terminal (lvim-term)
---@field restart    string  Restart the focused task
---@field stop       string  Stop the focused task (SIGTERM → SIGKILL)
---@field dispose    string  Dispose the focused task (drop its row + output)
---@field edit       string  Edit the focused task's command and run it as a new task
---@field new        string  Footer: run a new command
---@field filter_running string  Filter bar: show only running tasks
---@field filter_failed  string  Filter bar: show only failed tasks
---@field filter_success string  Filter bar: show only succeeded tasks
---@field filter_all     string  Filter bar: show every task
---@field clear_done string  Footer: drop every finished task row

---@type LvimTasksConfig
return {
    -- Where the task panel opens. Resolved per-command → this → (bottom is the sensible default
    -- for a task list you watch while working).
    layout = "bottom",
    -- Panel border/overlay title (the chassis places it per layout) and its alignment.
    title = "Tasks",
    title_pos = "left",
    -- Show the focused task's OUTPUT — its live terminal buffer — in a preview panel beside the
    -- list (<CR>/<C-l>/<Tab> reach it; it scrolls the real scrollback).
    preview = true,
    -- How many tasks the live registry keeps before dropping the oldest disposed rows.
    max_history = 30,
    -- Auto-dispose a SUCCEEDED task this many seconds after it finished (failed tasks are kept so
    -- you can inspect them). nil = keep succeeded tasks until manually cleared.
    dispose_succeeded_after = 300,
    -- Persist a durable task history to disk (opt-in) — survives restarts, powers `:LvimTasks
    -- history`, "redo last failed", and per-template average duration. Off by default. Needs
    -- sqlite.lua (via lvim-utils.store); degrades to the in-memory registry when absent.
    persist_history = false,
    -- Send problem-matcher results to the quickfix list (native setqflist; lvim-qf-loc styles it).
    qf = true,
    -- A compact "N running" chip in the statusline (lvim-hud overlay) while any task runs.
    hud_chip = true,
    -- Register templates parsed from a project's .vscode/tasks.json (shell/process tasks).
    vscode_tasks = true,
    -- Spinner frames animated on a running task's status cell (single-width braille).
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    -- Status glyphs (single-width Nerd Font).
    icons = {
        tasks = "󰑮", -- the panel / hud chip lead glyph
        pending = "󰔟", -- queued, not yet started
        running = "󰐊", -- overridden by the spinner while active
        success = "󰄬", -- exited 0
        failed = "󰅚", -- exited non-zero
        canceled = "󰜺", -- stopped by the user
    },
    -- The panel's LIVE keys — the row actions, the footer chips and the cheatsheet chord. The `g?` help
    -- window is built from THIS table, so a rebind shows up in it.
    keys = {
        help = "g?", -- the set-wide cheatsheet chord (the panel owns the `g` prefix — see lvim-ui)
        terminal = "t",
        restart = "r",
        stop = "x",
        dispose = "d",
        edit = "e",
        new = "n",
        clear_done = "c",
        -- The status FILTER bar. `u` for Running: `r` is the row RESTART key, and the bar hotkeys are
        -- re-mapped over the row keys on every header rebuild, so the two must not share a letter.
        filter_running = "u",
        filter_failed = "f",
        filter_success = "s",
        filter_all = "a",
    },
    -- Status accents: lvim-utils palette keys (track the live theme) or literal "#rrggbb".
    colors = {
        pending = "blue",
        running = "yellow",
        success = "green",
        failed = "red",
        canceled = "comment",
    },
}
