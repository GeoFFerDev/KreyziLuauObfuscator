-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- WrapInFunction.lua
--
-- This Script provides a Simple Obfuscation Step that wraps the entire Script into a function

local Step = require("prometheus.step");
local Ast = require("prometheus.ast");
local Scope = require("prometheus.scope");

local WrapInFunction = Step:extend();
WrapInFunction.Description = "This Step Wraps the Entire Script into a Function";
WrapInFunction.Name = "Wrap in Function";

WrapInFunction.SettingsDescriptor = {
	Iterations = {
		name = "Iterations",
		description = "The Number Of Iterations",
		type = "number",
		default = 1,
		min = 1,
		max = nil,
	}
}

function WrapInFunction:init(_) end

function WrapInFunction:apply(ast)
	for i = 1, self.Iterations, 1 do
		local body = ast.body;
		-- FIX Bug #3: guard against nil body.scope
		if not body or not body.scope then
			-- Create a synthetic scope if body.scope is nil
			if not body then
				body = Ast.Block({}, nil);
				ast.body = body;
			end
			if not body.scope then
				body.scope = ast.globalScope;
			end
		end

		local scope = Scope:new(ast.globalScope);
		body.scope:setParent(scope);

		-- FIX: trailing semicolons in table constructor are Lua 5.2+ syntax, remove for Lua 5.1/Luau
		ast.body = Ast.Block({
			Ast.ReturnStatement({
				Ast.FunctionCallExpression(Ast.FunctionLiteralExpression({Ast.VarargExpression()}, body), {Ast.VarargExpression()})
			})
		}, scope);
	end
end

return WrapInFunction;