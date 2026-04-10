-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- DualVmify.lua
--
-- Multi-layer VM: compiles the source into an inner VM, then re-compiles
-- that entire inner VM into an outer VM with a different execution model.
--
-- Result: two nested VMs, each requiring independent reverse-engineering.
--
--   Source code
--     └─► Inner VM  (if/else chain dispatch by default)
--           └─► Outer VM  (ChaosDispatch: indirection + entropy state)
--
-- The key property: the outer VM treats the inner VM's runtime code as
-- ordinary Lua and virtualises every operation it contains, including the
-- inner dispatch loop, all upvalue plumbing, and closure factories.
-- An analyst must defeat the outer VM before even seeing the inner VM layer.
--
-- Settings:
--   InnerDispatch       boolean  false = if/else, true = opcode dispatch table
--   InnerChaos          boolean  false (inner uses simpler mode by default)
--   OuterDispatch       boolean  true  (outer uses opcode dispatch)
--   OuterChaos          boolean  true  (outer uses chaos dispatch by default)
--   InnerFakeOpcodeCount  number  8
--   OuterFakeOpcodeCount  number  25

local Step     = require("prometheus.step")
local Compiler = require("prometheus.compiler.compiler")

local DualVmify = Step:extend()
DualVmify.Name        = "DualVmify"
DualVmify.Description =
    "Applies two distinct VM compilation passes: inner VM (if/else or opcode dispatch) " ..
    "wrapped by an outer VM (ChaosDispatch). The outer VM virtualises the entire inner " ..
    "VM runtime, requiring analysts to defeat two independent VM layers."

DualVmify.SettingsDescriptor = {
    InnerDispatch = {
        type    = "boolean",
        default = false,  -- inner: simple if/else chain (cheaper, distinct from outer)
    },
    InnerChaos = {
        type    = "boolean",
        default = false,
    },
    OuterDispatch = {
        type    = "boolean",
        default = true,
    },
    OuterChaos = {
        type    = "boolean",
        default = true,   -- outer: ChaosDispatch (different model from inner)
    },
    InnerFakeOpcodeCount = {
        type    = "number",
        default = 8,
        min     = 0,
        max     = 100,
    },
    OuterFakeOpcodeCount = {
        type    = "number",
        default = 25,
        min     = 0,
        max     = 200,
    },
    -- When true, fake handlers in both layers use stateful polymorphic bodies.
    StatefulFakeOps = {
        type    = "boolean",
        default = true,
    },
}

function DualVmify:init() end

function DualVmify:apply(ast)
    ------------------------------------------------------------
    -- Pass 1: compile source → inner VM AST
    ------------------------------------------------------------
    local innerCompiler = Compiler:new({
        useOpcodeDispatch = self.InnerDispatch,
        useChaosDispatch  = self.InnerChaos,
        fakeOpcodeCount   = self.InnerFakeOpcodeCount,
        statefulFakeOps   = self.StatefulFakeOps,
    })
    local innerAst = innerCompiler:compile(ast)

    ------------------------------------------------------------
    -- Pass 2: compile inner VM AST → outer VM AST
    -- The outer compiler treats the entire inner VM as source code
    -- and virtualises all its operations.
    ------------------------------------------------------------
    local outerCompiler = Compiler:new({
        useOpcodeDispatch = self.OuterDispatch,
        useChaosDispatch  = self.OuterChaos,
        fakeOpcodeCount   = self.OuterFakeOpcodeCount,
        statefulFakeOps   = self.StatefulFakeOps,
    })
    return outerCompiler:compile(innerAst)
end

return DualVmify
