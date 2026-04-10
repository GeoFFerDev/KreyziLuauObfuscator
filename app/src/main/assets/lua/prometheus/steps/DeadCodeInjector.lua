-- DeadCodeInjector.lua
-- Prometheus Step: inject dead functions, fake branches, and misleading logic.
-- All injected code is syntactically valid but never executed.
--
-- Place in: src/prometheus/steps/DeadCodeInjector.lua
-- Register in: src/prometheus/steps.lua

local Step     = require("prometheus.step")
local Ast      = require("prometheus.ast")
local Scope    = require("prometheus.scope")
local visitast = require("prometheus.visitast")
local AstKind  = Ast.AstKind

local DeadCodeInjector = Step:extend()
DeadCodeInjector.Name        = "DeadCodeInjector"
DeadCodeInjector.Description = "Injects dead functions and fake branches to waste analyst time."

DeadCodeInjector.SettingsDescriptor = {
    FakeFunctionCount = { type="number", default=6,  min=0, max=30 },
    FakeBranchCount   = { type="number", default=10, min=0, max=50 },
    -- Style: "math" | "roblox" | "mixed"
    -- "roblox" references game APIs to look like real game code
}

function DeadCodeInjector:init() end

-- Random 4-char hex suffix for uniqueness (kept for buildDeadBoolDecl)
local function nameSuffix()
    return string.format("%04x", math.random(0, 0xFFFF))
end


-- ---- Build dead function AST node directly from AST constructors ----------
-- We do NOT use the Prometheus parser here. Parsing generates a fresh
-- ast2.globalScope that is structurally detached from the outer script's
-- scope tree. Even after re-parenting the top-level scope, inner nested
-- scopes (argScope, loopScope) remain orphaned. When Vmify later visits
-- those nodes, compile_top.lua line 43 does:
--   node.scope.__depth < data.functionData.depth
-- and crashes with "attempt to compare nil with number" because __depth
-- was never set on those inner scopes (they never appeared in the outer
-- script's visitast walk that sets __depth).
--
-- Building with Scope:new(parentScope) directly guarantees every scope
-- chains correctly through the outer script's scope tree from the start.

local function buildDeadFunctionNode(template, globalScope, parentScope)
    -- Function variable lives in parentScope (visible to outer block)
    local funcId    = parentScope:addVariable()
    -- Function's own inner scope (args + locals): child of parentScope
    local funcScope = Scope:new(parentScope)

    -- Pick a random template index (1-4) to vary dead func bodies
    local pick = math.random(4)

    local stmts = {}

    if pick == 1 then
        -- local function __deadXXXX(a, b)
        --     local c = (a * 0x1A) + b
        --     if c > 0xFFFF then c = c - 0xFFFF end
        --     return c
        -- end
        local aVar = funcScope:addVariable()
        local bVar = funcScope:addVariable()
        local cVar = funcScope:addVariable()

        local ifScope = Scope:new(funcScope)
        ifScope:addReferenceToHigherScope(funcScope, cVar)

        stmts = {
            Ast.LocalVariableDeclaration(funcScope, {cVar}, {
                Ast.AddExpression(
                    Ast.MulExpression(
                        Ast.VariableExpression(funcScope, aVar),
                        Ast.NumberExpression(0x1A)),
                    Ast.VariableExpression(funcScope, bVar))
            }),
            Ast.IfStatement(
                Ast.GreaterThanExpression(
                    Ast.VariableExpression(funcScope, cVar),
                    Ast.NumberExpression(0xFFFF)),
                Ast.Block({
                    Ast.AssignmentStatement(
                        {Ast.AssignmentVariable(funcScope, cVar)},
                        {Ast.SubExpression(
                            Ast.VariableExpression(funcScope, cVar),
                            Ast.NumberExpression(0xFFFF))})
                }, ifScope),
                {}, nil),
            Ast.ReturnStatement({Ast.VariableExpression(funcScope, cVar)}),
        }
        local body = Ast.Block(stmts, funcScope)
        return Ast.LocalFunctionDeclaration(parentScope, funcId, {
            Ast.VariableExpression(funcScope, aVar),
            Ast.VariableExpression(funcScope, bVar),
        }, body)

    elseif pick == 2 then
        -- local function __deadXXXX(a, b)
        --     local c = a + b
        --     local d = c * 31 + 7
        --     return d
        -- end
        local aVar = funcScope:addVariable()
        local bVar = funcScope:addVariable()
        local cVar = funcScope:addVariable()
        local dVar = funcScope:addVariable()

        stmts = {
            Ast.LocalVariableDeclaration(funcScope, {cVar}, {
                Ast.AddExpression(
                    Ast.VariableExpression(funcScope, aVar),
                    Ast.VariableExpression(funcScope, bVar))
            }),
            Ast.LocalVariableDeclaration(funcScope, {dVar}, {
                Ast.AddExpression(
                    Ast.MulExpression(
                        Ast.VariableExpression(funcScope, cVar),
                        Ast.NumberExpression(31)),
                    Ast.NumberExpression(7))
            }),
            Ast.ReturnStatement({Ast.VariableExpression(funcScope, dVar)}),
        }
        local body = Ast.Block(stmts, funcScope)
        return Ast.LocalFunctionDeclaration(parentScope, funcId, {
            Ast.VariableExpression(funcScope, aVar),
            Ast.VariableExpression(funcScope, bVar),
        }, body)

    elseif pick == 3 then
        -- local function __deadXXXX(a)
        --     local b = a * a
        --     local c = b + a + 1
        --     return c
        -- end
        local aVar = funcScope:addVariable()
        local bVar = funcScope:addVariable()
        local cVar = funcScope:addVariable()

        stmts = {
            Ast.LocalVariableDeclaration(funcScope, {bVar}, {
                Ast.MulExpression(
                    Ast.VariableExpression(funcScope, aVar),
                    Ast.VariableExpression(funcScope, aVar))
            }),
            Ast.LocalVariableDeclaration(funcScope, {cVar}, {
                Ast.AddExpression(
                    Ast.AddExpression(
                        Ast.VariableExpression(funcScope, bVar),
                        Ast.VariableExpression(funcScope, aVar)),
                    Ast.NumberExpression(1))
            }),
            Ast.ReturnStatement({Ast.VariableExpression(funcScope, cVar)}),
        }
        local body = Ast.Block(stmts, funcScope)
        return Ast.LocalFunctionDeclaration(parentScope, funcId, {
            Ast.VariableExpression(funcScope, aVar),
        }, body)

    else
        -- local function __deadXXXX(a, b, c)
        --     local d = a + b
        --     local e = d - c
        --     return e
        -- end
        local aVar = funcScope:addVariable()
        local bVar = funcScope:addVariable()
        local cVar = funcScope:addVariable()
        local dVar = funcScope:addVariable()
        local eVar = funcScope:addVariable()

        stmts = {
            Ast.LocalVariableDeclaration(funcScope, {dVar}, {
                Ast.AddExpression(
                    Ast.VariableExpression(funcScope, aVar),
                    Ast.VariableExpression(funcScope, bVar))
            }),
            Ast.LocalVariableDeclaration(funcScope, {eVar}, {
                Ast.SubExpression(
                    Ast.VariableExpression(funcScope, dVar),
                    Ast.VariableExpression(funcScope, cVar))
            }),
            Ast.ReturnStatement({Ast.VariableExpression(funcScope, eVar)}),
        }
        local body = Ast.Block(stmts, funcScope)
        return Ast.LocalFunctionDeclaration(parentScope, funcId, {
            Ast.VariableExpression(funcScope, aVar),
            Ast.VariableExpression(funcScope, bVar),
            Ast.VariableExpression(funcScope, cVar),
        }, body)
    end
end

-- ---- Build a fake branch (always-false guard) ------------------------------
-- Generates:  if (0 ~= 0) then [dead_call] end

local function buildFakeBranch(deadFuncVarExpr, parentScope)
    local branchScope = Scope:new(parentScope)
    -- Opaque always-false: 0 ~= 0
    local condition = Ast.NotEqualsExpression(
        Ast.NumberExpression(0),
        Ast.NumberExpression(0))

    -- Dead body: call the dead function with plausible args
    local callArgs = {
        Ast.NumberExpression(math.random(0x1000, 0xFFFF)),
        Ast.StringExpression(string.format("key_%04x", math.random(0, 0xFFFF))),
    }
    local callStmt = Ast.FunctionCallStatement(deadFuncVarExpr, callArgs)

    return Ast.IfStatement(
        condition,
        Ast.Block({callStmt}, branchScope),
        {},   -- no elseifs
        nil)  -- no else
end

-- ---- Build a dead boolean constant -----------------------------------------
-- local __DEAD_BOOL_xxxx = false
-- Used as guards for fake branches that reference real-looking identifiers.

local function buildDeadBoolDecl(parentScope)
    local varId  = parentScope:addVariable()
    local suffix = nameSuffix()
    -- We can't rename it here directly, but MangledShuffled will rename it.
    local decl = Ast.LocalVariableDeclaration(
        parentScope, {varId}, {Ast.BooleanExpression(false)})
    return decl, varId
end

-- ---- Apply -----------------------------------------------------------------

function DeadCodeInjector:apply(ast)
    local globalScope = ast.globalScope
    local bodyScope   = ast.body.scope or Scope:new(globalScope)

    local injectedFuncExprs = {}  -- VariableExpressions for dead functions

    -- 1. Inject fake local functions at top of script
    -- buildDeadFunctionNode now picks a template internally via math.random(4)
    -- so no template argument is needed anymore.
    local insertPos = 1
    for i = 1, self.FakeFunctionCount do
        local node = buildDeadFunctionNode(nil, globalScope, bodyScope)
        if node then
            table.insert(ast.body.statements, insertPos, node)
            insertPos = insertPos + 1

            -- Track the variable if it's a LocalFunctionDeclaration
            if node.kind == AstKind.LocalFunctionDeclaration then
                table.insert(injectedFuncExprs,
                    Ast.VariableExpression(node.scope, node.id))
            end
        end
    end

    -- 2. Inject dead boolean sentinels
    local deadBoolExprs = {}
    for i = 1, math.ceil(self.FakeBranchCount / 3) do
        local decl, varId = buildDeadBoolDecl(bodyScope)
        table.insert(ast.body.statements, insertPos, decl)
        insertPos = insertPos + 1
        table.insert(deadBoolExprs,
            Ast.VariableExpression(bodyScope, varId))
    end

    -- 3. Scatter fake branches throughout the existing statements
    if self.FakeBranchCount > 0 and #ast.body.statements > insertPos then
        local totalReal = #ast.body.statements - insertPos
        local step = math.max(1, math.floor(totalReal / self.FakeBranchCount))

        local branchIdx = 0
        for pos = insertPos, #ast.body.statements, step do
            branchIdx = branchIdx + 1
            if branchIdx > self.FakeBranchCount then break end

            local funcExpr
            if #injectedFuncExprs > 0 then
                funcExpr = injectedFuncExprs[math.random(#injectedFuncExprs)]
            end

            local fakeBranch
            if funcExpr and math.random(2) == 1 then
                -- Branch that calls a dead function
                fakeBranch = buildFakeBranch(funcExpr, bodyScope)
            else
                -- Branch on dead boolean (if __DEAD_BOOL_xxxx then ... end)
                if #deadBoolExprs > 0 then
                    local sentinel = deadBoolExprs[math.random(#deadBoolExprs)]
                    local branchScope = Scope:new(bodyScope)
                    branchScope:addReferenceToHigherScope(bodyScope,
                        sentinel.id)
                    -- Dead body: a convincing-looking but harmless call
                    local inner = Ast.Block({
                        Ast.FunctionCallStatement(
                            Ast.IndexExpression(
                                Ast.VariableExpression(globalScope,
                                    select(2, globalScope:resolve("task")) or
                                    select(2, globalScope:resolve("wait"))),
                                Ast.StringExpression("wait")),
                            {Ast.NumberExpression(0)})
                    }, branchScope)
                    fakeBranch = Ast.IfStatement(sentinel, inner, {}, nil)
                end
            end

            if fakeBranch then
                table.insert(ast.body.statements, pos, fakeBranch)
            end
        end
    end

    return ast
end

return DeadCodeInjector
