-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- steps.lua
--
-- This Script provides a collection of obfuscation steps.

return {
	BvmStep = require("prometheus.bvm.step"),
	LuauSanitizer = require("prometheus.steps.LuauSanitizer"),
	RobloxInstanceTransformer = require("prometheus.steps.RobloxInstanceTransformer"),
	WrapInFunction = require("prometheus.steps.WrapInFunction"),
	SplitStrings = require("prometheus.steps.SplitStrings"),
	Vmify = require("prometheus.steps.Vmify"),
	PolyVmify = require("prometheus.steps.PolyVmify"),
	KeyedVmify = require("prometheus.steps.KeyedVmify"),
	ConstantArray = require("prometheus.steps.ConstantArray"),
	ProxifyLocals = require("prometheus.steps.ProxifyLocals"),
	AntiTamper = require("prometheus.steps.AntiTamper"),
	EncryptStrings = require("prometheus.steps.EncryptStrings"),
	NumbersToExpressions = require("prometheus.steps.NumbersToExpressions"),
	AddVararg = require("prometheus.steps.AddVararg"),
	WatermarkCheck = require("prometheus.steps.WatermarkCheck"),
	
	StringVault       = require("prometheus.steps.StringVault"),
    DeadCodeInjector  = require("prometheus.steps.DeadCodeInjector"),
    OpaquePredicates  = require("prometheus.steps.OpaquePredicates"),
    AntiHook          = require("prometheus.steps.AntiHook"),
    RuntimeGuard      = require("prometheus.steps.RuntimeGuard"),
    OutputPadding     = require("prometheus.steps.OutputPadding"),
    DualVmify         = require("prometheus.steps.DualVmify"),
    GraphNodePadding  = require("prometheus.steps.GraphNodePadding"),
    BytecodeCompressor  = require("prometheus.steps.BytecodeCompressor"),
}