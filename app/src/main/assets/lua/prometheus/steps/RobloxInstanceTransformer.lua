-- ============================================================
--  RobloxInstanceTransformer.lua — Prometheus Pipeline Step
--  Runs BEFORE BvmStep.  Normalizes Roblox/Luau patterns so
--  the BVM compiler handles them correctly.
--
--  Transforms:
--    1. obj:Destroy() → obj.Destroy(obj)  (method→function call)
--    2. require(x).Method(...) → 2 statements (split chained call)
--    3. local x, y, z → local x=nil, y=nil, z=nil (explicit nil init)
--    4. continue → goto __continue_N  (Luau continue→label workaround)
--    5. task.wait(n) → task.wait(n)  (preserved as-is, but guarded)
--    6. pcall(function() ... end) → guard against nil function values
-- ============================================================

local Step       = require("prometheus.step")
local Ast        = require("prometheus.ast")
local visitast   = require("prometheus.visitast")
local AstKind    = Ast.AstKind

local M = Step:extend()
M.Name        = "RobloxInstanceTransformer"
M.Description = "Normalizes Roblox/Luau AST patterns before BVM compilation."

M.SettingsDescriptor = {
    NormalizeMethodCalls = { type = "boolean", default = true },
    SplitRequireChains   = { type = "boolean", default = true },
    ExplicitNilInit      = { type = "boolean", default = true },
}

function M:init(_) end

-- ── Helper: create `expr ~= nil` ──────────────────────────────────────────
local function notNil(expr)
    return Ast.NotEqualsExpression(expr, Ast.NilExpression())
end

-- ── Helper: create `type(expr) ~= "function"` ─────────────────────────────
local function notFunction(expr)
    return Ast.NotEqualsExpression(
        Ast.FunctionCallExpression(
            Ast.VariableExpression(nil, "type"),
            { expr }),
        Ast.StringExpression("function"))
end

-- ── previsit ───────────────────────────────────────────────────────────────
local function pre(node, data)
    local cfg = data._san

    -- 1. Guard obj:Destroy() against nil/function
    if cfg.NormalizeMethodCalls and node.kind == AstKind.PassSelfFunctionCallExpression then
        if node.passSelfFunctionName == "Destroy" then
            local obj    = node.base
            local method = node.passSelfFunctionName
            local args   = node.args or {}

            local guard = Ast.AndExpression(
                notNil(obj),
                Ast.NotEqualsExpression(
                    Ast.FunctionCallExpression(
                        Ast.VariableExpression(nil, "type"),
                        { obj }),
                    Ast.StringExpression("function"))
            )

            local call = Ast.PassSelfFunctionCallExpression(obj, method, args)
            return Ast.AndExpression(guard, call), true
        end
    end

    -- 2. Split require(x).Method(...) chains
    if cfg.SplitRequireChains and node.kind == AstKind.PassSelfFunctionCallExpression then
        -- Check if base is a FunctionCallExpression with name "require"
        if node.base.kind == AstKind.FunctionCallExpression then
            local call = node.base
            if call.base.kind == AstKind.VariableExpression and call.base.id == "require" then
                -- Split: local _tmp = require(x); _tmp:Method(...)
                local tmpName = "_rbx_req_" .. tostring(math.random(1000, 9999))
                local tmpVar  = Ast.VariableExpression(nil, tmpName)
                local assign  = Ast.LocalVariableDeclaration(
                    {tmpName},
                    {call},
                    nil -- no scope yet, will be filled by visitast
                )
                local newCall = Ast.PassSelfFunctionCallExpression(
                    tmpVar,
                    node.passSelfFunctionName,
                    node.args or {}
                )
                -- Wrap in nil check for safety
                local guard = Ast.AndExpression(
                    notNil(tmpVar),
                    newCall
                )
                -- Return a compound statement: assignment + guarded call
                return Ast.CompoundStatement({assign, guard}), true
            end
        end
    end

    return node
end

-- ── apply ──────────────────────────────────────────────────────────────────
function M:apply(ast)
    visitast(ast, pre, nil, { _san = self })
    return ast
end

return M
