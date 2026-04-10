-- StringVault.lua
-- Prometheus Step: XOR + rotating-key string encryption
-- Replaces every string literal with a runtime decryption call.
-- Key and rotation seed are random per build (Seed=0 in config).
--
-- Place in: src/prometheus/steps/StringVault.lua
-- Register in: src/prometheus/steps.lua  →  StringVault = require("prometheus.steps.StringVault")

local Step      = require("prometheus.step")
local Ast       = require("prometheus.ast")
local Scope     = require("prometheus.scope")
local visitast  = require("prometheus.visitast")
local AstKind   = Ast.AstKind

local StringVault = Step:extend()
StringVault.Name        = "StringVault"
StringVault.Description = "XOR + rotating-LFSR string encryption with per-build random keys."

StringVault.SettingsDescriptor = {
    KeySize = {
        type    = "number",
        default = 12,
        min     = 4,
        max     = 32,
    },
    -- Minimum string length to encrypt (short strings like "=" aren't worth it)
    MinLength = {
        type    = "number",
        default = 2,
        min     = 1,
        max     = 32,
    },
    -- Split long strings into 2-3 concatenated encrypted chunks
    SplitLong = {
        type    = "boolean",
        default = true,
    },
    SplitThreshold = {
        type    = "number",
        default = 40,
        min     = 10,
        max     = 200,
    },
}

function StringVault:init() end

-- ---- Key generation --------------------------------------------------------

local function randomKey(size)
    local k = {}
    for i = 1, size do
        k[i] = math.random(1, 255)  -- avoid 0 (null byte edge cases)
    end
    return k
end

-- ---- Encrypt a string with XOR + rotating LFSR ----------------------------
-- Returns: encrypted string (raw bytes as Lua escape sequence)
-- The LFSR: r_next = (r * A + B) % 256
-- A and B are also per-build random constants stored alongside the key.

local function encryptString(str, key, seedR, lfsrA, lfsrB)
    local out = {}
    local r   = seedR
    for i = 1, #str do
        local b = str:byte(i)
        -- Cross-version XOR: ~ is Lua 5.3+; use arithmetic fallback for 5.1/5.2.
        -- bit32.bxor is available on LuaJIT / Lua 5.2; arithmetic fallback works
        -- on all versions.
        local k = key[(i - 1) % #key + 1]
        if bit32 then
            b = bit32.bxor(b, k)
        else
            -- Arithmetic XOR byte (both values 0-255)
            local xv = 0
            for bit = 0, 7 do
                local bd = math.floor(b  / 2^bit) % 2
                local kd = math.floor(k  / 2^bit) % 2
                if bd ~= kd then xv = xv + 2^bit end
            end
            b = xv
        end
        b = (b + r) % 256                  -- add LFSR state
        r = (r * lfsrA + lfsrB) % 256      -- advance LFSR
        out[i] = b
    end
    return out
end

-- Convert byte array to Lua escaped string literal body (e.g. \xAB\x1F...)
local function bytesToEscaped(bytes)
    local parts = {}
    for i, b in ipairs(bytes) do
        parts[i] = string.format("\\%d", b)
    end
    return table.concat(parts)
end

-- ---- Build the decoder function AST ----------------------------------------
-- Emits (in Lua pseudocode):
--   local function __SV(e)
--       local _k = {k1,k2,...}
--       local _r = seedR
--       local _o = {}
--       for _i = 1, #e do
--           local _b = e:byte(_i)
--           _b = bit32.bxor(_b, _k[((_i-1) % #_k) + 1])
--           _b = (_b + _r) % 256
--           _r = (_r * LFSR_A + LFSR_B) % 256
--           _o[_i] = string.char(_b)
--       end
--       return table.concat(_o)
--   end

local function buildDecoderAST(bodyScope, globalScope, key, seedR, lfsrA, lfsrB, decoderVarId)
    -- FIX: use bodyScope (ast.body.scope) directly as outerScope so the decoder
    -- function's scope chain is: loopScope->argScope->bodyScope->globalScope.
    -- Previously Scope:new(globalScope) created a detached chain that skipped
    -- ast.body.scope entirely, causing ConstantArray to crash when it called
    -- data.scope:addReferenceToHigherScope(self.rootScope=ast.body.scope, ...).
    local outerScope  = bodyScope
    local argScope    = Scope:new(outerScope)

    -- Parameters
    local eVar   = argScope:addVariable()   -- encrypted string arg
    -- Locals
    local kVar   = argScope:addVariable()   -- key table
    local rVar   = argScope:addVariable()   -- LFSR state
    local oVar   = argScope:addVariable()   -- output table
    local loopScope = Scope:new(argScope)
    local iVar   = loopScope:addVariable()  -- loop counter
    local bVar   = loopScope:addVariable()  -- current byte

    -- Add references so unparser doesn't choke
    loopScope:addReferenceToHigherScope(argScope, eVar)
    loopScope:addReferenceToHigherScope(argScope, kVar)
    loopScope:addReferenceToHigherScope(argScope, rVar)
    loopScope:addReferenceToHigherScope(argScope, oVar)

    -- Build key table entries
    local keyEntries = {}
    for _, v in ipairs(key) do
        table.insert(keyEntries, Ast.TableEntry(Ast.NumberExpression(v)))
    end

    local function V(scope, id)  return Ast.VariableExpression(scope, id) end
    local function N(n)          return Ast.NumberExpression(n) end

    -- string.char, table.concat, bit32.bxor references via global scope
    local _, stringVar = globalScope:resolve("string")
    local _, tableVar  = globalScope:resolve("table")
    local _, bit32Var  = globalScope:resolve("bit32")

    local function globalRef(scope, varId)
        scope:addReferenceToHigherScope(globalScope, varId)
        return Ast.VariableExpression(globalScope, varId)
    end

    -- e:byte(_i)  →  string.byte(e, _i)
    local function byteCall(scope)
        local _, strByteId = globalScope:resolve("string")
        scope:addReferenceToHigherScope(globalScope, strByteId)
        local strTbl = Ast.VariableExpression(globalScope, strByteId)
        return Ast.FunctionCallExpression(
            Ast.IndexExpression(strTbl, Ast.StringExpression("byte")),
            { V(argScope, eVar), V(loopScope, iVar) })
    end

    -- (_i - 1) % #_k + 1
    local function keyIndex(scope)
        return Ast.AddExpression(
            Ast.ModExpression(
                Ast.SubExpression(V(loopScope, iVar), N(1)),
                Ast.LenExpression(V(argScope, kVar))),
            N(1))
    end

    -- bit32.bxor(_b, _k[...])
    local function xorExpr(scope)
        local _, b32Id = globalScope:resolve("bit32")
        scope:addReferenceToHigherScope(globalScope, b32Id)
        local b32 = Ast.VariableExpression(globalScope, b32Id)
        return Ast.FunctionCallExpression(
            Ast.IndexExpression(b32, Ast.StringExpression("bxor")),
            { V(loopScope, bVar),
              Ast.IndexExpression(V(argScope, kVar), keyIndex(scope)) })
    end

    -- (_b + _r) % 256
    local function addRExpr()
        return Ast.ModExpression(
            Ast.AddExpression(V(loopScope, bVar), V(argScope, rVar)),
            N(256))
    end

    -- (_r * lfsrA + lfsrB) % 256
    local function lfsrAdvance()
        return Ast.ModExpression(
            Ast.AddExpression(
                Ast.MulExpression(V(argScope, rVar), N(lfsrA)),
                N(lfsrB)),
            N(256))
    end

    -- string.char(_b)
    local function strCharCall(scope)
        local _, strId = globalScope:resolve("string")
        scope:addReferenceToHigherScope(globalScope, strId)
        local strTbl = Ast.VariableExpression(globalScope, strId)
        return Ast.FunctionCallExpression(
            Ast.IndexExpression(strTbl, Ast.StringExpression("char")),
            { V(loopScope, bVar) })
    end

    -- table.concat(_o)
    local function concatCall(scope)
        local _, tblId = globalScope:resolve("table")
        scope:addReferenceToHigherScope(globalScope, tblId)
        local tblTbl = Ast.VariableExpression(globalScope, tblId)
        return Ast.FunctionCallExpression(
            Ast.IndexExpression(tblTbl, Ast.StringExpression("concat")),
            { V(argScope, oVar) })
    end

    local loopBody = Ast.Block({
        -- local _b = string.byte(e, _i)
        Ast.LocalVariableDeclaration(loopScope, {bVar}, {byteCall(loopScope)}),
        -- _b = bit32.bxor(_b, _k[...])
        Ast.AssignmentStatement(
            {Ast.AssignmentVariable(loopScope, bVar)}, {xorExpr(loopScope)}),
        -- _b = (_b + _r) % 256
        Ast.AssignmentStatement(
            {Ast.AssignmentVariable(loopScope, bVar)}, {addRExpr()}),
        -- _r = (_r * A + B) % 256
        Ast.AssignmentStatement(
            {Ast.AssignmentVariable(argScope, rVar)}, {lfsrAdvance()}),
        -- _o[_i] = string.char(_b)
        Ast.AssignmentStatement(
            {Ast.AssignmentIndexing(V(argScope, oVar), V(loopScope, iVar))},
            {strCharCall(loopScope)}),
    }, loopScope)

    local funcBody = Ast.Block({
        -- local _k = {k1, k2, ...}
        Ast.LocalVariableDeclaration(argScope, {kVar},
            {Ast.TableConstructorExpression(keyEntries)}),
        -- local _r = seedR
        Ast.LocalVariableDeclaration(argScope, {rVar}, {N(seedR)}),
        -- local _o = {}
        Ast.LocalVariableDeclaration(argScope, {oVar},
            {Ast.TableConstructorExpression({})}),
        -- for _i = 1, #e do ... end
        Ast.ForStatement(loopScope, iVar,
            N(1), Ast.LenExpression(V(argScope, eVar)), N(1),
            loopBody, argScope),
        -- return table.concat(_o)
        Ast.ReturnStatement({concatCall(argScope)}),
    }, argScope)

    return Ast.LocalFunctionDeclaration(outerScope, decoderVarId,
        {Ast.VariableExpression(argScope, eVar)}, funcBody)
end

-- ---- Apply step ------------------------------------------------------------

function StringVault:apply(ast)
    local globalScope = ast.globalScope

    -- Generate per-build random parameters
    local key    = randomKey(self.KeySize)
    local seedR  = math.random(1,  254)
    local lfsrA  = math.random(3,  31) * 2 + 1   -- odd multiplier
    local lfsrB  = math.random(1,  127)

    -- The decoder variable lives in bodyScope (ast.body.scope).
    -- makeCall guards addReferenceToHigherScope so it is never called from
    -- globalScope (top-level strings), which would crash scope.lua:243.
    local bodyScope    = ast.body.scope or globalScope
    local decoderVarId = bodyScope:addVariable()

    -- Collect all string nodes and their parent scopes
    local replacements = {}  -- { node_ref, encryptedCall }

    visitast(ast, function(node, data)
        if node.kind ~= AstKind.StringExpression then return end
        local s = node.value
        -- Skip very short or already-internal strings
        if #s < self.MinLength then return end
        -- Skip Roblox service/method name strings (heuristic: no spaces, short)
        if #s <= 8 and not s:find(" ") then return end

        local function makeCall(str)
            local enc = encryptString(str, key, seedR, lfsrA, lfsrB)
            -- Reset LFSR for each string (state is re-seeded per call from seedR)
            local escaped = bytesToEscaped(enc)
            local scope = data.scope or globalScope
            -- Guard: never call addReferenceToHigherScope FROM globalScope.
            -- Top-level strings have data.scope == globalScope; calling
            -- globalScope:addReferenceToHigherScope(bodyScope, id) crashes
            -- scope.lua:243 because self.isGlobal and not scope.isGlobal.
            if not scope.isGlobal then
                scope:addReferenceToHigherScope(bodyScope, decoderVarId)
            end
            return Ast.FunctionCallExpression(
                Ast.VariableExpression(bodyScope, decoderVarId),
                {Ast.StringExpression(escaped)})
        end

        if self.SplitLong and #s >= self.SplitThreshold then
            -- Split into two halves and concatenate encrypted calls
            local mid = math.floor(#s / 2)
            local a, b = s:sub(1, mid), s:sub(mid + 1)
            replacements[node] = Ast.StrCatExpression(makeCall(a), makeCall(b))
        else
            replacements[node] = makeCall(s)
        end
    end, nil, nil)

    -- Inject decoder function at the top of the script body
    local decoderFunc = buildDecoderAST(
        bodyScope, globalScope, key, seedR, lfsrA, lfsrB, decoderVarId)
    table.insert(ast.body.statements, 1, decoderFunc)

    -- FIX Bug #12: Perform replacements (post-walk, mutate nodes in-place)
    -- The visitast callback stored replacements[node], but visitast does not
    -- automatically replace nodes. We need to mutate the original nodes in-place.
    for node, replacement in pairs(replacements) do
        -- Copy all keys from the replacement node onto the original node.
        -- This effectively transforms the original StringExpression into the
        -- encrypted call expression without breaking the parent's references.
        for k, v in pairs(replacement) do
            node[k] = v
        end
    end

    return ast
end

return StringVault
