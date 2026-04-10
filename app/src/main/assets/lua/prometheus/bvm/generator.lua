-- ============================================================
--  bvm/generator.lua
--  Standalone BVM Generator
--
--  A SELF-CONTAINED generator that does NOT depend on Prometheus
--  internals.  It accepts raw Lua 5.1 source code as a string,
--  parses it with its own minimal recursive-descent front-end,
--  compiles it to BVM bytecode, and emits a complete VM script.
--
--  Usage (run from the shell):
--    lua bvm/generator.lua input.lua output.lua
--
--  Or require it from another script:
--    local BvmGen = require("prometheus.bvm.generator")
--    local vm_source = BvmGen.generate(lua_source_string)
--    print(vm_source)
--
--  Architecture overview (three-pass pipeline):
--
--    SOURCE STRING
--        │
--        ▼
--    ┌────────────────────────────────────────────────────────┐
--    │  PASS 1 — TOKENIZER                                    │
--    │  Converts source text into a flat token stream.        │
--    │  Token kinds: NAME, NUMBER, STRING, SYMBOL, EOF        │
--    └────────────────────────────────────────────────────────┘
--        │
--        ▼
--    ┌────────────────────────────────────────────────────────┐
--    │  PASS 2 — COMPILER  (single-pass, no AST)             │
--    │  Recursive-descent parser that directly emits BVM      │
--    │  instructions while parsing.  Each proto maps to a     │
--    │  function scope.  Register allocation is sequential.   │
--    │                                                        │
--    │  Instruction format (4 fields per instruction):        │
--    │    [OP_ID, A, B, C]  (all integers, 0-based registers) │
--    │                                                        │
--    │  RK encoding:                                          │
--    │    x <  256 → register  Stack[x]                       │
--    │    x >= 256 → constant  K[x - 255]                     │
--    └────────────────────────────────────────────────────────┘
--        │
--        ▼
--    ┌────────────────────────────────────────────────────────┐
--    │  PASS 3 — EMITTER                                      │
--    │  Serializes proto tree + randomized ISA into a         │
--    │  standalone Lua script containing:                     │
--    │    • do...end-fenced bytecode arrays                   │
--    │    • do...end-fenced constant pool arrays              │
--    │    • VM runtime (while PC loop + stack + upvalue boxes)│
--    └────────────────────────────────────────────────────────┘
--        │
--        ▼
--    OBFUSCATED BYTECODE VM SCRIPT
-- ============================================================

-- ── Load sub-modules (relative to this file's directory) ─────────────────
local ISA          = require("prometheus.bvm.isa")
local makeEmitter  = require("prometheus.bvm.emitter")

-- The Prometheus-aware compiler from compiler.lua requires Prometheus AST.
-- For the standalone path we use our own light front-end (see below).
-- If Prometheus IS available, the step.lua uses it instead.

-- ────────────────────────────────────────────────────────────────────────────
--  STANDALONE TOKENIZER
-- ────────────────────────────────────────────────────────────────────────────

local Tok = {}
Tok.__index = Tok

local KEYWORDS = {
    ["and"]=true,["break"]=true,["do"]=true,["else"]=true,
    ["elseif"]=true,["end"]=true,["false"]=true,["for"]=true,
    ["function"]=true,["if"]=true,["in"]=true,["local"]=true,
    ["nil"]=true,["not"]=true,["or"]=true,["repeat"]=true,
    ["return"]=true,["then"]=true,["true"]=true,["until"]=true,
    ["while"]=true,
}

function Tok.new(src)
    local t = setmetatable({src=src,pos=1,line=1,peek=nil}, Tok)
    t:advance()
    return t
end

function Tok:advance()
    self:skipWhitespaceAndComments()
    local s   = self.src
    local p   = self.pos
    local len = #s

    if p > len then
        self.peek = {kind="EOF", val=nil, line=self.line}
        return
    end

    local line = self.line
    local c = s:sub(p,p)

    -- String literals
    if c == '"' or c == "'" then
        local delim = c
        local i = p + 1
        local buf = {}
        while i <= len do
            local ch = s:sub(i,i)
            if ch == delim then
                self.pos = i + 1
                self.peek = {kind="STRING", val=table.concat(buf), line=line}
                return
            elseif ch == '\\' then
                local esc = s:sub(i+1,i+1)
                if     esc == 'n'  then buf[#buf+1]='\n'
                elseif esc == 't'  then buf[#buf+1]='\t'
                elseif esc == 'r'  then buf[#buf+1]='\r'
                elseif esc == '\\' then buf[#buf+1]='\\'
                elseif esc == "'"  then buf[#buf+1]="'"
                elseif esc == '"'  then buf[#buf+1]='"'
                elseif esc == '0'  then buf[#buf+1]='\0'
                else                    buf[#buf+1]=esc
                end
                i = i + 2
            else
                buf[#buf+1] = ch
                i = i + 1
            end
        end
        error("Unterminated string at line " .. line)

    -- Long strings [[ ... ]]
    elseif c == '[' and (s:sub(p+1,p+1) == '[' or s:sub(p+1,p+1) == '=') then
        local eq = ""
        local j  = p + 1
        while s:sub(j,j) == '=' do eq = eq..'='; j=j+1 end
        if s:sub(j,j) == '[' then
            j = j + 1
            local close = ']' .. eq .. ']'
            local k     = s:find(close, j, true)
            if not k then error("Unterminated long string at line "..line) end
            local val   = s:sub(j, k-1)
            -- Count newlines
            for _ in val:gmatch('\n') do self.line=self.line+1 end
            self.pos  = k + #close
            self.peek = {kind="STRING", val=val, line=line}
            return
        end
        -- else fall through to symbol [

    -- Numbers
    elseif c:match('%d') or (c == '.' and s:sub(p+1,p+1):match('%d')) then
        local num_pat = '^0[xX]%x+%.?%x*[pP][+-]?%x+' ..
                        '|^0[xX]%x+' ..
                        '|^%d+%.%d*[eE][+-]?%d+' ..
                        '|^%d+[eE][+-]?%d+' ..
                        '|^%d*%.%d+[eE][+-]?%d+' ..
                        '|^%d+%.%d*' ..
                        '|^%d*%.%d+' ..
                        '|^%d+'
        local val_str
        for _, pat in ipairs({
            '^0[xX]%x+%.?%x*[pP][+-]?%x+',
            '^0[xX]%x+',
            '^%d+%.%d*[eE][+-]?%d+',
            '^%d+[eE][+-]?%d+',
            '^%d*%.%d+[eE][+-]?%d+',
            '^%d+%.%d*',
            '^%d*%.%d+',
            '^%d+',
        }) do
            local m = s:match(pat, p)
            if m then val_str = m; break end
        end
        if val_str then
            self.pos  = p + #val_str
            self.peek = {kind="NUMBER", val=tonumber(val_str), line=line}
            return
        end

    -- Identifiers / keywords
    elseif c:match('[%a_]') then
        local m = s:match('^[%a%d_]+', p)
        self.pos = p + #m
        if KEYWORDS[m] then
            self.peek = {kind=m, val=m, line=line}
        else
            self.peek = {kind="NAME", val=m, line=line}
        end
        return

    -- Multi-char symbols
    else
        local two = s:sub(p,p+1)
        local multi = {
            [".."]=".."; ["..."]="...";
            ["=="]="=="; ["~="]="~=";
            ["<="]="<="; [">="]=">=";
            ["<<"]="<<"; [">>"]=">>"; ["//"]="//";
        }
        -- Check 3-char first
        if multi[s:sub(p,p+2)] then
            self.pos  = p + 3
            self.peek = {kind=s:sub(p,p+2), val=s:sub(p,p+2), line=line}
            return
        end
        if multi[two] then
            self.pos  = p + 2
            self.peek = {kind=two, val=two, line=line}
            return
        end
        -- Single char
        self.pos  = p + 1
        self.peek = {kind=c, val=c, line=line}
        return
    end

    -- Fallback single char
    self.pos  = p + 1
    self.peek = {kind=c, val=c, line=line}
end

function Tok:skipWhitespaceAndComments()
    local s = self.src
    local p = self.pos
    local len = #s
    while p <= len do
        local c = s:sub(p,p)
        if c == '\n' then self.line=self.line+1; p=p+1
        elseif c:match('%s') then p=p+1
        elseif s:sub(p,p+1) == '--' then
            -- Long comment?
            if s:sub(p+2,p+2) == '[' then
                local j = p+3
                local eq = ""
                while s:sub(j,j) == '=' do eq=eq..'='; j=j+1 end
                if s:sub(j,j) == '[' then
                    j = j+1
                    local close = ']'..eq..']'
                    local k = s:find(close,j,true)
                    if k then
                        for _ in s:sub(j,k):gmatch('\n') do self.line=self.line+1 end
                        p = k + #close
                    else p = len+1 end
                    goto continue
                end
            end
            -- Short comment: skip to end of line
            while p <= len and s:sub(p,p) ~= '\n' do p=p+1 end
        else break end
        ::continue::
    end
    self.pos = p
end

function Tok:check(kind)
    return self.peek.kind == kind
end

function Tok:match(kind)
    if self.peek.kind == kind then
        local t = self.peek
        self:advance()
        return t
    end
    return nil
end

function Tok:expect(kind)
    local t = self:match(kind)
    if not t then
        error(string.format("Expected %q, got %q (%q) at line %d",
            kind, self.peek.kind, tostring(self.peek.val), self.peek.line))
    end
    return t
end

-- ────────────────────────────────────────────────────────────────────────────
--  STANDALONE SINGLE-PASS COMPILER
--  (Recursive descent; directly emits BVM bytecode without an AST)
-- ────────────────────────────────────────────────────────────────────────────

local CONST_BIAS = ISA.CONST_BIAS
local FIELDS     = ISA.FIELDS

local SC = {}  -- Standalone Compiler
SC.__index = SC

function SC.new(op)
    local c = setmetatable({}, SC)
    c.op         = op
    c.all_protos = {}
    c.proto_stack = {}
    c.cur         = nil  -- current proto state
    return c
end

-- Proto state
local function newSCProto(parent, numparams, is_vararg)
    return {
        code       = {},
        k          = {},
        kmap       = {},
        protos     = {},       -- child proto_idx references
        upvaldefs  = {},       -- {instack, idx}
        numparams  = numparams,
        is_vararg  = is_vararg,
        maxstack   = numparams,
        nextreg    = numparams,
        parent     = parent,
        -- Variable tables
        locals     = {},       -- [{name, reg, captured}] in declaration order
        -- Pending break jumps (stacked per loop)
        break_stack = {},
        -- Pending continue jumps (stacked per loop)
        continue_stack = {},
    }
end

function SC:emit(opname, A, B, C)
    local code = self.cur.code
    local pos  = #code + 1
    code[pos]   = self.op[opname]
    code[pos+1] = A or 0
    code[pos+2] = B or 0
    code[pos+3] = C or 0
    if A and A+1 > self.cur.maxstack then self.cur.maxstack = A+1 end
    return pos
end

function SC:pc()
    return #self.cur.code + 1
end

function SC:patchJmp(pos, target)
    -- B field = target - pos - FIELDS  (signed offset after PC advance)
    self.cur.code[pos+2] = target - pos - FIELDS
end

function SC:emitJmp()
    return self:emit("OP_JMP", 0, 0, 0)
end

function SC:allocReg(n)
    n = n or 1
    local r = self.cur.nextreg
    self.cur.nextreg = self.cur.nextreg + n
    if self.cur.nextreg > self.cur.maxstack then
        self.cur.maxstack = self.cur.nextreg
    end
    return r
end

function SC:freeReg(n)
    self.cur.nextreg = self.cur.nextreg - (n or 1)
end

-- Constant pool
function SC:addK(v)
    local key
    if v == nil then key = "nil:"
    elseif v == true  then key = "bool:t"
    elseif v == false then key = "bool:f"
    elseif type(v) == "number" then key = "n:"..tostring(v)
    elseif type(v) == "string" then key = "s:"..v
    else error("bad constant") end
    local p = self.cur
    if p.kmap[key] then return p.kmap[key] end
    local idx = #p.k + 1
    p.k[idx] = v
    p.kmap[key] = idx
    return idx
end

function SC:Krk(v) return self:addK(v) + CONST_BIAS - 1 end

-- Local variable management
function SC:declareLocal(name)
    local r = self:allocReg(1)
    local locs = self.cur.locals
    locs[#locs+1] = {name=name, reg=r, captured=false}
    return r
end

function SC:findLocal(name)
    local locs = self.cur.locals
    for i = #locs, 1, -1 do
        if locs[i].name == name then return locs[i] end
    end
    return nil
end

-- Resolve name: local → "local",reg | upvalue → "upval",idx | global → "global"
function SC:resolveVar(name)
    -- Check locals in current proto
    local loc = self:findLocal(name)
    if loc then return "local", loc.reg, loc end

    -- Check upvalue cache in current proto
    local p = self.cur
    for i, ud in ipairs(p.upvaldefs) do
        if ud.name == name then return "upval", i end
    end

    -- Walk parent protos
    if p.parent then
        local saved = self.cur
        self.cur = p.parent
        local kind, idx, loc2 = self:resolveVar(name)
        self.cur = saved

        if kind == "local" then
            -- Capture as in-stack upvalue
            loc2.captured = true
            local ui = #p.upvaldefs + 1
            p.upvaldefs[ui] = {name=name, instack=true, idx=loc2.reg}
            return "upval", ui
        elseif kind == "upval" then
            local ui = #p.upvaldefs + 1
            p.upvaldefs[ui] = {name=name, instack=false, idx=idx}
            return "upval", ui
        end
    end

    return "global", name
end

-- Push/pop proto
function SC:pushProto(numparams, is_vararg)
    local parent = self.cur
    local st = newSCProto(parent, numparams, is_vararg)
    table.insert(self.proto_stack, parent)
    self.cur = st
    return st
end

function SC:popProto()
    local st = self.cur
    -- Implicit return
    local code = st.code
    local last_op = code[#code - FIELDS + 1]
    if last_op ~= self.op["OP_RETURN"] and last_op ~= self.op["OP_TAILCALL"] then
        self:emit("OP_RETURN", 0, 1, 0)
    end
    local idx = #self.all_protos + 1
    self.all_protos[idx] = st
    st.proto_idx = idx
    self.cur = table.remove(self.proto_stack)
    return idx
end

-- Scope: track base nextreg for local reclamation
function SC:pushScope()
    return self.cur.nextreg  -- caller saves this
end

function SC:popScope(base_reg)
    -- Close any captured locals going out of scope
    local locs = self.cur.locals
    local needs_close = false
    local new_locs = {}
    for i, loc in ipairs(locs) do
        if loc.reg >= base_reg then
            if loc.captured then needs_close = true end
        else
            new_locs[#new_locs+1] = loc
        end
    end
    if needs_close then
        self:emit("OP_CLOSE", base_reg, 0, 0)
    end
    self.cur.locals = new_locs
    self.cur.nextreg = base_reg
end

-- Loop stack
function SC:pushLoop()
    local p = self.cur
    p.break_stack[#p.break_stack+1]    = {}
    p.continue_stack[#p.continue_stack+1] = {}
end

function SC:addBreak()
    local bs = self.cur.break_stack
    local j = self:emitJmp()
    bs[#bs][#bs[#bs]+1] = j
end

function SC:patchBreaks(end_pc)
    local bs = self.cur.break_stack
    for _, j in ipairs(bs[#bs]) do self:patchJmp(j, end_pc) end
    bs[#bs] = nil
end

function SC:patchContinues(top_pc)
    local cs = self.cur.continue_stack
    for _, j in ipairs(cs[#cs]) do self:patchJmp(j, top_pc) end
    cs[#cs] = nil
end

-- ─── Expression parsing ──────────────────────────────────────────────────

function SC:parseExpr(dst, tok)
    return self:parseOr(dst, tok)
end

function SC:parseOr(dst, tok)
    local r = self:parseBinaryPrec(dst, tok, 1)
    return r
end

-- Pratt-style precedence table for binary ops
local BINOP_PREC = {
    ["or"] ={prec=1, assoc="L"},
    ["and"]={prec=2, assoc="L"},
    ["<"]  ={prec=3, assoc="L"},
    [">"]  ={prec=3, assoc="L"},
    ["<="] ={prec=3, assoc="L"},
    [">="] ={prec=3, assoc="L"},
    ["=="] ={prec=3, assoc="L"},
    ["~="] ={prec=3, assoc="L"},
    [".."] ={prec=4, assoc="R"},
    ["+"]  ={prec=5, assoc="L"},
    ["-"]  ={prec=5, assoc="L"},
    ["*"]  ={prec=6, assoc="L"},
    ["/"]  ={prec=6, assoc="L"},
    ["%"]  ={prec=6, assoc="L"},
    ["//"] ={prec=6, assoc="L"},
    ["^"]  ={prec=8, assoc="R"},
}

function SC:parseBinaryPrec(dst, tok, min_prec)
    local lhs = self:parseUnary(dst, tok)

    while true do
        local op_tok = tok.peek
        local info   = BINOP_PREC[op_tok.kind]
        if not info or info.prec < min_prec then break end

        tok:advance()
        local next_prec = info.assoc == "R" and info.prec or (info.prec + 1)

        local rhs_reg = self:allocReg(1)
        self:parseBinaryPrec(rhs_reg, tok, next_prec)

        local opk = op_tok.kind
        if     opk == "or" then
            -- short-circuit: lhs already in dst; if truthy skip to end
            self:emit("OP_TESTSET", dst, dst, 1)
            local j = self:emitJmp()
            self:emit("OP_MOVE", dst, rhs_reg, 0)
            self:patchJmp(j, self:pc())
        elseif opk == "and" then
            -- short-circuit: lhs already in dst; if falsy skip to end
            self:emit("OP_TESTSET", dst, dst, 0)
            local j = self:emitJmp()
            self:emit("OP_MOVE", dst, rhs_reg, 0)
            self:patchJmp(j, self:pc())
        elseif opk == ".." then
            -- collect into concat range
            self:emit("OP_CONCAT", dst, dst, rhs_reg)
        elseif opk == "+"  then self:emit("OP_ADD",dst,dst,rhs_reg)
        elseif opk == "-"  then self:emit("OP_SUB",dst,dst,rhs_reg)
        elseif opk == "*"  then self:emit("OP_MUL",dst,dst,rhs_reg)
        elseif opk == "/"  then self:emit("OP_DIV",dst,dst,rhs_reg)
        elseif opk == "%"  then self:emit("OP_MOD",dst,dst,rhs_reg)
        elseif opk == "//" then self:emit("OP_DIV",dst,dst,rhs_reg)  -- approx
        elseif opk == "^"  then self:emit("OP_POW",dst,dst,rhs_reg)
        elseif opk == "==" then
            self:emit("OP_EQ", 0, dst, rhs_reg)
            local jf = self:emitJmp()
            self:emit("OP_LOADBOOL", dst, 1, 1)
            self:patchJmp(jf, self:pc())
            self:emit("OP_LOADBOOL", dst, 0, 0)
        elseif opk == "~=" then
            self:emit("OP_EQ", 1, dst, rhs_reg)
            local jf = self:emitJmp()
            self:emit("OP_LOADBOOL", dst, 1, 1)
            self:patchJmp(jf, self:pc())
            self:emit("OP_LOADBOOL", dst, 0, 0)
        elseif opk == "<"  then
            self:emit("OP_LT", 0, dst, rhs_reg)
            local jf = self:emitJmp()
            self:emit("OP_LOADBOOL", dst, 1, 1)
            self:patchJmp(jf, self:pc())
            self:emit("OP_LOADBOOL", dst, 0, 0)
        elseif opk == ">"  then
            self:emit("OP_LT", 0, rhs_reg, dst)  -- swap operands
            local jf = self:emitJmp()
            self:emit("OP_LOADBOOL", dst, 1, 1)
            self:patchJmp(jf, self:pc())
            self:emit("OP_LOADBOOL", dst, 0, 0)
        elseif opk == "<=" then
            self:emit("OP_LE", 0, dst, rhs_reg)
            local jf = self:emitJmp()
            self:emit("OP_LOADBOOL", dst, 1, 1)
            self:patchJmp(jf, self:pc())
            self:emit("OP_LOADBOOL", dst, 0, 0)
        elseif opk == ">=" then
            self:emit("OP_LE", 0, rhs_reg, dst)
            local jf = self:emitJmp()
            self:emit("OP_LOADBOOL", dst, 1, 1)
            self:patchJmp(jf, self:pc())
            self:emit("OP_LOADBOOL", dst, 0, 0)
        end
        self:freeReg(1)  -- rhs_reg
        lhs = dst
    end

    return lhs
end

function SC:parseUnary(dst, tok)
    if tok:match("not") then
        local tmp = self:allocReg(1)
        self:parseUnary(tmp, tok)
        self:emit("OP_NOT", dst, tmp, 0)
        self:freeReg(1)
        return dst
    elseif tok:match("-") then
        local tmp = self:allocReg(1)
        self:parseUnary(tmp, tok)
        self:emit("OP_UNM", dst, tmp, 0)
        self:freeReg(1)
        return dst
    elseif tok:match("#") then
        local tmp = self:allocReg(1)
        self:parseUnary(tmp, tok)
        self:emit("OP_LEN", dst, tmp, 0)
        self:freeReg(1)
        return dst
    else
        return self:parsePower(dst, tok)
    end
end

function SC:parsePower(dst, tok)
    local base = self:parsePrimary(dst, tok)
    if tok:match("^") then
        local exp_reg = self:allocReg(1)
        self:parseUnary(exp_reg, tok)  -- right-assoc: unary binds tighter than ^
        self:emit("OP_POW", dst, dst, exp_reg)
        self:freeReg(1)
    end
    return base
end

function SC:parsePrimary(dst, tok)
    -- Parse a primary expression and zero or more suffix ops (calls, index, field)
    self:parseAtom(dst, tok)
    return self:parseSuffix(dst, tok)
end

function SC:parseAtom(dst, tok)
    local t = tok.peek

    if t.kind == "NUMBER" then
        tok:advance()
        self:emit("OP_LOADK", dst, self:addK(t.val), 0)
    elseif t.kind == "STRING" then
        tok:advance()
        self:emit("OP_LOADK", dst, self:addK(t.val), 0)
    elseif t.kind == "true" then
        tok:advance()
        self:emit("OP_LOADBOOL", dst, 1, 0)
    elseif t.kind == "false" then
        tok:advance()
        self:emit("OP_LOADBOOL", dst, 0, 0)
    elseif t.kind == "nil" then
        tok:advance()
        self:emit("OP_LOADNIL", dst, 0, 0)
    elseif t.kind == "..." then
        tok:advance()
        self:emit("OP_VARARG", dst, 0, 0)  -- B=0: all varargs
    elseif t.kind == "NAME" then
        tok:advance()
        local kind, idx = self:resolveVar(t.val)
        if kind == "local" then
            if idx ~= dst then self:emit("OP_MOVE", dst, idx, 0) end
        elseif kind == "upval" then
            self:emit("OP_GETUPVAL", dst, idx, 0)
        else
            self:emit("OP_GETGLOBAL", dst, self:addK(t.val), 0)
        end
    elseif t.kind == "function" then
        tok:advance()
        self:parseFunctionBody(dst, tok)
    elseif t.kind == "{" then
        self:parseTableConstructor(dst, tok)
    elseif t.kind == "(" then
        tok:advance()
        self:parseExpr(dst, tok)
        tok:expect(")")
    else
        error("Unexpected token in expression: " .. t.kind .. " ("..tostring(t.val)..") at line "..t.line)
    end
end

function SC:parseSuffix(dst, tok)
    while true do
        if tok:match(".") then
            -- Field access: dst = dst.field
            local field = tok:expect("NAME")
            local k_rk  = self:Krk(field.val)
            self:emit("OP_GETTABLE", dst, dst, k_rk)
        elseif tok:match("[") then
            -- Index: dst = dst[expr]
            local idx_reg = self:allocReg(1)
            self:parseExpr(idx_reg, tok)
            tok:expect("]")
            self:emit("OP_GETTABLE", dst, dst, idx_reg)
            self:freeReg(1)
        elseif tok.peek.kind == "(" or tok.peek.kind == "{" or tok.peek.kind == "STRING" then
            -- Function call: dst = dst(args...)
            self:parseCallSuffix(dst, dst, tok, false)
        elseif tok:match(":") then
            -- Method call: dst = dst:method(args...)
            local method = tok:expect("NAME")
            local self_reg = self:allocReg(1)
            self:emit("OP_MOVE", self_reg, dst, 0)
            local k_rk = self:Krk(method.val)
            self:emit("OP_SELF", dst, self_reg, k_rk)
            -- Don't free self_reg yet -- parseCallSuffix may allocate regs for
            -- arguments and we must not reuse the register holding self.
            self:parseCallSuffix(dst, dst+1, tok, true, self_reg)
            -- Now free self_reg AFTER the call has emitted
            self:freeReg(1)
        else
            break
        end
    end
    return dst
end

-- Parse call arguments and emit OP_CALL into `dst`
-- `reserved_reg` is a register that must NOT be reused for args (or nil).
function SC:parseCallSuffix(fn_reg, self_reg, tok, is_self, reserved_reg)
    local arg_base = fn_reg + (is_self and 2 or 1)
    local nargs

    if tok.peek.kind == "{" then
        -- Single table argument
        local r = self:allocReg(1)
        self:parseTableConstructor(r, tok)
        nargs = 1
    elseif tok.peek.kind == "STRING" then
        local r = self:allocReg(1)
        self:emit("OP_LOADK", r, self:addK(tok.peek.val), 0)
        tok:advance()
        nargs = 1
    else
        tok:expect("(")
        nargs = 0
        if not tok:match(")") then
            while true do
                local r = self:allocReg(1)
                local is_last = not (tok.peek.kind == ",")
                -- Check if the expression is the last arg (for multi-return)
                self:parseExpr(r, tok)
                nargs = nargs + 1
                if not tok:match(",") then break end
            end
            tok:expect(")")
        end
    end

    local B = nargs + 1  -- B=0 → multi-arg (we don't handle that here for simplicity)
    local C = 2          -- C=2 → exactly 1 return value
    self:emit("OP_CALL", fn_reg, B + (is_self and 1 or 0), C)
    self:freeReg(nargs)
end

function SC:parseFunctionBody(dst, tok)
    tok:expect("(")
    local params = {}
    local is_vararg = false
    if not tok:match(")") then
        while true do
            if tok:match("...") then
                is_vararg = true
                tok:expect(")")
                break
            end
            params[#params+1] = tok:expect("NAME").val
            if not tok:match(",") then
                tok:expect(")")
                break
            end
        end
    end

    -- Push new proto
    local child_st = self:pushProto(#params, is_vararg)

    -- Declare parameters
    for i, pname in ipairs(params) do
        local loc = {name=pname, reg=i-1, captured=false}
        child_st.locals[#child_st.locals+1] = loc
    end

    -- Compile body
    self:parseBlock(tok)
    tok:expect("end")

    -- Pop proto
    local proto_idx = self:popProto()

    -- Register child in parent's proto list
    local parent = self.cur
    local slot = #parent.protos + 1
    parent.protos[slot] = proto_idx

    -- Emit OP_CLOSURE + pseudo-ops
    self:emit("OP_CLOSURE", dst, slot, 0)
    for _, ud in ipairs(child_st.upvaldefs) do
        if ud.instack then
            self:emit("OP_MOVE", 1, ud.idx, 0)
        else
            self:emit("OP_GETUPVAL", 0, ud.idx, 0)
        end
    end
end

function SC:parseTableConstructor(dst, tok)
    tok:expect("{")
    self:emit("OP_NEWTABLE", dst, 0, 0)
    local array_i = 0
    while not tok:match("}") do
        if tok.peek.kind == "[" then
            -- [expr] = expr
            tok:advance()
            local k_reg = self:allocReg(1)
            self:parseExpr(k_reg, tok)
            tok:expect("]")
            tok:expect("=")
            local v_reg = self:allocReg(1)
            self:parseExpr(v_reg, tok)
            self:emit("OP_SETTABLE", dst, k_reg, v_reg)
            self:freeReg(2)
        elseif tok.peek.kind == "NAME" and self:_peekIsAssign(tok) then
            -- name = expr
            local key = tok:advance().val
            tok:expect("=")
            local v_reg = self:allocReg(1)
            self:parseExpr(v_reg, tok)
            self:emit("OP_SETTABLE", dst, self:Krk(key), v_reg)
            self:freeReg(1)
        else
            -- Array value
            array_i = array_i + 1
            local v_reg = self:allocReg(1)
            self:parseExpr(v_reg, tok)
            self:emit("OP_SETTABLE", dst, self:Krk(array_i), v_reg)
            self:freeReg(1)
        end
        if not tok:match(",") and not tok:match(";") then
            tok:expect("}")
            return
        end
    end
end

function SC:_peekIsAssign(tok)
    -- Look one token ahead of the NAME to see if it's "="
    -- We need a 2-token lookahead here.  Simple hack: save state.
    local saved_pos  = tok.pos
    local saved_peek = tok.peek
    local saved_line = tok.line
    tok:advance()
    local is_assign = tok.peek.kind == "="
    -- Restore
    tok.pos  = saved_pos
    tok.peek = saved_peek
    tok.line = saved_line
    return is_assign
end

-- ─── Statement parsing ───────────────────────────────────────────────────

local BLOCK_END = {["end"]=true, ["else"]=true, ["elseif"]=true,
                   ["until"]=true, ["EOF"]=true}

function SC:parseBlock(tok)
    while not BLOCK_END[tok.peek.kind] do
        if not self:parseStatement(tok) then break end
    end
end

function SC:parseStatement(tok)
    local t = tok.peek
    local kind = t.kind

    if kind == "local" then
        tok:advance()
        if tok.peek.kind == "function" then
            tok:advance()
            local name = tok:expect("NAME").val
            local r    = self:declareLocal(name)
            self:parseFunctionBody(r, tok)
        else
            -- local a, b, c = ...
            local names = {tok:expect("NAME").val}
            while tok:match(",") do
                names[#names+1] = tok:expect("NAME").val
            end
            local regs = {}
            for _, nm in ipairs(names) do
                regs[#regs+1] = self:declareLocal(nm)
            end
            if tok:match("=") then
                -- Reuse already-allocated regs (since declareLocal already allocated them)
                -- We need to compile into the right registers.
                -- Tricky: regs were already allocated, but their local entries exist.
                -- Temporarily set nextreg back, compile exprs there, then advance again.
                for i, r in ipairs(regs) do
                    if i < #regs then
                        self:parseExpr(r, tok)
                        tok:match(",")
                    else
                        self:parseExpr(r, tok)
                    end
                end
            else
                for _, r in ipairs(regs) do
                    self:emit("OP_LOADNIL", r, 0, 0)
                end
            end
        end

    elseif kind == "function" then
        tok:advance()
        self:parseFunctionDecl(tok)

    elseif kind == "if" then
        tok:advance()
        self:parseIfStmt(tok)

    elseif kind == "while" then
        tok:advance()
        local loop_top = self:pc()
        self:pushLoop()
        local cond_reg = self:allocReg(1)
        self:parseExpr(cond_reg, tok)
        tok:expect("do")
        self:emit("OP_TEST", cond_reg, 0, 0)
        self:freeReg(1)
        local jmp_exit = self:emitJmp()
        local scope_base = self:pushScope()
        self:parseBlock(tok)
        tok:expect("end")
        self:popScope(scope_base)
        local jmp_back = self:emitJmp()
        self:patchJmp(jmp_back, loop_top)
        local loop_end = self:pc()
        self:patchJmp(jmp_exit, loop_end)
        self:patchBreaks(loop_end)

    elseif kind == "repeat" then
        tok:advance()
        local loop_top = self:pc()
        self:pushLoop()
        local scope_base = self:pushScope()
        self:parseBlock(tok)
        tok:expect("until")
        local cond_reg = self:allocReg(1)
        self:parseExpr(cond_reg, tok)
        self:emit("OP_TEST", cond_reg, 0, 1)
        self:freeReg(1)
        local jmp_exit = self:emitJmp()
        local jmp_back = self:emitJmp()
        self:patchJmp(jmp_back, loop_top)
        local loop_end = self:pc()
        self:patchJmp(jmp_exit, loop_end)
        self:popScope(scope_base)
        self:patchBreaks(loop_end)

    elseif kind == "for" then
        tok:advance()
        self:parseForStmt(tok)

    elseif kind == "do" then
        tok:advance()
        local scope_base = self:pushScope()
        self:parseBlock(tok)
        tok:expect("end")
        self:popScope(scope_base)

    elseif kind == "return" then
        tok:advance()
        self:parseReturnStmt(tok)
        tok:match(";")
        return false  -- return always ends block

    elseif kind == "break" then
        tok:advance()
        self:addBreak()

    elseif kind == ";" then
        tok:advance()

    elseif kind == "NAME" or kind == "(" then
        -- Assignment or function call
        self:parseExprStat(tok)

    else
        return false
    end

    tok:match(";")
    return true
end

function SC:parseFunctionDecl(tok)
    -- function a.b.c:d(...) ... end
    local name = tok:expect("NAME").val
    local indices = {}
    local is_method = false

    while tok:match(".") do
        indices[#indices+1] = tok:expect("NAME").val
    end
    if tok:match(":") then
        indices[#indices+1] = tok:expect("NAME").val
        is_method = true
    end

    local fn_reg = self:allocReg(1)

    if is_method then
        -- Add implicit "self" parameter
        -- We'll handle this in parseFunctionBody via tok rewrite is complex;
        -- simplification: push a synthetic first param
    end

    self:parseFunctionBody(fn_reg, tok)

    -- Store result
    if #indices == 0 then
        local kind, idx = self:resolveVar(name)
        if kind == "local" then
            self:emit("OP_MOVE", idx, fn_reg, 0)
        elseif kind == "upval" then
            self:emit("OP_SETUPVAL", fn_reg, idx, 0)
        else
            self:emit("OP_SETGLOBAL", fn_reg, self:addK(name), 0)
        end
    else
        -- Navigate to base
        local base_reg = fn_reg + 1  -- we know fn_reg is last alloc'd
        -- simplified: just do a global set chain
        local kind, idx = self:resolveVar(name)
        if kind == "local" then
            self:emit("OP_MOVE", base_reg, idx, 0)
        elseif kind == "upval" then
            self:emit("OP_GETUPVAL", base_reg, idx, 0)
        else
            self:emit("OP_GETGLOBAL", base_reg, self:addK(name), 0)
        end
        for i = 1, #indices - 1 do
            self:emit("OP_GETTABLE", base_reg, base_reg, self:Krk(indices[i]))
        end
        self:emit("OP_SETTABLE", base_reg, self:Krk(indices[#indices]), fn_reg)
    end

    self:freeReg(1)
end

function SC:parseIfStmt(tok)
    local end_jumps = {}

    local function doBranch()
        local cond_reg = self:allocReg(1)
        self:parseExpr(cond_reg, tok)
        tok:expect("then")
        self:emit("OP_TEST", cond_reg, 0, 0)
        self:freeReg(1)
        local jmp_skip = self:emitJmp()
        local scope_base = self:pushScope()
        self:parseBlock(tok)
        self:popScope(scope_base)
        local jmp_end = self:emitJmp()
        end_jumps[#end_jumps+1] = jmp_end
        self:patchJmp(jmp_skip, self:pc())
    end

    doBranch()

    while tok:match("elseif") do
        doBranch()
    end

    if tok:match("else") then
        local scope_base = self:pushScope()
        self:parseBlock(tok)
        self:popScope(scope_base)
    end

    tok:expect("end")

    local end_pc = self:pc()
    for _, j in ipairs(end_jumps) do
        self:patchJmp(j, end_pc)
    end
end

function SC:parseForStmt(tok)
    local first_name = tok:expect("NAME").val

    if tok:match("=") then
        -- Numeric for
        local r_init  = self:allocReg(1)
        local r_limit = self:allocReg(1)
        local r_step  = self:allocReg(1)
        local r_var   = self:allocReg(1)

        self:parseExpr(r_init, tok)
        tok:expect(",")
        self:parseExpr(r_limit, tok)
        if tok:match(",") then
            self:parseExpr(r_step, tok)
        else
            self:emit("OP_LOADK", r_step, self:addK(1), 0)
        end
        tok:expect("do")
        self:pushLoop()

        local forprep_pos = self:emit("OP_FORPREP", r_init, 0, 0)
        local body_start  = self:pc()

        -- Loop variable
        local scope_base = self:pushScope()
        local loc = {name=first_name, reg=r_var, captured=false}
        self.cur.locals[#self.cur.locals+1] = loc

        self:parseBlock(tok)
        tok:expect("end")
        self:popScope(scope_base)

        local forloop_pos = self:emit("OP_FORLOOP", r_init, 0, 0)
        self.cur.code[forloop_pos+2] = body_start - forloop_pos - FIELDS
        self:patchJmp(forprep_pos, forloop_pos)

        local loop_end = self:pc()
        self:patchBreaks(loop_end)
        self:freeReg(4)

    else
        -- Generic for: for a, b, c in expr do
        local vars = {first_name}
        while tok:match(",") do
            vars[#vars+1] = tok:expect("NAME").val
        end
        tok:expect("in")

        local r_iter  = self:allocReg(1)
        local r_state = self:allocReg(1)
        local r_ctrl  = self:allocReg(1)
        -- Compile iterator expressions
        self:parseExpr(r_iter, tok)  -- simplified: only first expr
        while tok:match(",") do
            local r = self:allocReg(1)
            self:parseExpr(r, tok)
        end

        tok:expect("do")
        self:pushLoop()

        local scope_base = self:pushScope()
        local var_regs = {}
        for i, vname in ipairs(vars) do
            var_regs[i] = self:declareLocal(vname)
        end

        local loop_top = self:pc()
        local tfor_pos = self:emit("OP_TFORLOOP", r_iter, 0, #vars)
        local jmp_exit = self:emitJmp()

        self:parseBlock(tok)
        tok:expect("end")
        self:popScope(scope_base)

        local jmp_back = self:emitJmp()
        self:patchJmp(jmp_back, loop_top)
        local loop_end = self:pc()
        self:patchJmp(jmp_exit, loop_end)
        self:patchBreaks(loop_end)
        self:freeReg(3 + #vars)
    end
end

function SC:parseReturnStmt(tok)
    local args = {}
    if not BLOCK_END[tok.peek.kind] and tok.peek.kind ~= ";" then
        local r = self:allocReg(1)
        self:parseExpr(r, tok)
        args[1] = r
        while tok:match(",") do
            local r2 = self:allocReg(1)
            self:parseExpr(r2, tok)
            args[#args+1] = r2
        end
    end

    if #args == 0 then
        self:emit("OP_RETURN", 0, 1, 0)
    else
        self:emit("OP_RETURN", args[1], #args + 1, 0)
        self:freeReg(#args)
    end
end

function SC:parseExprStat(tok)
    -- Parse a primary expression; if followed by assignment, compile it.
    -- Otherwise, it's a function call statement.
    local dst = self:allocReg(1)
    self:parseAtom(dst, tok)

    -- Check for suffix + assignment
    local is_call = false
    while true do
        if tok:match(".") then
            local field = tok:expect("NAME")
            if tok:match("=") then
                -- field assignment
                local val = self:allocReg(1)
                self:parseExpr(val, tok)
                self:emit("OP_SETTABLE", dst, self:Krk(field.val), val)
                self:freeReg(1)
                break
            end
            self:emit("OP_GETTABLE", dst, dst, self:Krk(field.val))
        elseif tok.peek.kind == "[" then
            tok:advance()
            local idx = self:allocReg(1)
            self:parseExpr(idx, tok)
            tok:expect("]")
            if tok:match("=") then
                local val = self:allocReg(1)
                self:parseExpr(val, tok)
                self:emit("OP_SETTABLE", dst, idx, val)
                self:freeReg(2)
                break
            end
            self:emit("OP_GETTABLE", dst, dst, idx)
            self:freeReg(1)
        elseif tok.peek.kind == "(" or tok.peek.kind == "STRING" or tok.peek.kind == "{" then
            self:parseCallSuffix(dst, dst, tok, false)
            is_call = true
        elseif tok:match(":") then
            local method = tok:expect("NAME")
            local s_reg  = self:allocReg(1)
            self:emit("OP_MOVE", s_reg, dst, 0)
            self:emit("OP_SELF", dst, s_reg, self:Krk(method.val))
            -- Don't free s_reg yet -- parseCallSuffix may allocate regs
            self:parseCallSuffix(dst, dst+1, tok, true, s_reg)
            self:freeReg(1)
            is_call = true
        elseif tok:match("=") then
            -- Simple global/local assignment
            local val = self:allocReg(1)
            self:parseExpr(val, tok)
            -- We need the original variable for assignment - simplified
            self:emit("OP_MOVE", dst, val, 0)
            self:freeReg(1)
            break
        else
            break
        end
    end

    self:freeReg(1)
end

-- ── Root compilation ─────────────────────────────────────────────────────

function SC:compile(source)
    local tok = Tok.new(source)

    -- Root proto
    local root_st = self:pushProto(0, true)
    -- Upvalue 1 = _ENV
    root_st.upvaldefs[1] = {name="_ENV", instack=false, idx=0}

    self:parseBlock(tok)
    if tok.peek.kind ~= "EOF" then
        error("Parse error: unexpected token " .. tok.peek.kind ..
              " at line " .. tok.peek.line)
    end

    local root_idx = self:popProto()
    return self.all_protos, root_idx
end

-- ────────────────────────────────────────────────────────────────────────────
--  PUBLIC API
-- ────────────────────────────────────────────────────────────────────────────

local M = {}

-- generate(source_string) → obfuscated_vm_string
-- Runs a fresh ISA randomization on every call.
function M.generate(source)
    math.randomseed(os.time() + os.clock() * 1e6)

    local op, opname, op_aliases = ISA.randomize()
    local compiler   = SC.new(op)
    local all_protos, root_idx = compiler:compile(source)

    local emitter    = makeEmitter(op, opname, op_aliases)
    return emitter:emit(all_protos, root_idx)
end

-- CLI entry point
if arg and arg[0] and arg[0]:match("generator%.lua$") then
    local in_file  = arg[1]
    local out_file = arg[2]
    if not in_file then
        io.write("Usage: lua bvm/generator.lua <input.lua> [output.lua]\n")
        os.exit(1)
    end
    local f = assert(io.open(in_file, "r"))
    local src = f:read("*a")
    f:close()

    local result = M.generate(src)

    if out_file then
        local g = assert(io.open(out_file, "w"))
        g:write(result)
        g:close()
        io.write("BVM: wrote " .. #result .. " bytes to " .. out_file .. "\n")
    else
        io.write(result)
    end
end

return M
