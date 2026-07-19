-- lvim-tasks.templates: the named task-template registry.
-- A template is a generator: `{ name, desc?, group?, builder(ctx) -> spec|nil, condition(ctx) ->
-- boolean }`. Users register their own; lvim-build registers detected build/run/test actions
-- through the public API; the optional .vscode/tasks.json parser registers project tasks. The
-- chooser lists the templates whose `condition(ctx)` passes for the current context.
--
---@module "lvim-tasks.templates"

local M = {}

---@class LvimTaskTemplate
---@field name      string
---@field desc      string?
---@field group     string?
---@field builder   fun(ctx: table): LvimTaskSpec|nil  produce the concrete spec at run time
---@field condition (fun(ctx: table): boolean)?         when the template applies (default: always)

---@type table<string, LvimTaskTemplate>
local registry = {}

--- Register (or replace) a template by name.
---@param template LvimTaskTemplate
function M.register(template)
    if type(template) == "table" and type(template.name) == "string" then
        registry[template.name] = template
    end
end

--- Remove a template.
---@param name string
function M.unregister(name)
    registry[name] = nil
end

--- A template by name.
---@param name string
---@return LvimTaskTemplate?
function M.get(name)
    return registry[name]
end

--- The build context passed to `condition`/`builder`: the current file, filetype and cwd.
---@return table
function M.context()
    local file = vim.api.nvim_buf_get_name(0)
    return {
        file = file,
        ft = vim.bo.filetype,
        cwd = vim.uv and vim.uv.cwd() or vim.loop.cwd(),
    }
end

--- Templates applicable to `ctx` (condition passes), sorted by group then name.
---@param ctx table?
---@return LvimTaskTemplate[]
function M.applicable(ctx)
    ctx = ctx or M.context()
    local out = {}
    for _, t in pairs(registry) do
        -- `condition` is a USER hook (a template / lvim-build entry); a throw would break the whole chooser
        -- AND `:LvimTasks run` completion, so pcall it like every other user hook in the plugin.
        local ok = true
        if type(t.condition) == "function" then
            local pok, res = pcall(t.condition, ctx)
            ok = pok and res == true
        end
        if ok then
            out[#out + 1] = t
        end
    end
    table.sort(out, function(a, b)
        if (a.group or "") ~= (b.group or "") then
            return (a.group or "") < (b.group or "")
        end
        return a.name < b.name
    end)
    return out
end

--- Build a concrete spec from a template name for the current context, stamping the template name.
---@param name string
---@param ctx table?
---@return LvimTaskSpec?
function M.build(name, ctx)
    local t = registry[name]
    if not t or type(t.builder) ~= "function" then
        return nil
    end
    local spec = t.builder(ctx or M.context())
    if type(spec) ~= "table" then
        return nil
    end
    spec.name = spec.name or t.name
    spec.template = t.name
    spec.group = spec.group or t.group
    return spec
end

return M
