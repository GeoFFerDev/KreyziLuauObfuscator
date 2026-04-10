-- register_patch.lua
-- Replaces Compiler:setPos() with a version that is aware of both
-- polyCodec (compile-time opcode encoding) and keyedK (runtime key shift).
--
-- HOW TO APPLY:
--   In register.lua, replace the existing `function Compiler:setPos(scope, val)`
--   (lines ~219-228) with the function below.
--
-- Behavior:
--   • usePolyDispatch = true  → val is encoded through polyCodec at compile time
--                              (pos stores the encoded next-block ID)
--   • useKeyedDispatch = true → val is stored as (val + keyedK) % keyedMOD
--                               using a compile-time offset (K is known at
--                               compile time even though it's computed via
--                               opaque predicates at runtime — the actual
--                               numeric value is pre-determined)
--   • Both active simultaneously → poly-encode THEN key-shift
--   • Neither active            → original behavior (raw block ID)
--
-- The nil-val path (end-of-function cleanup via env table indexing) is
-- preserved unchanged.

local Ast = require("prometheus.ast")
local randomStrings = require("prometheus.randomStrings")

-- ── Drop-in replacement ───────────────────────────────────────────────────────
-- Paste this function body into Compiler:setPos() in register.lua.

local function patchedSetPos(self, scope, val)
    -- nil val: existing behavior — sets pos to a dummy env lookup (end of func)
    if not val then
        local v = Ast.IndexExpression(
            self:env(scope),
            randomStrings.randomStringNode(math.random(12, 14)))
        scope:addReferenceToHigherScope(self.containerFuncScope, self.posVar)
        return Ast.AssignmentStatement(
            { Ast.AssignmentVariable(self.containerFuncScope, self.posVar) },
            { v })
    end

    -- Apply compile-time transforms in order: poly first, then key shift.
    local encodedVal = val

    -- 1. Poly-encode: pass block ID through the math handler pipeline
    if self.usePolyDispatch and self.polyCodec then
        encodedVal = self.polyCodec.encode(encodedVal)
    end

    -- 2. Keyed shift: add the runtime key K (known at compile time)
    if self.useKeyedDispatch and self.keyedK then
        local MOD_K = self.keyedMOD or 16777216
        encodedVal  = (encodedVal + self.keyedK) % MOD_K
    end

    scope:addReferenceToHigherScope(self.containerFuncScope, self.posVar)
    return Ast.AssignmentStatement(
        { Ast.AssignmentVariable(self.containerFuncScope, self.posVar) },
        { Ast.NumberExpression(encodedVal) })
end

-- ── Instructions ─────────────────────────────────────────────────────────────
-- In register.lua, inside the `return function(Compiler)` block:
--
--   Replace:
--     function Compiler:setPos(scope, val)
--       if not val then
--         local v = Ast.IndexExpression(self:env(scope), ...)
--         ...
--       end
--       scope:addReferenceToHigherScope(...)
--       return Ast.AssignmentStatement({...}, {Ast.NumberExpression(val) or Ast.NilExpression()})
--     end
--
--   With the patchedSetPos function body above.
--   Alternatively, call this module from register.lua to inject the method:

return function(Compiler)
    -- Override setPos with the codec-aware version
    Compiler.setPos = patchedSetPos
end
