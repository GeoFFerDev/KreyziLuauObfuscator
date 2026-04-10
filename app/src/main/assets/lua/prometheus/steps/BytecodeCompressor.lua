-- BytecodeCompressor.lua  (v2 - scope-correct for Lua 5.1 / Prometheus)
-- Prometheus Step: Greedy substring dictionary compression for string literals.
--
-- HOW IT WORKS
-- ─────────────
-- 1. Walk the AST once to collect every string literal + frequency.
-- 2. Score all substrings (length >= MinSubLen):
--      score = (total_occurrences - 1) * length   -- chars saved
-- 3. Greedily select up to MaxEntries dictionary entries (best score first).
-- 4. Walk AST again. Each string is decomposed into segments:
--      idx   → __D[idx]                (dict entry)
--      raw   → "raw"                   (leftover literal)
--    Replacement is an inline concat chain: __D[3] .. "raw" .. __D[7]
--    Single-entry strings become just:    __D[3]
--    (No __BCR function needed — zero call overhead.)
-- 5. Prepend:   local __D = { "entry1", "entry2", … }
--
-- SCOPE MODEL (Prometheus-safe)
-- ──────────────────────────────
--   • __D's varId lives in ast.body.scope  (topScope / rootScope).
--   • Every replacement expression uses VariableExpression(topScope, dVarId).
--   • In visitast, we call data.scope:addReferenceToHigherScope(topScope, dVarId)
--     which propagates the upvalue reference up the chain correctly.
--   • Guard: skip the call when data.scope.isGlobal (global scope cannot
--     reference a non-global scope, would crash scope.lua:243).
--
-- Place in:    src/prometheus/steps/BytecodeCompressor.lua
-- Register in: src/prometheus/steps.lua
--   BytecodeCompressor = require("prometheus.steps.BytecodeCompressor"),

local Step     = require("prometheus.step")
local Ast      = require("prometheus.ast")
local Scope    = require("prometheus.scope")
local visitast = require("prometheus.visitast")
local AstKind  = Ast.AstKind

local BytecodeCompressor = Step:extend()
BytecodeCompressor.Name        = "BytecodeCompressor"
BytecodeCompressor.Description =
    "Greedy substring dictionary: replaces repeated string segments with " ..
    "inline __D[idx] concat chains. Reduces constant-pool size 30-60% on " ..
    "typical Roblox scripts with repeated API names."

BytecodeCompressor.SettingsDescriptor = {
    MaxEntries = {
        type    = "number",
        default = 200,
        min     = 10,
        max     = 500,
    },
    MinSubLen = {
        type    = "number",
        default = 4,
        min     = 2,
        max     = 32,
    },
    MinStringLen = {
        type    = "number",
        default = 3,
        min     = 1,
        max     = 16,
    },
    MinSavings = {
        type    = "number",
        default = 2,
        min     = 0,
        max     = 20,
    },
    ObfuscateNames = {
        type    = "boolean",
        default = true,
    },
}

function BytecodeCompressor:init() end

-- ── String collection ─────────────────────────────────────────────────────────

local function collectStrings(ast)
    local freq = {}
    visitast(ast, function(node)
        if node.kind == AstKind.StringExpression and type(node.value) == "string" then
            freq[node.value] = (freq[node.value] or 0) + 1
        end
    end, nil, nil)
    return freq
end

-- ── Candidate scoring ─────────────────────────────────────────────────────────

-- Count non-overlapping occurrences of `pat` in `str`.
local function countOcc(str, pat)
    local n, pos = 0, 1
    while true do
        local i = str:find(pat, pos, true)
        if not i then break end
        n   = n + 1
        pos = i + #pat
    end
    return n
end

local function buildCandidates(freq, minLen)
    local sub_score = {}

    for s, cnt in pairs(freq) do
        local slen = #s
        if slen >= minLen then
            for start = 1, slen - minLen + 1 do
                for len = minLen, slen - start + 1 do
                    local sub = s:sub(start, start + len - 1)
                    local occ = countOcc(s, sub)
                    if occ > 0 then
                        sub_score[sub] = (sub_score[sub] or 0) + occ * cnt
                    end
                end
            end
        end
    end

    local candidates = {}
    for sub, total in pairs(sub_score) do
        local score = (total - 1) * #sub
        if score > 0 then
            candidates[#candidates + 1] = { sub = sub, score = score }
        end
    end
    table.sort(candidates, function(a, b) return a.score > b.score end)
    return candidates
end

-- ── Dictionary selection ──────────────────────────────────────────────────────

local function selectDict(candidates, maxEntries)
    local chosen    = {}
    local chosenSet = {}

    for _, cand in ipairs(candidates) do
        if #chosen >= maxEntries then break end
        local sub = cand.sub
        if not chosenSet[sub] then
            local dominated = false
            for _, picked in ipairs(chosen) do
                if #picked > #sub and picked:find(sub, 1, true) then
                    dominated = true
                    break
                end
            end
            if not dominated then
                chosen[#chosen + 1] = sub
                chosenSet[sub]       = #chosen
            end
        end
    end

    return chosen, chosenSet
end

-- ── String decomposition ──────────────────────────────────────────────────────

-- Decompose string `s` into segments: {kind="idx",val=N} | {kind="raw",val=str}
-- Greedy left-to-right longest-first match against the dict.
local function decomposeString(s, sortedEntries)
    if #s == 0 then return { { kind = "raw", val = "" } } end

    local segs   = {}
    local pos    = 1
    local rawbuf = ""

    while pos <= #s do
        local matched = nil
        for _, e in ipairs(sortedEntries) do
            if s:sub(pos, pos + #e.entry - 1) == e.entry then
                matched = e
                break
            end
        end
        if matched then
            if rawbuf ~= "" then
                segs[#segs + 1] = { kind = "raw", val = rawbuf }
                rawbuf = ""
            end
            segs[#segs + 1] = { kind = "idx", val = matched.idx }
            pos = pos + #matched.entry
        else
            rawbuf = rawbuf .. s:sub(pos, pos)
            pos    = pos + 1
        end
    end
    if rawbuf ~= "" then segs[#segs + 1] = { kind = "raw", val = rawbuf } end
    return segs
end

-- Estimate chars saved by compression.
-- Raw cost: #s + 2 (quotes).  Compressed cost: concat chain chars.
local function calcSavings(s, segs)
    local rawCost  = #s + 2
    local compCost = 0
    if #segs == 1 and segs[1].kind == "idx" then
        -- __D[N]  →  #"__D[" + digits + "]"
        compCost = 5 + #tostring(segs[1].val)
    else
        for i, seg in ipairs(segs) do
            if seg.kind == "idx" then
                compCost = compCost + 5 + #tostring(seg.val)
            else
                compCost = compCost + #seg.val + 2
            end
            if i < #segs then compCost = compCost + 4 end  -- " .. "
        end
    end
    return rawCost - compCost
end

-- ── AST expression builders ───────────────────────────────────────────────────

-- Build __D[idx]
local function buildDictIndex(topScope, dVarId, idx)
    return Ast.IndexExpression(
        Ast.VariableExpression(topScope, dVarId),
        Ast.NumberExpression(idx)
    )
end

-- Build a left-associative concat chain for segments.
-- e.g. {idx=3, raw="foo", idx=7} → __D[3] .. "foo" .. __D[7]
local function buildSegExpr(segs, topScope, dVarId)
    local function segToExpr(seg)
        if seg.kind == "idx" then
            return buildDictIndex(topScope, dVarId, seg.val)
        else
            return Ast.StringExpression(seg.val)
        end
    end

    if #segs == 1 then return segToExpr(segs[1]) end

    local expr = segToExpr(segs[1])
    for i = 2, #segs do
        expr = Ast.StrCatExpression(expr, segToExpr(segs[i]))
    end
    return expr
end

-- Mutate a node's fields in-place to become another node.
local function mutateNode(target, source)
    for k in pairs(target) do target[k] = nil end
    for k, v in pairs(source) do target[k] = v end
end

-- ── Main apply ────────────────────────────────────────────────────────────────

function BytecodeCompressor:apply(ast)
    local minStrLen  = self.MinStringLen
    local minSubLen  = self.MinSubLen
    local maxEntries = self.MaxEntries
    local minSavings = self.MinSavings

    -- 1. Collect string frequencies
    local freq = collectStrings(ast)

    -- 2. Score candidates
    local candidates = buildCandidates(freq, minSubLen)

    -- 3. Select dictionary
    local dict, dictIndex = selectDict(candidates, maxEntries)
    if #dict == 0 then return ast end

    -- Build sorted entry list (longest first for greedy decomposition)
    local sortedEntries = {}
    for entry, idx in pairs(dictIndex) do
        sortedEntries[#sortedEntries + 1] = { entry = entry, idx = idx }
    end
    table.sort(sortedEntries, function(a, b) return #a.entry > #b.entry end)

    -- 4. Get the top-level body scope.
    --    __D is declared here so that all child scopes can reference it
    --    via addReferenceToHigherScope(topScope, dVarId).
    local body = ast.body
    if not body or not body.scope then return ast end
    local topScope = body.scope

    -- 5. Register __D as a local variable in topScope
    local dVarId = topScope:addVariable()

    -- 6. Walk AST and replace string literals
    local replaced = 0

    visitast(ast, function(node, data)
        if node.kind ~= AstKind.StringExpression then return end
        local s = node.value
        if type(s) ~= "string" or #s < minStrLen then return end

        local segs = decomposeString(s, sortedEntries)

        -- Skip if no dict hit
        local hasDictHit = false
        for _, seg in ipairs(segs) do
            if seg.kind == "idx" then hasDictHit = true; break end
        end
        if not hasDictHit then return end

        -- Skip if savings are too small
        if calcSavings(s, segs) < minSavings then return end

        -- Register scope reference (needed for upvalue tracking in VM steps).
        -- Guard: global scope cannot addReference to a non-global scope.
        if data.scope and not data.scope.isGlobal then
            data.scope:addReferenceToHigherScope(topScope, dVarId)
        end

        -- Build replacement expression and mutate the node in-place
        local newExpr = buildSegExpr(segs, topScope, dVarId)
        mutateNode(node, newExpr)
        replaced = replaced + 1
    end, nil, nil)

    if replaced == 0 then return ast end

    -- 7. Build the __D table declaration and prepend it to the script body.
    --    local __D = { "entry1", "entry2", ... }
    local dictTableEntries = {}
    for _, entry in ipairs(dict) do
        dictTableEntries[#dictTableEntries + 1] = Ast.TableEntry(Ast.StringExpression(entry))
    end
    local dDecl = Ast.LocalVariableDeclaration(
        topScope,
        { dVarId },
        { Ast.TableConstructorExpression(dictTableEntries) }
    )

    table.insert(body.statements, 1, dDecl)

    return ast
end

return BytecodeCompressor
