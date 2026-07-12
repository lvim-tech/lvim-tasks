-- lvim-tasks: :checkhealth lvim-tasks.
-- Diagnoses what makes the runner misbehave invisibly: the Neovim baseline (`jobstart(…, term =
-- true)`), the lvim-ui / lvim-utils chassis the panel is built on, the quickfix styling companion
-- (lvim-qf-loc, optional), the sqlite backend when the durable history is opted in, the current
-- workspace's .vscode/tasks.json, and a config sanity pass. Read-only reporting — never mutates
-- config or state.
--
---@module "lvim-tasks.health"

local config = require("lvim-tasks.config")

local M = {}

--- Validate the live config table; error per violation, ok when clean.
---@param health table  the vim.health reporter
local function check_config(health)
    local problems = 0
    local layouts = { float = true, area = true, bottom = true }
    if not layouts[config.layout] then
        problems = problems + 1
        health.error(("config.layout '%s' is not one of float/area/bottom"):format(tostring(config.layout)))
    end
    if type(config.max_history) ~= "number" or config.max_history < 1 then
        problems = problems + 1
        health.error("config.max_history must be a positive number")
    end
    local dsa = config.dispose_succeeded_after
    if dsa ~= nil and (type(dsa) ~= "number" or dsa < 0) then
        problems = problems + 1
        health.error("config.dispose_succeeded_after must be nil or a non-negative number of seconds")
    end
    if type(config.spinner) ~= "table" or #config.spinner == 0 then
        problems = problems + 1
        health.error("config.spinner must be a non-empty list of frames")
    end
    if problems == 0 then
        health.ok("config valid")
    end
end

--- Run the health report.
function M.check()
    local health = vim.health
    health.start("lvim-tasks")

    if vim.fn.has("nvim-0.11") == 1 then
        health.ok("Neovim >= 0.11")
    else
        health.error("Neovim >= 0.11 is required (jobstart term = true, vim.fs.root)")
    end

    -- the ecosystem the panel is built on
    local ok_ui = pcall(require, "lvim-ui")
    local ok_utils = pcall(require, "lvim-utils.utils")
    if ok_ui and ok_utils then
        health.ok("lvim-ui + lvim-utils found (panel / palette / store)")
    else
        health.error("lvim-ui / lvim-utils not found — the task panel cannot open")
    end

    -- matcher results go to the NATIVE quickfix; lvim-qf-loc styles it when present
    if pcall(require, "lvim-qf-loc") then
        health.ok("lvim-qf-loc found — matcher results get its list UI")
    else
        health.info("lvim-qf-loc not found — matcher results use the plain quickfix list")
    end

    -- the live registry
    local registry = require("lvim-tasks.registry")
    local matchers = require("lvim-tasks.matchers")
    health.info(("%d task(s) in the registry, %d running"):format(#registry.all(), registry.running_count()))
    health.info("builtin matchers: " .. table.concat(matchers.builtins(), ", "))

    -- durable history (opt-in): sqlite via lvim-utils.store
    if config.persist_history then
        local ok_store, store = pcall(require, "lvim-utils.store")
        if ok_store then
            store.health(health, false)
        end
        local history = require("lvim-tasks.history")
        if history.active() then
            health.ok("persistent history active")
        else
            health.warn("persist_history is on but the store did not open — history stays in-memory")
        end
    else
        health.info("persistent history is off (config.persist_history = false)")
    end

    -- the vscode tasks bridge
    if config.vscode_tasks then
        local has, path = require("lvim-tasks.parsers.vscode").detect()
        if has then
            health.ok(".vscode/tasks.json found: " .. tostring(path))
        else
            health.info("no .vscode/tasks.json in this workspace")
        end
    else
        health.info("vscode task ingestion is off (config.vscode_tasks = false)")
    end

    check_config(health)
end

return M
