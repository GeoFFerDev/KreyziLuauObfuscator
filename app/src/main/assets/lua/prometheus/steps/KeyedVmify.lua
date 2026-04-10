-- KeyedVmify.lua
-- Prometheus obfuscation step: Environment-Fingerprinted Keyed Execution VM.
--
-- ╔══════════════════════════════════════════════════════════════╗
-- ║  UNIQUE CONCEPT: Opaque-Predicate Runtime Key               ║
-- ║                                                              ║
-- ║  A session key K is computed ONCE at VM boot from a chain   ║
-- ║  of opaque boolean predicates. Every pos-assignment stores  ║
-- ║  (next_id + K) % MOD instead of next_id. Dispatch decodes  ║
-- ║  by subtracting K: _ops[(pos - K + MOD) % MOD]()           ║
-- ║                                                              ║
-- ║  Protection properties:                                      ║
-- ║  • K is always the same value at runtime (predicates are    ║
-- ║    tautologies), but static analysis cannot determine K     ║
-- ║    without evaluating type(), select(), math.*, etc.        ║
-- ║  • K is split across 4–8 additive shares masked by opaque  ║
-- ║    conditions, so no single expression reveals K.           ║
-- ║  • The handler table is keyed by REAL block IDs; the key    ║
-- ║    shift only applies to pos values in the bytecode stream. ║
-- ║  • Combine with PolyVmify (DualKeyedVmify) for double       ║
-- ║    protection: poly-encode the IDs AND key-shift the pos.   ║
-- ╚══════════════════════════════════════════════════════════════╝
--
-- Additional: EpochMutation mode (optional).
-- When enabled, K is re-mixed with an instruction counter C every
-- EPOCH_LEN dispatches via: K = (K * PRIME + C) % MOD
-- This provides time-based opcode mutation without breaking correctness
-- because the mutation is deterministic and pre-computed per block.

local Step       = require("prometheus.step")
local Compiler   = require("prometheus.compiler.compiler")
local TransformCodec = require("prometheus.compiler.transform_codec")

local KeyedVmify = Step:extend()
KeyedVmify.Name        = "KeyedVmify"
KeyedVmify.Description =
    "Compiles to a custom VM where pos values are additively shifted by a " ..
    "runtime key K derived from opaque predicates. K is always a fixed " ..
    "value but requires full Lua environment evaluation to determine, " ..
    "defeating static bytecode analysis. Optional epoch mutation adds " ..
    "time-based opcode reshuffling."

KeyedVmify.SettingsDescriptor = {
    -- Number of opaque key shares (more = harder to reconstruct K statically)
    KeyShares = {
        type    = "number",
        default = 6,
        min     = 3,
        max     = 12,
    },
    -- Fake opcode handlers (adds noise to the dispatch table)
    FakeOpcodeCount = {
        type    = "number",
        default = 15,
        min     = 0,
        max     = 200,
    },
    StatefulFakeOps = {
        type    = "boolean",
        default = true,
    },
    -- When true, K is re-mixed every EpochLen dispatches (time-based mutation)
    EpochMutation = {
        type    = "boolean",
        default = false,
    },
    -- Epoch length for mutation (dispatches between key re-mixes)
    EpochLen = {
        type    = "number",
        default = 128,
        min     = 16,
        max     = 4096,
    },
    -- Optionally stack a PolyVmify pipeline on top of the keyed shift
    PolyLayer = {
        type    = "boolean",
        default = false,
    },
    PolyDepth = {
        type    = "number",
        default = 2,
        min     = 1,
        max     = 4,
    },
}

function KeyedVmify:init() end

-- Generate opaque predicate Lua source that evaluates to a fixed integer value.
-- The predicates use type(), math/table/string library presence, and arithmetic
-- tautologies that are always true but look dynamic to static analysis.
-- Returns { src_lines, value } where src_lines is a table of Lua statement
-- strings and value is the sum (used as the key contribution from this share).
local function makeOpaqueShare(varName, targetVal)
    local MOD = 16777216
    targetVal = targetVal % MOD

    -- Split targetVal into A + B + C where opaque conditions gate each part
    -- A: from type(table) == "table" tautology
    -- B: from type(math) == "table" tautology
    -- C: remainder
    local A = math.random(1, math.floor(targetVal / 2) + 1)
    local B = math.random(0, targetVal - A)
    local C = (targetVal - A - B + MOD * 2) % MOD

    -- Each share uses a different opaque wrapper
    local wrappers = {
        -- type(table) is always "table"
        function(val)
            return ("(type(table) == \"table\" and %d or 0)"):format(val)
        end,
        -- type(math) is always "table"
        function(val)
            return ("(type(math) == \"table\" and %d or 0)"):format(val)
        end,
        -- type(string) is always "table"
        function(val)
            return ("(type(string) == \"table\" and %d or 0)"):format(val)
        end,
        -- 1+1 == 2 is always true
        function(val)
            return ("(1 + 1 == 2 and %d or 0)"):format(val)
        end,
        -- type(type) is always "function"
        function(val)
            return ("(type(type) == \"function\" and %d or 0)"):format(val)
        end,
        -- math.huge > 0 is always true
        function(val)
            return ("(math.huge > 0 and %d or 0)"):format(val)
        end,
        -- #\"\" == 0 is always true
        function(val)
            return ("(#\"\" == 0 and %d or 0)"):format(val)
        end,
        -- type(pcall) is always "function"
        function(val)
            return ("(type(pcall) == \"function\" and %d or 0)"):format(val)
        end,
    }

    local wa = wrappers[math.random(#wrappers)]
    local wb = wrappers[math.random(#wrappers)]
    local wc = wrappers[math.random(#wrappers)]

    local line = ("local %s = (%s + %s + %s) %% %d"):format(
        varName, wa(A), wb(B), wc(C), MOD)

    return line, targetVal
end

-- Build the full key derivation block as a Lua source string.
-- Returns: { src (multiline string), K (the actual numeric key value) }
function KeyedVmify:buildKeyDerivationSrc(numShares, keyVarName)
    local MOD = 16777216
    local shares = {}
    local shareVars = {}
    local totalK = 0
    local lines = {}

    for i = 1, numShares do
        local shareVal = math.random(1, MOD - 1)
        local sVarName = ("_ks%d"):format(i)
        local line, val = makeOpaqueShare(sVarName, shareVal)
        table.insert(lines, line)
        table.insert(shareVars, sVarName)
        totalK = (totalK + val) % MOD
    end

    -- Final key: sum of all shares mod MOD
    local sumExpr = table.concat(shareVars, " + ")
    table.insert(lines, ("local %s = (%s) %% %d"):format(keyVarName, sumExpr, MOD))

    return table.concat(lines, "\n"), totalK
end

function KeyedVmify:apply(ast)
    local numShares = self.KeyShares
    local KEY_VAR   = "_vmK"    -- name of the key variable in generated code
    local MOD       = 16777216

    -- Pre-compute the actual K value (deterministic sum of opaque shares)
    -- We need this at compile time to offset all pos assignments.
    -- Generate shares now:
    local shareVals = {}
    local totalK    = 0
    for i = 1, numShares do
        local v = math.random(1, MOD - 1)
        shareVals[i] = v
        totalK = (totalK + v) % MOD
    end

    -- Optional poly-layer on top
    local polyCodec = nil
    if self.PolyLayer and self.PolyDepth > 0 then
        local tc = TransformCodec.new(self.PolyDepth)
        -- Wrap as plain-function table so .encode() / .decode() work
        -- without OOP colon-call syntax (register_patch and emit_poly both
        -- call codec.encode(x) not codec:encode(x))
        polyCodec = {
            encode = function(id) return tc:encode(id) end,
            decode = function(id) return tc:decode(id) end,
            MOD    = tc.MOD,
        }
    end

    local compiler = Compiler:new({
        useKeyedDispatch  = true,
        keyedK            = totalK,
        keyedKShares      = shareVals,
        keyedKeyVar       = KEY_VAR,
        keyedMOD          = MOD,
        keyedEpoch        = self.EpochMutation,
        keyedEpochLen     = self.EpochLen,
        fakeOpcodeCount   = self.FakeOpcodeCount,
        statefulFakeOps   = self.StatefulFakeOps,
        polyCodec         = polyCodec,  -- nil unless PolyLayer=true
        usePolyDispatch   = self.PolyLayer,
    })

    return compiler:compile(ast)
end

return KeyedVmify
