# lvim-tasks

The task-runner framework of the lvim-tech set: define tasks (command + cwd + env), run them as
jobs with **live terminal output** (full ANSI colour — the output IS a terminal buffer), watch
them in a status panel, restart / stop / dispose them, register reusable **templates**, ingest a
project's **`.vscode/tasks.json`**, and (opt-in) keep a durable **run history** in SQLite. It is
the execution backend of **lvim-build** and a generic "run this and show me" API for any plugin.

- **Tasks** — one spec (`name`, `cmd` argv-or-string, `cwd`, `env`, `matcher`, `group`, `hooks`)
  becomes one job streaming into its OWN terminal buffer (scrollback = the output history). The
  lifecycle is `pending → running → success | failed | canceled`; every transition fires the
  `User LvimTasksChanged` autocmd and the spec's `hooks.on_start/on_output/on_exit`.
- **Panel** (`:LvimTasks`) — one row per task: a status badge (an animated spinner while running),
  the name in its status accent, the template group, the run time, the exit code — and a soft
  **ETA** (`~3.2s`) next to a running task when the history knows its template's average. A
  status **filter bar** with live counts; the border counter shows running/total. The focused
  task's **output** — its live terminal buffer — fills the preview panel beside the list.
- **Problem matchers** — a task with a `matcher` (`gcc`, `rust`, `go`, `typescript`, `python`,
  `pytest`, `lua`, `generic`, or a literal `errorformat`) has its output parsed on exit and pushed
  to the **quickfix list** (the native `setqflist` — lvim-qf-loc styles it when installed), so
  compile errors are clickable. Relative paths in the output are resolved against the TASK's `cwd`
  (via the errorformat directory stack), not the editor's — so a task run in a project root lands
  on the right files no matter where Neovim was started.
- **Templates** — named generators (`condition(ctx)` gates them, `builder(ctx)` produces the
  spec). Registered by you, by lvim-build's detectors, and from `.vscode/tasks.json` (the
  `shell`/`process` types, `${workspaceFolder}` expansion, the `$gcc`-style matcher names).
- **History** (opt-in `persist_history`) — one SQLite row per finished run (own db at
  `stdpath("data")/lvim-tasks/`): `:LvimTasks history` re-runs past commands across restarts,
  `:LvimTasks redo-failed` re-runs the last failure, and per-template average durations feed the
  panel's ETA. Nothing touches the db on the hot path — one insert on exit.
- **Statusline** — `require("lvim-tasks.status").get()` → `{ running, failed, success }` for a
  statusline component; meanwhile a compact "N tasks" chip shows in the lvim-hud overlay while
  anything runs (`hud_chip`).

## Requirements

- Neovim >= 0.11 (`jobstart(…, { term = true })`)
- [lvim-utils](https://github.com/lvim-tech/lvim-utils) (palette / merge / store)
- [lvim-ui](https://github.com/lvim-tech/lvim-ui) (the panel + choosers)
- Optional: [sqlite.lua](https://github.com/kkharji/sqlite.lua) for `persist_history`,
  [lvim-qf-loc](https://github.com/lvim-tech/lvim-qf-loc) for the styled quickfix,
  [lvim-hud](https://github.com/lvim-tech/lvim-hud) for the statusline chip

## Installation

### lvim-installer (recommended)

Install and manage it from the LVIM package manager — open the **Plugins** tab and install /
update / pin it:

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external plugin
manager is needed.

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-tasks" },
})
require("lvim-tasks").setup({})
```

## Usage

```vim
:LvimTasks                   " open the task panel
:LvimTasks bottom            " a layout token (float|area|bottom) anywhere in the args;
                             " a per-command layout is sticky for the session
:LvimTasks toggle            " toggle the panel
:LvimTasks run               " template chooser (condition-filtered, grouped labels)
:LvimTasks run <template>    " run a template by name (completes)
:LvimTasks redo              " re-run the last spec run in this project
:LvimTasks redo-failed       " re-run the most recent FAILED task (registry, then history)
:LvimTasks stop [id]         " stop a running task (default: the most recent one)
:LvimTasks history           " past runs (persist_history) — <CR> re-runs a row
:LvimTasks clear             " dispose every non-running task
```

### Panel keys

| Key | Action |
|---|---|
| `j` / `k` | move between task rows (the preview follows) |
| `<CR>` | open the OUTPUT — focus the preview on the task's terminal buffer |
| `t` | open the output as an **interactive terminal** (lvim-term) — type into the running program |
| `r` | restart the task (fresh output buffer) |
| `x` | stop the task (SIGTERM → SIGKILL escalation) |
| `d` | dispose the task (drop the row + its output) |
| `e` | edit the command and run it as a NEW task |
| `u` / `f` / `s` / `a` | filter: Running / Failed / Success / All (live counts) |
| `n` | new task (type a command) |
| `c` | clear done (dispose every non-running task) |
| `<C-j>` / `<C-k>` | move between sectors (filter bar · list · footer); `<C-k>` at the top leaves the panel |
| `<C-l>` / `<C-h>`, `<Tab>` | move into / out of the output preview |
| `q` / `<Esc>` | close |

### API

```lua
local tasks = require("lvim-tasks")

-- run a spec (returns the live task object)
local t = tasks.run({
    name = "build docs",
    cmd = { "make", "docs" }, -- argv list, or a string through the shell
    cwd = vim.fn.getcwd(),
    env = { FOO = "1" },
    matcher = "gcc", -- builtin name or a literal errorformat
    group = "Build",
    hooks = {
        on_start = function(task) end,
        on_output = function(task, lines) end,
        on_exit = function(task) end, -- task.status / task.exit_code are final here
    },
})

-- register a template (what lvim-build does for every detected action)
tasks.register({
    name = "cargo test",
    desc = "run the test suite",
    group = "Test",
    condition = function(ctx) -- ctx = { file, ft, cwd }
        return vim.fn.filereadable(ctx.cwd .. "/Cargo.toml") == 1
    end,
    builder = function(ctx)
        return { cmd = { "cargo", "test" }, cwd = ctx.cwd, matcher = "rust" }
    end,
})
tasks.run_template("cargo test")

tasks.list() -- every live task, newest first
tasks.get(id)
tasks.stop(id)
tasks.redo()
tasks.redo_failed()
require("lvim-tasks.status").get() -- { running = n, failed = n, success = n }
```

## Setup

The full default configuration (every option at its default):

```lua
require("lvim-tasks").setup({
    -- Where the task panel opens. Resolved per-command → this ("bottom" suits a task list you
    -- watch while working).
    layout = "bottom",
    -- Panel border/overlay title (the chassis places it per layout) and its alignment.
    title = "Tasks",
    title_pos = "left",
    -- Show the focused task's OUTPUT — its live terminal buffer — in a preview panel beside the
    -- list (<CR>/<C-l>/<Tab> reach it; it scrolls the real scrollback).
    preview = true,
    -- How many tasks the live registry keeps before dropping the oldest disposed rows.
    max_history = 30,
    -- Auto-dispose a SUCCEEDED task this many seconds after it finished (failed tasks are kept
    -- so you can inspect them). nil = keep succeeded tasks until manually cleared.
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
})
```

## Persistence

With `persist_history = true` the durable history lives in the plugin's OWN database —
`stdpath("data")/lvim-tasks/lvim-tasks.db` (SQLite via the shared `lvim-utils.store` wrapper,
versioned schema). One row per finished run: template, command, cwd, exit code, duration, started
at. Delete the file to reset it; nothing else is touched. Without sqlite.lua every history call
is a clean no-op.

## Highlights

Self-themed from the lvim-utils palette (re-derived on ColorScheme / palette sync); accents come
from `colors` above. Groups: `LvimTasks{Pending,Running,Success,Failed,Canceled}Badge`,
`LvimTasks{Pending,Running,Success,Failed,Canceled}Name`, `LvimTasksText`, `LvimTasksDim`,
`LvimTasksGroup`, `LvimTasksEta`, `LvimTasksEmpty`.

## Health

```vim
:checkhealth lvim-tasks
```

Reports the Neovim baseline, the lvim-ui / lvim-utils presence, lvim-qf-loc, the sqlite backend
(when `persist_history` is on), the current workspace's `.vscode/tasks.json`, the registry state,
the builtin matcher names, and validates the config.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
