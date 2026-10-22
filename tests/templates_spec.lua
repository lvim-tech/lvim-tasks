-- The template registry: what the chooser offers, in what order, and what a built spec carries.
--
-- `condition` and `builder` are USER hooks (a template of their own, an lvim-build entry, a
-- .vscode/tasks.json row). One that throws must cost that template its place in the list and
-- nothing else — a chooser that dies on a bad condition takes `:LvimTasks run` completion with it.

local templates = require("lvim-tasks.templates")

local NAMES = {}

--- Register a template for the duration of the suite and remember to drop it.
---@param t table
local function temp(t)
    NAMES[#NAMES + 1] = t.name
    templates.register(t)
    return t
end

--- Names of the applicable templates, in the order offered.
---@param ctx table?
---@return string[]
local function offered(ctx)
    return vim.tbl_map(function(t)
        return t.name
    end, templates.applicable(ctx))
end

describe("lvim-tasks.templates: the registry")

it("registers by name and replaces on a second registration", function()
    temp({ name = "lvim-test-a", desc = "first", builder = function() end })
    eq("first", templates.get("lvim-test-a").desc)
    templates.register({ name = "lvim-test-a", desc = "second", builder = function() end })
    eq("second", templates.get("lvim-test-a").desc, "one entry per name, the newer one")
end)

it("ignores a malformed registration instead of storing it", function()
    local before = #templates.applicable({})
    templates.register(nil)
    templates.register({ desc = "no name" })
    templates.register("not a table")
    eq(before, #templates.applicable({}), "nothing was added")
end)

it("forgets what it unregisters", function()
    temp({ name = "lvim-test-gone", builder = function() end })
    truthy(templates.get("lvim-test-gone") ~= nil)
    templates.unregister("lvim-test-gone")
    eq(nil, templates.get("lvim-test-gone"))
end)

describe("lvim-tasks.templates.applicable")

it("offers only the templates whose condition passes", function()
    temp({ name = "lvim-test-yes", builder = function() end, condition = function()
        return true
    end })
    temp({ name = "lvim-test-no", builder = function() end, condition = function()
        return false
    end })
    local list = offered({})
    truthy(vim.tbl_contains(list, "lvim-test-yes"), "the passing one is missing")
    truthy(not vim.tbl_contains(list, "lvim-test-no"), "the failing one was offered")
end)

it("treats a condition that returns anything but true as a no", function()
    temp({ name = "lvim-test-truthy", builder = function() end, condition = function()
        return "yes please"
    end })
    truthy(not vim.tbl_contains(offered({}), "lvim-test-truthy"), "only a real `true` counts")
end)

it("drops a template whose condition THROWS, and keeps the rest", function()
    temp({ name = "lvim-test-throws", builder = function() end, condition = function()
        error("a user hook blew up")
    end })
    temp({ name = "lvim-test-survives", builder = function() end })
    local list = offered({})
    truthy(not vim.tbl_contains(list, "lvim-test-throws"), "the thrower was offered anyway")
    truthy(vim.tbl_contains(list, "lvim-test-survives"), "it took the others down with it")
end)

it("sorts by group, then by name", function()
    temp({ name = "b-second", group = "Alpha", builder = function() end })
    temp({ name = "a-first", group = "Alpha", builder = function() end })
    temp({ name = "z-later", group = "Beta", builder = function() end })
    local list = offered({})
    local seen = {}
    for i, n in ipairs(list) do
        seen[n] = i
    end
    truthy(seen["a-first"] < seen["b-second"], "name order within a group")
    truthy(seen["b-second"] < seen["z-later"], "group order before name order")
end)

describe("lvim-tasks.templates.build")

it("stamps the template name on the spec it built", function()
    temp({ name = "lvim-test-build", group = "Build", builder = function()
        return { cmd = { "true" } }
    end })
    local spec = templates.build("lvim-test-build", {})
    eq("lvim-test-build", spec.template, "the history needs to know which template ran")
    eq("lvim-test-build", spec.name, "a spec with no name of its own takes the template's")
    eq("Build", spec.group)
end)

it("keeps the spec's own name and group when it has them", function()
    temp({ name = "lvim-test-named", group = "Build", builder = function()
        return { cmd = { "true" }, name = "my run", group = "Run" }
    end })
    local spec = templates.build("lvim-test-named", {})
    eq("my run", spec.name)
    eq("Run", spec.group)
    eq("lvim-test-named", spec.template)
end)

it("says nothing for a name nobody registered, or a builder that returns nothing", function()
    eq(nil, templates.build("lvim-test-no-such", {}))
    temp({ name = "lvim-test-nil", builder = function()
        return nil
    end })
    eq(nil, templates.build("lvim-test-nil", {}))
end)

describe("lvim-tasks.history: a no-op when there is nowhere to write")

local history = require("lvim-tasks.history")

it("list() answers with a table, never nil", function()
    eq("table", type(history.list()))
end)

it("avg_duration asks for a template", function()
    eq(nil, history.avg_duration(nil))
end)

it("record() leaves a transient task alone", function()
    local ok, err = pcall(history.record, {
        spec = { transient = true },
        exit_code = 0,
        status = "success",
        duration_ms = function()
            return 1
        end,
    })
    truthy(ok, tostring(err))
end)

if history.available and history.available() then
    it("averages the successful runs of a template", function()
        -- Only meaningful with a store: the suite's XDG homes are a throwaway directory, so this
        -- writes nowhere near the real history.
        local function task(ms, status)
            return {
                spec = { template = "lvim-test-avg", name = "t", cmd = { "true" } },
                exit_code = status == "success" and 0 or 1,
                status = status,
                started_epoch = 0,
                duration_ms = function()
                    return ms
                end,
            }
        end
        history.record(task(100, "success"))
        history.record(task(300, "success"))
        history.record(task(999, "failed"))
        eq(200, history.avg_duration("lvim-test-avg"), "the failed run must not count")
    end)
else
    skip("averages the successful runs of a template", "durable history is unavailable (no sqlite backend)")
end

for _, name in ipairs(NAMES) do
    templates.unregister(name)
end
