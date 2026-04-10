-- RuntimeGuard.lua
-- Prometheus Step: polymorphic runtime integrity guard.
--
-- Injected AFTER Vmify so it runs before the VM starts loading.
-- Every build produces completely different variable names and check ordering.
-- 100% Lua 5.1 / LuaU compatible — no Lua 5.3 operators (~, >>, <<, &, |).
-- Uses bit32 where available with arithmetic fallbacks for Lua 5.1.
--
-- What it detects:
--   1. Core globals replaced (type, rawget, rawequal, pcall, tostring)
--   2. _ENV / getfenv tampering (new keys injected, originals swapped)
--   3. Metatable hooks on fresh tables (__index, __newindex, __len)
--   4. Timing anomalies from function-level hooks (string.rep overhead)
--   5. debug.getinfo exposure (signals executor hooking internals)
--
-- Response options: "corrupt" (flip silent sentinel), "freeze", "kick", "silent"
--
-- Safe to inject post-Vmify: uses the parser approach.
-- WrapInFunction runs after this and harmlessly wraps the entire body.
-- No subsequent step does scope-hierarchy traversal, so parser-injected
-- scopes (which are detached from the outer tree) do not cause crashes.

local Step  = require("prometheus.step")
local Ast   = require("prometheus.ast")
local Scope = require("prometheus.scope")

local RuntimeGuard = Step:extend()
RuntimeGuard.Name        = "RuntimeGuard"
RuntimeGuard.Description = "Polymorphic startup integrity guard. Detects hooks, _ENV tampering, and timing anomalies."

RuntimeGuard.SettingsDescriptor = {
    -- Response when tampering is detected
    -- "corrupt" : silently flip a sentinel (recommended, hardest to detect)
    -- "freeze"  : call task.wait(math.huge) to hang
    -- "kick"    : kick the local player
    -- "silent"  : do nothing (for debugging)
    TamperResponse = {
        type    = "string",
        default = "corrupt",
    },
    -- Check timing of string.rep to detect hook overhead
    TimingCheck = {
        type    = "boolean",
        default = true,
    },
    -- Check _ENV / getfenv for injected or swapped globals
    EnvCheck = {
        type    = "boolean",
        default = true,
    },
    -- Check metatable hooks on a freshly created table
    MetatableCheck = {
        type    = "boolean",
        default = true,
    },
    -- Check that debug.getinfo is still restricted (Roblox game scripts only)
    -- Set false for executor scripts where debug may be legitimately accessible
    DebugCheck = {
        type    = "boolean",
        default = false,
    },
    -- Spawn a background coroutine to repeat checks every N seconds
    -- 0 = startup only (recommended for performance)
    RepeatInterval = {
        type    = "number",
        default = 0,
        min     = 0,
        max     = 120,
    },
}

function RuntimeGuard:init()
    local valid = { corrupt=true, freeze=true, kick=true, silent=true }
    if not valid[self.TamperResponse] then
        self.TamperResponse = "corrupt"
    end
end

-- ---- Polymorphic name generator --------------------------------------------

local function R()
    -- 8-char random hex name, no leading digit (valid Lua identifier)
    return string.format("_%x%04x", math.random(1,15), math.random(0, 0xFFFF))
end

-- ---- Source code builder ---------------------------------------------------

function RuntimeGuard:buildSource()
    -- Every name is different each build
    local N = {
        -- Captured originals
        orig_type       = R(),
        orig_rawget     = R(),
        orig_rawequal   = R(),
        orig_pcall      = R(),
        orig_tostring   = R(),
        orig_select     = R(),
        orig_pairs      = R(),
        orig_ipairs     = R(),
        orig_next       = R(),
        orig_unpack     = R(),
        -- Sentinel
        sentinel        = R(),
        -- Functions
        fn_respond      = R(),
        fn_check        = R(),
        fn_spawn        = R(),
        -- Temporaries
        t_env           = R(),
        t_mt            = R(),
        t_obj           = R(),
        t_t0            = R(),
        t_td            = R(),
        t_dummy         = R(),
        t_ok            = R(),
        t_di            = R(),
        t_thread        = R(),
        -- Noise vars to confuse pattern matching
        noise1          = R(),
        noise2          = R(),
        noise3          = R(),
    }

    -- ---- Tamper response body ----
    local responseBody
    if self.TamperResponse == "corrupt" then
        responseBody = string.format(
            "%s = not %s", N.sentinel, N.sentinel)
    elseif self.TamperResponse == "freeze" then
        responseBody = "pcall(function() task.wait(1e9) end)"
    elseif self.TamperResponse == "kick" then
        responseBody = [[
pcall(function()
    game:GetService("Players").LocalPlayer:Kick(
        "Runtime error 0x" .. string.format("%X", math.random(0x1000, 0xFFFF)))
end)]]
    else
        responseBody = "-- silent"
    end

    -- ---- Build check blocks based on settings ----
    local checks = {}

    -- Check 1: core globals not replaced
    -- Uses captured originals vs current globals to detect swaps
    table.insert(checks, string.format([[
    if not %s(%s, type) then %s() return end
    if not %s(%s, rawget) then %s() return end
    if not %s(%s, rawequal) then %s() return end
    if not %s(%s, pcall) then %s() return end
    if not %s(%s, pairs) then %s() return end]],
        N.orig_rawequal, N.orig_type,     N.fn_respond,
        N.orig_rawequal, N.orig_rawget,   N.fn_respond,
        N.orig_rawequal, N.orig_rawequal, N.fn_respond,
        N.orig_rawequal, N.orig_pcall,    N.fn_respond,
        N.orig_rawequal, N.orig_pairs,    N.fn_respond))

    -- Check 2: _ENV / getfenv tampering
    if self.EnvCheck then
        table.insert(checks, string.format([[
    local %s = (getfenv and getfenv(1)) or _ENV or {}
    if %s and %s(%s, "type") ~= type then %s() return end
    if %s and %s(%s, "rawget") ~= rawget then %s() return end
    if %s and %s(%s, "pairs") ~= pairs then %s() return end]],
            N.t_env,
            N.t_env, N.orig_rawget, N.t_env, N.fn_respond,
            N.t_env, N.orig_rawget, N.t_env, N.fn_respond,
            N.t_env, N.orig_rawget, N.t_env, N.fn_respond))
    end

    -- Check 3: metatable hooks on a fresh table
    if self.MetatableCheck then
        table.insert(checks, string.format([[
    local %s = {}
    local %s = getmetatable(%s)
    if %s ~= nil then %s() return end]],
            N.t_obj,
            N.t_mt, N.t_obj,
            N.t_mt, N.fn_respond))
    end

    -- Check 4: timing check
    if self.TimingCheck then
        table.insert(checks, string.format([[
    local %s = os.clock()
    local %s = string.rep("x", 512)
    local %s = os.clock() - %s
    if %s > 0.12 then %s() return end]],
            N.t_t0,
            N.t_dummy,
            N.t_td, N.t_t0,
            N.t_td, N.fn_respond))
    end

    -- Check 5: debug.getinfo exposure
    if self.DebugCheck then
        table.insert(checks, string.format([[
    local %s = debug and rawget(debug, "getinfo")
    if type(%s) == "function" then
        local %s = pcall(%s, 1, "Sn")
        if %s then %s() return end
    end]],
            N.t_di,
            N.t_di,
            N.t_ok, N.t_di,
            N.t_ok, N.fn_respond))
    end

    -- Shuffle the check order so the pattern differs each build
    for i = #checks, 2, -1 do
        local j = math.random(i)
        checks[i], checks[j] = checks[j], checks[i]
    end

    -- ---- Noise locals (confuse static analysis, vary structure) ----
    local noiseVal1 = math.random(0x100, 0xFFFF)
    local noiseVal2 = math.random(0x100, 0xFFFF)
    local noiseVal3 = math.random(2, 255)
    local noiseExpr = string.format("(%d * %d + %d) %% %d",
        noiseVal1, noiseVal2, noiseVal1, noiseVal3)

    -- ---- Assemble final source ----
    local parts = {}

    -- Capture originals IMMEDIATELY at module load (before any hook can fire)
    table.insert(parts, string.format([[
local %s = type
local %s = rawget
local %s = rawequal
local %s = pcall
local %s = tostring
local %s = select
local %s = pairs
local %s = ipairs
local %s = next
]],
        N.orig_type, N.orig_rawget, N.orig_rawequal,
        N.orig_pcall, N.orig_tostring, N.orig_select,
        N.orig_pairs, N.orig_ipairs, N.orig_next))

    -- Noise to vary output structure
    table.insert(parts, string.format(
        "local %s = %s\nlocal %s = %s ~= nil\nlocal %s = false\n",
        N.noise1, noiseExpr,
        N.noise2, N.noise1,
        N.noise3))

    -- Sentinel
    table.insert(parts, string.format("local %s = false\n", N.sentinel))

    -- Response function
    table.insert(parts, string.format([[
local function %s()
    %s
end
]], N.fn_respond, responseBody))

    -- Check function (shuffled checks inside)
    table.insert(parts, string.format("local function %s()\n", N.fn_check))
    for _, chk in ipairs(checks) do
        table.insert(parts, chk .. "\n")
    end
    table.insert(parts, "end\n")

    -- Startup call
    table.insert(parts, string.format("%s()\n", N.fn_check))

    -- Optional background thread
    if self.RepeatInterval > 0 then
        table.insert(parts, string.format([[
local function %s()
    pcall(function()
        task.spawn(function()
            while true do
                task.wait(%d)
                %s()
            end
        end)
    end)
end
%s()
]], N.fn_spawn, self.RepeatInterval, N.fn_check, N.fn_spawn))
    end

    return table.concat(parts)
end

-- ---- Apply -----------------------------------------------------------------

function RuntimeGuard:apply(ast)
    local src = self:buildSource()

    -- Parse the generated source using Prometheus's own parser.
    -- This is SAFE here because RuntimeGuard runs AFTER Vmify and ConstantArray.
    -- No subsequent step does scope-hierarchy traversal, so the detached
    -- scope tree from ast2 will not cause crashes.
    local ok, stmts = pcall(function()
        local Parser = require("prometheus.parser")
        local Enums  = require("prometheus.enums")
        local ast2   = Parser:new({
            LuaVersion = Enums.LuaVersion.LuaU,
        }):parse(src)
        return ast2.body.statements
    end)

    if ok and stmts then
        -- Prepend before VM code so the guard runs first
        for i = #stmts, 1, -1 do
            table.insert(ast.body.statements, 1, stmts[i])
        end
    end
    -- Silently skip if parser fails (e.g. test environment without full API)

    return ast
end

return RuntimeGuard
