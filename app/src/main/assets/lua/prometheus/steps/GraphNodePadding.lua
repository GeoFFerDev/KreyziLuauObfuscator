-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- GraphNodePadding.lua
--
-- Pads the output with a realistic fake GRAPH-BASED VM structure.
-- Unlike OutputPadding (which emits flat handler tables), this step
-- emits an interconnected node graph with topology, execution functions,
-- and a traversal engine — making it look like a completely different
-- VM architecture is present alongside the real one.
--
-- Each "node" is a table:
--   {
--     id   = <integer>,             -- node identifier
--     exec = function(ctx) ... end, -- handler function  
--     next = { n1, n2, ... },       -- edges to successor nodes
--     data = { ... },               -- "constant pool" for this node
--   }
--
-- A fake "graph executor" function is also emitted that traverses
-- the node graph starting from a root node — it looks exactly like
-- a genuine graph-based VM interpreter to reverse engineers.
--
-- The graph and executor are never actually called; they are dead code
-- designed to waste analyst time and inflate output size to ~PaddingKB.
--
-- Settings:
--   NodeCount  : number of graph nodes to generate (default 300)
--   PaddingKB  : approximate target padding in KB (default 256)
--   Seed       : if non-zero, override RNG for reproducible output

local Step  = require("prometheus.step")
local Ast   = require("prometheus.ast")
local Scope = require("prometheus.scope")

local GraphNodePadding = Step:extend()
GraphNodePadding.Name        = "GraphNodePadding"
GraphNodePadding.Description = "Pads output with a fake graph-based VM (nodes + edges + executor)."

GraphNodePadding.SettingsDescriptor = {
    NodeCount = {
        type    = "number",
        default = 300,
        min     = 10,
        max     = 5000,
    },
    PaddingKB = {
        type    = "number",
        default = 256,
        min     = 8,
        max     = 2048,
    },
    -- Number of fake "execution contexts" (each gets its own node graph)
    ContextCount = {
        type    = "number",
        default = 3,
        min     = 1,
        max     = 20,
    },
}

function GraphNodePadding:init() end

-- ---- Helpers ----------------------------------------------------------------

local function N(n)   return Ast.NumberExpression(n)  end
local function S(s)   return Ast.StringExpression(s)  end
local function B(b)   return Ast.BooleanExpression(b) end

-- Build one "exec" handler function for a node.
-- 8 body patterns, same as OutputPadding but parameterised differently.
local function buildExecFunc(parentScope, nodeId)
    local fScope = Scope:new(parentScope)
    local ctxVar = fScope:addVariable()  -- parameter: ctx
    local tVar   = fScope:addVariable()  -- local temp
    local uVar   = fScope:addVariable()  -- local temp2

    local A = math.random(2, 0xFFF)
    local B_ = math.random(1, 0xFFF)
    local C = math.random(1, 0xFF)
    local t = math.random(8)

    local stmts

    if t == 1 then
        -- t = A * nodeId + B  ; return t
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {tVar}, {
                Ast.AddExpression(
                    Ast.MulExpression(N(A), N(nodeId)),
                    N(B_)) }),
            Ast.ReturnStatement({ Ast.VariableExpression(fScope, tVar) }),
        }
    elseif t == 2 then
        -- t = ctx * A ; u = t - B ; return u
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {tVar}, {
                Ast.MulExpression(
                    Ast.VariableExpression(fScope, ctxVar),
                    N(A)) }),
            Ast.LocalVariableDeclaration(fScope, {uVar}, {
                Ast.SubExpression(
                    Ast.VariableExpression(fScope, tVar),
                    N(B_)) }),
            Ast.ReturnStatement({ Ast.VariableExpression(fScope, uVar) }),
        }
    elseif t == 3 then
        -- t = (ctx + nodeId) % C ; return t
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {tVar}, {
                Ast.ModExpression(
                    Ast.AddExpression(
                        Ast.VariableExpression(fScope, ctxVar),
                        N(nodeId)),
                    N(C > 0 and C or 1)) }),
            Ast.ReturnStatement({ Ast.VariableExpression(fScope, tVar) }),
        }
    elseif t == 4 then
        -- t = A * ctx + nodeId ; u = t * t - B ; return u
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {tVar}, {
                Ast.AddExpression(
                    Ast.MulExpression(N(A), Ast.VariableExpression(fScope, ctxVar)),
                    N(nodeId)) }),
            Ast.LocalVariableDeclaration(fScope, {uVar}, {
                Ast.SubExpression(
                    Ast.MulExpression(
                        Ast.VariableExpression(fScope, tVar),
                        Ast.VariableExpression(fScope, tVar)),
                    N(B_)) }),
            Ast.ReturnStatement({ Ast.VariableExpression(fScope, uVar) }),
        }
    elseif t == 5 then
        -- simple: return nodeId * A
        stmts = {
            Ast.ReturnStatement({
                Ast.MulExpression(N(nodeId), N(A)) }),
        }
    elseif t == 6 then
        -- t = ctx + A ; u = t - nodeId ; return u % C
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {tVar}, {
                Ast.AddExpression(Ast.VariableExpression(fScope, ctxVar), N(A)) }),
            Ast.LocalVariableDeclaration(fScope, {uVar}, {
                Ast.SubExpression(Ast.VariableExpression(fScope, tVar), N(nodeId)) }),
            Ast.ReturnStatement({
                Ast.ModExpression(
                    Ast.VariableExpression(fScope, uVar),
                    N(C > 0 and C or 1)) }),
        }
    elseif t == 7 then
        -- deep chain: t = A; u = ctx * t; return u - B
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {tVar}, { N(A) }),
            Ast.LocalVariableDeclaration(fScope, {uVar}, {
                Ast.MulExpression(
                    Ast.VariableExpression(fScope, ctxVar),
                    Ast.VariableExpression(fScope, tVar)) }),
            Ast.ReturnStatement({
                Ast.SubExpression(Ast.VariableExpression(fScope, uVar), N(B_)) }),
        }
    else
        -- t = nodeId + ctx*A ; u = t % C ; return u + B
        local vVar = fScope:addVariable()
        stmts = {
            Ast.LocalVariableDeclaration(fScope, {tVar}, {
                Ast.AddExpression(
                    N(nodeId),
                    Ast.MulExpression(Ast.VariableExpression(fScope, ctxVar), N(A))) }),
            Ast.LocalVariableDeclaration(fScope, {uVar}, {
                Ast.ModExpression(
                    Ast.VariableExpression(fScope, tVar),
                    N(C > 0 and C or 1)) }),
            Ast.LocalVariableDeclaration(fScope, {vVar}, {
                Ast.AddExpression(Ast.VariableExpression(fScope, uVar), N(B_)) }),
            Ast.ReturnStatement({ Ast.VariableExpression(fScope, vVar) }),
        }
    end

    return Ast.FunctionLiteralExpression(
        { Ast.VariableExpression(fScope, ctxVar) },
        Ast.Block(stmts, fScope),
        nil)
end

-- Build a fake "data" table for a node: {K1=V1, K2=V2, ...}
local function buildDataTable(parentScope, entryCount)
    local entries = {}
    for i = 1, entryCount do
        local key = math.random(0x100, 0xFFFF)
        local val = math.random(1, 0x7FFFF)
        table.insert(entries, Ast.KeyedTableEntry(N(key), N(val)))
    end
    return Ast.TableConstructorExpression(entries)
end

-- Build `next` edges table for a node: {n1, n2, ...}
local function buildNextTable(parentScope, allIds, maxEdges)
    local n = math.random(1, math.min(maxEdges, #allIds))
    -- shuffle and pick first n
    local copy = {}
    for _, id in ipairs(allIds) do copy[#copy+1] = id end
    for i = #copy, 2, -1 do
        local j = math.random(i)
        copy[i], copy[j] = copy[j], copy[i]
    end
    local entries = {}
    for i = 1, n do
        table.insert(entries, Ast.TableEntry(N(copy[i])))
    end
    return Ast.TableConstructorExpression(entries)
end

-- Build one node table constructor expression:
-- { id=ID, exec=function(ctx) ... end, next={...}, data={...} }
local function buildNodeExpr(parentScope, nodeId, allIds, maxEdges)
    local execFunc  = buildExecFunc(parentScope, nodeId)
    local nextTbl   = buildNextTable(parentScope, allIds, maxEdges)
    local dataTbl   = buildDataTable(parentScope, math.random(2, 6))
    return Ast.TableConstructorExpression({
        Ast.KeyedTableEntry(S("id"),   N(nodeId)),
        Ast.KeyedTableEntry(S("exec"), execFunc),
        Ast.KeyedTableEntry(S("next"), nextTbl),
        Ast.KeyedTableEntry(S("data"), dataTbl),
    })
end

-- Build the fake graph executor function:
-- function(graph, rootId, maxSteps)
--   local ctx = rootId
--   local steps = 0
--   while steps < maxSteps do
--     local node = graph[ctx]
--     if not node then break end
--     ctx = node.exec(ctx)
--     steps = steps + 1
--     if #node.next == 0 then break end
--   end
--   return ctx
-- end
local function buildExecutorFunc(parentScope)
    local fScope   = Scope:new(parentScope)
    local graphArg = fScope:addVariable()  -- graph
    local rootArg  = fScope:addVariable()  -- rootId
    local maxArg   = fScope:addVariable()  -- maxSteps
    local ctxVar   = fScope:addVariable()  -- ctx   (outer local)
    local stepVar  = fScope:addVariable()  -- steps (outer local)

    local bScope   = Scope:new(fScope)     -- while body scope

    -- References bScope needs to fScope upvalues
    bScope:addReferenceToHigherScope(fScope, graphArg)
    bScope:addReferenceToHigherScope(fScope, ctxVar)
    bScope:addReferenceToHigherScope(fScope, stepVar)
    bScope:addReferenceToHigherScope(fScope, maxArg)

    -- nodeVar is a local declared *inside* the while body (bScope)
    local nodeVar     = bScope:addVariable()
    local breakScope1 = Scope:new(bScope)
    local breakScope2 = Scope:new(bScope)

    -- Pre-create the WhileStatement so BreakStatements can reference it
    local whileStat = {
        kind = "WhileStatement",
        condition = nil,
        body = nil,
    }

    breakScope2:addReferenceToHigherScope(bScope, nodeVar)
    breakScope2:addReferenceToHigherScope(fScope, ctxVar)

    local whileBody = Ast.Block({
        -- local node = graph[ctx]
        Ast.LocalVariableDeclaration(bScope, {nodeVar}, {
            Ast.IndexExpression(
                Ast.VariableExpression(fScope, graphArg),
                Ast.VariableExpression(fScope, ctxVar)) }),
        -- if not node then break end
        Ast.IfStatement(
            Ast.NotExpression(Ast.VariableExpression(bScope, nodeVar)),
            Ast.Block({ Ast.BreakStatement(whileStat, breakScope1) }, breakScope1),
            {}, Ast.Block({}, Scope:new(bScope))),
        -- ctx = node.exec(ctx)
        Ast.AssignmentStatement(
            { Ast.AssignmentVariable(fScope, ctxVar) },
            { Ast.FunctionCallExpression(
                Ast.IndexExpression(
                    Ast.VariableExpression(bScope, nodeVar),
                    Ast.StringExpression("exec")),
                { Ast.VariableExpression(fScope, ctxVar) }) }),
        -- steps = steps + 1
        Ast.AssignmentStatement(
            { Ast.AssignmentVariable(fScope, stepVar) },
            { Ast.AddExpression(
                Ast.VariableExpression(fScope, stepVar),
                Ast.NumberExpression(1)) }),
        -- if #node.next == 0 then break end
        Ast.IfStatement(
            Ast.EqualsExpression(
                Ast.LenExpression(
                    Ast.IndexExpression(
                        Ast.VariableExpression(bScope, nodeVar),
                        Ast.StringExpression("next"))),
                Ast.NumberExpression(0)),
            Ast.Block({ Ast.BreakStatement(whileStat, breakScope2) }, breakScope2),
            {}, Ast.Block({}, Scope:new(bScope))),
    }, bScope)

    -- while steps < maxSteps do ... end
    local whileCond = Ast.LessThanExpression(
        Ast.VariableExpression(fScope, stepVar),
        Ast.VariableExpression(fScope, maxArg))

    whileStat.body = whileBody
    whileStat.condition = whileCond

    local body = Ast.Block({
        Ast.LocalVariableDeclaration(fScope, {ctxVar},  { Ast.VariableExpression(fScope, rootArg) }),
        Ast.LocalVariableDeclaration(fScope, {stepVar}, { Ast.NumberExpression(0) }),
        whileStat,
        Ast.ReturnStatement({ Ast.VariableExpression(fScope, ctxVar) }),
    }, fScope)

    return Ast.FunctionLiteralExpression(
        { Ast.VariableExpression(fScope, graphArg),
          Ast.VariableExpression(fScope, rootArg),
          Ast.VariableExpression(fScope, maxArg) },
        body, nil)
end

-- ---- Build one complete "VM context" block ---------------------------------
-- Returns a list of statements to be inserted:
--   local _gnN = {}          -- node table
--   _gnN[id1] = { id=…, exec=…, next=…, data=… }
--   ...
--   local _geN = function(graph, root, maxSteps) ... end  -- executor
local function buildContext(bodyScope, nodeCount)
    -- Generate unique node IDs
    local nodeIds = {}
    local usedIds = {}
    for i = 1, nodeCount do
        local id
        repeat id = math.random(1, 2^20)
        until not usedIds[id]
        usedIds[id] = true
        nodeIds[#nodeIds + 1] = id
    end

    local graphVar    = bodyScope:addVariable()
    local execVar     = bodyScope:addVariable()
    local rootSeedVar = bodyScope:addVariable()

    local stmts = {}

    -- local _gnX = {}
    table.insert(stmts, Ast.LocalVariableDeclaration(
        bodyScope, { graphVar }, { Ast.TableConstructorExpression({}) }))

    -- _gnX[id] = node  for each node
    local maxEdges = math.min(4, math.floor(nodeCount / 5) + 1)
    for _, nid in ipairs(nodeIds) do
        local nodeExpr = buildNodeExpr(bodyScope, nid, nodeIds, maxEdges)
        table.insert(stmts, Ast.AssignmentStatement(
            { Ast.AssignmentIndexing(
                Ast.VariableExpression(bodyScope, graphVar),
                Ast.NumberExpression(nid)) },
            { nodeExpr }))
    end

    -- local _geX = function(graph, root, maxSteps) ... end
    table.insert(stmts, Ast.LocalVariableDeclaration(
        bodyScope, { execVar }, { buildExecutorFunc(bodyScope) }))

    -- local _rsX = K  (pre-computed root seed — looks like initialisation)
    local rootSeed = nodeIds[math.random(#nodeIds)]
    table.insert(stmts, Ast.LocalVariableDeclaration(
        bodyScope, { rootSeedVar }, { Ast.NumberExpression(rootSeed) }))

    return stmts
end

-- ---- Apply -----------------------------------------------------------------

function GraphNodePadding:apply(ast)
    local bodyScope = ast.body.scope or ast.globalScope

    -- Determine how many nodes total we need
    -- Rough estimate: ~200 bytes per node (id + exec + next + data + assignment)
    local BYTES_PER_NODE = 200
    local targetBytes    = self.PaddingKB * 1024
    local totalNodes     = math.ceil(targetBytes / BYTES_PER_NODE)

    local nodeCount = self.NodeCount
    -- If PaddingKB target requires more nodes than NodeCount, scale up
    if totalNodes > nodeCount then nodeCount = totalNodes end

    local contextCount = self.ContextCount
    local nodesPerCtx  = math.ceil(nodeCount / contextCount)

    -- Insert at the top of the script body
    local insertPos = 1
    for c = 1, contextCount do
        local remaining = nodeCount - (c - 1) * nodesPerCtx
        local cnt = math.min(nodesPerCtx, remaining)
        if cnt <= 0 then break end

        local ctxStmts = buildContext(bodyScope, cnt)
        for _, stmt in ipairs(ctxStmts) do
            table.insert(ast.body.statements, insertPos, stmt)
            insertPos = insertPos + 1
        end
    end

    return ast
end

return GraphNodePadding
