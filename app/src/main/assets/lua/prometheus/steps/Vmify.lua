-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- Vmify.lua
--
-- This Script provides a Complex Obfuscation Step that will compile the entire Script to  a fully custom bytecode that does not share it's instructions
-- with lua, making it much harder to crack than other lua obfuscators

local Step = require("prometheus.step");
local Compiler = require("prometheus.compiler.compiler");

local Vmify = Step:extend();
Vmify.Description = "Compiles the script into a fully-custom bytecode VM. " ..
    "OpcodeDispatch=true emits a Luraph-style handler-table dispatch instead of " ..
    "if/else chains, making static control-flow analysis much harder. " ..
    "StatefulFakeOps=true (default) injects polymorphic fake handlers that " ..
    "reference real VM registers and posVar, making them indistinguishable " ..
    "from real opcodes to static analysis.";
Vmify.Name = "Vmify";

Vmify.SettingsDescriptor = {
    -- When true, each compiled block becomes an anonymous handler function
    -- stored in a dispatch table (_ops), and the VM loop becomes _ops[pos]().
    -- This mirrors Luraph's opcode-table architecture.
    OpcodeDispatch = {
        type    = "boolean",
        default = false,
    },
    -- When true, uses ChaosDispatch: two-level indirection (_ops[_idx[pos]]())
    -- with an entropy accumulator (_s) and dead-handler chains.
    -- Supersedes OpcodeDispatch when both are true.
    ChaosDispatch = {
        type    = "boolean",
        default = false,
    },
    -- Number of dummy/fake opcode handlers injected alongside real ones.
    -- They are never called but increase table noise and hamper static analysis.
    -- Only used when OpcodeDispatch = true or ChaosDispatch = true.
    FakeOpcodeCount = {
        type    = "number",
        default = 12,
        min     = 0,
        max     = 200,
    },
    -- When true, fake handlers use 5 polymorphic body patterns that reference
    -- real VM state (registers, posVar, conditionals) making them look
    -- indistinguishable from real opcodes to static analysis tools.
    -- Only relevant when OpcodeDispatch = true or ChaosDispatch = true.
    StatefulFakeOps = {
        type    = "boolean",
        default = true,
    },
}

function Vmify:init(_) end

function Vmify:apply(ast)
    local compiler = Compiler:new({
        useOpcodeDispatch = self.OpcodeDispatch,
        useChaosDispatch  = self.ChaosDispatch,
        fakeOpcodeCount   = self.FakeOpcodeCount,
        statefulFakeOps   = self.StatefulFakeOps,
    });
    return compiler:compile(ast);
end

return Vmify;