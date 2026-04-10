-- ============================================================
--  LuauSanitizer.lua  —  Prometheus Pipeline Step
--  Runs BEFORE BvmStep.  ONLY wraps obj:Destroy() calls in a
--  pcall guard.  Leaves all other method calls untouched.
--
--  Transform:  obj:Destroy()  →  pcall(function() obj:Destroy() end)
--
--  This is simpler and more reliable than AND guards, which
--  the BVM compiler can corrupt during AST→bytecode conversion.
-- ============================================================

local Step       = require("prometheus.step")
local Ast        = require("prometheus.ast")
local visitast   = require("prometheus.visitast")
local AstKind    = Ast.AstKind

local M = Step:extend()
M.Name        = "LuauSanitizer"
M.Description = "Guards obj:Destroy() with pcall before BVM compilation."

M.SettingsDescriptor = {
    GuardDestroy = { type = "boolean", default = true },
}

function M:init(_) end

-- ── previsit: Wrap Destroy() in pcall ─────────────────────────────────────
local function pre(node, data)
    if not data._san.GuardDestroy then return node end
    if node.kind ~= AstKind.PassSelfFunctionCallExpression then return node end

    -- ONLY guard Destroy() calls
    if node.passSelfFunctionName ~= "Destroy" then return node end

    local obj    = node.base
    local method = node.passSelfFunctionName
    local args   = node.args or {}

    -- Create: pcall(function() obj:Destroy() end)
    local call = Ast.PassSelfFunctionCallExpression(obj, method, args)
    local wrapper = Ast.FunctionExpression({}, Ast.CompoundStatement({call}))
    local pcallCall = Ast.FunctionCallExpression(
        Ast.VariableExpression(data.globalScope, "pcall"),
        { wrapper }
    )
    
    return pcallCall, true
end

-- ── apply ──────────────────────────────────────────────────────────────────
function M:apply(ast)
    visitast(ast, pre, nil, { _san = self })
    return ast
end

return M
