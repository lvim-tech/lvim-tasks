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
---@field colors          table<string, string>  Status accents (lvim-utils palette keys or "#rrggbb")

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
    -- Status accents: lvim-utils palette keys (track the live theme) or literal "#rrggbb".
    colors = {
        pending = "blue",
        running = "yellow",
        success = "green",
        failed = "red",
        canceled = "comment",
    },
}
