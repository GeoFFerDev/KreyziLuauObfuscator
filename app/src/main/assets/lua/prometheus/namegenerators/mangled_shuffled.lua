-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- namegenerators/mangled_shuffled.lua
--
-- Generates extremely short, meaningless identifier names with shuffled
-- character pools so the mapping is different on every obfuscation run.
-- Prioritises single-character names for maximum output-size reduction.

local util = require("prometheus.util");
local chararray = util.chararray;

-- Character pools that will be shuffled per-run.
local VarDigits = chararray("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_");
local VarStartDigits = chararray("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ");

-- Pre-computed pool sizes after shuffling (cached in prepare).
local _VarDigitsLen = 63
local _VarStartDigitsLen = 52

local function generateName(id, _)
	-- Single-char name for ids 0..51 (covers most scripts).
	if id < _VarStartDigitsLen then
		return VarStartDigits[(id % _VarStartDigitsLen) + 1]
	end
	-- Fallback to multi-char encoding for larger ids.
	local name = ''
	local d = id % _VarStartDigitsLen
	id = (id - d) / _VarStartDigitsLen
	name = name .. VarStartDigits[d + 1]
	while id > 0 do
		local e = id % _VarDigitsLen
		id = (id - e) / _VarDigitsLen
		name = name .. VarDigits[e + 1]
	end
	return name
end

-- Shuffle pools; called once per pipeline run.
local function prepare(_)
	util.shuffle(VarDigits)
	util.shuffle(VarStartDigits)
	_VarDigitsLen     = #VarDigits
	_VarStartDigitsLen = #VarStartDigits
end

return {
	generateName = generateName,
	prepare      = prepare,
}