-- ============================================================
--  bvm/emitter.lua
--  Bytecode VM Emitter — COMPLETELY REWRITTEN
--
--  Core Design:
--    OP_CLOSURE creates a TABLE with _bvmc/_bvmu/_bvmv fields
--    and __call metamethod. Tables are callable in Lua/Luau via
--    __call, detectable via type()=="table" for _bvmc check.
--
--    OP_CALL first checks type()=="table" and _bvmc → BVM path.
--    Otherwise → native Lua function path.
--
--    This avoids rawset() on functions (hard-crash in Lua 5.1)
--    and works universally across all Roblox executors.
-- ============================================================

local ISA       = require("prometheus.bvm.isa")
local CONST_BIAS = ISA.CONST_BIAS
local FIELDS     = ISA.FIELDS

local Emitter = {}
Emitter.__index = Emitter

function Emitter.new(op, opname, op_aliases, chunk_size)
    chunk_size = chunk_size or 50
    return setmetatable({
        op = op, opname = opname, op_aliases = op_aliases,
        lines = {}, indent = 0,
        chunk_size = chunk_size,
        compact = chunk_size >= 100,  -- Enable compact mode
    }, Emitter)
end

function Emitter:w(s)
    if self.compact then
        table.insert(self.lines, s)  -- No indentation
    else
        table.insert(self.lines, string.rep("  ", self.indent) .. s)
    end
end
function Emitter:push() self.indent = self.indent + 1 end
function Emitter:pop()  self.indent = self.indent - 1 end
function Emitter:flush() 
    return table.concat(self.lines, "\n")
end

-- Lua literal serializer
local function luaLit(v)
    if v == nil then return "nil"
    elseif type(v) == "boolean" then return tostring(v)
    elseif type(v) == "number" then
        if v ~= v then return "(0/0)" end
        if v ==  math.huge then return  "math.huge" end
        if v == -math.huge then return "-math.huge" end
        return string.format("%.17g", v)
    elseif type(v) == "string" then
        return string.format("%q", v)
    else
        error("luaLit: unsupported type " .. type(v))
    end
end

-- XOR helper for Lua 5.1 (no ~ operator)
local function xor8(a, b)
    if bit32 and bit32.bxor then return bit32.bxor(a, b) end
    local r, pa, pb = 0, 1, 1
    for _i = 0, 7 do
        local ab = math.floor(a / pa) % 2
        local bb = math.floor(b / pb) % 2
        if ab ~= bb then r = r + pa end
        pa = pa * 2; pb = pb * 2
    end
    return r
end

local function shiftEncodeString(s, key1, key2)
    local res = {}
    for i = 1, #s do
        res[i] = string.char(((xor8(s:byte(i), key1) - key2) % 256))
    end
    return table.concat(res)
end

-- Emit a table in chunks inside do...end blocks
function Emitter:emitTableChunked(tblvar, values, encoder)
    encoder = encoder or luaLit
    if #values == 0 then return end
    local i = 1
    local chunkSize = self.chunk_size
    while i <= #values do
        local limit = math.min(i + chunkSize - 1, #values)
        
        -- LARGE CHUNK MODE: Multiple assignments per line (parser-friendly)
        if chunkSize >= 100 then
            local lineParts = {}
            for j = i, limit do
                table.insert(lineParts, tblvar .. "[" .. j .. "]=" .. encoder(values[j]))
            end
            -- Pack 200 assignments per line
            for j = 1, #lineParts, 200 do
                local endJ = math.min(j + 199, #lineParts)
                local chunk = {}
                for k = j, endJ do
                    table.insert(chunk, lineParts[k])
                end
                self:w(table.concat(chunk, ";"))
            end
        else
            self:w("do")
            self:push()
            for j = i, limit do
                self:w(tblvar .. "[" .. j .. "]=" .. encoder(values[j]))
            end
            self:pop()
            self:w("end")
        end
        i = i + chunkSize
    end
end

-- Emit all proto data
function Emitter:emitProtos(all_protos, str_keys)
    local n = #all_protos

    self:w("local _K={}")
    for i = 1, n do self:w("_K["..i.."]={}") end
    self:w("local _BC={}")
    for i = 1, n do self:w("_BC["..i.."]={}") end
    self:w("local _PM={}")
    self:w("local _SK={}")
    if str_keys then
        for i = 1, n do
            self:w("_SK["..i.."]={"..str_keys[i][1]..","..str_keys[i][2].."}")
        end
    end

    -- _ENV_ref: use normal indexing (fires __index) for Roblox compat
    -- _ENV_ref: Roblox-safe global environment resolver.
    -- Priority: getgenv() > getfenv(0) > _ENV (if has game) > _G (if has game) > _ENV > _G > empty table
    self:w("local function _ge(t,k) if type(t)~='table' then return nil end return t[k] end")
    self:w("local _ENV_ref")
    self:w("do")
    self:push()
    self:w("local function _hg(t) return type(t)=='table' and _ge(t,'game')~=nil end")
    self:w("_ENV_ref = (type(getgenv)=='function' and getgenv())")
    self:w("  or (type(getfenv)=='function' and _hg(getfenv(0)) and getfenv(0))")
    self:w("  or (_hg(_ENV) and _ENV)")
    self:w("  or (_hg(_G) and _G)")
    self:w("  or (type(_ENV)=='table' and _ENV)")
    self:w("  or (type(_G)=='table' and _G)")
    self:w("  or {}")
    self:pop()
    self:w("end")

    for i, proto in ipairs(all_protos) do
        if #proto.k > 0 then
            local chunk_key = str_keys and str_keys[i]
            if chunk_key then
                local k1, k2 = chunk_key[1], chunk_key[2]
                local strEncoder = function(v)
                    if type(v) == "string" then
                        local encoded = shiftEncodeString(v, k1, k2)
                        local bytes = {}
                        for bi = 1, #encoded do bytes[bi] = string.byte(encoded, bi) end
                        return "string.char(" .. table.concat(bytes, ",") .. ")"
                    end
                    return luaLit(v)
                end
                self:emitTableChunked("_K[" .. i .. "]", proto.k, strEncoder)
            else
                self:emitTableChunked("_K[" .. i .. "]", proto.k)
            end
        end

        if #proto.code > 0 then
            self:emitTableChunked("_BC[" .. i .. "]", proto.code, tostring)
        end

        local upval_str = "{"
        for j, ud in ipairs(proto.upvaldefs) do
            upval_str = upval_str .. "{instack=" .. tostring(ud.instack) .. ",idx=" .. ud.idx .. "}"
            if j < #proto.upvaldefs then upval_str = upval_str .. "," end
        end
        upval_str = upval_str .. "}"

        local child_str = "{"
        for j, cidx in ipairs(proto.protos) do
            child_str = child_str .. cidx
            if j < #proto.protos then child_str = child_str .. "," end
        end
        child_str = child_str .. "}"

        self:w(string.format("_PM[%d]={np=%d,va=%s,nup=%d,up=%s,cp=%s}",
            i, proto.numparams, tostring(proto.is_vararg),
            #proto.upvaldefs, upval_str, child_str))
    end

    -- Dead chunks for anti-decompiler
    local O = self.op
    local num_dead = math.random(3, 6)
    for _d = 1, num_dead do
        local dead_idx = n + _d
        self:w("_BC["..dead_idx.."]={}")
        self:w("_K["..dead_idx.."]={}")
        local dead_code = {}
        local dc_len = math.random(8, 24)
        local move_id = O.OP_MOVE or 1
        local loadk_id = O.OP_LOADK or 2
        local loadn_id = O.OP_LOADNIL or 3
        local ret_id = O.OP_RETURN or 4
        local loadb_id = O.OP_LOADBOOL or 5
        local add_id = O.OP_ADD or 6
        local unm_id = O.OP_UNM or 7
        local op_pool = {move_id, loadk_id, loadn_id, loadb_id, add_id, unm_id}
        for _j = 1, dc_len - 1 do
            table.insert(dead_code, op_pool[math.random(#op_pool)])
            table.insert(dead_code, math.random(0, 5))
            table.insert(dead_code, math.random(0, 10))
            table.insert(dead_code, math.random(0, 10))
        end
        table.insert(dead_code, ret_id)
        table.insert(dead_code, 0)
        table.insert(dead_code, 1)
        table.insert(dead_code, 0)
        self:emitTableChunked("_BC[" .. dead_idx .. "]", dead_code, tostring)
        self:w("_K["..dead_idx.."]={}")
        self:w(string.format("_PM[%d]={np=0,va=false,nup=0,up={},cp={}}", dead_idx))
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  VM EMISSION
-- ═══════════════════════════════════════════════════════════════════════════
function Emitter:emitVM(root_proto_idx, str_keys)
    local O = self.op
    local O_aliases = self.op_aliases or {}

    -- Capture Lua builtins before rename step can corrupt them
    self:w("local _type=type")
    self:w("local _pairs=pairs")
    self:w("local _unpack=table.unpack or (rawget and rawget(table,'unpack'))")
    self:w("  or(_ENV_ref and(_ENV_ref.table and _ENV_ref.table.unpack or _ENV_ref.unpack)) or unpack")
    self:w("local function _pack(...) return {n=select('#',...),...} end")

    -- _exec function
    self:w("local _exec")
    self:w("_exec=function(pi,upvals,vararg,...)")
    self:push()

    self:w("if not pi then return end")
    self:w("local pm=_PM[pi]")
    self:w("if not pm then return end")
    self:w("local code=_BC[pi]")
    self:w("if not code then return end")
    self:w("local k=(_K[pi] or {})")

    -- Portable XOR
    self:w("local _bxor=bit32 and bit32.bxor or function(a,b)")
    self:push()
    self:w("local r=0")
    self:w("for _bi=0,7 do")
    self:push()
    self:w("local _p=2^_bi")
    self:w("local _ab=math.floor(a/_p)%2")
    self:w("local _bb=math.floor(b/_p)%2")
    self:w("if _ab~=_bb then r=r+_p end")
    self:pop()
    self:w("end")
    self:w("return r")
    self:pop()
    self:w("end")

    self:w("local function _rgs(s,key1,key2)")
    self:push()
    self:w("local _out={}")
    self:w("for _i=1,#s do _out[_i]=string.char((_bxor(string.byte(s,_i)+key2,key1))%256) end")
    self:w("return table.concat(_out)")
    self:pop()
    self:w("end")

    -- String decoder (only for protos that have string keys)
    self:w("if not _K._d then")
    self:push()
    self:w("_K._d=true")
    self:w("for __bi=1,#_K do")
    self:push()
    self:w("local __sk=_SK[__bi]")
    self:w("if __sk and type(_K[__bi])=='table' then")
    self:push()
    self:w("for __bj=1,#(_K[__bi] or {}) do")
    self:push()
    self:w("if type(_K[__bi][__bj])=='string' then")
    self:push()
    self:w("_K[__bi][__bj]=_rgs(_K[__bi][__bj],__sk[1],__sk[2])")
    self:pop()
    self:w("end")
    self:pop()
    self:w("end")
    self:pop()
    self:w("end")
    self:pop()
    self:w("end")
    self:pop()
    self:w("end")
    self:w("for __ci=1,#_SK do _SK[__ci]=nil end")

    self:w("local Stack={}")
    self:w("local pc=1")
    self:w("local top=pm.np or 0")
    self:w("local open_upvals={}")

    self:w("local _argc=select('#',...)")
    self:w("local _args={...}")
    self:w("for _pii=1,(pm.np or 0) do Stack[_pii-1]=_args[_pii] end")

    self:w("local _va={}")
    self:w("if pm.va then")
    self:push()
    self:w("for _vii=pm.np+1,_argc do _va[_vii-pm.np]=_args[_vii] end")
    self:pop()
    self:w("end")

    -- RK decode
    self:w("local CBIAS=" .. CONST_BIAS)
    self:w("local function rk(x)")
    self:push()
    self:w("if not x then return nil end")
    self:w("if x>=CBIAS then")
    self:push()
    self:w("local ci=x-CBIAS+1")
    self:w("if ci<1 or ci>#k then return nil end")
    self:w("return k[ci]")
    self:pop()
    self:w("end")
    self:w("if open_upvals[x] then return open_upvals[x].v end")
    self:w("return Stack[x]")
    self:pop()
    self:w("end")

    self:w("local _has_upv=false")

    self:w("local function setr(r,v)")
    self:push()
    self:w("if not r then return end")
    self:w("if _has_upv and open_upvals[r] then open_upvals[r].v=v else Stack[r]=v end")
    self:pop()
    self:w("end")

    self:w("local function getr(r)")
    self:push()
    self:w("if not r then return nil end")
    self:w("if _has_upv and open_upvals[r] then return open_upvals[r].v end")
    self:w("return Stack[r]")
    self:pop()
    self:w("end")

    -- _rg: normal indexing (fires __index for Roblox globals)
    self:w("local function _rg(t,k) if type(t)~='table' then return nil end return t[k] end")

    -- _safe_destroy: Runtime guard for obj:Destroy() to prevent crashes
    -- Handles: nil values, functions, and invalid objects
    self:w("local function _safe_destroy(obj)")
    self:push()
    self:w("if obj==nil then return end")
    self:w("local t=type(obj)")
    self:w("if t=='function' then return end")
    self:w("if type(obj.Destroy)=='function' then pcall(function() obj:Destroy() end) end")
    self:pop()
    self:w("end")

    -- _isbvm: no longer needed since closures are real functions
    -- All function calls go through the same native path

    -- Register opcode handlers
    local entries = {}
    local function opCase(name, body)
        local aliases = O_aliases[name]
        if not aliases or #aliases == 0 then return end
        for _, aid in ipairs(aliases) do
            table.insert(entries, {aid = aid, body = body})
        end
    end

    -- Data movement
    opCase("OP_MOVE",      {"setr(A,getr(B))"})
    opCase("OP_LOADK",     {"setr(A,k[B])"})
    opCase("OP_LOADNIL",   {"for _i=A,A+B do setr(_i,nil) end"})
    opCase("OP_LOADBOOL",  {"setr(A,B~=0)";"if C~=0 then pc=pc+4 end"})

    -- Upvalue / global
    opCase("OP_GETUPVAL",  {"local _uv=upvals[B]";"if _uv then setr(A,_uv.v) else setr(A,nil) end"})
    opCase("OP_SETUPVAL",  {"local _uv=upvals[B]";"if _uv then _uv.v=getr(A) end"})
    -- OP_GETGLOBAL: Robust global variable resolution for ALL Roblox executors
    -- Chain: _ENV_ref → getgenv() → getfenv(0) → _G → raw environment (for builtins like task)
    opCase("OP_GETGLOBAL", {
        "local _gv",
        "if _ENV_ref~=nil then _gv=_ENV_ref[k[B]] end",
        "if _gv==nil and type(getgenv)=='function' then _gv=getgenv()[k[B]] end",
        "if _gv==nil and type(getfenv)=='function' then",
        "  local _fe=getfenv(0)",
        "  if _fe then _gv=_fe[k[B]] end",
        "end",
        "if _gv==nil and type(_G)=='table' then _gv=_G[k[B]] end",
        "if _gv==nil and type(_ENV)=='table' then _gv=_ENV[k[B]] end",
        "setr(A,_gv)",
    })
    opCase("OP_SETGLOBAL", {
        "if _ENV_ref~=nil then _ENV_ref[k[B]]=getr(A)",
        "elseif type(getgenv)=='function' then getgenv()[k[B]]=getr(A) end",
    })

    -- Table ops (smart guards: pcall ONLY for functions, direct access for userdata/tables)
    opCase("OP_GETTABLE",  {
        "local _t=getr(B)",
        "if _t~=nil then",
        "  local _ty=type(_t)",
        "  if _ty=='function' then",
        "    local _ok,_v=pcall(function() return _t[rk(C)] end)",
        "    if _ok then setr(A,_v) else setr(A,nil) end",
        "  elseif _ty=='userdata' then",
        "    setr(A,_t[rk(C)])",
        "  else",
        "    setr(A,_t[rk(C)])",
        "  end",
        "else",
        "  setr(A,nil)",
        "end"
    })
    opCase("OP_SETTABLE",  {
        "local _t=getr(A)",
        "if _t~=nil then",
        "  local _ty=type(_t)",
        "  if _ty=='function' then",
        "    pcall(function() _t[rk(B)]=rk(C) end)",
        "  else",
        "    _t[rk(B)]=rk(C)",
        "  end",
        "end"
    })
    opCase("OP_NEWTABLE",  {"setr(A,{})"})
    opCase("OP_SELF",      {
        "local _t=getr(B)",
        "if _t~=nil then",
        "  local _ty=type(_t)",
        "  if _ty=='function' then",
        "    local _ok,_v=pcall(function() return _t[rk(C)] end)",
        "    if _ok then setr(A,_v) else setr(A,nil) end",
        "  elseif _ty=='userdata' then",
        "    setr(A,_t[rk(C)])",
        "  else",
        "    setr(A,_t[rk(C)])",
        "  end",
        "else",
        "  setr(A,nil)",
        "end",
        "setr(A+1,_t)"
    })
    opCase("OP_SETLIST",   {
        "local _tbl=getr(A)",
        "if _tbl~=nil then",
        "  local _base=((C-1))*50",
        "  local _cnt=B",
        "  if _cnt==0 then _cnt=top-A end",
        "  for _i=1,_cnt do if _tbl then _tbl[_base+_i]=getr(A+_i) end end",
        "end",
    })

    -- Arithmetic
    opCase("OP_ADD",  {"local _b=rk(B) local _c=rk(C) if _b==nil or _c==nil then setr(A,nil) else setr(A,_b+_c) end"})
    opCase("OP_SUB",  {"local _b=rk(B) local _c=rk(C) if _b==nil or _c==nil then setr(A,nil) else setr(A,_b-_c) end"})
    opCase("OP_MUL",  {"local _b=rk(B) local _c=rk(C) if _b==nil or _c==nil then setr(A,nil) else setr(A,_b*_c) end"})
    opCase("OP_DIV",  {"local _b=rk(B) local _c=rk(C) if _b==nil or _c==nil then setr(A,nil) else setr(A,_b/_c) end"})
    opCase("OP_MOD",  {"local _b=rk(B) local _c=rk(C) if _b==nil or _c==nil then setr(A,nil) else setr(A,_b%_c) end"})
    opCase("OP_POW",  {"local _b=rk(B) local _c=rk(C) if _b==nil or _c==nil then setr(A,nil) else setr(A,_b^_c) end"})
    opCase("OP_UNM",  {"local _b=getr(B) if _b==nil then setr(A,nil) else setr(A,-_b) end"})
    opCase("OP_NOT",  {"setr(A,not getr(B))"})
    opCase("OP_LEN",  {"local _b=getr(B) if _b==nil then setr(A,nil) else setr(A,#_b) end"})
    opCase("OP_CONCAT", {
        "local _parts={}",
        "for _i=B,C do local _v=getr(_i) _parts[#_parts+1]=tostring(_v~=nil and _v or '') end",
        "setr(A,table.concat(_parts))",
    })

    -- Control flow
    opCase("OP_JMP",   {"pc=pc+B"})
    opCase("OP_EQ",    {"if (rk(B)==rk(C))~=(A~=0) then pc=pc+4 end"})
    opCase("OP_LT",    {"if (rk(B)<rk(C))~=(A~=0) then pc=pc+4 end"})
    opCase("OP_LE",    {"if (rk(B)<=rk(C))~=(A~=0) then pc=pc+4 end"})
    opCase("OP_TEST",  {"if (not not getr(A))~=(C~=0) then pc=pc+4 end"})
    opCase("OP_TESTSET", {"if (not not getr(B))~=(C~=0) then pc=pc+4";"else setr(A,getr(B)) end"})

    -- ═══════════════════════════════════════════════════════════════════════
    --  OP_CALL: Unified handler for BVM closure tables and native functions
    -- ═══════════════════════════════════════════════════════════════════════
    --  BVM closures are TABLES with _bvmc + __call.
    --  Native Lua functions are type 'function'.
    --  Native functions get called directly; BVM tables go through _exec.
    -- ═══════════════════════════════════════════════════════════════════════
    opCase("OP_CALL", {
        "local _fn=getr(A)",
        "if _fn==nil then",
        "  local _nret=C-1",
        "  if _nret<=0 then top=A-1 end",
        "elseif _type(_fn)=='function' then",
        "  local _nargs=B-1",
        "  if _nargs<0 then _nargs=top-A end",
        "  local _nret=C-1",
        "  if _nret==0 then",
        "    if _nargs==0 then _fn()",
        "    elseif _nargs==1 then _fn(getr(A+1))",
        "    elseif _nargs==2 then _fn(getr(A+1),getr(A+2))",
        "    elseif _nargs==3 then _fn(getr(A+1),getr(A+2),getr(A+3))",
        "    elseif _nargs==4 then _fn(getr(A+1),getr(A+2),getr(A+3),getr(A+4))",
        "    else local _da={} for _ci=1,_nargs do _da[_ci]=getr(A+_ci) end;_fn(_unpack(_da,1,_nargs)) end",
        "    top=A-1",
        "  elseif _nret==1 then",
        "    if _nargs==0 then setr(A,_fn())",
        "    elseif _nargs==1 then setr(A,_fn(getr(A+1)))",
        "    elseif _nargs==2 then setr(A,_fn(getr(A+1),getr(A+2)))",
        "    elseif _nargs==3 then setr(A,_fn(getr(A+1),getr(A+2),getr(A+3)))",
        "    elseif _nargs==4 then setr(A,_fn(getr(A+1),getr(A+2),getr(A+3),getr(A+4)))",
        "    else local _da={} for _ci=1,_nargs do _da[_ci]=getr(A+_ci) end;setr(A,_fn(_unpack(_da,1,_nargs))) end",
        "    top=A",
        "  else",
        "    local _r",
        "    if _nargs==0 then _r={_fn()}",
        "    elseif _nargs==1 then _r={_fn(getr(A+1))}",
        "    elseif _nargs==2 then _r={_fn(getr(A+1),getr(A+2))}",
        "    elseif _nargs==3 then _r={_fn(getr(A+1),getr(A+2),getr(A+3))}",
        "    elseif _nargs==4 then _r={_fn(getr(A+1),getr(A+2),getr(A+3),getr(A+4))}",
        "    else local _da={} for _ci=1,_nargs do _da[_ci]=getr(A+_ci) end;_r={_fn(_unpack(_da,1,_nargs))} end",
        "    if _nret<0 then for _ci=1,#_r do setr(A+_ci-1,_r[_ci]) end;top=A+#_r-1",
        "    else for _ci=0,_nret-1 do setr(A+_ci,_r[_ci+1]) end;top=A+_nret-1 end",
        "  end",
        "end",
    })

    -- OP_TAILCALL
    opCase("OP_TAILCALL", {
        "local _fn=getr(A)",
        "if _fn==nil then return end",
        "local _nargs=B-1",
        "if _nargs<0 then _nargs=top-A end",
        "if _nargs==0 then return _fn()",
        "elseif _nargs==1 then return _fn(getr(A+1))",
        "elseif _nargs==2 then return _fn(getr(A+1),getr(A+2))",
        "elseif _nargs==3 then return _fn(getr(A+1),getr(A+2),getr(A+3))",
        "elseif _nargs==4 then return _fn(getr(A+1),getr(A+2),getr(A+3),getr(A+4))",
        "else local _da={} for _ci=1,_nargs do _da[_ci]=getr(A+_ci) end;return _fn(_unpack(_da,1,_nargs)) end",
    })

    -- OP_RETURN
    opCase("OP_RETURN", {
        "local _nret=B-1",
        "if _nret==0 then return end",
        "local _rvals={}",
        "if _nret<0 then",
        "  local _cnt=0",
        "  for _i=A,top do _cnt=_cnt+1;_rvals[_cnt]=getr(_i) end",
        "  return _unpack(_rvals,1,_cnt)",
        "else",
        "  for _i=0,_nret-1 do _rvals[_i+1]=getr(A+_i) end",
        "  return _unpack(_rvals,1,_nret)",
        "end",
    })

    -- Loops
    opCase("OP_FORPREP", {"setr(A,getr(A)-getr(A+2))";"pc=pc+B"})
    opCase("OP_FORLOOP", {
        "local _new_i=getr(A)+getr(A+2)",
        "setr(A,_new_i)",
        "local _step=getr(A+2)",
        "local _limit=getr(A+1)",
        "if (_step>0 and _new_i<=_limit) or (_step<=0 and _new_i>=_limit) then",
        "  setr(A+3,_new_i)",
        "  pc=pc+B",
        "end",
    })
    opCase("OP_TFORLOOP", {
        "local _iter_fn=getr(A)",
        "if _iter_fn==nil then break end",
        "local _it_res=_pack(_iter_fn(getr(A+1),getr(A+2)))",
        "if _it_res[1]~=nil then",
        "  setr(A+2,_it_res[1])",
        "  for _i=1,C do setr(A+2+_i,_it_res[_i]) end",
        "  pc=pc+4",
        "end",
    })

    -- OP_CLOSE
    opCase("OP_CLOSE", {
        "local _snap={}",
        "for _r=A,255 do if open_upvals[_r] then _snap[_r]=open_upvals[_r] end end",
        "for _r=A,255 do",
        "  local _box=_snap[_r]",
        "  if _box then _box.v=Stack[_r];open_upvals[_r]=nil end",
        "end",
    })

    -- ═══════════════════════════════════════════════════════════════════════
    --  OP_CLOSURE: Create a REAL Lua function with metadata via upvalues
    -- ═══════════════════════════════════════════════════════════════════════
    --  The function is a real Lua closure — works with ALL Roblox APIs:
    --  :Connect(), task.spawn(), pcall(), etc.
    --  We attach _bvmc/_bvmu/_bvmv as fields via rawset (works in Luau,
    --  silently ignored in Lua 5.1 where functions can't have fields).
    -- ═══════════════════════════════════════════════════════════════════════
    opCase("OP_CLOSURE", {
        "local _cpi=pm.cp[B]",
        "local _cpm=_PM[_cpi]",
        "if not _cpm then setr(A,nil) else",
        "local _new_upv={}",
        "for _ui=1,_cpm.nup do",
        "  local _pop=code[pc];local _pa=code[pc+1];local _pb=code[pc+2]",
        "  pc=pc+4",
        "  if _pa==1 then",
        "    if not open_upvals[_pb] then",
        "      open_upvals[_pb]={v=Stack[_pb]};_has_upv=true",
        "    end",
        "    _new_upv[_ui]=open_upvals[_pb]",
        "  else",
        "    _new_upv[_ui]=upvals[_pb]",
        "  end",
        "end",
        "local _fn=function(...)",
        "local _ok,_r1,_r2,_r3,_r4,_r5=pcall(_exec,_cpi,_new_upv,{_bvmc=_cpi,_bvmu=_new_upv,_bvmv={}},...)",
        "if not _ok then",
        "  warn('[BVM ERROR in proto #'.._cpi..'] pc='..tostring(pc)..': '..tostring(_r1))",
        "  if type(debug) == 'table' and debug.traceback then",
        "    warn(debug.traceback('', 2))",
        "  end",
        "end",
        "return _r1,_r2,_r3,_r4,_r5",
        "end",
        "setr(A,_fn)",
        "end",
    })

    -- OP_VARARG
    opCase("OP_VARARG", {
        "local _nva=B-1",
        "if _nva<0 then",
        "  local _cnt=_va.n or #_va",
        "  for _i=1,_cnt do setr(A+_i-1,_va[_i]) end",
        "  top=A+_cnt-1",
        "else",
        "  for _i=0,_nva-1 do setr(A+_i,_va[_i+1]) end",
        "  top=A+_nva-1",
        "end",
    })

    -- Shuffle for anti-pattern
    for i = #entries, 2, -1 do
        local j = math.random(i)
        entries[i], entries[j] = entries[j], entries[i]
    end

    -- Build dispatch loop
    self:w("-- [BVM] dispatch loop")
    self:w("while true do")
    self:push()
    self:w("if pc+3>#code then break end")
    self:w("local op=code[pc]")
    self:w("local A=code[pc+1]")
    self:w("local B=code[pc+2]")
    self:w("local C=code[pc+3]")
    self:w("pc=pc+4")

    local first = true
    for _, entry in ipairs(entries) do
        if first then
            self:w("if op=="..entry.aid.." then")
            first = false
        else
            self:w("elseif op=="..entry.aid.." then")
        end
        self:push()
        for _, line in ipairs(entry.body) do
            self:w(line)
        end
        self:pop()
    end
    self:w("end")

    self:pop()  -- end while
    self:w("end")  -- end while

    self:pop()  -- end _exec
    self:w("end")

    -- Bootstrap with error handling and state logging
    self:w("local _root_upv={{v=_ENV_ref}}")
    self:w("if _root_upv and _root_upv[1] then")
    self:push()
    self:w("local _ok, _err = pcall(_exec, "..root_proto_idx..", _root_upv, {})")
    self:w("if not _ok then")
    self:w("  warn('[BVM BOOT ERROR] '..tostring(_err))")
    self:w("  if type(debug) == 'table' and debug.traceback then")
    self:w("    warn(debug.traceback('', 1))")
    self:w("  end")
    self:w("else")
    self:w("  warn('[BVM] Execution completed successfully, result:', tostring(_err))")
    self:w("end")
    self:w("return _err")
    self:pop()
    self:w("end")
end

-- Top-level emit
function Emitter:emit(all_protos, root_proto_idx)
    self:w("-- Generated by Prometheus BVM Step")
    self:w("-- Polymorphic Bytecode Virtual Machine")
    self:w("return (function(...)")
    self:push()

    local n = #all_protos
    local str_keys = {}
    for i = 1, n do
        str_keys[i] = {math.random(1, 254), math.random(1, 254)}
    end

    self:emitProtos(all_protos, str_keys)
    self:emitVM(root_proto_idx, str_keys)

    self:pop()
    self:w("end)(...)")

    return self:flush()
end

return function(op_map, opname_map, op_aliases_map, chunk_size)
    return Emitter.new(op_map, opname_map, op_aliases_map, chunk_size)
end
