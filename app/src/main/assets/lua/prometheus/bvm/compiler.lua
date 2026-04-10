-- ============================================================
--  bvm/compiler.lua
--  Bytecode VM Compiler
--
--  Walks a Prometheus AST and compiles each function into a
--  "proto" (function prototype) containing:
--    code     : flat numeric bytecode array  [op,A,B,C, ...]
--    k        : constant pool (1-based)
--    protos   : nested child proto indices (1-based into all_protos)
--    upvaldefs: [{instack=bool, idx=number}] – upvalue capture descriptors
--    numparams: fixed parameter count
--    is_vararg: boolean
--    maxstack : max registers used
--
--  Variable resolution order (per proto):
--    1. Local in current proto's varmap → "local", reg
--    2. Captured from outer proto       → "upvalue", idx
--    3. Not found in any proto          → "global", key=name_string
--
--  Upvalue boxing:
--    Captured locals are maintained as {v=value} boxes on the
--    runtime stack so that inner functions can mutate them.
--    open_upvals[reg] tracks which registers are currently boxed.
--    OP_CLOSE seals all boxes for registers >= A on scope exit.
-- ============================================================

local ISA = require("prometheus.bvm.isa")

local Ast    -- loaded lazily from prometheus
local AstKind

local CONST_BIAS = ISA.CONST_BIAS
local FIELDS     = ISA.FIELDS

-- ── Proto state constructor ────────────────────────────────────────────────
local function newProtoState(parent, numparams, is_vararg)
    return {
        code       = {},    -- flat bytecode array
        k          = {},    -- constant pool
        kmap       = {},    -- dedup: "type:value" → 1-based index
        protos     = {},    -- child proto indices into compiler.all_protos
        upvaldefs  = {},    -- [{instack, idx}]  (parallel to runtime upvals[])
        numparams  = numparams or 0,
        is_vararg  = is_vararg or false,
        parent     = parent,
        nextreg    = numparams or 0,  -- next free register (0-based)
        maxstack   = numparams or 0,
        -- Variable maps
        varmap     = {},    -- [scope_obj][var_id] = register
        upvalcache = {},    -- [scope_obj][var_id] = upval_index (1-based)
        -- Captured-register tracking (which registers have been closed into boxes)
        captured   = {},    -- reg → true  (this proto's locals captured by children)
        -- Scope stack for push/pop
        scope_stack = {},
        -- Loop control patch lists (stacked)
        loop_stack  = {},
    }
end

-- ── Compiler class ─────────────────────────────────────────────────────────
local Compiler = {}
Compiler.__index = Compiler

function Compiler.new(op)
    local c = setmetatable({}, Compiler)
    c.op        = op          -- name → numeric opcode id
    c.all_protos = {}         -- linear list of all protos in DFS order
    c.state_stack = {}        -- stack of proto states (depth = function nesting)
    c.state      = nil        -- current proto state
    return c
end

-- ── Constant pool ─────────────────────────────────────────────────────────
function Compiler:addK(value)
    local key
    if     value == nil           then key = "nil:"
    elseif value == true          then key = "bool:true"
    elseif value == false         then key = "bool:false"
    elseif type(value) == "number" then key = "num:" .. tostring(value)
    elseif type(value) == "string" then key = "str:" .. value
    else error("BVM: unsupported constant type " .. type(value)) end

    local st = self.state
    if st.kmap[key] then return st.kmap[key] end
    local idx = #st.k + 1
    st.k[idx]   = value
    st.kmap[key] = idx
    return idx
end

-- Add constant and return RK-encoded index (>= CONST_BIAS)
function Compiler:addKrk(value)
    return self:addK(value) + CONST_BIAS - 1
end

-- ── Instruction emission ───────────────────────────────────────────────────
-- Returns the code-array index of the first field of this instruction.
function Compiler:emit(opname, A, B, C)
    local st   = self.state
    local code = st.code
    local pos  = #code + 1
    code[pos]   = self.op[opname]
    code[pos+1] = A or 0
    code[pos+2] = B or 0
    code[pos+3] = C or 0
    -- Track max stack
    if A and A + 1 > st.maxstack then st.maxstack = A + 1 end
    return pos
end

-- Emit OP_JMP with placeholder B; return pos for later patching.
function Compiler:emitJmp()
    return self:emit("OP_JMP", 0, 0, 0)
end

-- Current PC = position of next instruction to be emitted (1-based array index)
function Compiler:currentPC()
    return #self.state.code + 1
end

-- Patch a JMP at instruction position `jmp_pos` to jump to `target_pc`.
-- The VM advances PC by FIELDS before executing the jump offset, so:
--   target_pc = (jmp_pos + FIELDS) + B  →  B = target_pc - jmp_pos - FIELDS
function Compiler:patchJmp(jmp_pos, target_pc)
    self.state.code[jmp_pos + 2] = target_pc - jmp_pos - FIELDS
end

-- ── Register allocator ─────────────────────────────────────────────────────
function Compiler:allocReg(n)
    n = n or 1
    local st = self.state
    local r  = st.nextreg
    st.nextreg = st.nextreg + n
    if st.nextreg > st.maxstack then st.maxstack = st.nextreg end
    return r
end

function Compiler:freeReg(n)
    self.state.nextreg = self.state.nextreg - (n or 1)
end

-- Ensure register r is valid (expand nextreg if needed).
function Compiler:touchReg(r)
    local st = self.state
    if r + 1 > st.nextreg  then st.nextreg  = r + 1 end
    if r + 1 > st.maxstack then st.maxstack = r + 1 end
end

-- ── Scope management ──────────────────────────────────────────────────────
function Compiler:pushScope()
    local st = self.state
    table.insert(st.scope_stack, {
        nextreg     = st.nextreg,
        locals_top  = self:_countLocals(),
    })
end

function Compiler:_countLocals()
    local st = self.state
    local n  = 0
    for _ in pairs(st.varmap) do
        -- count across all scopes; we only need to track local count in
        -- the current proto, which is approximated by nextreg - numparams
    end
    return st.nextreg  -- simpler: just track nextreg
end

function Compiler:popScope(emit_close)
    local st  = self.state
    local top = table.remove(st.scope_stack)
    local min_reg = top.nextreg  -- first register going out of scope

    -- If any registers in [min_reg, nextreg) were captured, emit OP_CLOSE
    if emit_close then
        local needs_close = false
        for r = min_reg, st.nextreg - 1 do
            if st.captured[r] then needs_close = true; break end
        end
        if needs_close then
            self:emit("OP_CLOSE", min_reg, 0, 0)
        end
    end

    -- Reclaim registers for variables declared in this scope
    -- (Remove them from varmap so lookups don't find them anymore)
    for scope_obj, vars in pairs(st.varmap) do
        for var_id, reg in pairs(vars) do
            if reg >= min_reg then
                vars[var_id] = nil
            end
        end
    end

    st.nextreg = min_reg
end

-- ── Variable declaration ───────────────────────────────────────────────────
function Compiler:declareLocal(scope_obj, var_id)
    local r  = self:allocReg(1)
    local st = self.state
    if not st.varmap[scope_obj] then st.varmap[scope_obj] = {} end
    st.varmap[scope_obj][var_id] = r
    return r
end

-- ── Variable resolution ───────────────────────────────────────────────────
-- Returns: "local", reg | "upvalue", idx | "global", nil
-- Recursively walks proto stack to detect upvalue capture.
function Compiler:resolveVar(scope_obj, var_id)
    local st = self.state

    -- 1. Local in current proto
    if st.varmap[scope_obj] and st.varmap[scope_obj][var_id] ~= nil then
        return "local", st.varmap[scope_obj][var_id]
    end

    -- 2. Already-resolved upvalue in current proto
    if st.upvalcache[scope_obj] and st.upvalcache[scope_obj][var_id] ~= nil then
        return "upvalue", st.upvalcache[scope_obj][var_id]
    end

    -- 3. Look in parent proto (requires crossing a function boundary → upvalue)
    if st.parent then
        -- Temporarily switch state to parent to resolve there
        local saved = self.state
        self.state  = st.parent
        local kind, idx = self:resolveVar(scope_obj, var_id)
        self.state  = saved

        if kind == "local" then
            -- Mark the parent's register as captured
            st.parent.captured[idx] = true
            -- Add upvalue descriptor: instack=true, idx=parent_reg
            local upval_idx = #st.upvaldefs + 1
            st.upvaldefs[upval_idx] = {instack = true, idx = idx}
            if not st.upvalcache[scope_obj] then st.upvalcache[scope_obj] = {} end
            st.upvalcache[scope_obj][var_id] = upval_idx
            return "upvalue", upval_idx
        elseif kind == "upvalue" then
            -- Propagate: capture from parent's upvalue list
            local upval_idx = #st.upvaldefs + 1
            st.upvaldefs[upval_idx] = {instack = false, idx = idx}
            if not st.upvalcache[scope_obj] then st.upvalcache[scope_obj] = {} end
            st.upvalcache[scope_obj][var_id] = upval_idx
            return "upvalue", upval_idx
        end
    end

    -- 4. Global
    return "global", nil
end

-- ── RK helper: produce RK-encoded B/C for an expression ─────────────────
-- If the expression is a simple constant, returns its RK directly.
-- Otherwise compiles it into `dst` register and returns dst.
-- Also returns a "used_reg" boolean so caller knows if dst was consumed.
function Compiler:exprToRK(expr, dst)
    local kind = expr.kind
    if kind == AstKind.NumberExpression then
        return self:addKrk(expr.value), false
    elseif kind == AstKind.StringExpression then
        return self:addKrk(expr.value), false
    elseif kind == AstKind.BooleanExpression then
        return self:addKrk(expr.value), false
    elseif kind == AstKind.NilExpression then
        return self:addKrk(nil), false
    else
        self:compileExpr(expr, dst)
        return dst, true
    end
end

-- ── Push/pop function-level state ─────────────────────────────────────────
function Compiler:pushProto(numparams, is_vararg)
    local parent = self.state
    local st     = newProtoState(parent, numparams, is_vararg)
    table.insert(self.state_stack, parent)
    self.state = st
    return st
end

function Compiler:popProto()
    local st = self.state
    -- Register this proto into the global list
    local proto_idx = #self.all_protos + 1
    self.all_protos[proto_idx] = st
    st.proto_idx = proto_idx

    -- Emit implicit OP_RETURN at end (B=1 → 0 return values)
    -- Only if the last instruction isn't already a return/tailcall.
    local code = st.code
    local last_op = code[#code - FIELDS + 1]  -- op field of last instruction
    if last_op ~= self.op["OP_RETURN"] and last_op ~= self.op["OP_TAILCALL"] then
        self:emit("OP_RETURN", 0, 1, 0)
    end

    -- Restore parent
    self.state = table.remove(self.state_stack)
    return proto_idx
end

-- ── Loop control stack ─────────────────────────────────────────────────────
function Compiler:pushLoop()
    table.insert(self.state.loop_stack, {breaks = {}, continue_jumps = {}})
end

function Compiler:popLoop(loop_end_pc, continue_pc)
    local info = table.remove(self.state.loop_stack)
    -- Patch all break jumps to the instruction AFTER the loop
    for _, jmp_pos in ipairs(info.breaks) do
        self:patchJmp(jmp_pos, loop_end_pc)
    end
    -- Patch all continue jumps to the loop-back position (or loop_end if not provided)
    if info.continue_jumps and #info.continue_jumps > 0 then
        local target = continue_pc or loop_end_pc
        for _, jmp_pos in ipairs(info.continue_jumps) do
            self:patchJmp(jmp_pos, target)
        end
    end
end

function Compiler:emitBreak()
    local st = self.state
    if #st.loop_stack == 0 then
        error("BVM: break outside loop")
    end
    local jmp_pos = self:emitJmp()
    table.insert(st.loop_stack[#st.loop_stack].breaks, jmp_pos)
end

function Compiler:emitContinue()
    local st = self.state
    if #st.loop_stack == 0 then
        error("BVM: continue outside loop")
    end
    local loop_info = st.loop_stack[#st.loop_stack]
    if not loop_info.continue_jumps then
        loop_info.continue_jumps = {}
    end
    local jmp_pos = self:emitJmp()
    table.insert(loop_info.continue_jumps, jmp_pos)
end

-- ══════════════════════════════════════════════════════════════════════════
--  EXPRESSION COMPILATION
-- ══════════════════════════════════════════════════════════════════════════
-- compileExpr(node, dst, nret)
--   Compiles expression `node`, placing result in register `dst`.
--   `nret`:  1  = single value (default)
--            0  = discard (only for side effects, e.g., a call stmt)
--           -1  = multi-value (for call at end of expression list)
--   Returns the actual destination register used (may differ from dst
--   when the expression is itself a register reference).

function Compiler:compileExpr(node, dst, nret)
    nret = nret or 1
    local kind = node.kind

    -- ── Simple literals ─────────────────────────────────────────────────
    if kind == AstKind.NumberExpression then
        self:emit("OP_LOADK", dst, self:addK(node.value), 0)
        return dst

    elseif kind == AstKind.StringExpression then
        self:emit("OP_LOADK", dst, self:addK(node.value), 0)
        return dst

    elseif kind == AstKind.BooleanExpression then
        self:emit("OP_LOADBOOL", dst, node.value and 1 or 0, 0)
        return dst

    elseif kind == AstKind.NilExpression then
        self:emit("OP_LOADNIL", dst, 0, 0)
        return dst

    elseif kind == AstKind.VarargExpression then
        -- Stack[dst..dst+nret-2] = vararg  (nret=-1 → B=0: all vararg)
        local B = (nret == -1) and 0 or (nret + 1)
        self:emit("OP_VARARG", dst, B, 0)
        return dst

    -- ── Variable access ─────────────────────────────────────────────────
    elseif kind == AstKind.VariableExpression then
        local vkind, vidx = self:resolveVar(node.scope, node.id)
        if vkind == "local" then
            if vidx ~= dst then
                self:emit("OP_MOVE", dst, vidx, 0)
            end
            return dst
        elseif vkind == "upvalue" then
            self:emit("OP_GETUPVAL", dst, vidx, 0)
            return dst
        else -- global
            -- Look up the variable's name from scope
            local name = self:_varName(node.scope, node.id)
            self:emit("OP_GETGLOBAL", dst, self:addK(name), 0)
            return dst
        end

    -- ── Table index ─────────────────────────────────────────────────────
    elseif kind == AstKind.IndexExpression then
        local t_reg = self:allocReg(1)
        self:compileExpr(node.base, t_reg)
        local c_rk, used = self:exprToRK(node.index, dst)
        if used and c_rk == dst then
            -- dst was consumed by the index; use a temp
            local idx_tmp = self:allocReg(1)
            self:compileExpr(node.index, idx_tmp)
            self:emit("OP_GETTABLE", dst, t_reg, idx_tmp)
            self:freeReg(1)
        else
            self:emit("OP_GETTABLE", dst, t_reg, c_rk)
        end
        self:freeReg(1) -- free t_reg
        return dst

    -- ── Arithmetic / comparison binary ops ─────────────────────────────
    elseif self:_isBinaryArith(kind) then
        return self:compileBinaryArith(node, dst)

    elseif kind == AstKind.StrCatExpression then
        return self:compileConcat(node, dst)

    elseif kind == AstKind.NegateExpression then
        local tmp = self:allocReg(1)
        self:compileExpr(node.rhs, tmp)
        self:emit("OP_UNM", dst, tmp, 0)
        self:freeReg(1)
        return dst

    elseif kind == AstKind.NotExpression then
        local tmp = self:allocReg(1)
        self:compileExpr(node.rhs, tmp)
        self:emit("OP_NOT", dst, tmp, 0)
        self:freeReg(1)
        return dst

    elseif kind == AstKind.LenExpression then
        local tmp = self:allocReg(1)
        self:compileExpr(node.rhs, tmp)
        self:emit("OP_LEN", dst, tmp, 0)
        self:freeReg(1)
        return dst

    -- ── Short-circuit boolean ops ────────────────────────────────────────
    elseif kind == AstKind.AndExpression then
        self:compileExpr(node.lhs, dst)
        local test_pos = self:emit("OP_TESTSET", dst, dst, 0)  -- if false, skip JMP
        local jmp_pos  = self:emitJmp()
        self:compileExpr(node.rhs, dst)
        self:patchJmp(jmp_pos, self:currentPC())
        -- patch the TESTSET's C=1 means: skip (jump over rhs) if Stack[dst] IS falsy
        self.state.code[test_pos + 3] = 0   -- C=0: skip if falsy (and-short-circuit)
        return dst

    elseif kind == AstKind.OrExpression then
        self:compileExpr(node.lhs, dst)
        local test_pos = self:emit("OP_TESTSET", dst, dst, 1)  -- if true, skip JMP
        local jmp_pos  = self:emitJmp()
        self:compileExpr(node.rhs, dst)
        self:patchJmp(jmp_pos, self:currentPC())
        return dst

    -- ── Comparison ops (produce a boolean result) ────────────────────────
    elseif self:_isComparison(kind) then
        return self:compileComparison(node, dst)

    -- ── Function call expression ─────────────────────────────────────────
    elseif kind == AstKind.FunctionCallExpression then
        return self:compileFuncCall(node, dst, nret)

    elseif kind == AstKind.PassSelfFunctionCallExpression then
        return self:compileSelfCall(node, dst, nret)

    -- ── Table constructor ────────────────────────────────────────────────
    elseif kind == AstKind.TableConstructorExpression then
        return self:compileTableConstructor(node, dst)

    -- ── Function literal ─────────────────────────────────────────────────
    elseif kind == AstKind.FunctionLiteralExpression then
        return self:compileFunctionLiteral(node, dst)

    -- ── IfElse expression (Luau ternary) ────────────────────────────────
    elseif kind == AstKind.IfElseExpression then
        return self:compileIfElseExpr(node, dst)

    else
        error("BVM compiler: unhandled expression kind: " .. tostring(kind))
    end
end

-- ── Binary arithmetic helper ──────────────────────────────────────────────
local BINOP_MAP = {
    [true]  = {},  -- placeholder; filled below
}
local ARITH_KINDS   -- forward ref; built after AstKind is loaded
local COMPARE_KINDS -- forward ref

function Compiler:_isBinaryArith(kind)
    if not ARITH_KINDS then return false end
    return ARITH_KINDS[kind] ~= nil
end

function Compiler:_isComparison(kind)
    if not COMPARE_KINDS then return false end
    return COMPARE_KINDS[kind] ~= nil
end

function Compiler:compileBinaryArith(node, dst)
    local opname = ARITH_KINDS[node.kind]
    local tmp1   = self:allocReg(1)
    local tmp2   = self:allocReg(1)
    local b_rk, b_used = self:exprToRK(node.lhs,  tmp1)
    local c_rk, c_used = self:exprToRK(node.rhs, tmp2)
    self:emit(opname, dst, b_rk, c_rk)
    self:freeReg(2)
    return dst
end

function Compiler:compileConcat(node, dst)
    -- Collect all concat operands
    local ops = {}
    local function collect(n)
        if n.kind == AstKind.StrCatExpression then
            collect(n.lhs)
            collect(n.rhs)
        else
            table.insert(ops, n)
        end
    end
    collect(node)

    local base_reg = self:allocReg(#ops)
    for i, op_node in ipairs(ops) do
        self:compileExpr(op_node, base_reg + i - 1)
    end
    self:emit("OP_CONCAT", dst, base_reg, base_reg + #ops - 1)
    self:freeReg(#ops)
    return dst
end

function Compiler:compileComparison(node, dst)
    local opname = COMPARE_KINDS[node.kind]
    local flip   = COMPARE_KINDS[node.kind .. "_flip"] or false
    local swap   = COMPARE_KINDS[node.kind .. "_swap"] or false
    local tmp1   = self:allocReg(1)
    local tmp2   = self:allocReg(1)

    local b_rk, _ = self:exprToRK(node.lhs,  tmp1)
    local c_rk, _ = self:exprToRK(node.rhs, tmp2)

    -- GreaterThan/GreaterThanOrEquals reuse OP_LT/OP_LE with swapped operands:
    -- "a > b" → OP_LT(b, a); "a >= b" → OP_LE(b, a)
    if swap then b_rk, c_rk = c_rk, b_rk end

    self:emit(opname, flip and 1 or 0, b_rk, c_rk)
    self:freeReg(2)

    -- Pattern: COND + JMP(skip) + LOADBOOL(true,skip1) + LOADBOOL(false)
    local jmp_false = self:emitJmp()            -- jump to false path
    self:emit("OP_LOADBOOL", dst, 1, 1)          -- dst=true, skip next
    self:patchJmp(jmp_false, self:currentPC())
    self:emit("OP_LOADBOOL", dst, 0, 0)          -- dst=false
    return dst
end

-- ── Function call compilation ─────────────────────────────────────────────
-- Places the function at `dst`, args at dst+1..dst+n, emits OP_CALL.
-- Results land at dst..dst+nret-1.
-- nret: 1=single, 0=discard, -1=multi (B=0)
function Compiler:compileFuncCall(node, dst, nret)
    nret = nret or 1
    -- Function goes into dst
    self:compileExpr(node.base, dst)
    -- Save nextreg so arg-slot reservations don't leak after the call
    local saved_nextreg = self.state.nextreg
    if dst + 1 > saved_nextreg then self.state.nextreg = dst + 1 end
    local nargs = self:compileArgList(node.args, dst + 1)
    local B = (nargs == -1) and 0 or (nargs + 1)
    local C = (nret  == -1) and 0 or (nret  + 1)
    self:emit("OP_CALL", dst, B, C)
    -- Restore nextreg: result lands at dst, so nextreg = dst+1
    self.state.nextreg = saved_nextreg
    return dst
end

function Compiler:compileSelfCall(node, dst, nret)
    nret = nret or 1
    -- Stack[dst+1] = table; Stack[dst] = table[method]
    local tbl_tmp = self:allocReg(1)
    self:compileExpr(node.base, tbl_tmp)
    local idx_rk, _ = self:exprToRK({ kind = AstKind.StringExpression, value = node.passSelfFunctionName }, dst)
    self:emit("OP_SELF", dst, tbl_tmp, idx_rk)
    self:freeReg(1)  -- tbl_tmp (now dst+1 holds it)
    -- Save nextreg before arg compilation to prevent slot leaks
    local saved_nextreg = self.state.nextreg
    if dst + 2 > saved_nextreg then self.state.nextreg = dst + 2 end
    -- Args start at dst+2
    local nargs = self:compileArgList(node.args, dst + 2)
    local total_args = (nargs == -1) and 0 or (nargs + 2)  -- +1 for self, +1 for B offset
    local C = (nret == -1) and 0 or (nret + 1)
    self:emit("OP_CALL", dst, total_args, C)
    -- Restore nextreg: result at dst, so nextreg back to saved
    self.state.nextreg = saved_nextreg
    return dst
end

-- Compile argument list starting at register `base_reg`.
-- Returns number of fixed args, or -1 if last arg is variadic (call/vararg).
-- If `forceNret` is a positive integer, the last argument is compiled with
-- that specific nret value (useful for generic for iterator expressions
-- where pairs() must produce exactly 3 results: iter, state, ctrl).
function Compiler:compileArgList(args, base_reg, forceNret)
    if #args == 0 then return 0 end
    for i = 1, #args - 1 do
        -- Ensure nextreg covers this arg slot before compiling it
        local st = self.state
        if base_reg + i - 1 >= st.nextreg then st.nextreg = base_reg + i end
        self:compileExpr(args[i], base_reg + i - 1, 1)
    end
    local last = args[#args]
    local slot = base_reg + #args - 1
    local st = self.state
    if slot >= st.nextreg then st.nextreg = slot + 1 end
    local is_multi = (last.kind == AstKind.FunctionCallExpression or
                      last.kind == AstKind.PassSelfFunctionCallExpression or
                      last.kind == AstKind.VarargExpression)
    if forceNret ~= nil then
        self:compileExpr(last, slot, forceNret)
        return #args
    elseif is_multi then
        self:compileExpr(last, slot, -1)
        return -1
    else
        self:compileExpr(last, slot, 1)
        return #args
    end
end
-- ── Table constructor ─────────────────────────────────────────────────────
function Compiler:compileTableConstructor(node, dst)
    self:emit("OP_NEWTABLE", dst, 0, 0)
    local entries = node.entries
    local array_i = 0   -- current array index being filled
    local i = 1
    while i <= #entries do
        local entry = entries[i]
        if entry.kind == AstKind.KeyedTableEntry then
            -- Hash entry: tbl[key] = val
            local key_tmp = self:allocReg(1)
            local val_tmp = self:allocReg(1)
            local k_rk, k_used = self:exprToRK(entry.key,   key_tmp)
            local v_rk, v_used = self:exprToRK(entry.value, val_tmp)
            self:emit("OP_SETTABLE", dst, k_rk, v_rk)
            self:freeReg(2)
        else
            -- Array entry (TableEntry)
            array_i = array_i + 1
            local val_tmp = self:allocReg(1)

            -- Always compile as single result; use SETTABLE with numeric key.
            -- (The mixed SETTABLE+SETLIST flush path was incorrect: previous
            -- entries' registers are already freed before the flush SETLIST
            -- runs, causing garbage values to overwrite correctly-stored items.)
            self:compileExpr(entry.value, val_tmp, 1)
            -- Use SETTABLE with numeric key
            local k_rk = self:addKrk(array_i)
            self:emit("OP_SETTABLE", dst, k_rk, val_tmp)
            self:freeReg(1)
        end
        i = i + 1
    end
    return dst
end

-- ── Function literal (closure) ────────────────────────────────────────────
function Compiler:compileFunctionLiteral(node, dst)
    local args     = node.args
    local numparams = #args
    local is_vararg = false  -- detect via last arg being VarargExpression
    if numparams > 0 and args[numparams].kind == AstKind.VarargExpression then
        numparams = numparams - 1
        is_vararg = true
    end

    -- Check for vararg marker in args list (Prometheus uses VarargExpression as sentinal)
    -- Also check if body uses "..."
    -- Simple heuristic: always mark nested functions as vararg-capable
    -- (safe over-approximation; callers just pass extra args which are ignored)
    -- Actually use the node's own scope info if available
    if node.scope and node.scope.hasVararg then
        is_vararg = true
    end

    -- Push a new proto state
    local child_st = self:pushProto(numparams, is_vararg)

    -- Register parameters in the child proto
    for i = 1, numparams do
        local arg_var = args[i]
        if not child_st.varmap[arg_var.scope] then
            child_st.varmap[arg_var.scope] = {}
        end
        child_st.varmap[arg_var.scope][arg_var.id] = i - 1  -- 0-based register
    end

    -- Compile the function body
    self:pushScope()
    self:compileBlock(node.body)
    self:popScope(true)

    -- Pop and register proto
    local proto_idx = self:popProto()

    -- Register this child proto in the parent's proto list
    local parent_st = self.state
    local local_proto_slot = #parent_st.protos + 1
    parent_st.protos[local_proto_slot] = proto_idx

    -- Emit OP_CLOSURE + pseudo-ops for upvalue capture
    self:emit("OP_CLOSURE", dst, local_proto_slot, 0)
    for _, updef in ipairs(child_st.upvaldefs) do
        -- Pseudo-op: [OP_MOVE, instack_flag, idx, 0] or [OP_GETUPVAL, 0, idx, 0]
        -- OP_MOVE pseudo: instack=1 means "from parent register idx"
        -- OP_GETUPVAL pseudo: instack=0 means "from parent upvalue idx"
        if updef.instack then
            self:emit("OP_MOVE",     1, updef.idx, 0)
        else
            self:emit("OP_GETUPVAL", 0, updef.idx, 0)
        end
    end

    return dst
end

-- ── IfElse expression (Luau ternary) ─────────────────────────────────────
function Compiler:compileIfElseExpr(node, dst)
    local cond_tmp = self:allocReg(1)
    self:compileExpr(node.condition, cond_tmp)
    self:emit("OP_TEST", cond_tmp, 0, 0)  -- skip if falsy
    self:freeReg(1)
    local jmp_else = self:emitJmp()
    self:compileExpr(node.true_value, dst)
    local jmp_end  = self:emitJmp()
    self:patchJmp(jmp_else, self:currentPC())
    self:compileExpr(node.false_value, dst)
    self:patchJmp(jmp_end,  self:currentPC())
    return dst
end

-- ══════════════════════════════════════════════════════════════════════════
--  STATEMENT COMPILATION
-- ══════════════════════════════════════════════════════════════════════════
function Compiler:compileBlock(block)
    for _, stmt in ipairs(block.statements) do
        self:compileStmt(stmt)
    end
end

function Compiler:compileStmt(node)
    local kind = node.kind

    if kind == AstKind.LocalVariableDeclaration then
        self:compileLocalDecl(node)

    elseif kind == AstKind.AssignmentStatement then
        self:compileAssignment(node)

    elseif kind == AstKind.FunctionCallStatement then
        local tmp = self:allocReg(1)
        self:compileFuncCall(node, tmp, 0)
        self:freeReg(1)

    elseif kind == AstKind.PassSelfFunctionCallStatement then
        local tmp = self:allocReg(1)
        self:compileSelfCall({base=node.base, passSelfFunctionName=node.passSelfFunctionName, args=node.args}, tmp, 0)
        self:freeReg(1)

    elseif kind == AstKind.ReturnStatement then
        self:compileReturn(node)

    elseif kind == AstKind.IfStatement then
        self:compileIf(node)

    elseif kind == AstKind.WhileStatement then
        self:compileWhile(node)

    elseif kind == AstKind.RepeatStatement then
        self:compileRepeat(node)

    elseif kind == AstKind.ForStatement then
        self:compileNumericFor(node)

    elseif kind == AstKind.ForInStatement then
        self:compileGenericFor(node)

    elseif kind == AstKind.DoStatement then
        self:pushScope()
        self:compileBlock(node.body)
        self:popScope(true)

    elseif kind == AstKind.LocalFunctionDeclaration then
        self:compileLocalFunction(node)

    elseif kind == AstKind.FunctionDeclaration then
        self:compileFunctionDecl(node)

    elseif kind == AstKind.BreakStatement then
        self:emitBreak()

    elseif kind == AstKind.ContinueStatement then
        self:emitContinue()

    elseif kind == AstKind.NopStatement then
        -- nothing

    elseif kind == AstKind.CompoundAddStatement or
           kind == AstKind.CompoundSubStatement or
           kind == AstKind.CompoundMulStatement or
           kind == AstKind.CompoundDivStatement or
           kind == AstKind.CompoundModStatement or
           kind == AstKind.CompoundPowStatement or
           kind == AstKind.CompoundConcatStatement then
        self:compileCompound(node)
    else
        -- Silently skip unknown nodes (GotoStatement, LabelStatement, etc.)
    end
end

-- ── local a, b, c = exprs ─────────────────────────────────────────────────
function Compiler:compileLocalDecl(node)
    local ids   = node.ids
    local exprs = node.expressions or {}
    local n     = #ids

    -- Compile expressions into temporaries first, then declare locals
    local tmps = {}
    for i = 1, n do
        tmps[i] = self:allocReg(1)
    end

    -- Special case: single multi-return expression fills all n slots.
    -- e.g. local ok, result = pcall(f, x)  →  pcall expands into both registers.
    if #exprs == 1 and n > 1 then
        local expr = exprs[1]
        local is_multi = expr and (
            expr.kind == AstKind.FunctionCallExpression or
            expr.kind == AstKind.PassSelfFunctionCallExpression or
            expr.kind == AstKind.VarargExpression)
        if is_multi then
            self:compileExpr(expr, tmps[1], -1)
            -- remaining slots already allocated; OP_CALL with nret=-1 fills them
            -- bind and return early
            local st = self.state
            for i, var_id in ipairs(ids) do
                if not st.varmap[node.scope] then st.varmap[node.scope] = {} end
                st.varmap[node.scope][var_id] = tmps[i]
            end
            return
        end
    end

    for i = 1, n do
        local expr = exprs[i]
        if i == n and #exprs >= n then
            -- last var gets last expr (possibly multi-return)
            local is_multi = expr and (
                expr.kind == AstKind.FunctionCallExpression or
                expr.kind == AstKind.PassSelfFunctionCallExpression or
                expr.kind == AstKind.VarargExpression)
            if is_multi then
                self:compileExpr(expr, tmps[i], -1)
            else
                if expr then self:compileExpr(expr, tmps[i]) end
            end
        elseif expr then
            self:compileExpr(expr, tmps[i], 1)
        else
            self:emit("OP_LOADNIL", tmps[i], 0, 0)
        end
    end

    -- Now bind the temporaries to variable names in scope
    -- (they're already in the right registers; just update varmap)
    local st = self.state
    for i, var_id in ipairs(ids) do
        if not st.varmap[node.scope] then st.varmap[node.scope] = {} end
        st.varmap[node.scope][var_id] = tmps[i]
    end
end

-- ── a, b = exprs ─────────────────────────────────────────────────────────
function Compiler:compileAssignment(node)
    local lhs = node.lhs
    local rhs = node.rhs
    local n   = #lhs

    -- Evaluate all RHS into temporaries
    local tmps = {}
    for i = 1, n do
        tmps[i] = self:allocReg(1)
    end

    for i = 1, n do
        local expr = rhs[i]
        if not expr then
            self:emit("OP_LOADNIL", tmps[i], 0, 0)
        -- FIX Bug 8: guard against nil rhs (previously crashed "attempt to get length of nil")
        elseif i == n and rhs and #rhs >= n then
            local is_multi = (
                expr.kind == AstKind.FunctionCallExpression or
                expr.kind == AstKind.PassSelfFunctionCallExpression or
                expr.kind == AstKind.VarargExpression)
            if is_multi then
                self:compileExpr(expr, tmps[i], n - i + 1)
            else
                self:compileExpr(expr, tmps[i], 1)
            end
        else
            self:compileExpr(expr, tmps[i], 1)
        end
    end

    -- Assign temporaries to LHS targets
    for i, target in ipairs(lhs) do
        local val_reg = tmps[i]
        if target.kind == AstKind.AssignmentVariable then
            local vkind, vidx = self:resolveVar(target.scope, target.id)
            if vkind == "local" then
                if vidx ~= val_reg then
                    self:emit("OP_MOVE", vidx, val_reg, 0)
                end
            elseif vkind == "upvalue" then
                self:emit("OP_SETUPVAL", val_reg, vidx, 0)
            else
                local name = self:_varName(target.scope, target.id)
                self:emit("OP_SETGLOBAL", val_reg, self:addK(name), 0)
            end
        elseif target.kind == AstKind.AssignmentIndexing then
            local tbl_tmp = self:allocReg(1)
            local idx_tmp = self:allocReg(1)
            self:compileExpr(target.base,  tbl_tmp)
            local k_rk, _ = self:exprToRK(target.index, idx_tmp)
            self:emit("OP_SETTABLE", tbl_tmp, k_rk, val_reg)
            self:freeReg(2)
        end
    end

    self:freeReg(n)
end

-- ── return exprs ──────────────────────────────────────────────────────────
function Compiler:compileReturn(node)
    local args = node.args or {}
    if #args == 0 then
        self:emit("OP_RETURN", 0, 1, 0)
        return
    end

    local base_reg = self.state.nextreg  -- start of return value registers

    for i = 1, #args - 1 do
        local r = self:allocReg(1)
        self:compileExpr(args[i], r, 1)
    end

    -- Last arg: might be multi-return
    local last = args[#args]
    local last_reg = self:allocReg(1)
    local is_multi = (last.kind == AstKind.FunctionCallExpression or
                      last.kind == AstKind.PassSelfFunctionCallExpression or
                      last.kind == AstKind.VarargExpression)
    if is_multi then
        self:compileExpr(last, last_reg, -1)
        self:emit("OP_RETURN", base_reg, 0, 0)  -- B=0: multi-return
    else
        self:compileExpr(last, last_reg, 1)
        self:emit("OP_RETURN", base_reg, #args + 1, 0)
    end

    -- Free temporaries (we're returning, nextreg doesn't matter after this)
    self:freeReg(#args)
end

-- ── if / elseif / else ────────────────────────────────────────────────────
function Compiler:compileIf(node)
    local end_jumps = {}

    -- Helper: compile one condition + body branch
    local function compileBranch(cond, body)
        local tmp = self:allocReg(1)
        self:compileExpr(cond, tmp)
        self:emit("OP_TEST", tmp, 0, 0)   -- skip JMP if true
        self:freeReg(1)
        local jmp_skip = self:emitJmp()   -- JMP over body (if false)
        self:pushScope()
        self:compileBlock(body)
        self:popScope(true)
        -- JMP to end (skip remaining branches)
        local jmp_end = self:emitJmp()
        table.insert(end_jumps, jmp_end)
        self:patchJmp(jmp_skip, self:currentPC())
    end

    compileBranch(node.condition, node.body)

    for _, elseif_clause in ipairs(node.elseifs) do
        compileBranch(elseif_clause.condition, elseif_clause.body)
    end

    if node.elsebody then
        self:pushScope()
        self:compileBlock(node.elsebody)
        self:popScope(true)
    end

    local end_pc = self:currentPC()
    for _, jmp_pos in ipairs(end_jumps) do
        self:patchJmp(jmp_pos, end_pc)
    end
end

-- ── while cond do body end ────────────────────────────────────────────────
function Compiler:compileWhile(node)
    local loop_start = self:currentPC()
    self:pushLoop()

    local tmp = self:allocReg(1)
    self:compileExpr(node.condition, tmp)
    self:emit("OP_TEST", tmp, 0, 0)  -- skip JMP if true
    self:freeReg(1)
    local jmp_exit = self:emitJmp()

    self:pushScope()
    self:compileBlock(node.body)
    self:popScope(true)

    -- Jump back to top
    local jmp_back = self:emitJmp()
    self:patchJmp(jmp_back, loop_start)

    -- Patch exit jump
    local loop_end = self:currentPC()
    self:patchJmp(jmp_exit, loop_end)
    -- FIX: continue in while loops must re-evaluate the condition,
    -- NOT skip directly to the body. Jumping to body_start would
    -- bypass the condition check, causing infinite loops even when
    -- Config.AutoRace or AR_STATE changes.
    self:popLoop(loop_end, loop_start)
end

-- ── repeat body until cond ────────────────────────────────────────────────
function Compiler:compileRepeat(node)
    local loop_start = self:currentPC()
    self:pushLoop()

    self:pushScope()
    self:compileBlock(node.body)

    local tmp = self:allocReg(1)
    self:compileExpr(node.condition, tmp)
    -- C=1: skip next instr when condition is FALSE → falls through to exit
    -- C=0 was WRONG: it skipped when TRUE, so _keyDone=false triggered exit immediately
    self:emit("OP_TEST", tmp, 0, 1)
    self:freeReg(1)
    -- Condition TRUE: execute this jmp → loop back
    local jmp_back = self:emitJmp()
    self:patchJmp(jmp_back, loop_start)
    -- Condition FALSE: skip jmp_back → fall through = exit loop
    local loop_end = self:currentPC()

    self:popScope(true)
    self:popLoop(loop_end, loop_start)
end

-- ── for i = init, limit, step do body end ───────────────────────────────
function Compiler:compileNumericFor(node)
    -- Reserve 4 internal registers: [i, limit, step, loop_var]
    local r_i     = self:allocReg(1)
    local r_limit = self:allocReg(1)
    local r_step  = self:allocReg(1)
    local r_var   = self:allocReg(1)  -- exposed loop variable

    self:compileExpr(node.initialValue, r_i)
    self:compileExpr(node.finalValue,   r_limit)
    if node.incrementBy then
        self:compileExpr(node.incrementBy, r_step)
    else
        self:emit("OP_LOADK", r_step, self:addK(1), 0)
    end

    -- OP_FORPREP: r_i -= r_step; PC += B (to FORLOOP)
    local forprep_pos = self:emit("OP_FORPREP", r_i, 0, 0)

    local loop_start = self:currentPC()  -- position of OP_FORLOOP

    -- Declare loop variable (r_var = r_i after FORLOOP copies it)
    local st = self.state
    if not st.varmap[node.scope] then st.varmap[node.scope] = {} end
    st.varmap[node.scope][node.id] = r_var

    self:pushLoop()
    self:pushScope()
    self:compileBlock(node.body)
    self:popScope(true)

    -- OP_FORLOOP: r_i += r_step; if valid then PC += B; r_var = r_i
    -- B jumps BACK to the start of the body (first instruction after FORLOOP)
    local forloop_pos = self:emit("OP_FORLOOP", r_i, 0, 0)
    local loop_end    = self:currentPC()

    -- Patch FORPREP to jump FORWARD to FORLOOP
    self:patchJmp(forprep_pos, forloop_pos)
    -- Patch FORLOOP to jump BACKWARD to body start (after FORLOOP itself)
    self.state.code[forloop_pos + 2] = loop_start - forloop_pos - FIELDS

    -- FIX: continue in numeric for must go back to FORLOOP to
    -- re-evaluate the counter and limit.
    self:popLoop(loop_end, loop_start)
    self:freeReg(4)
end

-- ── for k, v in iter do body end ─────────────────────────────────────────
function Compiler:compileGenericFor(node)
    -- Registers: [iter_func, state, ctrl, var1, var2, ...]
    local r_iter  = self:allocReg(1)
    local r_state = self:allocReg(1)
    local r_ctrl  = self:allocReg(1)

    -- Save nextreg AFTER allocating iter/state/ctrl so that temporary
    -- registers created inside compileArgList (e.g. for pairs(tbl)) don't
    -- push nextreg forward.  Restoring it ensures var-regs are allocated
    -- at r_ctrl+1, r_ctrl+2, … exactly where OP_TFORLOOP expects them.
    local saved_nextreg = self.state.nextreg
    -- FIX: Force nret=3 so pairs(table) produces exactly 3 results:
    -- iter function (next), state (table), ctrl (nil) — all on the stack
    -- where TFORLOOP expects them at r_iter, r_iter+1, r_iter+2.
    self:compileArgList(node.expressions, r_iter, 3)
    self.state.nextreg = saved_nextreg

    local nvars = #node.ids
    -- Declare loop variables
    local var_regs = {}
    local st = self.state
    for i, var_id in ipairs(node.ids) do
        local r = self:allocReg(1)
        var_regs[i] = r
        if not st.varmap[node.scope] then st.varmap[node.scope] = {} end
        st.varmap[node.scope][var_id] = r
    end

    local loop_start = self:currentPC()
    self:pushLoop()

    -- OP_TFORLOOP: calls iter_func(state, ctrl), places results in var regs
    -- If first result is nil, PC += 4 (exit loop)
    local tfor_pos = self:emit("OP_TFORLOOP", r_iter, 0, nvars)
    local jmp_exit_pos = self:emitJmp()

    -- Body
    self:pushScope()
    self:compileBlock(node.body)
    self:popScope(true)

    -- Jump back to TFORLOOP
    local jmp_back = self:emitJmp()
    self:patchJmp(jmp_back, loop_start)

    local loop_end = self:currentPC()
    self:patchJmp(jmp_exit_pos, loop_end)
    -- FIX: continue in for-in loops must go back to TFORLOOP to fetch
    -- the next iteration, NOT skip to body_start which would re-use
    -- stale loop variables.
    self:popLoop(loop_end, loop_start)
    self:freeReg(3 + nvars)
end

-- ── local function f(...) ─────────────────────────────────────────────────
function Compiler:compileLocalFunction(node)
    -- Declare the variable FIRST (allows self-recursion via upvalue)
    local r = self:declareLocal(node.scope, node.id)
    self:compileFunctionLiteral({
        kind = AstKind.FunctionLiteralExpression,
        args = node.args,
        body = node.body,
        scope = nil,
    }, r)
end

-- ── function a.b.c(...) ───────────────────────────────────────────────────
function Compiler:compileFunctionDecl(node)
    local tmp = self:allocReg(1)
    self:compileFunctionLiteral({
        kind  = AstKind.FunctionLiteralExpression,
        args  = node.args,
        body  = node.body,
        scope = nil,
    }, tmp)

    if #node.indices == 0 then
        -- Simple assignment: a = function
        local vkind, vidx = self:resolveVar(node.scope, node.id)
        if vkind == "local" then
            self:emit("OP_MOVE", vidx, tmp, 0)
        elseif vkind == "upvalue" then
            self:emit("OP_SETUPVAL", tmp, vidx, 0)
        else
            local name = self:_varName(node.scope, node.id)
            self:emit("OP_SETGLOBAL", tmp, self:addK(name), 0)
        end
    else
        -- Indexed assignment: a.b.c = function
        local tbl_tmp = self:allocReg(1)
        -- Get base
        local vkind, vidx = self:resolveVar(node.scope, node.id)
        if vkind == "local" then
            self:emit("OP_MOVE", tbl_tmp, vidx, 0)
        elseif vkind == "upvalue" then
            self:emit("OP_GETUPVAL", tbl_tmp, vidx, 0)
        else
            local name = self:_varName(node.scope, node.id)
            self:emit("OP_GETGLOBAL", tbl_tmp, self:addK(name), 0)
        end
        -- Navigate indices except last
        for i = 1, #node.indices - 1 do
            local key_rk = self:addKrk(node.indices[i])
            self:emit("OP_GETTABLE", tbl_tmp, tbl_tmp, key_rk)
        end
        -- Set final key
        local last_key_rk = self:addKrk(node.indices[#node.indices])
        self:emit("OP_SETTABLE", tbl_tmp, last_key_rk, tmp)
        self:freeReg(1)
    end
    self:freeReg(1)
end

-- ── Compound assignment (+=, -=, etc.) ───────────────────────────────────
local COMPOUND_OP = {
    [true] = {},  -- filled after AstKind loaded
}
local COMPOUND_ARITH_MAP  -- forward ref

function Compiler:compileCompound(node)
    local opname = COMPOUND_ARITH_MAP and COMPOUND_ARITH_MAP[node.kind]
    if not opname then return end

    local lhs = node.lhs
    local rhs_tmp = self:allocReg(1)
    local lhs_tmp = self:allocReg(1)

    -- Load LHS into lhs_tmp
    if lhs.kind == AstKind.AssignmentVariable then
        local vk, vi = self:resolveVar(lhs.scope, lhs.id)
        if vk == "local" then
            self:emit("OP_MOVE", lhs_tmp, vi, 0)
        elseif vk == "upvalue" then
            self:emit("OP_GETUPVAL", lhs_tmp, vi, 0)
        else
            self:emit("OP_GETGLOBAL", lhs_tmp, self:addK(self:_varName(lhs.scope, lhs.id)), 0)
        end
    else
        self:compileExpr(lhs.base, lhs_tmp)
    end

    -- Load RHS
    local rhs_rk, _ = self:exprToRK(node.rhs, rhs_tmp)
    self:emit(opname, lhs_tmp, lhs_tmp, rhs_rk)

    -- Store back
    if lhs.kind == AstKind.AssignmentVariable then
        local vk, vi = self:resolveVar(lhs.scope, lhs.id)
        if vk == "local" then
            self:emit("OP_MOVE", vi, lhs_tmp, 0)
        elseif vk == "upvalue" then
            self:emit("OP_SETUPVAL", lhs_tmp, vi, 0)
        else
            self:emit("OP_SETGLOBAL", lhs_tmp, self:addK(self:_varName(lhs.scope, lhs.id)), 0)
        end
    else
        local idx_rk = self:addKrk(lhs.index)  -- simplified; real: compile index expr
        self:emit("OP_SETTABLE", lhs_tmp, idx_rk, lhs_tmp)
    end
    self:freeReg(2)
end

-- ── Variable name lookup ──────────────────────────────────────────────────
-- Retrieves the string name of a variable from a Prometheus scope object.
function Compiler:_varName(scope_obj, var_id)
    if scope_obj and scope_obj.variablesLookup then
        for name, vid in pairs(scope_obj.variablesLookup) do
            if vid == var_id then return name end
        end
    end
    -- If names were renamed by Prometheus pipeline, use a placeholder.
    -- The GlobalScope always has the real names.
    if scope_obj and scope_obj.isGlobal then
        for name, vid in pairs(scope_obj.variablesLookup or {}) do
            if vid == var_id then return name end
        end
    end
    return "__bvm_var_" .. tostring(var_id)
end

-- ══════════════════════════════════════════════════════════════════════════
--  MAIN ENTRY POINT
-- ══════════════════════════════════════════════════════════════════════════
-- compile(ast, op_map)  →  all_protos (array), root_proto_idx
--   ast    : Prometheus TopNode
--   op_map : randomized opcode name→id map from ISA.randomize()

function Compiler:compile(ast)
    -- Lazy-load Prometheus AST/AstKind (allows use outside prometheus too)
    if not Ast then
        Ast = require("prometheus.ast")
        AstKind = Ast.AstKind

        -- Build opcode maps now that AstKind is available
        ARITH_KINDS = {
            [AstKind.AddExpression] = "OP_ADD",
            [AstKind.SubExpression] = "OP_SUB",
            [AstKind.MulExpression] = "OP_MUL",
            [AstKind.DivExpression] = "OP_DIV",
            [AstKind.ModExpression] = "OP_MOD",
            [AstKind.PowExpression] = "OP_POW",
        }
        COMPARE_KINDS = {
            [AstKind.EqualsExpression]              = "OP_EQ",
            [AstKind.NotEqualsExpression]           = "OP_EQ",
            [AstKind.NotEqualsExpression .. "_flip"] = true,
            [AstKind.LessThanExpression]            = "OP_LT",
            [AstKind.LessThanOrEqualsExpression]    = "OP_LE",
            [AstKind.GreaterThanExpression]         = "OP_LT",   -- swap B,C: a>b → OP_LT(b,a)
            [AstKind.GreaterThanExpression .. "_swap"] = true,
            [AstKind.GreaterThanOrEqualsExpression] = "OP_LE",   -- swap B,C: a>=b → OP_LE(b,a)
            [AstKind.GreaterThanOrEqualsExpression .. "_swap"] = true,
        }
        COMPOUND_ARITH_MAP = {
            [AstKind.CompoundAddStatement]    = "OP_ADD",
            [AstKind.CompoundSubStatement]    = "OP_SUB",
            [AstKind.CompoundMulStatement]    = "OP_MUL",
            [AstKind.CompoundDivStatement]    = "OP_DIV",
            [AstKind.CompoundModStatement]    = "OP_MOD",
            [AstKind.CompoundPowStatement]    = "OP_POW",
            [AstKind.CompoundConcatStatement] = "OP_CONCAT",
        }
    end

    -- Root proto: top-level script body (vararg, 0 params)
    local root_st = self:pushProto(0, true)

    -- Declare _ENV as upvalue 1 of the root proto
    root_st.upvaldefs[1] = {instack = false, idx = 0}  -- from host environment

    self:pushScope()
    self:compileBlock(ast.body)
    self:popScope(false)

    local root_idx = self:popProto()
    return self.all_protos, root_idx
end

-- ── Factory function ─────────────────────────────────────────────────────
return function(op_map)
    return Compiler.new(op_map)
end
