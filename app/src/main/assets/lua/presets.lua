-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- presets.lua
--
-- This Script provides the predefined obfuscation presets for Prometheus.
--
-- FIXED (2026-04-06): All presets now default to LuaVersion = "LuaU"
-- so they work correctly with Roblox/Luau executors.
-- Previously, most presets defaulted to "Lua51", causing:
--   - Luau syntax rejection at parse time (continue, compound assignment, etc.)
--   - Environment resolution failures _ENV and _G on Roblox executors
--   - Silent empty output at runtime (no errors visible to user)
--
-- Added "LuauBvm" preset: single BvmStep tuned for Luau output.

return {
	-- Minifies your code. Does not obfuscate it. No performance loss.
	["Minify"] = {
		LuaVersion = "LuaU",
		VarNamePrefix = "",
		NameGenerator = "MangledShuffled",
		PrettyPrint = false,
		Seed = 0,
		Steps = {},
	},

	-- Weak obfuscation. Very readable, low performance loss.
	["Weak"] = {
		LuaVersion = "LuaU",
		VarNamePrefix = "",
		NameGenerator = "MangledShuffled",
		PrettyPrint = false,
		Seed = 0,
		Steps = {
			{ Name = "Vmify", Settings = {} },
			{
				Name = "ConstantArray",
				Settings = {
					Threshold = 1,
					StringsOnly = true
				},
			},
			{ Name = "WrapInFunction", Settings = {} },
		},
	},

	-- This is here for the tests.lua file.
	-- It helps isolate any problems with the Vmify step.
	-- It is not recommended to use this preset for obfuscation.
	-- Use the Weak, Medium, or Strong for obfuscation instead.
	["Vmify"] = {
		LuaVersion = "LuaU",
		VarNamePrefix = "",
		NameGenerator = "MangledShuffled",
		PrettyPrint = false,
		Seed = 0,
		Steps = {
			{ Name = "Vmify", Settings = {} },
		},
	},

	-- Medium obfuscation. Moderate obfuscation, moderate performance loss.
	["Medium"] = {
		LuaVersion = "LuaU",
		VarNamePrefix = "",
		NameGenerator = "MangledShuffled",
		PrettyPrint = false,
		Seed = 0,
		Steps = {
			{ Name = "Vmify", Settings = {} },
			{
				Name = "AntiTamper",
				Settings = {
					UseDebug = true,
				},
			},
			{
				Name = "EncryptStrings",
				Settings = {
					Threshold = 1,
					StringsOnly = true,
					Shuffle = true,
					Rotate = true,
					LocalWrapperThreshold = 0,
				},
			},
			{ Name = "NumbersToExpressions", Settings = {} },
			{ Name = "Vmify", Settings = {} },
		},
	},

	-- Strong obfuscation, high performance loss.
	["Strong"] = {
		LuaVersion = "LuaU",
		VarNamePrefix = "",
		NameGenerator = "MangledShuffled",
		PrettyPrint = false,
		Seed = 0,
		Steps = {
			{ Name = "Vmify", Settings = {} },
			{ Name = "EncryptStrings", Settings = {} },
			{
				Name = "AntiTamper",
				Settings = {
					UseDebug = false,
				},
			},
			{ Name = "Vmify", Settings = {} },
			{
				Name = "ConstantArray",
				Settings = {
					Threshold = 1,
					StringsOnly = true,
					Shuffle = true,
					Rotate = true,
					LocalWrapperThreshold = 0
				},
			},
			{
				Name = "NumbersToExpressions",
				Settings = {
					NumberRepresentationMutaton = true
				},
			},
			{ Name = "WrapInFunction", Settings = {} },
		},
	},

	-- Roblox/loadstring-friendly preset.
	-- Avoids VM-based steps for better compatibility in LocalScripts/executors.
	["RobloxSafe"] = {
		LuaVersion = "LuaU",
		VarNamePrefix = "",
		NameGenerator = "MangledShuffled",
		PrettyPrint = false,
		Seed = 0,
		Steps = {
			{ Name = "EncryptStrings", Settings = {} },
			{
				Name = "ConstantArray",
				Settings = {
					Threshold = 1,
					StringsOnly = true,
					Shuffle = true,
					Rotate = true,
					LocalWrapperThreshold = 0,
				},
			},
			{ Name = "NumbersToExpressions", Settings = {} },
			{ Name = "WrapInFunction", Settings = {} },
		},
	},

	-- Luau BVM preset (custom)
	-- Full bytecode VM obfuscation tuned specifically for Luau/Roblox executors.
	-- Wraps the entire script in a BVM with randomized ISA opcodes.
	["LuauBvm"] = {
		LuaVersion = "LuaU",
		VarNamePrefix = "",
		NameGenerator = "MangledShuffled",
		PrettyPrint = false,
		Seed = 0,
		Steps = {
			{
				Name = "BvmStep",
				Settings = {
					ChunkSize         = 50,
					ObfuscateDispatch = false,
					SeedRng           = true,
				}
			},
		},
	},
}
