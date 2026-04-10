-- android_entry.lua
-- Injected globals from Java (ObfuscatorEngine):
--   KREYZI_BASE   : string  — absolute path to extracted lua dir (ends with /)
--   KREYZI_SOURCE : string  — Lua source code to obfuscate
--   KREYZI_CONFIG : string  — Lua chunk returning a config table
--   KREYZI_LUAVER : string or nil — "LuaU" | "Lua51"

local base = KREYZI_BASE

-- LuaJ has no CLI arg table; config.lua iterates it so provide an empty one
if not arg then _G.arg = {} end

-- ── 1. Set up package.path ─────────────────────────────────────────────────
-- require("prometheus")         → base/prometheus.lua
-- require("prometheus.pipeline") → base/prometheus/pipeline.lua
-- require("colors"), etc.       → base/colors.lua
package.path =
    base .. "?.lua;" ..
    base .. "?/init.lua;" ..
    package.path

-- ── 2. Patch debug.getinfo so script_path() helpers work ──────────────────
-- LuaJ standardGlobals() omits the debug lib — ensure the table exists
if type(debug) ~= "table" then
    _G.debug = {}
end
debug = _G.debug  -- re-bind local after possible assignment
local _real_debug_getinfo = debug.getinfo
debug.getinfo = function(level, what)
    if what == "S" then
        return { source = "@" .. base .. "prometheus.lua" }
    end
    if _real_debug_getinfo then
        return _real_debug_getinfo(level, what)
    end
    return {}
end

-- ── 3. Load Prometheus ─────────────────────────────────────────────────────
local ok, Prometheus = pcall(require, "prometheus")
if not ok then
    KREYZI_ERROR  = tostring(Prometheus)
    KREYZI_OUTPUT = nil
    return
end

-- Restore real debug.getinfo now that modules are loaded
if _real_debug_getinfo then
    debug.getinfo = _real_debug_getinfo
end

-- ── 4. Build config from injected Lua chunk ────────────────────────────────
local configFn, err = (loadstring or load)(KREYZI_CONFIG)
if not configFn then
    KREYZI_ERROR  = "Config parse error: " .. tostring(err)
    KREYZI_OUTPUT = nil
    return
end
-- Sandbox: run in empty env (matches cli.lua behaviour)
if setfenv then setfenv(configFn, {}) end

local config = configFn()
if not config then
    KREYZI_ERROR  = "Config returned nil"
    KREYZI_OUTPUT = nil
    return
end

-- Override Lua version if user picked one explicitly
if KREYZI_LUAVER and KREYZI_LUAVER ~= "" then
    config.LuaVersion = KREYZI_LUAVER
end

-- ── 5. Run pipeline ────────────────────────────────────────────────────────
Prometheus.Logger.logLevel = Prometheus.Logger.LogLevel.Info

local pipeline = Prometheus.Pipeline:fromConfig(config)

local status, result = pcall(function()
    return pipeline:apply(KREYZI_SOURCE, "input.lua")
end)

if status then
    KREYZI_OUTPUT = result
    KREYZI_ERROR  = nil
else
    KREYZI_OUTPUT = nil
    KREYZI_ERROR  = tostring(result)
end
