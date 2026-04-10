-- ============================================================
--  bvm/isa.lua
--  Custom Instruction Set Architecture (ISA)
--  for the Bytecode Virtual Machine Generator.
--
--  Every obfuscation run calls ISA.randomize(), which Fisher-
--  Yates shuffles a pool of 1..254 and assigns a unique random
--  numeric ID to every logical opcode name.  The resulting map
--  is baked into both the emitted bytecode header and the VM
--  dispatcher, so the "language" the VM speaks changes every
--  run — polymorphic opcodes.
-- ============================================================

local ISA = {}

-- ── Canonical opcode names (logical identifiers, never emitted) ────────────
ISA.NAMES = {
    -- Data movement
    "OP_MOVE",       -- Stack[A] = Stack[B]
    "OP_LOADK",      -- Stack[A] = K[B]
    "OP_LOADNIL",    -- Stack[A..A+B] = nil
    "OP_LOADBOOL",   -- Stack[A] = bool(B); if C then PC+=4
    -- Upvalue / global access
    "OP_GETUPVAL",   -- Stack[A] = upvals[B].v
    "OP_SETUPVAL",   -- upvals[B].v = Stack[A]
    "OP_GETGLOBAL",  -- Stack[A] = ENV[K[B]]
    "OP_SETGLOBAL",  -- ENV[K[B]] = Stack[A]
    -- Table operations
    "OP_GETTABLE",   -- Stack[A] = Stack[B][RK(C)]
    "OP_SETTABLE",   -- Stack[A][RK(B)] = RK(C)
    "OP_NEWTABLE",   -- Stack[A] = {}
    "OP_SELF",       -- Stack[A+1]=Stack[B]; Stack[A]=Stack[B][RK(C)]
    "OP_SETLIST",    -- Stack[A][(C-1)*50+i] = Stack[A+i], i=1..B
    -- Arithmetic
    "OP_ADD",        -- Stack[A] = RK(B) + RK(C)
    "OP_SUB",        -- Stack[A] = RK(B) - RK(C)
    "OP_MUL",        -- Stack[A] = RK(B) * RK(C)
    "OP_DIV",        -- Stack[A] = RK(B) / RK(C)
    "OP_MOD",        -- Stack[A] = RK(B) % RK(C)
    "OP_POW",        -- Stack[A] = RK(B) ^ RK(C)
    "OP_UNM",        -- Stack[A] = -Stack[B]
    -- Logical / string
    "OP_NOT",        -- Stack[A] = not Stack[B]
    "OP_LEN",        -- Stack[A] = #Stack[B]
    "OP_CONCAT",     -- Stack[A] = Stack[B]..…..Stack[C]
    -- Control flow
    "OP_JMP",        -- PC += B   (B = signed raw byte offset after PC advance)
    "OP_EQ",         -- if (RK(B)==RK(C))~=(A~=0) then PC+=4
    "OP_LT",         -- if (RK(B)< RK(C))~=(A~=0) then PC+=4
    "OP_LE",         -- if (RK(B)<=RK(C))~=(A~=0) then PC+=4
    "OP_TEST",       -- if bool(Stack[A])~=(C~=0) then PC+=4
    "OP_TESTSET",    -- if bool(Stack[B])~=(C~=0) then PC+=4 else Stack[A]=Stack[B]
    -- Function calls
    "OP_CALL",       -- Stack[A..A+C-2]=Stack[A](Stack[A+1..A+B-1]); B=0→top, C=0→multi
    "OP_TAILCALL",   -- return Stack[A](Stack[A+1..A+B-1])
    "OP_RETURN",     -- return Stack[A..A+B-2]; B=0→multi-return
    -- Numeric for loop
    "OP_FORPREP",    -- Stack[A] -= Stack[A+2]; PC += B
    "OP_FORLOOP",    -- Stack[A] += Stack[A+2]; if valid then PC += B
    -- Generic for loop
    "OP_TFORLOOP",   -- Stack[A+3..A+2+C]=Stack[A](Stack[A+1],Stack[A+2]); …
    -- Upvalue lifecycle
    "OP_CLOSE",      -- close open upvalue boxes for registers >= A
    -- Closures
    "OP_CLOSURE",    -- Stack[A] = closure(PROTO[B]); next N instrs are pseudo-ops
    -- Vararg
    "OP_VARARG",     -- Stack[A..A+B-2] = vararg; B=0→all vararg
}

-- ── Encoding constants ─────────────────────────────────────────────────────
-- RK(x): x >= CONST_BIAS → constant K[x - CONST_BIAS + 1]
--        x <  CONST_BIAS → register Stack[x]
ISA.CONST_BIAS    = 256
ISA.FIELDS        = 4   -- fields per instruction: [OP, A, B, C]
ISA.OPCODE_COUNT  = #ISA.NAMES

-- ── Polymorphic opcode randomization WITH aliasing ────────────────────────
-- Returns two tables:
--   op    : name → numeric ID  (used by compiler and emitter)
--   opname: numeric ID → name  (used for debugging / disassembly)
--   op_aliases: name → {id1, id2, ...}  (all aliases for a given opcode)
--
-- Each opcode gets 1 primary ID + 1-2 alias IDs drawn from the unused pool.
-- The compiler emits the primary ID. The runtime dispatcher accepts ALL
-- aliases for that opcode, so 2-3 different integers trigger the same
-- handler. This makes static analysis harder because pattern-matching
-- a single integer per opcode is no longer sufficient.
function ISA.randomize()
    -- Build a candidate pool: 1..254 (leave 0 unused as a sentinel).
    local pool = {}
    for i = 1, 254 do pool[i] = i end

    -- Fisher-Yates in-place shuffle
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end

    local op        = {}  -- name  → primary numeric id
    local opname    = {}  -- numeric id → name
    local op_aliases = {} -- name → {id1, id2, ...}

    local num_opcodes = #ISA.NAMES
    local pool_idx = 1

    for i, name in ipairs(ISA.NAMES) do
        -- Assign primary ID
        local primary_id = pool[pool_idx]
        pool_idx = pool_idx + 1
        op[name]   = primary_id
        opname[primary_id] = name

        -- Randomly assign 1-2 alias IDs from remaining pool
        local num_aliases = math.random(1, 2)  -- 1 or 2 extra IDs
        local aliases = {primary_id}
        for _ = 1, num_aliases do
            if pool_idx <= 254 then
                local alias_id = pool[pool_idx]
                pool_idx = pool_idx + 1
                table.insert(aliases, alias_id)
                opname[alias_id] = name  -- alias maps to same opcode name
            end
        end
        op_aliases[name] = aliases
    end

    return op, opname, op_aliases
end

return ISA
