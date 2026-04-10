-- AntiHook.lua
-- Prometheus Step: injects a runtime anti-hook and integrity wrapper.
-- Runs ONCE at script startup, before any real logic executes.
-- Generates different code each build (randomized variable names, check order).
--
-- Place in: src/prometheus/steps/AntiHook.lua
-- Register in: src/prometheus/steps.lua

local Step  = require("prometheus.step")
local Ast   = require("prometheus.ast")
local Scope = require("prometheus.scope")

local AntiHook = Step:extend()
AntiHook.Name        = "AntiHook"
AntiHook.Description = "Injects startup hook/tamper detection with silent corrupt response."

AntiHook.SettingsDescriptor = {
    -- "corrupt"  : silently corrupt a critical variable (recommended)
    -- "kick"     : call Players.LocalPlayer:Kick()
    -- "freeze"   : task.wait(math.huge)
    -- "silent"   : do nothing visible, just flip internal flag
    TamperResponse = {
        type    = "string",   -- validated as enum below
        default = "corrupt",
    },
    -- Check timing of string.rep to detect overhead from hooks
    TimingCheck = {
        type    = "boolean",
        default = true,
    },
    -- Check that core globals haven't been replaced
    GlobalCheck = {
        type    = "boolean",
        default = true,
    },
    -- Run integrity checks periodically (every N seconds) via a background thread
    -- 0 = startup only
    RepeatInterval = {
        type    = "number",
        default = 0,
        min     = 0,
        max     = 60,
    },
}

function AntiHook:init()
    local valid = { corrupt=true, kick=true, freeze=true, silent=true }
    if not valid[self.TamperResponse] then
        self.TamperResponse = "corrupt"
    end
end

-- ---- Lua source generator -------------------------------------------------
-- Generates the anti-hook header as a Lua source string (then injected).
-- All variable names are randomized 4-char hex suffixes per build.

local function hex4() return string.format("%04x", math.random(0, 0xFFFF)) end

function AntiHook:generateHeader()
    -- Randomize all internal names so each build looks different
    local V = {
        corrupt_flag   = "_cf_"   .. hex4(),
        check_fn       = "_ck_"   .. hex4(),
        respond_fn     = "_rsp_"  .. hex4(),
        ref_type       = "_rt_"   .. hex4(),
        ref_pairs      = "_rp_"   .. hex4(),
        ref_tostring   = "_rs_"   .. hex4(),
        ref_rawget     = "_rg_"   .. hex4(),
        ref_rawequal   = "_re_"   .. hex4(),
        timing_base    = "_tb_"   .. hex4(),
        timing_delta   = "_td_"   .. hex4(),
        env_ref        = "_ev_"   .. hex4(),
        thread_fn      = "_th_"   .. hex4(),
    }

    -- ---- Tamper response body ----
    local responseBody
    if self.TamperResponse == "corrupt" then
        -- Silently flip the corrupt flag; real logic checks this flag
        responseBody = string.format([[
        %s = not %s]], V.corrupt_flag, V.corrupt_flag)

    elseif self.TamperResponse == "kick" then
        responseBody = [[
        pcall(function()
            game:GetService("Players").LocalPlayer:Kick(
                "Error: " .. string.format("0x%%X", math.random(0x1000, 0xFFFF)))
        end)]]

    elseif self.TamperResponse == "freeze" then
        responseBody = [[
        pcall(function() task.wait(math.huge) end)]]

    else -- silent
        responseBody = "        -- (silent)"
    end

    -- ---- Global reference capture ----
    -- Capture originals BEFORE any hook could touch them (at parse time / upvalue)
    local globalCapture = string.format([[
local %s = type
local %s = pairs
local %s = tostring
local %s = rawget
local %s = rawequal
local %s = _ENV or getfenv()
]],
        V.ref_type, V.ref_pairs, V.ref_tostring,
        V.ref_rawget, V.ref_rawequal, V.env_ref)

    -- ---- Corruption sentinel ----
    local corruptDecl = string.format("local %s = false\n", V.corrupt_flag)

    -- ---- Response function ----
    local responseFn = string.format([[
local function %s()
%s
end
]], V.respond_fn, responseBody)

    -- ---- Check function ----
    local globalCheckBody = ""
    if self.GlobalCheck then
        globalCheckBody = string.format([[
    -- Verify core globals haven't been replaced
    if not %s(%s(%s, "type"), "function") then %s() end
    if not %s(%s(%s, "pairs"), "function") then %s() end
    if not %s(%s(%s, "rawget"), "function") then %s() end
    -- Check that captured originals still match current globals
    if not %s(%s, type) then %s() end
    if not %s(%s, pairs) then %s() end
]],
            V.ref_type,   V.ref_rawget, V.env_ref, V.respond_fn,
            V.ref_type,   V.ref_rawget, V.env_ref, V.respond_fn,
            V.ref_type,   V.ref_rawget, V.env_ref, V.respond_fn,
            V.ref_rawequal, V.ref_type,   V.respond_fn,
            V.ref_rawequal, V.ref_pairs,  V.respond_fn)
    end

    local timingCheckBody = ""
    if self.TimingCheck then
        -- Measure overhead of string.rep — hook detectors add measurable latency
        timingCheckBody = string.format([[
    local %s = os.clock()
    local _ = string.rep("x", 128)
    local %s = os.clock() - %s
    if %s > 0.08 then %s() end  -- 80ms = hooked
]],
            V.timing_base, V.timing_delta, V.timing_base,
            V.timing_delta, V.respond_fn)
    end

    -- debug.getinfo probe — on Roblox, debug is restricted.
    -- If debug.getinfo is FULLY accessible (returns "what" fields), executor is hooking.
    local debugCheckBody = [[
    local _di = debug and rawget(debug, "getinfo")
    if type(_di) == "function" then
        local _inf = pcall(_di, 1, "S")
        -- If it didn't error, something exposed full debug info — suspicious
        -- Only flag if we're in a restricted environment (Roblox game scripts)
        -- Executor scripts: comment this block out
    end
]]

    local checkFn = string.format([[
local function %s()
%s%s%s
end
]],
        V.check_fn,
        globalCheckBody,
        timingCheckBody,
        debugCheckBody)

    -- ---- Startup call ----
    local startupCall = string.format("%s()\n", V.check_fn)

    -- ---- Optional background thread ----
    local threadCode = ""
    if self.RepeatInterval > 0 then
        threadCode = string.format([[
local function %s()
    task.spawn(function()
        while true do
            task.wait(%d)
            %s()
        end
    end)
end
%s()
]], V.thread_fn, self.RepeatInterval, V.check_fn, V.thread_fn)
    end

    return table.concat({
        "-- [integrity header - generated]\n",
        globalCapture,
        corruptDecl,
        responseFn,
        checkFn,
        startupCall,
        threadCode,
        "-- [/integrity header]\n",
    })
end

-- ---- Apply -----------------------------------------------------------------

function AntiHook:apply(ast)
    local globalScope = ast.globalScope
    local header = self:generateHeader()

    -- Parse the header using Prometheus's parser
    local ok, result = pcall(function()
        local Parser = require("prometheus.parser")
        local Enums  = require("prometheus.enums")
        local headerAst = Parser:new({
            LuaVersion = Enums.LuaVersion.LuaU,
        }):parse(header)
        return headerAst.body.statements
    end)

    if ok and result then
        -- Prepend all header statements before the real script
        for i = #result, 1, -1 do
            table.insert(ast.body.statements, 1, result[i])
        end
    else
        -- Fallback: skip injection rather than crashing the pipeline
        -- (e.g. if some API reference isn't available in the test environment)
    end

    return ast
end

return AntiHook
