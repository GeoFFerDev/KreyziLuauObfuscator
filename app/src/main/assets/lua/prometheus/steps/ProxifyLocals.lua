-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- ProxifyLocals.lua
--
-- This Script provides an Obfuscation Step for putting all Locals into Proxy Objects
-- (Patched to fully support Roblox C++ Userdata Instances)

local Step = require("prometheus.step");
local Ast = require("prometheus.ast");
local Scope = require("prometheus.scope");
local visitast = require("prometheus.visitast");
local RandomLiterals = require("prometheus.randomLiterals")

local AstKind = Ast.AstKind;

local ProxifyLocals = Step:extend();
ProxifyLocals.Description = "This Step wraps all locals into Proxy Objects";
ProxifyLocals.Name = "Proxify Locals";

ProxifyLocals.SettingsDescriptor = {
	LiteralType = {
		name = "LiteralType",
		description = "The type of the randomly generated literals",
		type = "enum",
		values = {
			"dictionary",
			"number",
			"string",
            "any",
		},
		default = "string",
	},
}

local function shallowcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in pairs(orig) do
            copy[orig_key] = orig_value
        end
    else
        copy = orig
    end
    return copy
end

local function callNameGenerator(generatorFunction, ...)
	if(type(generatorFunction) == "table") then
		generatorFunction = generatorFunction.generateName;
	end
	return generatorFunction(...);
end

local MetatableExpressions = {
    {
        constructor = Ast.AddExpression,
        key = "__add";
    },
    {
        constructor = Ast.SubExpression,
        key = "__sub";
    },
    {
        constructor = Ast.MulExpression,
        key = "__mul";
    },
    {
        constructor = Ast.DivExpression,
        key = "__div";
    },
    {
        constructor = Ast.PowExpression,
        key = "__pow";
    },
    {
        constructor = Ast.StrCatExpression,
        key = "__concat";
    }
}

function ProxifyLocals:init(_) end

local function generateLocalMetatableInfo(pipeline)
    local usedOps = {};
    local info = {};
    for i, v in ipairs({"setValue", "getValue", "index"}) do
        local rop;
        repeat
            rop = MetatableExpressions[math.random(#MetatableExpressions)];
        until not usedOps[rop];
        usedOps[rop] = true;
        info[v] = rop;
    end

    info.valueName = callNameGenerator(pipeline.namegenerator, math.random(1, 4096));

    return info;
end

function ProxifyLocals:CreateAssignmentExpression(info, expr, parentScope)
    local metatableVals = {};

    -- Setvalue Entry (Patched to use rawset)
    local setValueFunctionScope = Scope:new(parentScope);
    local setValueSelf = setValueFunctionScope:addVariable();
    local setValueArg = setValueFunctionScope:addVariable();
    local setvalueFunctionLiteral = Ast.FunctionLiteralExpression(
        {
            Ast.VariableExpression(setValueFunctionScope, setValueSelf),
            Ast.VariableExpression(setValueFunctionScope, setValueArg),
        },
        Ast.Block({
            Ast.FunctionCallStatement(
                Ast.VariableExpression(setValueFunctionScope:resolveGlobal("rawset")),
                {
                    Ast.VariableExpression(setValueFunctionScope, setValueSelf),
                    Ast.StringExpression(info.valueName),
                    Ast.VariableExpression(setValueFunctionScope, setValueArg)
                }
            )
        }, setValueFunctionScope)
    );
    table.insert(metatableVals, Ast.KeyedTableEntry(Ast.StringExpression(info.setValue.key), setvalueFunctionLiteral));

    -- Getvalue Entry (Patched to use rawget)
    local getValueFunctionScope = Scope:new(parentScope);
    local getValueSelf = getValueFunctionScope:addVariable();
    local getValueArg = getValueFunctionScope:addVariable();
    
    local getValueIdxExpr = Ast.FunctionCallExpression(Ast.VariableExpression(getValueFunctionScope:resolveGlobal("rawget")), {
        Ast.VariableExpression(getValueFunctionScope, getValueSelf),
        Ast.StringExpression(info.valueName),
    });

    local getvalueFunctionLiteral = Ast.FunctionLiteralExpression(
        {
            Ast.VariableExpression(getValueFunctionScope, getValueSelf),
            Ast.VariableExpression(getValueFunctionScope, getValueArg),
        },
        Ast.Block({
            Ast.ReturnStatement({
                getValueIdxExpr;
            });
        }, getValueFunctionScope)
    );
    table.insert(metatableVals, Ast.KeyedTableEntry(Ast.StringExpression(info.getValue.key), getvalueFunctionLiteral));

    -- =========================================================================
    -- SMART __index METAMETHOD FOR ROBLOX INSTANCES
    -- Bypasses Ast.BinaryExpression entirely using string.find()
    -- =========================================================================
    local indexScope = Scope:new(parentScope)
    local idxSelf = indexScope:addVariable()
    local idxKey = indexScope:addVariable()
    local realVar = indexScope:addVariable()
    local valVar = indexScope:addVariable()

    local stat1 = Ast.LocalVariableDeclaration(indexScope, {realVar}, {
        Ast.FunctionCallExpression(Ast.VariableExpression(indexScope:resolveGlobal("rawget")), {
            Ast.VariableExpression(indexScope, idxSelf),
            Ast.StringExpression(info.valueName)
        })
    })

    local stat2 = Ast.LocalVariableDeclaration(indexScope, {valVar}, {
        Ast.IndexExpression(
            Ast.VariableExpression(indexScope, realVar),
            Ast.VariableExpression(indexScope, idxKey)
        )
    })

    -- cond1: string.find(type(realVar), "user")
    local cond1 = Ast.FunctionCallExpression(
        Ast.IndexExpression(
            Ast.VariableExpression(indexScope:resolveGlobal("string")),
            Ast.StringExpression("find")
        ),
        {
            Ast.FunctionCallExpression(Ast.VariableExpression(indexScope:resolveGlobal("type")), {
                Ast.VariableExpression(indexScope, realVar)
            }),
            Ast.StringExpression("user")
        }
    )

    -- cond2: string.find(type(valVar), "func")
    local cond2 = Ast.FunctionCallExpression(
        Ast.IndexExpression(
            Ast.VariableExpression(indexScope:resolveGlobal("string")),
            Ast.StringExpression("find")
        ),
        {
            Ast.FunctionCallExpression(Ast.VariableExpression(indexScope:resolveGlobal("type")), {
                Ast.VariableExpression(indexScope, valVar)
            }),
            Ast.StringExpression("func")
        }
    )

    local wrapperScope = Scope:new(indexScope)
    local wParams = { Ast.VariableExpression(wrapperScope, wrapperScope:addVariable()) }
    local wArgs = { Ast.VariableExpression(wrapperScope, realVar) }
    
    for i=1, 8 do
        local pVar = wrapperScope:addVariable()
        table.insert(wParams, Ast.VariableExpression(wrapperScope, pVar))
        table.insert(wArgs, Ast.VariableExpression(wrapperScope, pVar))
    end

    local wrapperFunc = Ast.FunctionLiteralExpression(
        wParams,
        Ast.Block({
            Ast.ReturnStatement({
                Ast.FunctionCallExpression(Ast.VariableExpression(wrapperScope, valVar), wArgs)
            })
        }, wrapperScope)
    )

    local ifInner = Ast.IfStatement(cond2, Ast.Block({
        Ast.ReturnStatement({ wrapperFunc })
    }, Scope:new(indexScope)))

    local ifOuter = Ast.IfStatement(cond1, Ast.Block({
        ifInner
    }, Scope:new(indexScope)))

    local retStat = Ast.ReturnStatement({ Ast.VariableExpression(indexScope, valVar) })

    local indexFunc = Ast.FunctionLiteralExpression(
        { Ast.VariableExpression(indexScope, idxSelf), Ast.VariableExpression(indexScope, idxKey) },
        Ast.Block({ stat1, stat2, ifOuter, retStat }, indexScope)
    )

    table.insert(metatableVals, Ast.KeyedTableEntry(Ast.StringExpression("__index"), indexFunc))

    -- =========================================================================
    -- SMART __newindex METAMETHOD FOR ROBLOX INSTANCES
    -- =========================================================================
    local niScope = Scope:new(parentScope)
    local niSelf = niScope:addVariable()
    local niKey = niScope:addVariable()
    local niVal = niScope:addVariable()
    local niRealVar = niScope:addVariable()

    local niStat1 = Ast.LocalVariableDeclaration(niScope, {niRealVar}, {
        Ast.FunctionCallExpression(Ast.VariableExpression(niScope:resolveGlobal("rawget")), {
            Ast.VariableExpression(niScope, niSelf),
            Ast.StringExpression(info.valueName)
        })
    })

    local niStat2 = Ast.AssignmentStatement({
        Ast.AssignmentIndexing(Ast.VariableExpression(niScope, niRealVar), Ast.VariableExpression(niScope, niKey))
    }, {
        Ast.VariableExpression(niScope, niVal)
    })

    local niFunc = Ast.FunctionLiteralExpression(
        { Ast.VariableExpression(niScope, niSelf), Ast.VariableExpression(niScope, niKey), Ast.VariableExpression(niScope, niVal) },
        Ast.Block({ niStat1, niStat2 }, niScope)
    )

    table.insert(metatableVals, Ast.KeyedTableEntry(Ast.StringExpression("__newindex"), niFunc))

    -- Final Return
    parentScope:addReferenceToHigherScope(self.setMetatableVarScope, self.setMetatableVarId);
    return Ast.FunctionCallExpression(
        Ast.VariableExpression(self.setMetatableVarScope, self.setMetatableVarId),
        {
            Ast.TableConstructorExpression({
                Ast.KeyedTableEntry(Ast.StringExpression(info.valueName), expr)
            }),
            Ast.TableConstructorExpression(metatableVals)
        }
    );
end

function ProxifyLocals:apply(ast, pipeline)
    local localMetatableInfos = {};
    local function getLocalMetatableInfo(scope, id)
        if(scope.isGlobal) then return nil end;

        localMetatableInfos[scope] = localMetatableInfos[scope] or {};
        if localMetatableInfos[scope][id] then
            if localMetatableInfos[scope][id].locked then
                return nil
            end
            return localMetatableInfos[scope][id];
        end
        local localMetatableInfo = generateLocalMetatableInfo(pipeline);
        localMetatableInfos[scope][id] = localMetatableInfo;
        return localMetatableInfo;
    end

    local function disableMetatableInfo(scope, id)
        if(scope.isGlobal) then return nil end;

        localMetatableInfos[scope] = localMetatableInfos[scope] or {};
        localMetatableInfos[scope][id] = {locked = true}
    end

    self.setMetatableVarScope = ast.body.scope;
    self.setMetatableVarId = ast.body.scope:addVariable();

    self.emptyFunctionScope = ast.body.scope;
    self.emptyFunctionId = ast.body.scope:addVariable();
    self.emptyFunctionUsed = false;

    table.insert(ast.body.statements, 1, Ast.LocalVariableDeclaration(self.emptyFunctionScope, {self.emptyFunctionId}, {
        Ast.FunctionLiteralExpression({}, Ast.Block({}, Scope:new(ast.body.scope)));
    }));


    visitast(ast, function(node, data)
        if(node.kind == AstKind.ForStatement) then
            disableMetatableInfo(node.scope, node.id)
        end
        if(node.kind == AstKind.ForInStatement) then
            for i, id in ipairs(node.ids) do
                disableMetatableInfo(node.scope, id);
            end
        end

        if(node.kind == AstKind.FunctionDeclaration or node.kind == AstKind.LocalFunctionDeclaration or node.kind == AstKind.FunctionLiteralExpression) then
            for i, expr in ipairs(node.args) do
                if expr.kind == AstKind.VariableExpression then
                    disableMetatableInfo(expr.scope, expr.id);
                end
            end
        end

        if(node.kind == AstKind.AssignmentStatement) then
            if(#node.lhs == 1 and node.lhs[1].kind == AstKind.AssignmentVariable) then
                local variable = node.lhs[1];
                local localMetatableInfo = getLocalMetatableInfo(variable.scope, variable.id);
                if localMetatableInfo then
                    local args = shallowcopy(node.rhs);
                    local vexp = Ast.VariableExpression(variable.scope, variable.id);
                    vexp.__ignoreProxifyLocals = true;
                    args[1] = localMetatableInfo.setValue.constructor(vexp, args[1]);
                    self.emptyFunctionUsed = true;
                    data.scope:addReferenceToHigherScope(self.emptyFunctionScope, self.emptyFunctionId);
                    return Ast.FunctionCallStatement(Ast.VariableExpression(self.emptyFunctionScope, self.emptyFunctionId), args);
                end
            end
        end
    end, function(node, data)
        if(node.kind == AstKind.LocalVariableDeclaration) then
            for i, id in ipairs(node.ids) do
                local expr = node.expressions[i] or Ast.NilExpression();
                local localMetatableInfo = getLocalMetatableInfo(node.scope, id);
                if localMetatableInfo then
                    local newExpr = self:CreateAssignmentExpression(localMetatableInfo, expr, node.scope);
                    node.expressions[i] = newExpr;
                end
            end
        end

        if(node.kind == AstKind.VariableExpression and not node.__ignoreProxifyLocals) then
            local localMetatableInfo = getLocalMetatableInfo(node.scope, node.id);
            if localMetatableInfo then
                local literal;
                if self.LiteralType == "dictionary" then
                    literal = RandomLiterals.Dictionary();
                elseif self.LiteralType == "number" then
                    literal = RandomLiterals.Number();
                elseif self.LiteralType == "string" then
                    literal = RandomLiterals.String(pipeline);
                else
                    literal = RandomLiterals.Any(pipeline);
                end
                return localMetatableInfo.getValue.constructor(node, literal);
            end
        end

        if(node.kind == AstKind.AssignmentVariable) then
            local localMetatableInfo = getLocalMetatableInfo(node.scope, node.id);
            if localMetatableInfo then
                -- FIX: BvmStep requires the base of an AssignmentIndexing to be a VariableExpression, 
                -- not an AssignmentVariable. This prevents the compiler crash on multiple assignments.
                local baseExpr = Ast.VariableExpression(node.scope, node.id)
                return Ast.AssignmentIndexing(baseExpr, Ast.StringExpression(localMetatableInfo.valueName));
            end
        end

        if(node.kind == AstKind.LocalFunctionDeclaration) then
            local localMetatableInfo = getLocalMetatableInfo(node.scope, node.id);
            if localMetatableInfo then
                local funcLiteral = Ast.FunctionLiteralExpression(node.args, node.body);
                local newExpr = self:CreateAssignmentExpression(localMetatableInfo, funcLiteral, node.scope);
                return Ast.LocalVariableDeclaration(node.scope, {node.id}, {newExpr});
            end
        end

        if(node.kind == AstKind.FunctionDeclaration) then
            local localMetatableInfo = getLocalMetatableInfo(node.scope, node.id);
            if(localMetatableInfo) then
                table.insert(node.indices, 1, localMetatableInfo.valueName);
            end
        end
    end)

    table.insert(ast.body.statements, 1, Ast.LocalVariableDeclaration(self.setMetatableVarScope, {self.setMetatableVarId}, {
        Ast.VariableExpression(self.setMetatableVarScope:resolveGlobal("setmetatable"))
    }));
end

return ProxifyLocals;