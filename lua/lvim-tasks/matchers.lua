-- lvim-tasks.matchers: problem matchers — a task's output → structured locations.
-- A matcher is an `errorformat` string (or a named built-in). On a task's exit its terminal
-- buffer's lines are parsed with `getqflist({ efm = …, lines = … })` and the results are pushed
-- to the QUICKFIX list via the native setqflist — which lvim-qf-loc styles into its list UI. No
-- direct coupling to lvim-qf-loc: populating the standard quickfix is the seam.
--
---@module "lvim-tasks.matchers"

local api = vim.api
local fn = vim.fn
local config = require("lvim-tasks.config")

local M = {}

-- Built-in errorformat presets, keyed by matcher name. `%f` file, `%l` line, `%c` col, `%m` msg.
---@type table<string, string>
local BUILTIN = {
    -- gcc/clang: `file:line:col: error: message`
    gcc = [[%f:%l:%c: %t%*[^:]: %m,%f:%l: %t%*[^:]: %m]],
    -- rustc: `error[E0001]: msg` then ` --> file:line:col`
    rust = [[%Eerror[E%n]: %m,%Eerror: %m,%Wwarning: %m,%C %#--> %f:%l:%c,%C%m]],
    -- go build: `file:line:col: message`
    go = [[%f:%l:%c: %m,%f:%l: %m]],
    -- tsc: `file(line,col): error TSxxxx: message`
    typescript = [[%f(%l\,%c): %*[^:]: %m]],
    -- python traceback: `  File "file", line N, in fn` (+ plain SyntaxError locations)
    python = [[%*\sFile "%f"\, line %l\, in %m,%*\sFile "%f"\, line %l]],
    -- pytest: it does NOT print a traceback for a failing assert — it prints its own failure
    -- footer `tests/test_x.py:2: AssertionError` (and a traceback only for collection/import
    -- errors), so the `python` matcher finds nothing in a pytest run. Both forms here.
    pytest = [[%f:%l: %m,%*\sFile "%f"\, line %l\, in %m,%*\sFile "%f"\, line %l]],
    -- lua / luajit runtime + compile errors: `lua: file:line: message` (any leading runner name)
    lua = [[%*[^:]: %f:%l: %m,%f:%l: %m]],
    -- eslint/generic `file:line:col`
    generic = [[%f:%l:%c: %m,%f:%l: %m,%f: %m]],
}

--- Resolve a matcher name/errorformat to an actual errorformat string.
---@param matcher string
---@return string?
local function efm_of(matcher)
    if not matcher or matcher == "" then
        return nil
    end
    -- A name maps to a built-in; anything else is treated as a literal errorformat.
    return BUILTIN[matcher] or matcher
end

--- Parse a finished task's output with its matcher and push the results to the quickfix list.
--- No-op when the task has no matcher, config.qf is off, or nothing parsed.
---@param task LvimTask
function M.apply(task)
    if not config.qf or not task.spec.matcher then
        return
    end
    local efm = efm_of(task.spec.matcher)
    if not efm then
        return
    end
    if not task.bufnr or not api.nvim_buf_is_valid(task.bufnr) then
        return
    end
    local lines = api.nvim_buf_get_lines(task.bufnr, 0, -1, false)
    -- Strip trailing blank scrollback so the parse isn't diluted.
    while #lines > 0 and lines[#lines] == "" do
        lines[#lines] = nil
    end
    if #lines == 0 then
        return
    end
    -- A task runs in ITS OWN cwd, which is usually NOT Neovim's — so the relative `%f` paths a
    -- compiler/test runner prints (`tests/test_x.py:2: …`) would be resolved against the editor's
    -- cwd and point at files that do not exist. Vim's own mechanism for this is the errorformat
    -- DIRECTORY STACK: `%D` pushes a directory that subsequent relative names resolve against. So
    -- the parse is fed one synthetic "Entering directory" line, exactly as `make -w` emits.
    if task.spec.cwd and task.spec.cwd ~= "" then
        efm = [[%DEntering directory '%f',]] .. efm
        table.insert(lines, 1, ("Entering directory '%s'"):format(task.spec.cwd))
    end
    local parsed = fn.getqflist({ efm = efm, lines = lines })
    local items = (type(parsed) == "table" and parsed.items) or {}
    -- Keep only entries that resolved to a real location (bufnr/lnum) — efm emits filler rows.
    local located = {}
    for _, it in ipairs(items) do
        if (it.bufnr and it.bufnr > 0) or (it.lnum and it.lnum > 0) then
            located[#located + 1] = it
        end
    end
    if #located == 0 then
        return
    end
    fn.setqflist({}, "r", {
        title = ("lvim-tasks: %s"):format(task.spec.name or "task"),
        items = located,
    })
end

--- The built-in matcher names (for docs / health).
---@return string[]
function M.builtins()
    local out = {}
    for name in pairs(BUILTIN) do
        out[#out + 1] = name
    end
    table.sort(out)
    return out
end

return M
