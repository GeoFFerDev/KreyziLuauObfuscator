-- OutputPadding.lua
-- Prometheus Step: pad the output with realistic-looking fake VM handler code.
--
-- Injects a local table of anonymous "opcode handler" functions that look
-- exactly like Vmify's OpcodeDispatch output — indexed tables of arithmetic
-- functions. Analysts waste time tracing these before realising they're dead.
--
-- Built entirely from AST nodes (no parser) so scope chains are always
-- correct regardless of which step runs after this one.
--
-- Settings:
--   PaddingKB   : approximate bytes to add (default 512 KB)
--   Realistic   : true = vary function bodies with 4 templates
--                 false = simpler bodies (faster to generate)
--
-- The padding table is a local variable that is declared but never indexed
-- outside its own declaration, so it contributes zero runtime overhead
-- (the Lua VM/LuaU JIT will trivially discard it).
--
-- NOTE: Run this BEFORE WrapInFunction so the padding ends up inside the
-- wrapper function (otherwise it would be at the very top level of the file,
-- which is fine but slightly more obvious).

local Step  = require("prometheus.step")
local Ast   = require("prometheus.ast")
local Scope = require("prometheus.scope")

local OutputPadding = Step:extend()
OutputPadding.Name        = "OutputPadding"
OutputPadding.Description = "Pads output with realistic-looking fake VM handler code to a target size."

OutputPadding.SettingsDescriptor = {
    -- Target padding size in kilobytes
    PaddingKB = {
        type    = "number",
        default = 512,
        min     = 16,
        max     = 4096,
    },
    -- true  = 4 body templates, randomized constants (more variety, slightly slower)
    -- false = 1 body template (fastest)
    Realistic = {
        type    = "boolean",
        default = true,
    },
}

function OutputPadding:init() end

-- ---- Helpers ---------------------------------------------------------------

local function N(n)   return Ast.NumberExpression(n) end
local function V(s,i) return Ast.VariableExpression(s, i) end

-- Estimate unparsed bytes per handler:
-- Templates 1-4: ~80 chars; templates 5-8: ~110 chars (extra intermediates).
-- Use 95 as a balanced estimate across all 8 patterns.
local CHARS_PER_HANDLER = 95

-- ---- Build one handler function expression ---------------------------------
-- Returns a FunctionLiteralExpression whose scope chains to parentScope.
-- 8 templates cycled randomly to defeat deobfuscator pattern clustering.

local function buildHandler(parentScope, template)
    local fScope = Scope:new(parentScope)
    local aVar   = fScope:addVariable()  -- param a
    local bVar   = fScope:addVariable()  -- param b
    local cVar   = fScope:addVariable()  -- local c
    local dVar   = fScope:addVariable()  -- local d

    local A = math.random(2, 999)
    local B = math.random(1, 999)
    local C = math.random(1, 999)
    local D = math.random(2, 499)
    local E = math.random(1, 999)

    local stmts

    -- 8 templates, varied per handler.
    -- Templates 1–4: classic two-intermediate affine/modulo patterns.
    -- Templates 5–8: deeper chains (3–4 intermediates, quadratic terms,
    --   constant-dominated hash-style) to defeat pattern clustering.
    local t = template or math.random(8)

    if t == 1 then
        -- T1: c = A*a + B;  d = c - C*b;  return d
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {cVar}, {
                Ast.AddExpression(
                    Ast.MulExpression(N(A), V(fScope, aVar)),
                    N(B))
            }),
            Ast.LocalVariableDeclaration(fScope, {dVar}, {
                Ast.SubExpression(
                    V(fScope, cVar),
                    Ast.MulExpression(N(C), V(fScope, bVar)))
            }),
            Ast.ReturnStatement({ V(fScope, dVar) }),
        }

    elseif t == 2 then
        -- T2: c = a + b;  d = c*A - B;  return d
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {cVar}, {
                Ast.AddExpression(V(fScope, aVar), V(fScope, bVar))
            }),
            Ast.LocalVariableDeclaration(fScope, {dVar}, {
                Ast.SubExpression(
                    Ast.MulExpression(V(fScope, cVar), N(A)),
                    N(B))
            }),
            Ast.ReturnStatement({ V(fScope, dVar) }),
        }

    elseif t == 3 then
        -- T3: c = a * b;  d = (c + A) % C;  return d
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {cVar}, {
                Ast.MulExpression(V(fScope, aVar), V(fScope, bVar))
            }),
            Ast.LocalVariableDeclaration(fScope, {dVar}, {
                Ast.ModExpression(
                    Ast.AddExpression(V(fScope, cVar), N(A)),
                    N(C))
            }),
            Ast.ReturnStatement({ V(fScope, dVar) }),
        }

    elseif t == 4 then
        -- T4: c = A + a*b;  d = c - b + B;  return d
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {cVar}, {
                Ast.AddExpression(
                    N(A),
                    Ast.MulExpression(V(fScope, aVar), V(fScope, bVar)))
            }),
            Ast.LocalVariableDeclaration(fScope, {dVar}, {
                Ast.AddExpression(
                    Ast.SubExpression(V(fScope, cVar), V(fScope, bVar)),
                    N(B))
            }),
            Ast.ReturnStatement({ V(fScope, dVar) }),
        }

    elseif t == 5 then
        -- T5: quadratic chain — c = a*a + b;  d = c - a*E;  f = d + C;  return f
        -- (3 intermediates, quadratic term defeats linear-only classifiers)
        local fVar = fScope:addVariable()
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {cVar}, {
                Ast.AddExpression(
                    Ast.MulExpression(V(fScope, aVar), V(fScope, aVar)),
                    V(fScope, bVar))
            }),
            Ast.LocalVariableDeclaration(fScope, {dVar}, {
                Ast.SubExpression(
                    V(fScope, cVar),
                    Ast.MulExpression(V(fScope, aVar), N(E)))
            }),
            Ast.LocalVariableDeclaration(fScope, {fVar}, {
                Ast.AddExpression(V(fScope, dVar), N(C))
            }),
            Ast.ReturnStatement({ V(fScope, fVar) }),
        }

    elseif t == 6 then
        -- T6: deep affine — c = A*a + B;  d = c*b - C;  f = d + D*a;  return f
        -- (4 constants, 3 intermediates, input used twice)
        local fVar = fScope:addVariable()
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {cVar}, {
                Ast.AddExpression(
                    Ast.MulExpression(N(A), V(fScope, aVar)),
                    N(B))
            }),
            Ast.LocalVariableDeclaration(fScope, {dVar}, {
                Ast.SubExpression(
                    Ast.MulExpression(V(fScope, cVar), V(fScope, bVar)),
                    N(C))
            }),
            Ast.LocalVariableDeclaration(fScope, {fVar}, {
                Ast.AddExpression(
                    V(fScope, dVar),
                    Ast.MulExpression(N(D), V(fScope, aVar)))
            }),
            Ast.ReturnStatement({ V(fScope, fVar) }),
        }

    elseif t == 7 then
        -- T7: modulo pipeline — c = a*b;  d = (c+A)%C;  f = d*B + a;  return f
        -- (modulo output imitates hash/checksum logic)
        local fVar = fScope:addVariable()
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {cVar}, {
                Ast.MulExpression(V(fScope, aVar), V(fScope, bVar))
            }),
            Ast.LocalVariableDeclaration(fScope, {dVar}, {
                Ast.ModExpression(
                    Ast.AddExpression(V(fScope, cVar), N(A)),
                    N(C))
            }),
            Ast.LocalVariableDeclaration(fScope, {fVar}, {
                Ast.AddExpression(
                    Ast.MulExpression(V(fScope, dVar), N(B)),
                    V(fScope, aVar))
            }),
            Ast.ReturnStatement({ V(fScope, fVar) }),
        }

    else -- t == 8
        -- T8: constant-dominated "hash" — c = A;  d = a + c;  f = (d-b)*B;  g = f - C;  return g
        -- (4 intermediates, looks like SDBM/FNV hash step)
        local fVar = fScope:addVariable()
        local gVar = fScope:addVariable()
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {cVar}, { N(A) }),
            Ast.LocalVariableDeclaration(fScope, {dVar}, {
                Ast.AddExpression(V(fScope, aVar), V(fScope, cVar))
            }),
            Ast.LocalVariableDeclaration(fScope, {fVar}, {
                Ast.MulExpression(
                    Ast.SubExpression(V(fScope, dVar), V(fScope, bVar)),
                    N(B))
            }),
            Ast.LocalVariableDeclaration(fScope, {gVar}, {
                Ast.SubExpression(V(fScope, fVar), N(C))
            }),
            Ast.ReturnStatement({ V(fScope, gVar) }),
        }
    end

    local body = Ast.Block(stmts, fScope)
    return Ast.FunctionLiteralExpression(
        { V(fScope, aVar), V(fScope, bVar) },
        body,
        fScope)
end

-- ---- Build one "VM module" -------------------------------------------------
-- Emits two nodes:
--   1. local __noiseXXX = K1 * K2 + K3   (looks like a pre-computed seed)
--   2. local __vmXXXX   = { [1]=function..., ... }
--
-- The noise var is never read; it exists to make the module header look like
-- a real constant-pool block that initialises a runtime salt before filling
-- the handler table — exactly what an analyst expects to see.

local function buildVmModule(bodyScope, chunksPerModule, realistic)
    local noiseVarId  = bodyScope:addVariable()
    local tableVarId  = bodyScope:addVariable()

    -- Entropy accumulator declaration (dead, but looks live)
    local nK1 = math.random(0x10, 0xFFFF)
    local nK2 = math.random(0x10, 0xFFFF)
    local nK3 = math.random(1, 0xFFF)
    local noiseDecl = Ast.LocalVariableDeclaration(bodyScope, {noiseVarId}, {
        Ast.AddExpression(
            Ast.MulExpression(N(nK1), N(nK2)),
            N(nK3))
    })

    local entries = {}
    for i = 1, chunksPerModule do
        local tmpl = realistic and math.random(8) or math.random(4)
        local handler = buildHandler(bodyScope, tmpl)
        table.insert(entries, Ast.KeyedTableEntry(N(i), handler))
    end

    local tbl = Ast.TableConstructorExpression(entries)
    local tableDecl = Ast.LocalVariableDeclaration(bodyScope, {tableVarId}, {tbl})

    -- Return both nodes; Apply will insert them sequentially
    return noiseDecl, tableDecl
end

-- ---- Apply -----------------------------------------------------------------

function OutputPadding:apply(ast)
    local bodyScope = ast.body.scope or ast.globalScope

    local targetBytes   = self.PaddingKB * 1024
    local totalHandlers = math.ceil(targetBytes / CHARS_PER_HANDLER)

    -- Split handlers across multiple tables so no single local is enormous.
    -- Each "VM module" table has ~200 handlers (~16KB per table).
    local HANDLERS_PER_MODULE = 200
    local moduleCount = math.ceil(totalHandlers / HANDLERS_PER_MODULE)

    -- Inject padding modules at the top of the script body so they appear
    -- before the actual VM, mimicking the constant-pool header pattern.
    local insertPos = 1
    for m = 1, moduleCount do
        local remaining = totalHandlers - (m - 1) * HANDLERS_PER_MODULE
        local count = math.min(HANDLERS_PER_MODULE, remaining)
        if count <= 0 then break end

        local noiseDecl, tableDecl = buildVmModule(bodyScope, count, self.Realistic)
        table.insert(ast.body.statements, insertPos, noiseDecl)
        insertPos = insertPos + 1
        table.insert(ast.body.statements, insertPos, tableDecl)
        insertPos = insertPos + 1
    end

    return ast
end

return OutputPadding
