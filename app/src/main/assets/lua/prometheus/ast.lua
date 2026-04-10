-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- ast.lua
--
-- IMPROVED: Added GotoStatement, LabelStatement (Lua 5.2+) and
-- bitwise/idiv expression nodes (Lua 5.3+).

local Ast = {}

local AstKind = {
	-- Misc
	TopNode  = "TopNode";
	Block    = "Block";

	-- Statements
	ContinueStatement              = "ContinueStatement";
	BreakStatement                 = "BreakStatement";
	GotoStatement                  = "GotoStatement";    -- Lua 5.2+
	LabelStatement                 = "LabelStatement";   -- Lua 5.2+
	DoStatement                    = "DoStatement";
	WhileStatement                 = "WhileStatement";
	ReturnStatement                = "ReturnStatement";
	RepeatStatement                = "RepeatStatement";
	ForInStatement                 = "ForInStatement";
	ForStatement                   = "ForStatement";
	IfStatement                    = "IfStatement";
	FunctionDeclaration            = "FunctionDeclaration";
	LocalFunctionDeclaration       = "LocalFunctionDeclaration";
	LocalVariableDeclaration       = "LocalVariableDeclaration";
	FunctionCallStatement          = "FunctionCallStatement";
	PassSelfFunctionCallStatement  = "PassSelfFunctionCallStatement";
	AssignmentStatement            = "AssignmentStatement";

	-- LuaU Compound Statements
	CompoundAddStatement    = "CompoundAddStatement";
	CompoundSubStatement    = "CompoundSubStatement";
	CompoundMulStatement    = "CompoundMulStatement";
	CompoundDivStatement    = "CompoundDivStatement";
	CompoundModStatement    = "CompoundModStatement";
	CompoundPowStatement    = "CompoundPowStatement";
	CompoundConcatStatement = "CompoundConcatStatement";

	-- Assignment Index
	AssignmentIndexing = "AssignmentIndexing";
	AssignmentVariable = "AssignmentVariable";

	-- Expression Nodes
	BooleanExpression               = "BooleanExpression";
	NumberExpression                = "NumberExpression";
	StringExpression                = "StringExpression";
	NilExpression                   = "NilExpression";
	VarargExpression                = "VarargExpression";
	OrExpression                    = "OrExpression";
	AndExpression                   = "AndExpression";
	LessThanExpression              = "LessThanExpression";
	GreaterThanExpression           = "GreaterThanExpression";
	LessThanOrEqualsExpression      = "LessThanOrEqualsExpression";
	GreaterThanOrEqualsExpression   = "GreaterThanOrEqualsExpression";
	NotEqualsExpression             = "NotEqualsExpression";
	EqualsExpression                = "EqualsExpression";
	StrCatExpression                = "StrCatExpression";
	AddExpression                   = "AddExpression";
	SubExpression                   = "SubExpression";
	MulExpression                   = "MulExpression";
	DivExpression                   = "DivExpression";
	IdivExpression                  = "IdivExpression";   -- Lua 5.3+  //
	ModExpression                   = "ModExpression";
	BAndExpression                  = "BAndExpression";   -- Lua 5.3+  &
	BOrExpression                   = "BOrExpression";    -- Lua 5.3+  |
	BXorExpression                  = "BXorExpression";   -- Lua 5.3+  ~ (binary)
	ShlExpression                   = "ShlExpression";    -- Lua 5.3+  <<
	ShrExpression                   = "ShrExpression";    -- Lua 5.3+  >>
	NotExpression                   = "NotExpression";
	LenExpression                   = "LenExpression";
	NegateExpression                = "NegateExpression";
	BNotExpression                  = "BNotExpression";   -- Lua 5.3+  ~ (unary)
	PowExpression                   = "PowExpression";
	IndexExpression                 = "IndexExpression";
	FunctionCallExpression          = "FunctionCallExpression";
	PassSelfFunctionCallExpression  = "PassSelfFunctionCallExpression";
	VariableExpression              = "VariableExpression";
	FunctionLiteralExpression       = "FunctionLiteralExpression";
	TableConstructorExpression      = "TableConstructorExpression";

	-- Table Entry
	TableEntry        = "TableEntry";
	KeyedTableEntry   = "KeyedTableEntry";

	-- Misc
	NopStatement        = "NopStatement";
	IfElseExpression    = "IfElseExpression";
}

-- Precedence table (lower number = higher precedence when generating parens)
local astKindExpressionLookup = {
	[AstKind.BooleanExpression]              = 0;
	[AstKind.NumberExpression]               = 0;
	[AstKind.StringExpression]               = 0;
	[AstKind.NilExpression]                  = 0;
	[AstKind.VarargExpression]               = 0;
	[AstKind.OrExpression]                   = 12;
	[AstKind.AndExpression]                  = 11;
	[AstKind.LessThanExpression]             = 10;
	[AstKind.GreaterThanExpression]          = 10;
	[AstKind.LessThanOrEqualsExpression]     = 10;
	[AstKind.GreaterThanOrEqualsExpression]  = 10;
	[AstKind.NotEqualsExpression]            = 10;
	[AstKind.EqualsExpression]               = 10;
	-- Bitwise ops – Lua 5.3 precedence (between comparison and strcat)
	[AstKind.BOrExpression]                  = 9;
	[AstKind.BXorExpression]                 = 8;  -- was StrCat slot
	[AstKind.BAndExpression]                 = 7;
	[AstKind.ShlExpression]                  = 6;
	[AstKind.ShrExpression]                  = 6;
	-- original slots shifted down
	[AstKind.StrCatExpression]               = 5;
	[AstKind.AddExpression]                  = 4;
	[AstKind.SubExpression]                  = 4;
	[AstKind.MulExpression]                  = 3;
	[AstKind.DivExpression]                  = 3;
	[AstKind.IdivExpression]                 = 3;
	[AstKind.ModExpression]                  = 3;
	[AstKind.NotExpression]                  = 2;
	[AstKind.LenExpression]                  = 2;
	[AstKind.NegateExpression]               = 2;
	[AstKind.BNotExpression]                 = 2;
	[AstKind.PowExpression]                  = 1;
	[AstKind.IndexExpression]                = 0;
	[AstKind.AssignmentIndexing]             = 0;
	[AstKind.FunctionCallExpression]         = 0;
	[AstKind.PassSelfFunctionCallExpression] = 0;
	[AstKind.VariableExpression]             = 0;
	[AstKind.FunctionLiteralExpression]      = 0;
	[AstKind.TableConstructorExpression]     = 0;
}

Ast.AstKind = AstKind;

function Ast.astKindExpressionToNumber(kind)
	return astKindExpressionLookup[kind] or 0;
end

function Ast.ConstantNode(val)
	if val == nil    then return Ast.NilExpression() end
	if val == true   then return Ast.BooleanExpression(true) end
	if val == false  then return Ast.BooleanExpression(false) end
	if type(val) == "number" then return Ast.NumberExpression(val) end
	if type(val) == "string" then return Ast.StringExpression(val) end
	error("Ast.ConstantNode: unsupported type " .. type(val))
end

-- ── Statements ───────────────────────────────────────────────────────────────

function Ast.NopStatement()
	return { kind = AstKind.NopStatement; }
end

function Ast.IfElseExpression(condition, true_value, false_value)
	return {
		kind        = AstKind.IfElseExpression,
		condition   = condition,
		true_value  = true_value,
		false_value = false_value,
	}
end

function Ast.TopNode(body, globalScope)
	return {
		kind        = AstKind.TopNode,
		body        = body,
		globalScope = globalScope,
	}
end

function Ast.TableEntry(value)
	return {
		kind  = AstKind.TableEntry,
		value = value,
	}
end

function Ast.KeyedTableEntry(key, value)
	return {
		kind  = AstKind.KeyedTableEntry,
		key   = key,
		value = value,
	}
end

function Ast.TableConstructorExpression(entries)
	return {
		kind    = AstKind.TableConstructorExpression,
		entries = entries,
	}
end

function Ast.Block(statements, scope)
	return {
		kind       = AstKind.Block,
		statements = statements,
		scope      = scope,
	}
end

function Ast.BreakStatement(loop, scope)
	return {
		kind  = AstKind.BreakStatement,
		loop  = loop,
		scope = scope,
	}
end

function Ast.ContinueStatement(loop, scope)
	return {
		kind  = AstKind.ContinueStatement,
		loop  = loop,
		scope = scope,
	}
end

-- Lua 5.2+
function Ast.GotoStatement(label)
	return {
		kind  = AstKind.GotoStatement,
		label = label,   -- string label name
	}
end

-- Lua 5.2+
function Ast.LabelStatement(label)
	return {
		kind  = AstKind.LabelStatement,
		label = label,   -- string label name
	}
end

function Ast.PassSelfFunctionCallStatement(base, passSelfFunctionName, args)
	return {
		kind                  = AstKind.PassSelfFunctionCallStatement,
		base                  = base,
		passSelfFunctionName  = passSelfFunctionName,
		args                  = args,
	}
end

function Ast.AssignmentStatement(lhs, rhs)
	return {
		kind = AstKind.AssignmentStatement,
		lhs  = lhs,
		rhs  = rhs,
	}
end

function Ast.CompoundAddStatement(lhs, rhs)
	return { kind = AstKind.CompoundAddStatement, lhs = lhs, rhs = rhs }
end
function Ast.CompoundSubStatement(lhs, rhs)
	return { kind = AstKind.CompoundSubStatement, lhs = lhs, rhs = rhs }
end
function Ast.CompoundMulStatement(lhs, rhs)
	return { kind = AstKind.CompoundMulStatement, lhs = lhs, rhs = rhs }
end
function Ast.CompoundDivStatement(lhs, rhs)
	return { kind = AstKind.CompoundDivStatement, lhs = lhs, rhs = rhs }
end
function Ast.CompoundPowStatement(lhs, rhs)
	return { kind = AstKind.CompoundPowStatement, lhs = lhs, rhs = rhs }
end
function Ast.CompoundModStatement(lhs, rhs)
	return { kind = AstKind.CompoundModStatement, lhs = lhs, rhs = rhs }
end
function Ast.CompoundConcatStatement(lhs, rhs)
	return { kind = AstKind.CompoundConcatStatement, lhs = lhs, rhs = rhs }
end

function Ast.FunctionCallStatement(base, args)
	return { kind = AstKind.FunctionCallStatement, base = base, args = args }
end

function Ast.ReturnStatement(args)
	return { kind = AstKind.ReturnStatement, args = args }
end

function Ast.DoStatement(body)
	return { kind = AstKind.DoStatement, body = body }
end

function Ast.WhileStatement(body, condition, parentScope)
	return {
		kind        = AstKind.WhileStatement,
		body        = body,
		condition   = condition,
		parentScope = parentScope,
	}
end

function Ast.ForInStatement(scope, vars, expressions, body, parentScope)
	return {
		kind        = AstKind.ForInStatement,
		scope       = scope,
		ids         = vars,
		expressions = expressions,
		body        = body,
		parentScope = parentScope,
	}
end

function Ast.ForStatement(scope, id, initialValue, finalValue, incrementBy, body, parentScope)
	return {
		kind          = AstKind.ForStatement,
		scope         = scope,
		id            = id,
		initialValue  = initialValue,
		finalValue    = finalValue,
		incrementBy   = incrementBy,
		body          = body,
		parentScope   = parentScope,
	}
end

function Ast.RepeatStatement(body, condition, scope)
	return {
		kind      = AstKind.RepeatStatement,
		body      = body,
		condition = condition,
		scope     = scope,
	}
end

function Ast.IfStatement(condition, body, elseifs, elsebody)
	return {
		kind      = AstKind.IfStatement,
		condition = condition,
		body      = body,
		elseifs   = elseifs or {},
		elsebody  = elsebody,
	}
end

function Ast.FunctionDeclaration(scope, id, indices, args, body)
	return {
		kind    = AstKind.FunctionDeclaration,
		scope   = scope,
		id      = id,
		indices = indices,
		args    = args,
		body    = body,
	}
end

function Ast.LocalFunctionDeclaration(scope, id, args, body)
	return {
		kind  = AstKind.LocalFunctionDeclaration,
		scope = scope,
		id    = id,
		args  = args,
		body  = body,
	}
end

function Ast.LocalVariableDeclaration(scope, ids, values)
	return {
		kind   = AstKind.LocalVariableDeclaration,
		scope  = scope,
		ids    = ids,
		expressions = values,
	}
end

-- ── Expressions ──────────────────────────────────────────────────────────────

local function binExpr(kind, lhs, rhs, hasParens)
	return { kind = kind, lhs = lhs, rhs = rhs, hasParens = hasParens }
end

function Ast.VarargExpression()
	return { kind = AstKind.VarargExpression }
end
function Ast.BooleanExpression(value)
	return { kind = AstKind.BooleanExpression, value = value }
end
function Ast.NilExpression()
	return { kind = AstKind.NilExpression }
end
function Ast.NumberExpression(value)
	return { kind = AstKind.NumberExpression, value = value }
end
function Ast.StringExpression(value)
	return { kind = AstKind.StringExpression, value = value }
end

function Ast.OrExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.OrExpression, lhs, rhs, hasParens)
end
function Ast.AndExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.AndExpression, lhs, rhs, hasParens)
end
function Ast.LessThanExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.LessThanExpression, lhs, rhs, hasParens)
end
function Ast.GreaterThanExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.GreaterThanExpression, lhs, rhs, hasParens)
end
function Ast.LessThanOrEqualsExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.LessThanOrEqualsExpression, lhs, rhs, hasParens)
end
function Ast.GreaterThanOrEqualsExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.GreaterThanOrEqualsExpression, lhs, rhs, hasParens)
end
function Ast.NotEqualsExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.NotEqualsExpression, lhs, rhs, hasParens)
end
function Ast.EqualsExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.EqualsExpression, lhs, rhs, hasParens)
end
function Ast.StrCatExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.StrCatExpression, lhs, rhs, hasParens)
end
function Ast.AddExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.AddExpression, lhs, rhs, hasParens)
end
function Ast.SubExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.SubExpression, lhs, rhs, hasParens)
end
function Ast.MulExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.MulExpression, lhs, rhs, hasParens)
end
function Ast.DivExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.DivExpression, lhs, rhs, hasParens)
end
function Ast.IdivExpression(lhs, rhs, hasParens)        -- Lua 5.3+ //
	return binExpr(AstKind.IdivExpression, lhs, rhs, hasParens)
end
function Ast.ModExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.ModExpression, lhs, rhs, hasParens)
end
function Ast.BAndExpression(lhs, rhs, hasParens)        -- Lua 5.3+ &
	return binExpr(AstKind.BAndExpression, lhs, rhs, hasParens)
end
function Ast.BOrExpression(lhs, rhs, hasParens)         -- Lua 5.3+ |
	return binExpr(AstKind.BOrExpression, lhs, rhs, hasParens)
end
function Ast.BXorExpression(lhs, rhs, hasParens)        -- Lua 5.3+ ~ binary
	return binExpr(AstKind.BXorExpression, lhs, rhs, hasParens)
end
function Ast.ShlExpression(lhs, rhs, hasParens)         -- Lua 5.3+ <<
	return binExpr(AstKind.ShlExpression, lhs, rhs, hasParens)
end
function Ast.ShrExpression(lhs, rhs, hasParens)         -- Lua 5.3+ >>
	return binExpr(AstKind.ShrExpression, lhs, rhs, hasParens)
end

local function unaryExpr(kind, rhs, hasParens)
	return { kind = kind, rhs = rhs, hasParens = hasParens }
end

function Ast.NotExpression(rhs, hasParens)
	return unaryExpr(AstKind.NotExpression, rhs, hasParens)
end
function Ast.LenExpression(rhs, hasParens)
	return unaryExpr(AstKind.LenExpression, rhs, hasParens)
end
function Ast.NegateExpression(rhs, hasParens)
	return unaryExpr(AstKind.NegateExpression, rhs, hasParens)
end
function Ast.BNotExpression(rhs, hasParens)              -- Lua 5.3+ ~ unary
	return unaryExpr(AstKind.BNotExpression, rhs, hasParens)
end
function Ast.PowExpression(lhs, rhs, hasParens)
	return binExpr(AstKind.PowExpression, lhs, rhs, hasParens)
end

function Ast.IndexExpression(base, index)
	return { kind = AstKind.IndexExpression, base = base, index = index }
end
function Ast.AssignmentIndexing(base, index)
	return { kind = AstKind.AssignmentIndexing, base = base, index = index }
end
function Ast.FunctionCallExpression(base, args)
	return { kind = AstKind.FunctionCallExpression, base = base, args = args }
end
function Ast.PassSelfFunctionCallExpression(base, passSelfFunctionName, args)
	return {
		kind                 = AstKind.PassSelfFunctionCallExpression,
		base                 = base,
		passSelfFunctionName = passSelfFunctionName,
		args                 = args,
	}
end
function Ast.VariableExpression(scope, id)
	return { kind = AstKind.VariableExpression, scope = scope, id = id }
end
function Ast.AssignmentVariable(scope, id)
	return { kind = AstKind.AssignmentVariable, scope = scope, id = id }
end
function Ast.FunctionLiteralExpression(args, body, scope)
	return { kind = AstKind.FunctionLiteralExpression, args = args, body = body, scope = scope }
end

return Ast;
