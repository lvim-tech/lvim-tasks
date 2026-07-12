-- lvim-tasks.parsers.vscode: a project's `.vscode/tasks.json` → lvim-tasks templates.
-- Supports the common subset: the `shell` and `process` task types (command + args + options.cwd
-- / options.env), the task `group` (build/test → the display group), and the `$gcc`-style named
-- problem matchers (mapped onto the matchers.lua builtins). tasks.json is JSONC in the wild, so a
-- small string-aware scanner strips comments and trailing commas before `vim.json.decode` — a
-- regex pass would eat `//` inside command strings (URLs).
--
-- `ensure()` is called lazily by the choosers (and completion): it re-scans only when the file's
-- mtime changes and unregisters templates whose task rows disappeared, so the template registry
-- always mirrors the file with zero autocmds.
--
---@module "lvim-tasks.parsers.vscode"

local templates = require("lvim-tasks.templates")

local M = {}

-- The named problem matchers we can honour, mapped onto the matchers.lua builtins.
---@type table<string, string>
local MATCHER_MAP = {
    ["$gcc"] = "gcc",
    ["$rustc"] = "rust",
    ["$go"] = "go",
    ["$tsc"] = "typescript",
    ["$tsc-watch"] = "typescript",
    ["$eslint-compact"] = "generic",
    ["$eslint-stylish"] = "generic",
    ["$msCompile"] = "generic",
}

---@type string?  the tasks.json path of the last scan
local scanned_path = nil
---@type integer?  its mtime seconds at that scan
local scanned_mtime = nil
---@type string[]  template names registered by the last scan (unregistered on re-scan)
local registered = {}

--- Strip JSONC-isms so `vim.json.decode` accepts the file: `//` + `/* */` comments OUTSIDE
--- strings, then trailing commas before `]`/`}`. A character scanner, not a regex — a URL inside
--- a command string must survive.
---@param text string
---@return string
local function sanitize(text)
    local out, i, n = {}, 1, #text
    local in_str, esc = false, false
    while i <= n do
        local ch = text:sub(i, i)
        if in_str then
            out[#out + 1] = ch
            if esc then
                esc = false
            elseif ch == "\\" then
                esc = true
            elseif ch == '"' then
                in_str = false
            end
            i = i + 1
        elseif ch == '"' then
            in_str = true
            out[#out + 1] = ch
            i = i + 1
        elseif ch == "/" and text:sub(i + 1, i + 1) == "/" then
            i = (text:find("\n", i, true) or n + 1) -- keep the newline (line numbers/structure)
        elseif ch == "/" and text:sub(i + 1, i + 1) == "*" then
            local close = text:find("*/", i + 2, true)
            i = close and (close + 2) or (n + 1)
        else
            out[#out + 1] = ch
            i = i + 1
        end
    end
    local joined = table.concat(out)
    -- trailing commas: `, ]` / , }` (whitespace between) are invalid JSON but common JSONC
    joined = joined:gsub(",(%s*[%]}])", "%1")
    return joined
end

--- Substitute the supported `${…}` variables in a string.
---@param s string
---@param root string  the workspace folder
---@return string
local function expand(s, root)
    local map = {
        workspaceFolder = root,
        workspaceFolderBasename = vim.fs.basename(root),
        file = vim.api.nvim_buf_get_name(0),
        cwd = vim.fn.getcwd(),
    }
    return (s:gsub("%${([%w]+)}", function(k)
        return map[k] or ("${" .. k .. "}")
    end))
end

--- The workspace root owning a `.vscode/tasks.json` for the current buffer/cwd, or nil.
---@return string? root, string? path
local function find()
    local root = vim.fs.root(0, ".vscode")
    if not root then
        return nil, nil
    end
    local path = root .. "/.vscode/tasks.json"
    if vim.fn.filereadable(path) == 0 then
        return nil, nil
    end
    return vim.fs.normalize(root), path
end

--- The display group for a task's `group` field ("build"/"test" or `{ kind = … }`).
---@param g any
---@return string?
local function group_of(g)
    local kind = type(g) == "table" and g.kind or g
    if kind == "build" then
        return "Build"
    elseif kind == "test" then
        return "Test"
    end
    return nil
end

--- One tasks.json task record → a registered template (nil when the type is unsupported).
---@param t table
---@param root string
---@return LvimTaskTemplate?
local function to_template(t, root)
    if type(t) ~= "table" or type(t.label) ~= "string" then
        return nil
    end
    local ttype = t.type or "shell"
    if ttype ~= "shell" and ttype ~= "process" then
        return nil
    end
    if type(t.command) ~= "string" then
        return nil
    end
    local matcher
    local pm = t.problemMatcher
    if type(pm) == "string" then
        matcher = MATCHER_MAP[pm]
    elseif type(pm) == "table" then
        for _, m in ipairs(pm) do
            matcher = MATCHER_MAP[m]
            if matcher then
                break
            end
        end
    end
    local name = "vscode: " .. t.label
    return {
        name = name,
        desc = t.detail,
        group = group_of(t.group),
        condition = function()
            -- applicable while the SAME workspace still carries the file (a cwd change away
            -- from the project drops these templates from the chooser without a re-scan)
            return (select(1, find())) == root
        end,
        builder = function()
            local opts = type(t.options) == "table" and t.options or {}
            local cwd = type(opts.cwd) == "string" and expand(opts.cwd, root) or root
            local env
            if type(opts.env) == "table" then
                env = {}
                for k, v in pairs(opts.env) do
                    env[k] = expand(tostring(v), root)
                end
            end
            local cmd
            if ttype == "process" then
                cmd = { expand(t.command, root) }
                for _, a in ipairs(type(t.args) == "table" and t.args or {}) do
                    cmd[#cmd + 1] = expand(tostring(a), root)
                end
            else
                -- shell: one command line through the user's shell; args with spaces are quoted
                local parts = { expand(t.command, root) }
                for _, a in ipairs(type(t.args) == "table" and t.args or {}) do
                    local s = expand(tostring(a), root)
                    if s:find("%s") then
                        s = '"' .. s .. '"'
                    end
                    parts[#parts + 1] = s
                end
                cmd = table.concat(parts, " ")
            end
            return { name = t.label, cmd = cmd, cwd = cwd, env = env, matcher = matcher }
        end,
    }
end

--- Sync the template registry with the current workspace's tasks.json: scan on first call and
--- whenever the file's mtime changes; unregister the previous scan's templates first. Safe to
--- call often (one `stat` on the fast path).
function M.ensure()
    local _, path = find()
    local mtime = nil
    if path then
        local st = (vim.uv or vim.loop).fs_stat(path)
        mtime = st and st.mtime.sec or nil
    end
    if path == scanned_path and mtime == scanned_mtime then
        return
    end
    for _, name in ipairs(registered) do
        templates.unregister(name)
    end
    registered = {}
    scanned_path, scanned_mtime = path, mtime
    if not path then
        return
    end
    local root = vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(path)))
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
        return
    end
    local dok, doc = pcall(vim.json.decode, sanitize(table.concat(lines, "\n")))
    if not dok or type(doc) ~= "table" then
        vim.notify("lvim-tasks: could not parse " .. path, vim.log.levels.WARN)
        return
    end
    for _, t in ipairs(type(doc.tasks) == "table" and doc.tasks or {}) do
        local tpl = to_template(t, root)
        if tpl then
            templates.register(tpl)
            registered[#registered + 1] = tpl.name
        end
    end
end

--- Whether the current workspace has a parseable tasks.json (for :checkhealth).
---@return boolean has, string? path
function M.detect()
    local _, path = find()
    return path ~= nil, path
end

return M
