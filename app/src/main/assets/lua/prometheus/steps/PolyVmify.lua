-- PolyVmify.lua
-- Prometheus obfuscation step: Polymorphic Opcode VM.
--
-- Extends the existing Vmify architecture with a multi-layer math transform
-- pipeline that encodes ALL block IDs at compile time. The dispatch table is
-- keyed by encoded IDs, and every pos-assignment in the bytecode stores the
-- encoded next-block value. No decode is needed at runtime — the table keys
-- and stored pos values use the same encoding convention, so dispatch remains:
--
--   while pos do _ops[pos]() end   ← exactly the same as OpcodeDispatch
--
-- The difference: the numbers stored in `pos` and indexed into `_ops` are
-- outputs of a 2–5 layer affine transform pipeline, making them appear random
-- to static analysis. The transform parameters change every compilation.
--
-- Additional protection:
--   • Real block IDs are scrambled by MathHandlers (pool of 8 invertible
--     transform templates, randomly instantiated per compilation).
--   • Fake opcode handlers use the same encoded-ID space, blending with real
--     ones. Their IDs are also pipeline outputs, indistinguishable in the table.
--   • The pipeline parameters are embedded as integer constants in the
--     generated code, never as named variables.

local Step         = require("prometheus.step")
local Compiler     = require("prometheus.compiler.compiler")
local TransformCodec = require("prometheus.compiler.transform_codec")
local MathHandlers   = require("prometheus.compiler.math_handlers")

local PolyVmify = Step:extend()
PolyVmify.Name        = "PolyVmify"
PolyVmify.Description =
    "Compiles the script into a custom bytecode VM with a compile-time " ..
    "polymorphic opcode encoding pipeline. Block IDs are transformed through " ..
    "N affine layers before storage, making all pos values appear random. " ..
    "Dispatch remains O(1) with no runtime decode overhead."

PolyVmify.SettingsDescriptor = {
    -- Number of affine transform layers (2 = fast, 5 = maximum scrambling)
    PipelineDepth = {
        type    = "number",
        default = 3,
        min     = 2,
        max     = 5,
    },
    -- Use MathHandlers pool (random templates) vs pure TransformCodec affines.
    -- true  = richer variety of transform shapes (recommended)
    -- false = strictly affine layers (faster, simpler)
    UseHandlerPool = {
        type    = "boolean",
        default = true,
    },
    -- Pool size when UseHandlerPool = true (more = more variety between runs)
    HandlerPoolSize = {
        type    = "number",
        default = 64,
        min     = 16,
        max     = 256,
    },
    -- Number of fake/noise opcode handlers injected into the dispatch table.
    FakeOpcodeCount = {
        type    = "number",
        default = 20,
        min     = 0,
        max     = 200,
    },
    -- Stateful fake handlers (reference real VM registers, harder to distinguish)
    StatefulFakeOps = {
        type    = "boolean",
        default = true,
    },
    -- ChaosDispatch: two-level indirection on top of poly encoding (maximum mode)
    ChaosLayer = {
        type    = "boolean",
        default = false,
    },
}

function PolyVmify:init() end

function PolyVmify:apply(ast)
    -- Build the opcode encoding pipeline
    local codec
    if self.UseHandlerPool then
        local pool     = MathHandlers.generatePool(self.HandlerPoolSize)
        local pipeline = MathHandlers.selectPipeline(pool, self.PipelineDepth)
        codec = MathHandlers.buildCodec(pipeline)
    else
        codec = TransformCodec.new(self.PipelineDepth)
    end

    -- Verify codec integrity before using it (catches any edge-case math bugs)
    local ok, err = MathHandlers.verify(codec, 200)
    if not ok then
        error("PolyVmify: codec self-test failed: " .. tostring(err))
    end

    local compiler = Compiler:new({
        usePolyDispatch   = true,
        polyCodec         = codec,
        fakeOpcodeCount   = self.FakeOpcodeCount,
        statefulFakeOps   = self.StatefulFakeOps,
        -- ChaosLayer wraps the poly dispatch in a second indirection table
        useChaosOverPoly  = self.ChaosLayer,
    })

    return compiler:compile(ast)
end

return PolyVmify
