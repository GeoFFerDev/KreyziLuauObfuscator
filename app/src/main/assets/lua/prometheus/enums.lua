-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- enums.lua
--
-- IMPROVED: Added Lua52 (goto/labels), Lua53 (//,&,|,~,<<,>>), Lua54 conventions.

local Enums = {};
local chararray = require("prometheus.util").chararray;

Enums.LuaVersion = {
	LuaU  = "LuaU",
	Lua51 = "Lua51",
	Lua52 = "Lua52",
	Lua53 = "Lua53",
	Lua54 = "Lua54",
}

-- Base Lua 5.1 convention
local function mkLua51()
	return {
		Keywords = {
			"and", "break", "continue", "do", "else", "elseif",
			"end", "false", "for", "function", "if",
			"in", "local", "nil", "not", "or",
			"repeat", "return", "then", "true", "until", "while"
		},
		SymbolChars     = chararray("+-*/%^#=~<>(){}[];:,."),
		MaxSymbolLength = 3,
		Symbols = {
			"+", "-", "*", "/", "%", "^", "#",
			"==", "~=", "<=", ">=", "<", ">", "=",
			"(", ")", "{", "}", "[", "]",
			";", ":", ",", ".", "..", "...",
		},
		IdentChars        = chararray("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789"),
		NumberChars       = chararray("0123456789"),
		HexNumberChars    = chararray("0123456789abcdefABCDEF"),
		BinaryNumberChars = {"0","1"},
		DecimalExponent   = {"e","E"},
		HexadecimalNums   = {"x","X"},
		BinaryNums        = {"b","B"},
		DecimalSeperators = false,
		EscapeSequences = {
			["a"]="\a";["b"]="\b";["f"]="\f";["n"]="\n";["r"]="\r";
			["t"]="\t";["v"]="\v";["\\"]="\\";["\""]="\"";
			["\'"]="\'";
		},
		NumericalEscapes            = true,
		EscapeZIgnoreNextWhitespace = true,
		HexEscapes                  = true,
		UnicodeEscapes              = true,
	}
end

-- Lua 5.2: adds goto keyword and :: label symbol
local function mkLua52()
	local c = mkLua51()
	c.Keywords = {
		"and","break","continue","do","else","elseif",
		"end","false","for","function","goto","if",
		"in","local","nil","not","or",
		"repeat","return","then","true","until","while"
	}
	c.Symbols = {
		"+","-","*","/","%","^","#",
		"==","~=","<=",">=","<",">","=",
		"(",")","{","}","[","]",
		";",":","::",",",".","..","...",
	}
	c.SymbolChars     = chararray("+-*/%^#=~<>(){}[];:,.")
	c.MaxSymbolLength = 3
	return c
end

-- Lua 5.3: adds // idiv + bitwise &|~<<>>
local function mkLua53()
	local c = mkLua52()
	c.Symbols = {
		"+","-","*","/","//","%","^","#",
		"==","~=","<=",">=","<<",">>","<",">","=",
		"&","|","~",
		"(",")","{","}","[","]",
		";",":","::",",",".","..","...",
	}
	c.SymbolChars     = chararray("+-*/%^#=~<>(){}[];:,.|&")
	c.MaxSymbolLength = 3
	return c
end

-- Lua 5.4: same operators as 5.3; <close>/<const> attributes handled in parser
local function mkLua54()
	local c = mkLua53()
	return c
end

Enums.Conventions = {
	[Enums.LuaVersion.Lua51] = mkLua51(),
	[Enums.LuaVersion.Lua52] = mkLua52(),
	[Enums.LuaVersion.Lua53] = mkLua53(),
	[Enums.LuaVersion.Lua54] = mkLua54(),
	[Enums.LuaVersion.LuaU]  = {
		Keywords = {
			"and","break","do","else","elseif","continue",
			"end","false","for","function","if",
			"in","local","nil","not","or",
			"repeat","return","then","true","until","while"
		},
		SymbolChars     = chararray("+-*/%^#=~<>(){}[];:,."),
		MaxSymbolLength = 3,
		Symbols = {
			"+","-","*","/","%","^","#",
			"==","~=","<=",">=","<",">","=",
			"+=","-=","/=","%=","^=","..=","*=",
			"(",")","[","]","{","}",
			";",":",",",".","..","...",
			"::","->","?","|","&",
		},
		IdentChars        = chararray("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789"),
		NumberChars       = chararray("0123456789"),
		HexNumberChars    = chararray("0123456789abcdefABCDEF"),
		BinaryNumberChars = {"0","1"},
		DecimalExponent   = {"e","E"},
		HexadecimalNums   = {"x","X"},
		BinaryNums        = {"b","B"},
		DecimalSeperators = {"_"},
		EscapeSequences = {
			["a"]="\a";["b"]="\b";["f"]="\f";["n"]="\n";["r"]="\r";
			["t"]="\t";["v"]="\v";["\\"]="\\";["\""]="\"";
			["\'"]="\'";
		},
		NumericalEscapes            = true,
		EscapeZIgnoreNextWhitespace = true,
		HexEscapes                  = true,
		UnicodeEscapes              = true,
	},
}

return Enums;
