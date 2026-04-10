-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- emit.lua
--
-- This Script contains the container function body emission for the compiler.

local Ast = require("prometheus.ast");
local Scope = require("prometheus.scope");
local util = require("prometheus.util");
local constants = require("prometheus.compiler.constants");
local AstKind = Ast.AstKind;

local MAX_REGS = constants.MAX_REGS;

return function(Compiler)
    local function hasAnyEntries(tbl)
        return type(tbl) == "table" and next(tbl) ~= nil;
    end

    local function unionLookupTables(a, b)
        local out = {};
        for k, v in pairs(a or {}) do
            out[k] = v;
        end
        for k, v in pairs(b or {}) do
            out[k] = v;
        end
        return out;
    end

    -- Maximum number of targets in a single merged multi-assignment.
    --
    -- ROOT CAUSE of "Out of registers: exceeded limit 255":
    --   mergeAdjacentParallelAssignments runs 7 times and has no size cap.
    --   For a large VM block with 200+ independent register-copy statements
    --   all conflict-free, they collapse into ONE multi-assignment after 7
    --   passes.  When Luau compiles  r0,r1,...,r230 = v0,v1,...,v230  it
    --   must hold all N RHS values in consecutive temporary registers
    --   simultaneously (before any SETUPVAL can run).  With ~22 base
    --   registers already declared in the container function:
    --       22 base + 234 temps = 256  → exceeds the 255-register hard limit.
    --
    -- Fix: refuse to merge if the resulting lhs would exceed MERGE_CAP.
    -- 200 targets + 22 base + a few expression temps = ~230, safely under 255.
    local MERGE_CAP = 200;

    local function canMergeParallelAssignmentStatements(statA, statB)
        if type(statA) ~= "table" or type(statB) ~= "table" then
            return false;
        end

        if statA.usesUpvals or statB.usesUpvals then
            return false;
        end

        local a = statA.statement;
        local b = statB.statement;
        if type(a) ~= "table" or type(b) ~= "table" then
            return false;
        end
        if a.kind ~= AstKind.AssignmentStatement or b.kind ~= AstKind.AssignmentStatement then
            return false;
        end

        if type(a.lhs) ~= "table" or type(a.rhs) ~= "table" or type(b.lhs) ~= "table" or type(b.rhs) ~= "table" then
            return false;
        end

        if #a.lhs ~= #a.rhs or #b.lhs ~= #b.rhs then
            return false;
        end

        -- Register-limit guard: the merged multi-assignment would require all
        -- (#a.lhs + #b.lhs) RHS values to be held in consecutive temporary
        -- registers simultaneously.  With ~22 base registers already declared
        -- in the container function, a merged lhs larger than MERGE_CAP pushes
        -- the total past Luau's 255-register hard limit.
        if #a.lhs + #b.lhs > MERGE_CAP then
            return false;
        end

        -- Avoid merging vararg/call assignments because they can affect multi-return behavior.
        local function hasUnsafeRhs(rhsList)
            for _, rhsExpr in ipairs(rhsList) do
                if type(rhsExpr) ~= "table" then
                    return true;
                end
                local kind = rhsExpr.kind;
                if kind == AstKind.FunctionCallExpression or kind == AstKind.PassSelfFunctionCallExpression or kind == AstKind.VarargExpression then
                    return true;
                end
            end
            return false;
        end
        if hasUnsafeRhs(a.rhs) or hasUnsafeRhs(b.rhs) then
            return false;
        end

        local aReads = type(statA.reads) == "table" and statA.reads or {};
        local aWrites = type(statA.writes) == "table" and statA.writes or {};
        local bReads = type(statB.reads) == "table" and statB.reads or {};
        local bWrites = type(statB.writes) == "table" and statB.writes or {};

        -- Allow merging even if one statement has no writes (e.g., x = o(x) style assignments)
        -- Only require that at least one of them has writes
        if not hasAnyEntries(aWrites) and not hasAnyEntries(bWrites) then
            return false;
        end

        for r in pairs(aReads) do
            if bWrites[r] then
                return false;
            end
        end

        for r, b in pairs(aWrites) do
            if bWrites[r] or bReads[r] then
                return false;
            end
        end

        return true;
    end

    local function mergeParallelAssignmentStatements(statA, statB)
        local lhs = {};
        local rhs = {};
        local aLhs, bLhs = statA.statement.lhs, statB.statement.lhs;
        local aRhs, bRhs = statA.statement.rhs, statB.statement.rhs;
        for i = 1, #aLhs do lhs[i] = aLhs[i]; end
        for i = 1, #bLhs do lhs[#aLhs + i] = bLhs[i]; end
        for i = 1, #aRhs do rhs[i] = aRhs[i]; end
        for i = 1, #bRhs do rhs[#aRhs + i] = bRhs[i]; end

        return {
            statement = Ast.AssignmentStatement(lhs, rhs),
            writes = unionLookupTables(statA.writes, statB.writes),
            reads = unionLookupTables(statA.reads, statB.reads),
            usesUpvals = statA.usesUpvals or statB.usesUpvals,
        };
    end

    local function mergeAdjacentParallelAssignments(blockstats)
        local merged = {};
        local i = 1;
        while i <= #blockstats do
            local stat = blockstats[i];
            i = i + 1;

            while i <= #blockstats and canMergeParallelAssignmentStatements(stat, blockstats[i]) do
                stat = mergeParallelAssignmentStatements(stat, blockstats[i]);
                i = i + 1;
            end

            table.insert(merged, stat);
        end
        return merged;
    end

    -- -------------------------------------------------------------------------
    -- Shared helper: process raw self.blocks into sorted, instruction-reordered
    -- arrayBlocks suitable for both dispatch modes.
    -- Returns: arrayBlocks  (array of {id, block=Ast.Block, scope})
    -- -------------------------------------------------------------------------
    local function buildSortedBlocks(self)
        local blocks = {};

        util.shuffle(self.blocks);

        for i, block in ipairs(self.blocks) do
            local id        = block.id;
            local blockstats = block.statements;

            -- Instruction reordering (same as original emit logic)
            for idx = 2, #blockstats do
                local stat    = blockstats[idx];
                local reads   = stat.reads;
                local writes  = stat.writes;
                local maxShift = 0;
                local usesUpvals = stat.usesUpvals;
                for shift = 1, idx - 1 do
                    local stat2   = blockstats[idx - shift];
                    if stat2.usesUpvals and usesUpvals then break; end
                    local reads2  = stat2.reads;
                    local writes2 = stat2.writes;
                    local ok = true;
                    for r in pairs(reads2) do
                        if writes[r] then ok = false; break; end
                    end
                    if ok then
                        for r in pairs(writes2) do
                            if writes[r] or reads[r] then ok = false; break; end
                        end
                    end
                    if not ok then break; end
                    maxShift = shift;
                end
                local shift = math.random(0, maxShift);
                for j = 1, shift do
                    blockstats[idx - j], blockstats[idx - j + 1] =
                        blockstats[idx - j + 1], blockstats[idx - j];
                end
            end

            -- Merge parallel assignments
            local merged = mergeAdjacentParallelAssignments(blockstats);
            for _ = 1, 7 do
                merged = mergeAdjacentParallelAssignments(merged);
            end

            local stmtList = {};
            for _, stat in ipairs(merged) do
                table.insert(stmtList, stat.statement);
            end

            local entry = { id = id, index = i, block = Ast.Block(stmtList, block.scope) };
            table.insert(blocks, entry);
            blocks[id] = entry;
        end

        -- Strip hash-key entries, sort by id
        local arr = {};
        for _, v in ipairs(blocks) do arr[#arr + 1] = v; end
        table.sort(arr, function(a, b) return a.id < b.id; end);
        return arr;
    end

    -- -------------------------------------------------------------------------
    -- Original if/else-chain dispatch body (unchanged logic, now calls helper)
    -- -------------------------------------------------------------------------
    function Compiler:emitContainerFuncBody()
        -- Priority: Keyed > Poly > Chaos > Opcode > IfElse
        if self.useKeyedDispatch then
            return self:emitContainerFuncBodyKeyedDispatch();
        end
        if self.usePolyDispatch then
            if self.useChaosOverPoly then
                return self:emitContainerFuncBodyChaosDispatch();
            end
            return self:emitContainerFuncBodyPolyDispatch();
        end
        if self.useChaosDispatch then
            return self:emitContainerFuncBodyChaosDispatch();
        end
        if self.useOpcodeDispatch then
            return self:emitContainerFuncBodyOpcodeDispatch();
        end

        local blocks = buildSortedBlocks(self);

        -- Build a strict threshold condition between adjacent block IDs.
        local function buildBlockThresholdCondition(scope, leftId, rightId, useAndOr)
            local bound   = math.floor((leftId + rightId) / 2);
            local posExpr = self:pos(scope);
            local boundExpr = Ast.NumberExpression(bound);
            if useAndOr then
                return Ast.LessThanExpression(posExpr, boundExpr);
            else
                local variant = math.random(1, 2);
                if variant == 1 then
                    return Ast.LessThanExpression(posExpr, boundExpr);
                else
                    return Ast.GreaterThanExpression(boundExpr, posExpr);
                end
            end
        end

        local function buildElseifChain(tb, l, r, pScope)
            if r < l then
                local effectiveParent = pScope or self.containerFuncScope;
                local emptyScope = Scope:new(effectiveParent);
                return Ast.Block({}, emptyScope);
            end
            local len = r - l + 1;
            if len == 1 then
                local effectiveParent = pScope or self.containerFuncScope;
                tb[l].block.scope:setParent(effectiveParent);
                return tb[l].block;
            end
            if len <= 4 then
                local effectiveParent = pScope or self.containerFuncScope;
                local ifScope = Scope:new(effectiveParent);
                local elseifs = {};
                tb[l].block.scope:setParent(ifScope);
                local firstCondition = buildBlockThresholdCondition(ifScope, tb[l].id, tb[l + 1].id, false);
                local firstBlock = tb[l].block;
                for i = l + 1, r - 1 do
                    tb[i].block.scope:setParent(ifScope);
                    local condition = buildBlockThresholdCondition(ifScope, tb[i].id, tb[i + 1].id, false);
                    table.insert(elseifs, { condition = condition, body = tb[i].block });
                end
                tb[r].block.scope:setParent(ifScope);
                local elseBlock = tb[r].block;
                return Ast.Block({ Ast.IfStatement(firstCondition, firstBlock, elseifs, elseBlock) }, ifScope);
            end
            local mid       = l + math.ceil(len / 2);
            local leftMaxId = tb[mid - 1].id;
            local rightMinId = tb[mid].id;
            local bound     = math.floor((leftMaxId + rightMinId) / 2);
            local effectiveParent = pScope or self.containerFuncScope;
            local ifScope   = Scope:new(effectiveParent);
            local lBlock    = buildElseifChain(tb, l, mid - 1, ifScope);
            local rBlock    = buildElseifChain(tb, mid, r, ifScope);
            local condStyle = math.random(1, 3);
            local condition, trueBlock, falseBlock;
            if condStyle == 1 then
                condition  = Ast.LessThanExpression(self:pos(ifScope), Ast.NumberExpression(bound));
                trueBlock, falseBlock = lBlock, rBlock;
            elseif condStyle == 2 then
                condition  = Ast.GreaterThanExpression(Ast.NumberExpression(bound), self:pos(ifScope));
                trueBlock, falseBlock = lBlock, rBlock;
            else
                condition  = Ast.GreaterThanExpression(self:pos(ifScope), Ast.NumberExpression(bound));
                trueBlock, falseBlock = rBlock, lBlock;
            end
            return Ast.Block({ Ast.IfStatement(condition, trueBlock, {}, falseBlock) }, ifScope);
        end

        local whileBody = buildElseifChain(blocks, 1, #blocks, self.containerFuncScope);
        if self.whileScope then
            self.whileScope:setParent(self.containerFuncScope);
        end

        self.whileScope:addReferenceToHigherScope(self.containerFuncScope, self.returnVar, 1);
        self.whileScope:addReferenceToHigherScope(self.containerFuncScope, self.posVar);
        self.containerFuncScope:addReferenceToHigherScope(self.scope, self.unpackVar);

        local declarations = { self.returnVar };
        for i, var in pairs(self.registerVars) do
            if i ~= MAX_REGS then table.insert(declarations, var); end
        end

        local stats = {};
        if self.maxUsedRegister >= MAX_REGS then
            table.insert(stats, Ast.LocalVariableDeclaration(
                self.containerFuncScope, { self.registerVars[MAX_REGS] }, { Ast.TableConstructorExpression({}) }));
        end
        table.insert(stats, Ast.LocalVariableDeclaration(
            self.containerFuncScope, util.shuffle(declarations), {}));
        table.insert(stats, Ast.WhileStatement(
            whileBody, Ast.VariableExpression(self.containerFuncScope, self.posVar)));
        table.insert(stats, Ast.AssignmentStatement(
            { Ast.AssignmentVariable(self.containerFuncScope, self.posVar) },
            { Ast.LenExpression(Ast.VariableExpression(self.containerFuncScope, self.detectGcCollectVar)) }));
        table.insert(stats, Ast.ReturnStatement{
            Ast.FunctionCallExpression(
                Ast.VariableExpression(self.scope, self.unpackVar),
                { Ast.VariableExpression(self.containerFuncScope, self.returnVar) })
        });

        return Ast.Block(stats, self.containerFuncScope);
    end

    -- =========================================================================
    -- ChaosDispatch VM mode
    -- =========================================================================
    -- Architecture: three-layer indirection with entropy accumulation.
    --
    --   _ops  : physical handler table,  keyed by RANDOM PHYSICAL SLOTS
    --   _idx  : logical→physical map,    _idx[block_id] = physical_slot
    --   _s    : 28-bit entropy accumulator updated every dispatch cycle
    --
    -- The dispatch loop reads:
    --   while pos do
    --     _s = (_s * K1 + pos) % PRIME   -- state mix  (looks like it affects dispatch)
    --     _ops[_idx[pos]]()              -- two-level indirection
    --   end
    --
    -- Why this is hard to reverse:
    --   1. `_s` is always computed and referenced, so analysts assume it
    --      influences dispatch — it doesn't, but tracing it wastes time.
    --   2. `_idx` decouples logical block IDs from physical handler keys.
    --      Static analysis must trace both tables before mapping a pos
    --      value to its handler.
    --   3. Fake handler chains: some physical slots hold lambdas that call
    --      other fake lambdas before terminating, creating false call-graphs
    --      that decompilers trace exhaustively.
    --   4. Fake `_idx` entries point at fake physical slots, adding noise
    --      to both lookup tables simultaneously.
    --   5. Physical slot IDs are random (full 2^24 range), preventing any
    --      sequential / offset-based analysis.
    -- =========================================================================
    function Compiler:emitContainerFuncBodyChaosDispatch()
        local blocks = buildSortedBlocks(self)

        -- Chaos parameters (compile-time constants, unique per obfuscation run)
        local PRIME  = 16777259    -- small prime > 2^24 for modular state
        local K1     = math.random(3, 0x3FFF) * 2 + 1   -- odd multiplier
        local SEED   = math.random(1, 0x0FFFFFFF)

        -- Variables for the three dispatch structures
        local opsVar  = self.containerFuncScope:addVariable()   -- _ops
        local idxVar  = self.containerFuncScope:addVariable()   -- _idx
        local stateVar = self.containerFuncScope:addVariable()  -- _s

        -- ---- Assign physical slots to real blocks ----
        -- Each block gets a random physical key, independent of its logical ID.
        local physicalSlots = {}   -- blockEntry → physical_key
        for _, blockEntry in ipairs(blocks) do
            local slot
            repeat slot = math.random(1, 2^24)
            until not self.usedBlockIds[slot]
            self.usedBlockIds[slot] = true
            physicalSlots[blockEntry.id] = slot
        end

        -- ---- Build real opcode handlers ----
        -- Stored at their physical slots; _idx maps logical ID → physical slot.
        local handlerEntries = {}   -- {physicalKey, funcNode}
        local idxEntries     = {}   -- {logicalId,   physicalKey}

        for _, blockEntry in ipairs(blocks) do
            local hFuncScope = Scope:new(self.containerFuncScope)
            blockEntry.block.scope:setParent(hFuncScope)

            local hFunc = Ast.FunctionLiteralExpression({}, blockEntry.block, nil)
            local phys  = physicalSlots[blockEntry.id]
            table.insert(handlerEntries, { key = phys,          func = hFunc })
            table.insert(idxEntries,     { logId = blockEntry.id, phys = phys })
        end

        -- ---- Dead-handler chains ----
        -- Each chain is N handlers that call the next, forming a ring
        -- that terminates with pos=false.  Analysts spend time tracing these.
        local deadChainCount  = math.max(2, math.floor((self.fakeOpcodeCount or 12) / 3))
        local deadChainLen    = 3   -- links per chain
        local deadChainSlots  = {}  -- all physical keys used by dead chains
        local deadFakeIdxKeys = {}  -- logical IDs for fake _idx entries

        -- Helper: terminal dead handler body
        local function buildDeadTerminal(fhScope)
            local fb = Scope:new(fhScope)
            fb:addReferenceToHigherScope(self.containerFuncScope, self.posVar)
            return Ast.FunctionLiteralExpression({}, Ast.Block({
                Ast.AssignmentStatement(
                    { Ast.AssignmentVariable(self.containerFuncScope, self.posVar) },
                    { Ast.BooleanExpression(false) })
            }, fb), nil)
        end

        for c = 1, deadChainCount do
            local chainSlots = {}
            for i = 1, deadChainLen do
                local s
                repeat s = math.random(1, 2^24)
                until not self.usedBlockIds[s]
                self.usedBlockIds[s] = true
                table.insert(chainSlots, s)
                table.insert(deadChainSlots, s)
            end

            -- Build chain: slot[i] calls _ops[slot[i+1]], last slot kills pos
            for i = 1, deadChainLen do
                local fhScope = Scope:new(self.containerFuncScope)
                local fb      = Scope:new(fhScope)
                local func

                if i == deadChainLen then
                    func = buildDeadTerminal(fhScope)
                else
                    -- call the next chain link
                    local nextSlot = chainSlots[i + 1]
                    fb:addReferenceToHigherScope(self.containerFuncScope, opsVar)
                    local K2 = math.random(2, 999)
                    local K3 = math.random(1, 999)
                    local tmpV = fb:addVariable()
                    func = Ast.FunctionLiteralExpression({}, Ast.Block({
                        -- local _t = K2 * K3   (dead noise, looks like address calc)
                        Ast.LocalVariableDeclaration(fb, {tmpV}, {
                            Ast.MulExpression(
                                Ast.NumberExpression(K2),
                                Ast.NumberExpression(K3))
                        }),
                        -- _ops[nextSlot]()
                        Ast.FunctionCallStatement(
                            Ast.IndexExpression(
                                Ast.VariableExpression(self.containerFuncScope, opsVar),
                                Ast.NumberExpression(nextSlot)),
                            {})
                    }, fb), nil)
                end
                table.insert(handlerEntries, { key = chainSlots[i], func = func })
            end

            -- Add a fake _idx entry pointing into this chain's first slot
            local fakeLogId
            repeat fakeLogId = math.random(1, 2^24)
            until not self.usedBlockIds[fakeLogId]
            self.usedBlockIds[fakeLogId] = true
            table.insert(idxEntries, { logId = fakeLogId, phys = chainSlots[1] })
            table.insert(deadFakeIdxKeys, fakeLogId)
        end

        -- ---- Extra isolated fake _ops entries ----
        local isolatedFakeCount = (self.fakeOpcodeCount or 12) - deadChainCount * deadChainLen
        if isolatedFakeCount < 0 then isolatedFakeCount = 0 end

        local function buildFakeHandlerBodyChaos(pattern, fhScope)
            local fb  = Scope:new(fhScope)
            fb:addReferenceToHigherScope(self.containerFuncScope, self.posVar)
            fb:addReferenceToHigherScope(self.containerFuncScope, stateVar)
            local K1c = math.random(3, 997)
            local K2c = math.random(3, 997)
            local K3c = math.random(3, 997)

            local function killPos(scope)
                scope:addReferenceToHigherScope(self.containerFuncScope, self.posVar)
                return Ast.AssignmentStatement(
                    { Ast.AssignmentVariable(self.containerFuncScope, self.posVar) },
                    { Ast.BooleanExpression(false) })
            end

            if pattern == 1 then
                return Ast.Block({ killPos(fb) }, fb)
            elseif pattern == 2 then
                local c1 = fb:addVariable()
                return Ast.Block({
                    Ast.LocalVariableDeclaration(fb, {c1}, {
                        Ast.AddExpression(
                            Ast.MulExpression(
                                Ast.NumberExpression(K1c),
                                Ast.VariableExpression(self.containerFuncScope, stateVar)),
                            Ast.NumberExpression(K2c))
                    }),
                    killPos(fb),
                }, fb)
            elseif pattern == 3 then
                -- Fake conditional referencing _s: looks like a state-driven branch
                local thenScp = Scope:new(fb)
                thenScp:addReferenceToHigherScope(self.containerFuncScope, self.posVar)
                local elseScp = Scope:new(fb)
                elseScp:addReferenceToHigherScope(self.containerFuncScope, self.posVar)
                return Ast.Block({
                    Ast.IfStatement(
                        Ast.GreaterThanExpression(
                            Ast.VariableExpression(self.containerFuncScope, stateVar),
                            Ast.NumberExpression(math.random(0x4000, 0xEFFF))),
                        Ast.Block({ killPos(thenScp) }, thenScp),
                        {},
                        Ast.Block({
                            Ast.AssignmentStatement(
                                { Ast.AssignmentVariable(self.containerFuncScope, self.posVar) },
                                { Ast.NilExpression() })
                        }, elseScp)),
                }, fb)
            elseif pattern == 4 then
                local c1 = fb:addVariable(); local c2 = fb:addVariable()
                return Ast.Block({
                    Ast.LocalVariableDeclaration(fb, {c1}, {
                        Ast.MulExpression(
                            Ast.VariableExpression(self.containerFuncScope, stateVar),
                            Ast.NumberExpression(K1c)) }),
                    Ast.LocalVariableDeclaration(fb, {c2}, {
                        Ast.ModExpression(
                            Ast.AddExpression(
                                Ast.VariableExpression(fb, c1),
                                Ast.NumberExpression(K2c)),
                            Ast.NumberExpression(K3c)) }),
                    killPos(fb),
                }, fb)
            else
                -- Pattern 5: references a real register + _s for maximum authenticity
                local regKeys = {}
                for k in pairs(self.registerVars) do
                    if type(k) == "number" and k < constants.MAX_REGS then
                        table.insert(regKeys, k)
                    end
                end
                if #regKeys > 0 then
                    local regId  = regKeys[math.random(#regKeys)]
                    local regVid = self.registerVars[regId]
                    fb:addReferenceToHigherScope(self.containerFuncScope, regVid)
                    local c1 = fb:addVariable()
                    return Ast.Block({
                        Ast.LocalVariableDeclaration(fb, {c1}, {
                            Ast.AddExpression(
                                Ast.MulExpression(
                                    Ast.VariableExpression(self.containerFuncScope, regVid),
                                    Ast.VariableExpression(self.containerFuncScope, stateVar)),
                                Ast.NumberExpression(K1c)) }),
                        killPos(fb),
                    }, fb)
                else
                    local c1 = fb:addVariable()
                    return Ast.Block({
                        Ast.LocalVariableDeclaration(fb, {c1}, {
                            Ast.AddExpression(
                                Ast.NumberExpression(K1c),
                                Ast.NumberExpression(K2c)) }),
                        killPos(fb),
                    }, fb)
                end
            end
        end

        for i = 1, isolatedFakeCount do
            local fakeSlot
            repeat fakeSlot = math.random(1, 2^24)
            until not self.usedBlockIds[fakeSlot]
            self.usedBlockIds[fakeSlot] = true

            local pattern = ((i - 1) % 5) + 1
            if math.random(2) == 1 then pattern = math.random(1, 5) end

            local fhScope  = Scope:new(self.containerFuncScope)
            local fakeBody = buildFakeHandlerBodyChaos(pattern, fhScope)
            local fakeFunc = Ast.FunctionLiteralExpression({}, fakeBody, nil)
            table.insert(handlerEntries, { key = fakeSlot, func = fakeFunc })
        end

        -- ---- Shuffle both tables so real/fake are interleaved ----
        util.shuffle(handlerEntries)
        util.shuffle(idxEntries)

        -- ---- Build _ops[slot] = handler statements ----
        local opsAssignStats = {}
        for _, entry in ipairs(handlerEntries) do
            local aScope = Scope:new(self.containerFuncScope)
            aScope:addReferenceToHigherScope(self.containerFuncScope, opsVar)
            table.insert(opsAssignStats, Ast.AssignmentStatement(
                { Ast.AssignmentIndexing(
                    Ast.VariableExpression(self.containerFuncScope, opsVar),
                    Ast.NumberExpression(entry.key)) },
                { entry.func }
            ))
        end

        -- ---- Build _idx[logId] = physSlot statements ----
        local idxAssignStats = {}
        for _, entry in ipairs(idxEntries) do
            local aScope = Scope:new(self.containerFuncScope)
            aScope:addReferenceToHigherScope(self.containerFuncScope, idxVar)
            table.insert(idxAssignStats, Ast.AssignmentStatement(
                { Ast.AssignmentIndexing(
                    Ast.VariableExpression(self.containerFuncScope, idxVar),
                    Ast.NumberExpression(entry.logId)) },
                { Ast.NumberExpression(entry.phys) }
            ))
        end

        -- ---- Build chaos dispatch while body ----
        -- while pos do
        --   _s = (_s * K1 + pos) % PRIME
        --   _ops[_idx[pos]]()
        -- end
        if self.whileScope then self.whileScope:setParent(self.containerFuncScope) end
        self.whileScope:addReferenceToHigherScope(self.containerFuncScope, self.posVar)
        self.whileScope:addReferenceToHigherScope(self.containerFuncScope, opsVar)
        self.whileScope:addReferenceToHigherScope(self.containerFuncScope, idxVar)
        self.whileScope:addReferenceToHigherScope(self.containerFuncScope, stateVar)
        self.containerFuncScope:addReferenceToHigherScope(self.scope, self.unpackVar)

        -- _s = (_s * K1 + pos) % PRIME
        local stateUpdateStmt = Ast.AssignmentStatement(
            { Ast.AssignmentVariable(self.containerFuncScope, stateVar) },
            { Ast.ModExpression(
                Ast.AddExpression(
                    Ast.MulExpression(
                        Ast.VariableExpression(self.containerFuncScope, stateVar),
                        Ast.NumberExpression(K1)),
                    Ast.VariableExpression(self.containerFuncScope, self.posVar)),
                Ast.NumberExpression(PRIME)) }
        )

        -- _ops[_idx[pos]]()
        local dispatchStmt = Ast.FunctionCallStatement(
            Ast.IndexExpression(
                Ast.VariableExpression(self.containerFuncScope, opsVar),
                Ast.IndexExpression(
                    Ast.VariableExpression(self.containerFuncScope, idxVar),
                    self:pos(self.whileScope))),
            {})

        local whileBody = Ast.Block({ stateUpdateStmt, dispatchStmt }, self.whileScope)

        -- ---- Assemble container function body ----
        --
        -- Register-limit strategy — same principle as OpcodeDispatch:
        --   _ops and _idx are declared outside the do...end fence so the
        --   while loop's dispatch expression (_ops[_idx[pos]]()) can still
        --   read both tables.  All handler-assignment and index-map-assignment
        --   statements are placed inside a single do...end block so that Luau
        --   reclaims every closure-init temporary before the while loop begins.
        --
        local declarations = { self.returnVar }
        for i, var in pairs(self.registerVars) do
            if i ~= MAX_REGS then table.insert(declarations, var) end
        end

        local stats = {}
        if self.maxUsedRegister >= MAX_REGS then
            table.insert(stats, Ast.LocalVariableDeclaration(
                self.containerFuncScope,
                { self.registerVars[MAX_REGS] },
                { Ast.TableConstructorExpression({}) }))
        end

        table.insert(stats, Ast.LocalVariableDeclaration(
            self.containerFuncScope, util.shuffle(declarations), {}))

        -- _ops, _idx, _s declared in outer scope (needed by while loop)
        table.insert(stats, Ast.LocalVariableDeclaration(
            self.containerFuncScope, { opsVar }, { Ast.TableConstructorExpression({}) }))
        table.insert(stats, Ast.LocalVariableDeclaration(
            self.containerFuncScope, { idxVar }, { Ast.TableConstructorExpression({}) }))
        table.insert(stats, Ast.LocalVariableDeclaration(
            self.containerFuncScope, { stateVar }, { Ast.NumberExpression(SEED) }))

        -- ── Dual scope fence ─────────────────────────────────────────────────
        -- Merge _ops[slot]=handler  AND  _idx[logId]=phys  into one do...end
        -- block.  Luau reclaims all closure-init and arithmetic temporaries
        -- from both init sequences before the while-dispatch loop begins.
        local chaosInitScope = Scope:new(self.containerFuncScope)
        local chaosInitStats = {}
        for _, stmt in ipairs(opsAssignStats) do chaosInitStats[#chaosInitStats+1] = stmt end
        for _, stmt in ipairs(idxAssignStats) do chaosInitStats[#chaosInitStats+1] = stmt end
        table.insert(stats, Ast.DoStatement(Ast.Block(chaosInitStats, chaosInitScope)))

        -- while pos do
        --   _s = (_s * K1 + pos) % PRIME
        --   _ops[_idx[pos]]()
        -- end
        table.insert(stats, Ast.WhileStatement(
            whileBody, Ast.VariableExpression(self.containerFuncScope, self.posVar)))

        -- GC sentinel cleanup
        table.insert(stats, Ast.AssignmentStatement(
            { Ast.AssignmentVariable(self.containerFuncScope, self.posVar) },
            { Ast.LenExpression(Ast.VariableExpression(self.containerFuncScope, self.detectGcCollectVar)) }))

        -- return unpack(returnVar)
        table.insert(stats, Ast.ReturnStatement{
            Ast.FunctionCallExpression(
                Ast.VariableExpression(self.scope, self.unpackVar),
                { Ast.VariableExpression(self.containerFuncScope, self.returnVar) })
        })

        return Ast.Block(stats, self.containerFuncScope)
    end

    -- -------------------------------------------------------------------------
    -- NEW: Opcode-dispatch-table body
    --
    -- Architecture (mirrors Luraph v14.6):
    --   local _ops = {}
    --   _ops[blockId_1] = function() ... end   -- real handler
    --   _ops[blockId_2] = function() ... end
    --   ...
    --   _ops[fakeId_1]  = function() end       -- noise handler (never called)
    --   ...
    --   while pos do _ops[pos]() end
    --
    -- Each handler is a closure over the VM's register locals and pos/return,
    -- so it can read/write them as upvalues. Handler assignments are shuffled
    -- to remove any ordering clues.
    -- -------------------------------------------------------------------------
    function Compiler:emitContainerFuncBodyOpcodeDispatch()
        local blocks = buildSortedBlocks(self);

        -- Variable for the dispatch table itself, declared in containerFuncScope
        local opsVar = self.containerFuncScope:addVariable();

        -- ---- Build real opcode handlers ----
        local handlerEntries = {}; -- { id, funcNode }

        for _, blockEntry in ipairs(blocks) do
            -- Create a new scope for the handler function boundary.
            -- After setParent, block.scope's variablesFromHigherScopes are
            -- re-propagated through handlerFuncScope → containerFuncScope,
            -- so all register/pos upvalue captures are correctly tracked.
            local handlerFuncScope = Scope:new(self.containerFuncScope);
            blockEntry.block.scope:setParent(handlerFuncScope);

            -- function() [block statements] end
            local handlerFunc = Ast.FunctionLiteralExpression(
                {}, blockEntry.block, nil);

            table.insert(handlerEntries, { id = blockEntry.id, func = handlerFunc });
        end

        -- ---- Inject fake/noise opcode handlers ----
        -- These are never dispatched to; they exist purely to inflate the
        -- opcode table and mislead static analysis tools.
        --
        -- 5 polymorphic body patterns are cycled randomly to defeat
        -- clustering / pattern-matching by deobfuscators:
        --
        --   Pattern 1: trivial  pos = false
        --   Pattern 2: local chain   (2 intermediates) + pos = false
        --   Pattern 3: fake conditional (both branches kill pos)
        --   Pattern 4: three-step arithmetic pipeline + pos = false
        --   Pattern 5: register-flavoured (references a real register var)
        --
        -- All terminate the VM safely if ever reached (pos becomes falsy).

        -- Helper: build one fake handler body with the given pattern index.
        local function buildFakeHandlerBody(pattern, fhScope)
            local fbScope = Scope:new(fhScope);
            fbScope:addReferenceToHigherScope(self.containerFuncScope, self.posVar);

            local K1 = math.random(3, 997);
            local K2 = math.random(3, 997);
            local K3 = math.random(3, 997);

            -- Shared terminal: pos = false
            local function killPos(scope)
                scope:addReferenceToHigherScope(self.containerFuncScope, self.posVar);
                return Ast.AssignmentStatement(
                    { Ast.AssignmentVariable(self.containerFuncScope, self.posVar) },
                    { Ast.BooleanExpression(false) });
            end

            if pattern == 1 then
                -- Trivial: pos = false
                return Ast.Block({ killPos(fbScope) }, fbScope);

            elseif pattern == 2 then
                -- Local computation chain (2 intermediates) then kill pos
                local c1 = fbScope:addVariable();
                local c2 = fbScope:addVariable();
                return Ast.Block({
                    Ast.LocalVariableDeclaration(fbScope, {c1}, {
                        Ast.AddExpression(
                            Ast.MulExpression(
                                Ast.NumberExpression(K1),
                                Ast.VariableExpression(self.containerFuncScope, self.posVar)),
                            Ast.NumberExpression(K2))
                    }),
                    Ast.LocalVariableDeclaration(fbScope, {c2}, {
                        Ast.SubExpression(
                            Ast.MulExpression(
                                Ast.VariableExpression(fbScope, c1),
                                Ast.NumberExpression(K3)),
                            Ast.NumberExpression(K1))
                    }),
                    killPos(fbScope),
                }, fbScope);

            elseif pattern == 3 then
                -- Fake conditional: constant comparison that looks dynamic,
                -- both branches terminate the VM (one with false, one with nil).
                local cVar = fbScope:addVariable();
                local thenScp = Scope:new(fbScope);
                thenScp:addReferenceToHigherScope(self.containerFuncScope, self.posVar);
                local elseScp = Scope:new(fbScope);
                elseScp:addReferenceToHigherScope(self.containerFuncScope, self.posVar);

                return Ast.Block({
                    Ast.LocalVariableDeclaration(fbScope, {cVar}, {
                        Ast.AddExpression(
                            Ast.MulExpression(Ast.NumberExpression(K1), Ast.NumberExpression(K2)),
                            Ast.NumberExpression(K3))
                    }),
                    Ast.IfStatement(
                        Ast.GreaterThanExpression(
                            Ast.VariableExpression(fbScope, cVar),
                            Ast.NumberExpression(math.random(0x4000, 0xEFFF))),
                        Ast.Block({ killPos(thenScp) }, thenScp),
                        {},
                        Ast.Block({
                            Ast.AssignmentStatement(
                                { Ast.AssignmentVariable(self.containerFuncScope, self.posVar) },
                                { Ast.NilExpression() })
                        }, elseScp)),
                }, fbScope);

            elseif pattern == 4 then
                -- Three-step arithmetic pipeline with modulo + pos kill
                local c1 = fbScope:addVariable();
                local c2 = fbScope:addVariable();
                local c3 = fbScope:addVariable();
                return Ast.Block({
                    Ast.LocalVariableDeclaration(fbScope, {c1}, {
                        Ast.MulExpression(
                            Ast.VariableExpression(self.containerFuncScope, self.posVar),
                            Ast.NumberExpression(K1))
                    }),
                    Ast.LocalVariableDeclaration(fbScope, {c2}, {
                        Ast.AddExpression(
                            Ast.VariableExpression(fbScope, c1),
                            Ast.NumberExpression(K2))
                    }),
                    Ast.LocalVariableDeclaration(fbScope, {c3}, {
                        Ast.ModExpression(
                            Ast.VariableExpression(fbScope, c2),
                            Ast.NumberExpression(K3))
                    }),
                    killPos(fbScope),
                }, fbScope);

            else
                -- Pattern 5: reference a real register variable to look like
                -- a legitimate handler that reads/writes VM registers.
                -- Falls back to a two-local chain when no registers exist yet.
                local regKeys = {};
                for k in pairs(self.registerVars) do
                    if type(k) == "number" and k < MAX_REGS then
                        table.insert(regKeys, k);
                    end
                end

                if #regKeys > 0 then
                    local regId    = regKeys[math.random(#regKeys)];
                    local regVarId = self.registerVars[regId];
                    fbScope:addReferenceToHigherScope(self.containerFuncScope, regVarId);
                    local c1 = fbScope:addVariable();
                    local c2 = fbScope:addVariable();
                    return Ast.Block({
                        Ast.LocalVariableDeclaration(fbScope, {c1}, {
                            Ast.AddExpression(
                                Ast.VariableExpression(self.containerFuncScope, regVarId),
                                Ast.NumberExpression(K1))
                        }),
                        Ast.LocalVariableDeclaration(fbScope, {c2}, {
                            Ast.SubExpression(
                                Ast.MulExpression(
                                    Ast.VariableExpression(fbScope, c1),
                                    Ast.NumberExpression(K2)),
                                Ast.NumberExpression(K3))
                        }),
                        killPos(fbScope),
                    }, fbScope);
                else
                    -- No registers yet — plain two-local fallback
                    local c1 = fbScope:addVariable();
                    return Ast.Block({
                        Ast.LocalVariableDeclaration(fbScope, {c1}, {
                            Ast.AddExpression(
                                Ast.NumberExpression(K1),
                                Ast.NumberExpression(K2))
                        }),
                        killPos(fbScope),
                    }, fbScope);
                end
            end
        end

        local fakeCount = self.fakeOpcodeCount or 12;
        for i = 1, fakeCount do
            local fakeId;
            repeat fakeId = math.random(1, 2^24);
            until not self.usedBlockIds[fakeId];
            self.usedBlockIds[fakeId] = true;

            -- When statefulFakeOps is true: cycle all 5 polymorphic patterns.
            -- When false: use the trivial pattern-1 only (original behaviour).
            local pattern;
            if self.statefulFakeOps then
                pattern = ((i - 1) % 5) + 1;
                if math.random(2) == 1 then
                    pattern = math.random(1, 5);
                end
            else
                pattern = 1;
            end

            local fakeHandlerFuncScope = Scope:new(self.containerFuncScope);
            local fakeBody = buildFakeHandlerBody(pattern, fakeHandlerFuncScope);
            local fakeFunc = Ast.FunctionLiteralExpression({}, fakeBody, nil);
            table.insert(handlerEntries, { id = fakeId, func = fakeFunc });
        end

        -- Shuffle assignment order so real vs fake are interleaved randomly
        util.shuffle(handlerEntries);

        -- Build _ops[id] = func statements
        local opsAssignStats = {};
        for _, entry in ipairs(handlerEntries) do
            local assignScope = Scope:new(self.containerFuncScope);
            assignScope:addReferenceToHigherScope(self.containerFuncScope, opsVar);
            table.insert(opsAssignStats, Ast.AssignmentStatement(
                { Ast.AssignmentIndexing(
                    Ast.VariableExpression(self.containerFuncScope, opsVar),
                    Ast.NumberExpression(entry.id)) },
                { entry.func }
            ));
        end

        -- ---- Build while body: _ops[pos]() ----
        if self.whileScope then
            self.whileScope:setParent(self.containerFuncScope);
        end
        self.whileScope:addReferenceToHigherScope(self.containerFuncScope, self.posVar);
        self.whileScope:addReferenceToHigherScope(self.containerFuncScope, opsVar);
        self.containerFuncScope:addReferenceToHigherScope(self.scope, self.unpackVar);

        local whileBody = Ast.Block({
            Ast.FunctionCallStatement(
                Ast.IndexExpression(
                    Ast.VariableExpression(self.containerFuncScope, opsVar),
                    self:pos(self.whileScope)),
                {})
        }, self.whileScope);

        -- ── Assemble the container function body ────────────────────────────────
        --
        -- Register-limit strategy (Luau 255-register hard limit):
        --
        --   The container function has ~25 declared registers (params + locals).
        --   The remaining ~230 headroom is consumed by Luau's temporaries during
        --   expression evaluation.
        --
        --   Problem: without a scope fence, Luau's live-variable analysis treats
        --   every upvalue-source register referenced by the CLOSURE pseudo-
        --   instructions of the handler closures as simultaneously live across the
        --   ENTIRE flat statement list (ops-init + while loop).  On a large script
        --   with 200+ handlers this exhausts the 255-register budget.
        --
        --   Fix: wrap all _ops[n]=handler assignments inside a do...end block.
        --   Luau's compiler sees the block boundary, reclaims all temporary
        --   registers used during the closure-init phase, and starts the while
        --   loop with a clean register window.  _opsVar is declared OUTSIDE the
        --   do block (in containerFuncScope) so the while loop can still read it.
        --
        local declarations = { self.returnVar };
        for i, var in pairs(self.registerVars) do
            if i ~= MAX_REGS then table.insert(declarations, var); end
        end

        local stats = {};

        -- Spill table for registers >= MAX_REGS (same as original emit)
        if self.maxUsedRegister >= MAX_REGS then
            table.insert(stats, Ast.LocalVariableDeclaration(
                self.containerFuncScope,
                { self.registerVars[MAX_REGS] },
                { Ast.TableConstructorExpression({}) }));
        end

        -- Register locals + returnVar (shuffled)
        table.insert(stats, Ast.LocalVariableDeclaration(
            self.containerFuncScope, util.shuffle(declarations), {}));

        -- local _ops = {}   (declared in outer scope so the while loop can see it)
        table.insert(stats, Ast.LocalVariableDeclaration(
            self.containerFuncScope, { opsVar }, { Ast.TableConstructorExpression({}) }));

        -- ── Scope fence: wrap all handler-assignment statements in do...end ──
        -- This lets Luau reclaim every closure-init temporary before the while
        -- loop begins, preventing the 255-register overflow on large scripts.
        local opsInitScope = Scope:new(self.containerFuncScope);
        local opsInitStats = {};
        for _, stmt in ipairs(opsAssignStats) do
            table.insert(opsInitStats, stmt);
        end
        table.insert(stats, Ast.DoStatement(Ast.Block(opsInitStats, opsInitScope)));

        -- while pos do _ops[pos]() end
        table.insert(stats, Ast.WhileStatement(
            whileBody, Ast.VariableExpression(self.containerFuncScope, self.posVar)));

        -- GC-sentinel cleanup (same as original)
        table.insert(stats, Ast.AssignmentStatement(
            { Ast.AssignmentVariable(self.containerFuncScope, self.posVar) },
            { Ast.LenExpression(Ast.VariableExpression(self.containerFuncScope, self.detectGcCollectVar)) }));

        -- return unpack(returnVar)
        table.insert(stats, Ast.ReturnStatement{
            Ast.FunctionCallExpression(
                Ast.VariableExpression(self.scope, self.unpackVar),
                { Ast.VariableExpression(self.containerFuncScope, self.returnVar) })
        });

        return Ast.Block(stats, self.containerFuncScope);
    end

end
