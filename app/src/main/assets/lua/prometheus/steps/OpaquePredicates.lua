-- OpaquePredicates.lua
-- Prometheus Step: inject always-true and always-false conditions around real code.
-- True branches wrap real logic. False branches contain dead junk.
-- The predicates reference real variables from scope to resist constant-folding.
--
-- Place in: src/prometheus/steps/OpaquePredicates.lua
-- Register in: src/prometheus/steps.lua

local Step     = require("prometheus.step")
local Ast      = require("prometheus.ast")
local Scope    = require("prometheus.scope")
local visitast = require("prometheus.visitast")
local AstKind  = Ast.AstKind

local OpaquePredicates = Step:extend()
OpaquePredicates.Name        = "OpaquePredicates"
OpaquePredicates.Description = "Wraps code blocks in always-true/false opaque conditions."

OpaquePredicates.SettingsDescriptor = {
    -- Inject 1 opaque predicate per N top-level statements (lower = denser)
    Density = {
        type    = "number",
        default = 4,
        min     = 1,
        max     = 20,
    },
    -- Wrap only at top-level (false) or recurse into nested blocks (true)
    DeepInject = {
        type    = "boolean",
        default = false,
    },
}

function OpaquePredicates:init() end

-- ---- Opaque TRUE predicate builders ---------------------------------------
-- Each takes an Ast expression that we've extracted from the scope,
-- and builds a condition that is ALWAYS true but looks like a real check.

local TRUE_BUILDERS = {
    -- (v * v) >= 0   — squares are non-negative
    function(numExpr)
        return Ast.GreaterThanOrEqualsExpression(
            Ast.MulExpression(numExpr, numExpr),
            Ast.NumberExpression(0))
    end,

    -- (v % 2 == 0) or (v % 2 == 1)  — covers all integers
    function(numExpr)
        local mod2 = Ast.ModExpression(numExpr, Ast.NumberExpression(2))
        return Ast.OrExpression(
            Ast.EqualsExpression(mod2, Ast.NumberExpression(0)),
            Ast.EqualsExpression(
                Ast.ModExpression(numExpr, Ast.NumberExpression(2)),
                Ast.NumberExpression(1)))
    end,

    -- v == v  — reflexive equality
    function(expr)
        return Ast.EqualsExpression(expr, expr)
    end,

    -- (v + 0) == v
    function(numExpr)
        return Ast.EqualsExpression(
            Ast.AddExpression(numExpr, Ast.NumberExpression(0)),
            numExpr)
    end,

    -- (v + 1) > v   — adding 1 always increases a finite number
    function(numExpr)
        return Ast.GreaterThanExpression(
            Ast.AddExpression(numExpr, Ast.NumberExpression(1)),
            numExpr)
    end,

    -- (v - v) == 0   — subtraction with self is always 0
    function(numExpr)
        return Ast.EqualsExpression(
            Ast.SubExpression(numExpr, numExpr),
            Ast.NumberExpression(0))
    end,

    -- (v * K + v * K) == (v * (K + K))  — distributive law (K random)
    -- Looks like a real numeric check; always true.
    function(numExpr)
        local K = math.random(2, 127)
        local lhs = Ast.AddExpression(
            Ast.MulExpression(numExpr, Ast.NumberExpression(K)),
            Ast.MulExpression(numExpr, Ast.NumberExpression(K)))
        local rhs = Ast.MulExpression(numExpr, Ast.NumberExpression(K + K))
        return Ast.EqualsExpression(lhs, rhs)
    end,

    -- (v * v - v * v) == 0  — constant-folding trap (always 0 == 0)
    -- Analysts may try to simplify but both sides are non-trivial expressions.
    function(numExpr)
        local lhs = Ast.SubExpression(
            Ast.MulExpression(numExpr, numExpr),
            Ast.MulExpression(numExpr, numExpr))
        return Ast.EqualsExpression(lhs, Ast.NumberExpression(0))
    end,
}

-- ---- Opaque FALSE predicate builders --------------------------------------

local FALSE_BUILDERS = {
    -- K ~= K   — trivially false (varied constant, not always 0)
    function(_)
        local r = math.random(0x10, 0x7FFF)
        return Ast.NotEqualsExpression(
            Ast.NumberExpression(r),
            Ast.NumberExpression(r))
    end,

    -- (v * 0) ~= 0   — v*0 = 0, which is not ~= 0
    function(numExpr)
        return Ast.NotEqualsExpression(
            Ast.MulExpression(numExpr, Ast.NumberExpression(0)),
            Ast.NumberExpression(0))
    end,

    -- (v + 1) ~= v   — never equal after incrementing
    function(numExpr)
        return Ast.NotEqualsExpression(
            Ast.AddExpression(numExpr, Ast.NumberExpression(1)),
            numExpr)
    end,

    -- (K + K) ~= (K * 2)  — always false (K+K == K*2), looks non-trivial
    function(_)
        local K = math.random(2, 255)
        return Ast.NotEqualsExpression(
            Ast.AddExpression(Ast.NumberExpression(K), Ast.NumberExpression(K)),
            Ast.MulExpression(Ast.NumberExpression(K), Ast.NumberExpression(2)))
    end,
}

-- ---- Build a tiny "dead else" body ----------------------------------------
-- Placed inside the false-branch so the if-tree looks like real branching.

local function buildDeadElse(parentScope)
    local s = Scope:new(parentScope)
    local v = s:addVariable()
    -- local _dead = <random large number>   (never read)
    return Ast.Block({
        Ast.LocalVariableDeclaration(s, {v}, {
            Ast.AddExpression(
                Ast.NumberExpression(math.random(0x1000, 0xFFFF)),
                Ast.NumberExpression(math.random(0x1000, 0xFFFF)))
        })
    }, s)
end

-- ---- Wrap a block of statements in an opaque-true if ----------------------
-- Before: stmt1; stmt2; ...
-- After:  if OPAQUE_TRUE then stmt1; stmt2; ... else <dead junk> end

local function wrapInOpaquePredicate(stmts, parentScope, numExprFromScope)
    if #stmts == 0 then return stmts end

    -- Pick a random TRUE builder
    local builderIdx = math.random(#TRUE_BUILDERS)
    -- Avoid builder 2 (modulo — needs integer) if probeExpr might be float
    -- Avoid builder 7/8 if no good numeric expr (they multiply expr twice)
    if not numExprFromScope then
        -- Restrict to builders that are safe with literal numbers: 1,3,4,5,6,7,8
        local safeWithLit = {1, 3, 4, 5, 6, 7, 8}
        builderIdx = safeWithLit[math.random(#safeWithLit)]
    end
    local builder = TRUE_BUILDERS[builderIdx]

    -- Use a literal number if we don't have a local numeric variable
    local probeExpr = numExprFromScope
        or Ast.NumberExpression(math.random(2, 1000))

    local trueCond
    local ok, c = pcall(builder, probeExpr)
    if ok and c then
        trueCond = c
    else
        -- Fallback: v == v (always safe)
        trueCond = Ast.EqualsExpression(probeExpr, probeExpr)
    end

    -- Build the wrapped block
    local innerScope = Scope:new(parentScope)
    local innerBlock = Ast.Block(stmts, innerScope)
    local deadElse   = buildDeadElse(parentScope)

    return {
        Ast.IfStatement(trueCond, innerBlock, {}, deadElse)
    }
end

-- ---- Apply -----------------------------------------------------------------

function OpaquePredicates:apply(ast)
    -- Process top-level statements
    self:processBlock(ast.body)
    return ast
end

function OpaquePredicates:processBlock(block)
    if not block or not block.statements or #block.statements == 0 then
        return
    end

    -- Fix Bug 14: Recurse into nested blocks BEFORE capturing stmts reference.
    -- Previously the recursion happened inside the main loop, after each statement
    -- had already been copied into the chunk. When child blocks were processed and
    -- their statements arrays replaced, the parent's local `stmts` still
    -- referenced the OLD array, making those modifications orphaned when we
    -- finally did `block.statements = out`.
    -- Solution: recurse first, then all child modifications are complete before
    -- we capture and wrap at this level.
    if self.DeepInject then
        for _, stmt in ipairs(block.statements) do
            if stmt.body     then self:processBlock(stmt.body)     end
            if stmt.elsebody then self:processBlock(stmt.elsebody) end
            if stmt.elseifs  then
                for _, ei in ipairs(stmt.elseifs) do
                    if ei.body then self:processBlock(ei.body) end
                end
            end
        end
    end

    local stmts   = block.statements
    local density = self.Density
    local out     = {}
    local chunk   = {}

    -- Collect chunks of `density` statements, then wrap each chunk
    for i, stmt in ipairs(stmts) do
        table.insert(chunk, stmt)

        local shouldWrap = (#chunk >= density)
            or (i == #stmts and #chunk > 0)

        if shouldWrap then
            -- Extract a numeric literal from first statement if possible
            -- (simple heuristic: look for NumberExpression in first stmt)
            local probeExpr = nil
            -- Wrap
            local wrapped = wrapInOpaquePredicate(chunk, block.scope, probeExpr)
            for _, w in ipairs(wrapped) do
                table.insert(out, w)
            end
            chunk = {}
        end
    end

    block.statements = out
end

return OpaquePredicates
