-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- compiler.lua
--
-- This Script is the main compiler module.

local Ast = require("prometheus.ast");
local Scope = require("prometheus.scope");
local util = require("prometheus.util");

local lookupify = util.lookupify;
local AstKind = Ast.AstKind;

-- Cross-version unique sentinel factory.
-- newproxy() was removed in Lua 5.2.  A table with a unique address is an
-- equally valid sentinel that works on every Lua version including LuaJIT.
local function newSentinel(label)
	return setmetatable({}, {
		__tostring  = function() return "sentinel<" .. label .. ">" end,
		__metatable = false,
	});
end

local unpack = unpack or table.unpack;
local blockModule = require("prometheus.compiler.block");
local registerModule = require("prometheus.compiler.register");
local upvalueModule = require("prometheus.compiler.upvalue");
local emitModule = require("prometheus.compiler.emit");
local compileCoreModule  = require("prometheus.compiler.compile_core");
local emitPolyModule    = require("prometheus.compiler.emit_poly");
local registerPatch     = require("prometheus.compiler.register_patch");

local Compiler = {};

function Compiler:new(settings)
    settings = settings or {};
    local compiler = {
        blocks = {};
        registers = {};
        activeBlock = nil;
        registersForVar = {};
        usedRegisters = 0;
        maxUsedRegister = 0;
        registerVars = {};

        -- Opcode-dispatch settings (passed in from Vmify step)
        useOpcodeDispatch = settings.useOpcodeDispatch or false;
        fakeOpcodeCount   = settings.fakeOpcodeCount   or 12;
        statefulFakeOps   = settings.statefulFakeOps ~= false;  -- default true
        useChaosDispatch  = settings.useChaosDispatch  or false;

        -- PolyVmify settings
        usePolyDispatch   = settings.usePolyDispatch   or false;
        polyCodec         = settings.polyCodec         or nil;
        useChaosOverPoly  = settings.useChaosOverPoly  or false;

        -- KeyedVmify settings
        useKeyedDispatch  = settings.useKeyedDispatch  or false;
        keyedK            = settings.keyedK            or 0;
        keyedKShares      = settings.keyedKShares      or {};
        keyedKeyVar       = settings.keyedKeyVar       or "_vmK";
        keyedMOD          = settings.keyedMOD          or 16777216;
        keyedEpoch        = settings.keyedEpoch        or false;
        keyedEpochLen     = settings.keyedEpochLen     or 128;

        -- PolyVmify settings
        usePolyDispatch   = settings.usePolyDispatch   or false;
        polyCodec         = settings.polyCodec         or nil;
        useChaosOverPoly  = settings.useChaosOverPoly  or false;

        -- KeyedVmify settings
        useKeyedDispatch  = settings.useKeyedDispatch  or false;
        keyedK            = settings.keyedK            or 0;
        keyedKShares      = settings.keyedKShares      or {};
        keyedKeyVar       = settings.keyedKeyVar       or "_vmK";
        keyedMOD          = settings.keyedMOD          or 16777216;
        keyedEpoch        = settings.keyedEpoch        or false;
        keyedEpochLen     = settings.keyedEpochLen     or 128;

        VAR_REGISTER    = newSentinel("VAR_REGISTER");
        RETURN_ALL      = newSentinel("RETURN_ALL");
        POS_REGISTER    = newSentinel("POS_REGISTER");
        RETURN_REGISTER = newSentinel("RETURN_REGISTER");
        UPVALUE         = newSentinel("UPVALUE");

        BIN_OPS = lookupify{
            AstKind.LessThanExpression,
            AstKind.GreaterThanExpression,
            AstKind.LessThanOrEqualsExpression,
            AstKind.GreaterThanOrEqualsExpression,
            AstKind.NotEqualsExpression,
            AstKind.EqualsExpression,
            AstKind.StrCatExpression,
            AstKind.AddExpression,
            AstKind.SubExpression,
            AstKind.MulExpression,
            AstKind.DivExpression,
            AstKind.ModExpression,
            AstKind.PowExpression,
        };
    };

    setmetatable(compiler, self);
    self.__index = self;

    return compiler;
end

blockModule(Compiler);
registerModule(Compiler);
upvalueModule(Compiler);
emitModule(Compiler);
compileCoreModule(Compiler);
emitPolyModule(Compiler);
registerPatch(Compiler);
emitPolyModule(Compiler);
registerPatch(Compiler);

function Compiler:pushRegisterUsageInfo()
    table.insert(self.registerUsageStack, {
        usedRegisters = self.usedRegisters;
        registers = self.registers;
    });
    self.usedRegisters = 0;
    self.registers = {};
end

function Compiler:popRegisterUsageInfo()
    local info = table.remove(self.registerUsageStack);
    self.usedRegisters = info.usedRegisters;
    self.registers = info.registers;
end

function Compiler:compile(ast)
    self.blocks = {};
    self.registers = {};
    self.activeBlock = nil;
    self.registersForVar = {};
    self.scopeFunctionDepths = {};
    self.maxUsedRegister = 0;
    self.usedRegisters = 0;
    self.registerVars = {};
    self.usedBlockIds = {};

    self.upvalVars = {};
    self.registerUsageStack = {};

    self.upvalsProxyLenReturn = math.random(-2^22, 2^22);

    local newGlobalScope = Scope:newGlobal();
    local psc = Scope:new(newGlobalScope, nil);

    local _, getfenvVar = newGlobalScope:resolve("getfenv");
    local _, tableVar = newGlobalScope:resolve("table");
    local _, unpackVar = newGlobalScope:resolve("unpack");
    local _, envVar = newGlobalScope:resolve("_ENV");
    local _, newproxyVar = newGlobalScope:resolve("newproxy");
    local _, setmetatableVar = newGlobalScope:resolve("setmetatable");
    local _, getmetatableVar = newGlobalScope:resolve("getmetatable");
    local _, selectVar = newGlobalScope:resolve("select");

    psc:addReferenceToHigherScope(newGlobalScope, getfenvVar, 2);
    psc:addReferenceToHigherScope(newGlobalScope, tableVar);
    psc:addReferenceToHigherScope(newGlobalScope, unpackVar);
    psc:addReferenceToHigherScope(newGlobalScope, envVar);
    psc:addReferenceToHigherScope(newGlobalScope, newproxyVar);
    psc:addReferenceToHigherScope(newGlobalScope, setmetatableVar);
    psc:addReferenceToHigherScope(newGlobalScope, getmetatableVar);

    self.scope = Scope:new(psc);
    self.envVar = self.scope:addVariable();
    self.containerFuncVar = self.scope:addVariable();
    self.unpackVar = self.scope:addVariable();
    self.newproxyVar = self.scope:addVariable();
    self.setmetatableVar = self.scope:addVariable();
    self.getmetatableVar = self.scope:addVariable();
    self.selectVar = self.scope:addVariable();

    local argVar = self.scope:addVariable();

    self.containerFuncScope = Scope:new(self.scope);
    self.whileScope = Scope:new(self.containerFuncScope);

    self.posVar = self.containerFuncScope:addVariable();
    self.argsVar = self.containerFuncScope:addVariable();
    self.currentUpvaluesVar = self.containerFuncScope:addVariable();
    self.detectGcCollectVar = self.containerFuncScope:addVariable();
    self.returnVar = self.containerFuncScope:addVariable();

    self.upvaluesTable = self.scope:addVariable();
    self.upvaluesReferenceCountsTable = self.scope:addVariable();
    self.allocUpvalFunction = self.scope:addVariable();
    self.currentUpvalId = self.scope:addVariable();

    self.upvaluesProxyFunctionVar = self.scope:addVariable();
    self.upvaluesGcFunctionVar = self.scope:addVariable();
    self.freeUpvalueFunc = self.scope:addVariable();

    self.createClosureVars = {};
    self.createVarargClosureVar = self.scope:addVariable();
    local createClosureScope = Scope:new(self.scope);
    local createClosurePosArg = createClosureScope:addVariable();
    local createClosureUpvalsArg = createClosureScope:addVariable();
    local createClosureProxyObject = createClosureScope:addVariable();
    local createClosureFuncVar = createClosureScope:addVariable();

    local createClosureSubScope = Scope:new(createClosureScope);

    local upvalEntries = {};
    local upvalueIds = {};
    self.getUpvalueId = function(self, scope, id)
        local expression;
        local scopeFuncDepth = self.scopeFunctionDepths[scope];
        -- scopeFuncDepth == nil means the scope belongs to a wrapper block
        -- injected by a pipeline step (e.g. OpaquePredicates) that wraps top-
        -- level statements in an IfStatement with a fresh inner scope.  Those
        -- scopes were never seen by getVarRegister and therefore have no depth
        -- entry, but they live at funcDepth 0 by construction.
        -- Treat any unrecognised (nil or missing) depth the same way: allocate
        -- an upvalue via allocUpvalFunction instead of crashing.
        if scopeFuncDepth == nil then
            scopeFuncDepth = 0;
        end
        if(scopeFuncDepth == 0) then
            if upvalueIds[id] then
                return upvalueIds[id];
            end
            expression = Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.allocUpvalFunction), {});
        else
            -- Graceful fallback: when the scope has a real function depth but
            -- we cannot resolve the upvalue, allocate it via the normal path
            -- instead of erroring out.
            if not upvalueIds[id] then
                expression = Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.allocUpvalFunction), {});
            else
                return upvalueIds[id];
            end
        end
        table.insert(upvalEntries, Ast.TableEntry(expression));
        local uid = #upvalEntries;
        upvalueIds[id] = uid;
        return uid;
    end

    createClosureSubScope:addReferenceToHigherScope(self.scope, self.containerFuncVar);
    createClosureSubScope:addReferenceToHigherScope(createClosureScope, createClosurePosArg)
    createClosureSubScope:addReferenceToHigherScope(createClosureScope, createClosureUpvalsArg, 1)
    createClosureScope:addReferenceToHigherScope(self.scope, self.upvaluesProxyFunctionVar)
    createClosureSubScope:addReferenceToHigherScope(createClosureScope, createClosureProxyObject);

    self:compileTopNode(ast);

    local functionNodeAssignments = {
        {
            var = Ast.AssignmentVariable(self.scope, self.containerFuncVar),
            val = Ast.FunctionLiteralExpression({
                Ast.VariableExpression(self.containerFuncScope, self.posVar),
                Ast.VariableExpression(self.containerFuncScope, self.argsVar),
                Ast.VariableExpression(self.containerFuncScope, self.currentUpvaluesVar),
                Ast.VariableExpression(self.containerFuncScope, self.detectGcCollectVar)
            }, self:emitContainerFuncBody());
        }, {
            var = Ast.AssignmentVariable(self.scope, self.createVarargClosureVar),
            val = Ast.FunctionLiteralExpression({
                    Ast.VariableExpression(createClosureScope, createClosurePosArg),
                    Ast.VariableExpression(createClosureScope, createClosureUpvalsArg),
                },
                Ast.Block({
                    Ast.LocalVariableDeclaration(createClosureScope, {
                        createClosureProxyObject
                    }, {
                        Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.upvaluesProxyFunctionVar), {
                            Ast.VariableExpression(createClosureScope, createClosureUpvalsArg)
                        })
                    }),
                    Ast.LocalVariableDeclaration(createClosureScope, {createClosureFuncVar},{
                        Ast.FunctionLiteralExpression({
                            Ast.VarargExpression();
                        },
                        Ast.Block({
                            Ast.ReturnStatement{
                                Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.containerFuncVar), {
                                    Ast.VariableExpression(createClosureScope, createClosurePosArg),
                                    Ast.TableConstructorExpression({Ast.TableEntry(Ast.VarargExpression())}),
                                    Ast.VariableExpression(createClosureScope, createClosureUpvalsArg),
                                    Ast.VariableExpression(createClosureScope, createClosureProxyObject)
                                })
                            }
                        }, createClosureSubScope)
                        );
                    });
                    Ast.ReturnStatement{Ast.VariableExpression(createClosureScope, createClosureFuncVar)};
                }, createClosureScope)
            );
        }, {
            var = Ast.AssignmentVariable(self.scope, self.upvaluesTable),
            val = Ast.TableConstructorExpression({}),
        }, {
            var = Ast.AssignmentVariable(self.scope, self.upvaluesReferenceCountsTable),
            val = Ast.TableConstructorExpression({}),
        }, {
            var = Ast.AssignmentVariable(self.scope, self.allocUpvalFunction),
            val = self:createAllocUpvalFunction(),
        }, {
            var = Ast.AssignmentVariable(self.scope, self.currentUpvalId),
            val = Ast.NumberExpression(0),
        }, {
            var = Ast.AssignmentVariable(self.scope, self.upvaluesProxyFunctionVar),
            val = self:createUpvaluesProxyFunc(),
        }, {
            var = Ast.AssignmentVariable(self.scope, self.upvaluesGcFunctionVar),
            val = self:createUpvaluesGcFunc(),
        }, {
            var = Ast.AssignmentVariable(self.scope, self.freeUpvalueFunc),
            val = self:createFreeUpvalueFunc(),
        },
    }

    local tbl = {
        Ast.VariableExpression(self.scope, self.containerFuncVar),
        Ast.VariableExpression(self.scope, self.createVarargClosureVar),
        Ast.VariableExpression(self.scope, self.upvaluesTable),
        Ast.VariableExpression(self.scope, self.upvaluesReferenceCountsTable),
        Ast.VariableExpression(self.scope, self.allocUpvalFunction),
        Ast.VariableExpression(self.scope, self.currentUpvalId),
        Ast.VariableExpression(self.scope, self.upvaluesProxyFunctionVar),
        Ast.VariableExpression(self.scope, self.upvaluesGcFunctionVar),
        Ast.VariableExpression(self.scope, self.freeUpvalueFunc),
    };
    for i, entry in pairs(self.createClosureVars) do
        table.insert(functionNodeAssignments, entry);
        table.insert(tbl, Ast.VariableExpression(entry.var.scope, entry.var.id));
    end

    util.shuffle(functionNodeAssignments);
    local assignmentStatLhs, assignmentStatRhs = {}, {};
    for i, v in ipairs(functionNodeAssignments) do
        assignmentStatLhs[i] = v.var;
        assignmentStatRhs[i] = v.val;
    end


    -- NEW: Position Shuffler
    local ids = util.shuffle({1, 2, 3, 4, 5, 6, 7});

    local items = {
        Ast.VariableExpression(self.scope, self.envVar),
        Ast.VariableExpression(self.scope, self.unpackVar),
        Ast.VariableExpression(self.scope, self.newproxyVar),
        Ast.VariableExpression(self.scope, self.setmetatableVar),
        Ast.VariableExpression(self.scope, self.getmetatableVar),
        Ast.VariableExpression(self.scope, self.selectVar),
        Ast.VariableExpression(self.scope, argVar),
    }

    local astItems = {
        Ast.OrExpression(Ast.AndExpression(Ast.VariableExpression(newGlobalScope, getfenvVar), Ast.FunctionCallExpression(Ast.VariableExpression(newGlobalScope, getfenvVar), {})), Ast.VariableExpression(newGlobalScope, envVar));
        Ast.OrExpression(Ast.VariableExpression(newGlobalScope, unpackVar), Ast.IndexExpression(Ast.VariableExpression(newGlobalScope, tableVar), Ast.StringExpression("unpack")));
        -- Cross-version sentinel factory: newproxy removed in Lua 5.2, use setmetatable instead
        Ast.FunctionLiteralExpression({}, Ast.Block({
            Ast.ReturnStatement({
                Ast.FunctionCallExpression(Ast.VariableExpression(newGlobalScope, setmetatableVar), {
                    Ast.TableConstructorExpression({}),
                    Ast.TableConstructorExpression({}),
                })
            })
        }, nil), nil);
        Ast.VariableExpression(newGlobalScope, setmetatableVar);
        Ast.VariableExpression(newGlobalScope, getmetatableVar);
        Ast.VariableExpression(newGlobalScope, selectVar);
        Ast.TableConstructorExpression({
            Ast.TableEntry(Ast.VarargExpression());
        })
    }

    local functionNode = Ast.FunctionLiteralExpression({
      items[ids[1]], items[ids[2]], items[ids[3]], items[ids[4]],
      items[ids[5]], items[ids[6]], items[ids[7]],
      unpack(util.shuffle(tbl))
    }, Ast.Block({
        Ast.AssignmentStatement(assignmentStatLhs, assignmentStatRhs);
        Ast.ReturnStatement{
            Ast.FunctionCallExpression(Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.createVarargClosureVar), {
                    Ast.NumberExpression(self:encodeStartId(self.startBlockId));
                    Ast.TableConstructorExpression(upvalEntries);
                }), {Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.unpackVar), {Ast.VariableExpression(self.scope, argVar)})});
        }
    }, self.scope));

    return Ast.TopNode(Ast.Block({
        Ast.ReturnStatement{Ast.FunctionCallExpression(functionNode, {
            astItems[ids[1]], astItems[ids[2]], astItems[ids[3]], astItems[ids[4]],
            astItems[ids[5]], astItems[ids[6]], astItems[ids[7]],
        })};
    }, psc), newGlobalScope);
end

function Compiler:getCreateClosureVar(argCount)
    if not self.createClosureVars[argCount] then
        local var = Ast.AssignmentVariable(self.scope, self.scope:addVariable());
        local createClosureScope = Scope:new(self.scope);
        local createClosureSubScope = Scope:new(createClosureScope);

        local createClosurePosArg = createClosureScope:addVariable();
        local createClosureUpvalsArg = createClosureScope:addVariable();
        local createClosureProxyObject = createClosureScope:addVariable();
        local createClosureFuncVar = createClosureScope:addVariable();

        createClosureSubScope:addReferenceToHigherScope(self.scope, self.containerFuncVar);
        createClosureSubScope:addReferenceToHigherScope(createClosureScope, createClosurePosArg)
        createClosureSubScope:addReferenceToHigherScope(createClosureScope, createClosureUpvalsArg, 1)
        createClosureScope:addReferenceToHigherScope(self.scope, self.upvaluesProxyFunctionVar)
        createClosureSubScope:addReferenceToHigherScope(createClosureScope, createClosureProxyObject);

        local  argsTb, argsTb2 = {}, {};
        for i = 1, argCount do
            local arg = createClosureSubScope:addVariable()
            argsTb[i] = Ast.VariableExpression(createClosureSubScope, arg);
            argsTb2[i] = Ast.TableEntry(Ast.VariableExpression(createClosureSubScope, arg));
        end

        local val = Ast.FunctionLiteralExpression({
            Ast.VariableExpression(createClosureScope, createClosurePosArg),
            Ast.VariableExpression(createClosureScope, createClosureUpvalsArg),
        }, Ast.Block({
                Ast.LocalVariableDeclaration(createClosureScope, {
                    createClosureProxyObject
                }, {
                    Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.upvaluesProxyFunctionVar), {
                        Ast.VariableExpression(createClosureScope, createClosureUpvalsArg)
                    })
                }),
                Ast.LocalVariableDeclaration(createClosureScope, {createClosureFuncVar},{
                    Ast.FunctionLiteralExpression(argsTb,
                    Ast.Block({
                        Ast.ReturnStatement{
                            Ast.FunctionCallExpression(Ast.VariableExpression(self.scope, self.containerFuncVar), {
                                Ast.VariableExpression(createClosureScope, createClosurePosArg),
                                Ast.TableConstructorExpression(argsTb2),
                                Ast.VariableExpression(createClosureScope, createClosureUpvalsArg),
                                Ast.VariableExpression(createClosureScope, createClosureProxyObject)
                            })
                        }
                    }, createClosureSubScope)
                    );
                });
                Ast.ReturnStatement{Ast.VariableExpression(createClosureScope, createClosureFuncVar)}
            }, createClosureScope)
        );
        self.createClosureVars[argCount] = {
            var = var,
            val = val,
        }
    end


    local var = self.createClosureVars[argCount].var;
    return var.scope, var.id;
end

function Compiler:encodeStartId(id)
    if self.usePolyDispatch and self.polyCodec then
        id = self.polyCodec.encode(id)
    end
    if self.useKeyedDispatch and self.keyedK and self.keyedK ~= 0 then
        id = (id + self.keyedK) % (self.keyedMOD or 16777216)
    end
    return id
end

return Compiler;
